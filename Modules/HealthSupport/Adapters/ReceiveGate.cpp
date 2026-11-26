#include "ReceiveGate.hpp"
#include <sys/stat.h>
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>
#include <cerrno>
#include <cstring>
#include <limits>

namespace watchfix { namespace healthsupport {
namespace {
const char journalName[] = "receive-journal-v1";
const char dependencyName[] = "read-dependency-v1";
const char header[] = "WFHS-R1\n";
const char enabledRecord[] = "ENABLED\n";
const char stoppedRecord[] = "STOPPED\n";
const char dependency[] = "WFHS-READ-DEPENDENCY-v1\n";
const off_t maximumJournalBytes = 1024 * 1024;

bool fileIsPrivate(int fd) {
    struct stat st;
    return !fstat(fd,&st) && S_ISREG(st.st_mode) && st.st_uid==geteuid() &&
        (st.st_mode&0777)==0600 && st.st_nlink==1;
}
bool writeAll(int fd,const char *data,std::size_t count) {
    while(count) {
        const ssize_t n=write(fd,data,count);
        if(n<0 && errno==EINTR)continue;
        if(n<=0)return false;
        data+=n;count-=static_cast<std::size_t>(n);
    }
    return true;
}
bool durableFile(int fd) {
    if(fsync(fd))return false;
#ifdef F_FULLFSYNC
    // No fallback on unsupported storage: fail closed rather than claiming
    // hardware-flush durability from fsync alone on Darwin.
    if(fcntl(fd,F_FULLFSYNC))return false;
#endif
    return true;
}
bool readExactly(int fd,char *data,std::size_t count,off_t offset) {
    while(count) {
        const ssize_t n=pread(fd,data,count,offset);
        if(n<0 && errno==EINTR)continue;
        if(n<=0)return false;
        data+=n;count-=static_cast<std::size_t>(n);offset+=n;
    }
    return true;
}
}

struct ReceiveGateState {
    int directory=-1,journal=-1;
    pid_t process=0;
    mutable std::mutex mutex;
    std::condition_variable drained;
    bool healthy=false,enabled=false,dependency=false,stopping=false,stop_persisted=false;
    std::size_t flights=0;
    ~ReceiveGateState() {
        // No native callback/restart or dependency removal at destruction.
        // Leases keep this state and its file lock alive through original calls.
        if(journal>=0)close(journal);
        if(directory>=0)close(directory);
    }
};

namespace {
bool appendRecord(ReceiveGateState &state,const char *record) {
    struct stat st;
    if(!fileIsPrivate(state.journal)||fstat(state.journal,&st)||st.st_size<8||
       st.st_size>maximumJournalBytes-8)return false;
    return writeAll(state.journal,record,8)&&durableFile(state.journal);
}
bool roomForEnableAndStop(ReceiveGateState &state) {
    struct stat st;
    return fileIsPrivate(state.journal)&&!fstat(state.journal,&st)&&st.st_size>=8&&
        st.st_size<=maximumJournalBytes-16;
}
// 0 absent, 1 exact existing marker, -1 invalid/unreadable.
int dependencyState(int directory) {
    int fd=openat(directory,dependencyName,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);
    if(fd<0)return errno==ENOENT?0:-1;
    struct stat st;char bytes[sizeof(dependency)-1];
    const bool valid=fileIsPrivate(fd)&&!fstat(fd,&st)&&st.st_size==sizeof(bytes)&&
        readExactly(fd,bytes,sizeof(bytes),0)&&!std::memcmp(bytes,dependency,sizeof(bytes));
    close(fd);return valid?1:-1;
}
bool ensureDependency(ReceiveGateState &state) {
    const int existing=dependencyState(state.directory);
    if(existing<0)return false;
    if(existing==1) {
        state.dependency=true;
        int fd=openat(state.directory,dependencyName,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);
        if(fd<0)return false;
        const bool valid=fileIsPrivate(fd)&&durableFile(fd);
        close(fd);
        return valid&&!fsync(state.directory);
    }
    // Mark dependency conservatively BEFORE any grant. Never remove or clear it.
    int fd=openat(state.directory,dependencyName,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    if(fd<0)return false;
    state.dependency=true;
    const bool valid=fileIsPrivate(fd)&&writeAll(fd,dependency,sizeof(dependency)-1)&&durableFile(fd);
    close(fd);
    return valid&&!fsync(state.directory);
}
}

std::shared_ptr<ReceiveGate> ReceiveGate::initializeFresh(int fd,ReceiveGateStatus &status) {
    return open(fd,true,status);
}
std::shared_ptr<ReceiveGate> ReceiveGate::openExisting(int fd,ReceiveGateStatus &status) {
    return open(fd,false,status);
}
std::shared_ptr<ReceiveGate> ReceiveGate::open(int fd,bool fresh,ReceiveGateStatus &status) {
    status=ReceiveGateStatus::invalid_directory;
    struct stat st;
    if(fstat(fd,&st)||!S_ISDIR(st.st_mode)||st.st_uid!=geteuid()||(st.st_mode&0777)!=0700)return {};
    auto state=std::make_shared<ReceiveGateState>();
    state->directory=fcntl(fd,F_DUPFD_CLOEXEC,0);state->process=getpid();
    if(state->directory<0){status=ReceiveGateStatus::unavailable;return {};}
    const int flags=O_RDWR|O_APPEND|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK|(fresh?(O_CREAT|O_EXCL):0);
    state->journal=openat(state->directory,journalName,flags,0600);
    status=ReceiveGateStatus::unavailable;
    if(state->journal<0||!fileIsPrivate(state->journal)||flock(state->journal,LOCK_EX|LOCK_NB))return {};
    status=ReceiveGateStatus::invalid_metadata;
    if(fstat(state->journal,&st)||st.st_size>maximumJournalBytes)return {};
    bool ever_enabled=false;
    if(fresh) {
        // An old dependency marker must not be disguised as a fresh install.
        if(dependencyState(state->directory)!=0)return {};
        status=ReceiveGateStatus::persistence_failed;
        if(!writeAll(state->journal,header,8)||!durableFile(state->journal)||fsync(state->directory))return {};
    } else {
        if(st.st_size<8||st.st_size%8)return {};
        char record[8];
        if(!readExactly(state->journal,record,8,0)||std::memcmp(record,header,8))return {};
        for(off_t offset=8;offset<st.st_size;offset+=8) {
            if(!readExactly(state->journal,record,8,offset))return {};
            if(!std::memcmp(record,enabledRecord,8))ever_enabled=true;
            else if(std::memcmp(record,stoppedRecord,8))return {};
        }
        const int marker=dependencyState(state->directory);
        if(marker<0||(ever_enabled&&marker!=1))return {};
        state->dependency=marker==1;
    }
    // Every startup explicitly records stop, even if last process crashed while
    // enabled. Never auto-grant based on yesterday's preferences or journal.
    status=ReceiveGateStatus::persistence_failed;
    if(!appendRecord(*state,stoppedRecord))return {};
    state->healthy=true;state->stop_persisted=true;
    status=ReceiveGateStatus::complete;
    return std::shared_ptr<ReceiveGate>(new ReceiveGate(std::move(state)));
}

ReceiveGateStatus ReceiveGate::enable() {
    if(getpid()!=state_->process)return ReceiveGateStatus::wrong_process;
    std::lock_guard<std::mutex> lock(state_->mutex);
    if(!state_->healthy)return ReceiveGateStatus::persistence_failed;
    if(state_->enabled)return ReceiveGateStatus::complete;
    // Enabling while an earlier stop still drains is not a new safe epoch.
    if(state_->flights||state_->stopping)return ReceiveGateStatus::draining;
    if(!roomForEnableAndStop(*state_))return ReceiveGateStatus::resource_limit;
    if(!ensureDependency(*state_)||!appendRecord(*state_,enabledRecord)) {
        state_->healthy=false;state_->enabled=false;return ReceiveGateStatus::persistence_failed;
    }
    state_->stop_persisted=false;state_->enabled=true;return ReceiveGateStatus::complete;
}
ReceiveLease ReceiveGate::acquire() {
    if(getpid()!=state_->process)return {};
    std::lock_guard<std::mutex> lock(state_->mutex);
    if(!state_->healthy||!state_->enabled||state_->flights==std::numeric_limits<std::size_t>::max())return {};
    ++state_->flights;return ReceiveLease(state_);
}
ReceiveGateStatus ReceiveGate::stop(std::chrono::milliseconds timeout) {
    if(getpid()!=state_->process)return ReceiveGateStatus::wrong_process;
    std::unique_lock<std::mutex> lock(state_->mutex);
    state_->enabled=false;
    if(state_->stopping)return ReceiveGateStatus::draining;
    if(!state_->healthy)return ReceiveGateStatus::persistence_failed;
    if(!state_->stop_persisted) {
        if(!appendRecord(*state_,stoppedRecord)) {state_->healthy=false;return ReceiveGateStatus::persistence_failed;}
        state_->stop_persisted=true;
    }
    if(!state_->flights)return ReceiveGateStatus::complete;
    if(timeout.count()<=0)return ReceiveGateStatus::draining;
    state_->stopping=true;
    const bool complete=state_->drained.wait_for(lock,timeout,[&]{return !state_->flights;});
    state_->stopping=false;
    return complete?ReceiveGateStatus::complete:ReceiveGateStatus::draining;
}
bool ReceiveGate::enabled() const {
    if(getpid()!=state_->process)return false;
    std::lock_guard<std::mutex> lock(state_->mutex);return state_->healthy&&state_->enabled;
}
std::size_t ReceiveGate::inFlight() const {
    if(getpid()!=state_->process)return 0;
    std::lock_guard<std::mutex> lock(state_->mutex);return state_->flights;
}
bool ReceiveGate::ownHistoryHasNoReadDependency() const {
    if(getpid()!=state_->process)return false;
    std::lock_guard<std::mutex> lock(state_->mutex);
    return state_->healthy&&!state_->dependency&&dependencyState(state_->directory)==0;
}
bool ReceiveLease::allowed() const noexcept {return state_&&getpid()==state_->process;}
void ReceiveLease::release() noexcept {
    if(!state_)return;
    if(getpid()==state_->process) {
        std::lock_guard<std::mutex> lock(state_->mutex);
        if(state_->flights)--state_->flights;
        state_->drained.notify_all();
    }
    state_.reset();
}
ReceiveLease::~ReceiveLease(){release();}
ReceiveLease &ReceiveLease::operator=(ReceiveLease &&other) noexcept {
    if(this!=&other){release();state_=std::move(other.state_);}return *this;
}
} }
