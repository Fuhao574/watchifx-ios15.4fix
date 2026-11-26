#include "ReceiveGate.hpp"
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <cassert>
#include <cstdio>
#include <thread>
#include <future>
#include <cstring>
using namespace watchfix::healthsupport;
static int openDirectory(const char *path) {
    int fd=open(path,O_RDONLY|O_DIRECTORY|O_CLOEXEC);assert(fd>=0);return fd;
}
int main(int argc,char **argv) {
    assert(argc==2||argc==3);int directory=openDirectory(argv[1]);ReceiveGateStatus status;
    if(argc==3) {
        if(!std::strcmp(argv[2],"enable-crash")) {
            auto owner=ReceiveGate::initializeFresh(directory,status);assert(owner);
            assert(owner->enable()==ReceiveGateStatus::complete);
            _exit(0); // deliberate own-process abrupt exit, no destructors
        }
        if(!std::strcmp(argv[2],"restart-check")) {
            auto owner=ReceiveGate::openExisting(directory,status);
            assert(owner&&!owner->enabled()&&!owner->ownHistoryHasNoReadDependency());
            std::puts("PASS restart from enabled journal remains disabled");return 0;
        }
        if(!std::strcmp(argv[2],"reject-existing")) {
            assert(!ReceiveGate::openExisting(directory,status));
            std::puts("PASS invalid existing state rejected without repair");return 0;
        }
        if(!std::strcmp(argv[2],"reject-fresh")) {
            assert(!ReceiveGate::initializeFresh(directory,status));
            std::puts("PASS invalid fresh directory rejected");return 0;
        }
        if(!std::strcmp(argv[2],"near-limit")) {
            auto owner=ReceiveGate::openExisting(directory,status);assert(owner);
            struct stat before,after;assert(!fstatat(directory,"receive-journal-v1",&before,0));
            assert(owner->enable()==ReceiveGateStatus::resource_limit&&!owner->enabled());
            assert(owner->stop(std::chrono::milliseconds(0))==ReceiveGateStatus::complete);
            assert(owner->stop(std::chrono::milliseconds(0))==ReceiveGateStatus::complete);
            assert(!fstatat(directory,"receive-journal-v1",&after,0)&&before.st_size==after.st_size);
            std::puts("PASS capacity reserves stop/repeated disabled stop no append");return 0;
        }
        assert(false);
    }
    auto gate=ReceiveGate::initializeFresh(directory,status);
    assert(gate&&status==ReceiveGateStatus::complete&&!gate->enabled());
    assert(gate->ownHistoryHasNoReadDependency()&&!gate->acquire().allowed());
    struct stat initial,stopped;assert(!fstatat(directory,"receive-journal-v1",&initial,0));
    assert(gate->stop(std::chrono::milliseconds(0))==ReceiveGateStatus::complete);
    assert(!fstatat(directory,"receive-journal-v1",&stopped,0)&&initial.st_size==stopped.st_size);
    auto conflict=ReceiveGate::openExisting(directory,status);
    assert(!conflict&&status==ReceiveGateStatus::unavailable);
    assert(gate->enable()==ReceiveGateStatus::complete&&gate->enabled());
    struct stat marker;assert(fstatat(directory,"read-dependency-v1",&marker,AT_SYMLINK_NOFOLLOW)==0);
    assert(!gate->ownHistoryHasNoReadDependency());
    auto first=gate->acquire(),second=gate->acquire();
    assert(first.allowed()&&second.allowed()&&gate->inFlight()==2);
    assert(gate->stop(std::chrono::milliseconds(0))==ReceiveGateStatus::draining);
    assert(!gate->enabled()&&!gate->acquire().allowed()&&first.allowed());
    assert(gate->enable()==ReceiveGateStatus::draining);
    second=ReceiveLease();assert(gate->inFlight()==1);
    std::promise<void> started;
    auto stopping=std::async(std::launch::async,[&] {
        started.set_value();return gate->stop(std::chrono::seconds(5));
    });
    started.get_future().get();
    first=ReceiveLease();
    assert(stopping.get()==ReceiveGateStatus::complete&&gate->inFlight()==0&&!gate->enabled());
    // Restart ignores enabled journal state. Persisted dependency never clears.
    assert(gate->enable()==ReceiveGateStatus::complete);
    gate.reset();
    gate=ReceiveGate::openExisting(directory,status);
    assert(gate&&status==ReceiveGateStatus::complete&&!gate->enabled()&&!gate->ownHistoryHasNoReadDependency());
    // Lease keeps file lock/state alive even if facade is dropped.
    assert(gate->enable()==ReceiveGateStatus::complete);
    auto tail=gate->acquire();gate.reset();
    assert(!ReceiveGate::openExisting(directory,status)&&status==ReceiveGateStatus::unavailable);
    tail=ReceiveLease();gate=ReceiveGate::openExisting(directory,status);assert(gate);
    // Exception unwinds the lease; native callback won't remain falsely active.
    assert(gate->enable()==ReceiveGateStatus::complete);
    try {auto lease=gate->acquire();assert(lease.allowed());throw 7;} catch(int) {}
    assert(gate->inFlight()==0);
    assert(gate->stop(std::chrono::milliseconds(0))==ReceiveGateStatus::complete);
    gate.reset();
    // Partial journal after a simulated interrupted write: no recovery/truncate,
    // no auto-enable and no missing-data conclusion. Preserve bytes for review.
    int journal=openat(directory,"receive-journal-v1",O_WRONLY|O_APPEND|O_NOFOLLOW);assert(journal>=0);
    assert(write(journal,"ENA",3)==3);close(journal);
    assert(!ReceiveGate::openExisting(directory,status)&&status==ReceiveGateStatus::invalid_metadata);
    close(directory);
    std::puts("PASS durable receive dependency-before-grant/inflight drain/exclusive owner/restart disabled/corruption fails closed");
}
