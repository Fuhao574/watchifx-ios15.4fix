#ifndef WF_SLEEP_BOUNDED_LOG_H
#define WF_SLEEP_BOUNDED_LOG_H
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <mutex>
#include <sys/stat.h>
#include <unistd.h>

namespace WFSleepDiagnostic {
// Diagnostic writes ONLY, never a policy/configuration/database writer.
class BoundedLog final {
    std::mutex lock_;
    int file_ = -1;
    size_t lines_ = 0, bytes_ = 0;
    dev_t device_{};
    ino_t inode_{};
    bool attempted_ = false;
public:
    static constexpr size_t MaxLines = 256, MaxBytes = 128*1024, MaxLine = 1024;
    BoundedLog() = default;
    BoundedLog(const BoundedLog &) = delete;
    ~BoundedLog() { if (file_ >= 0) close(file_); }
    bool Open(const char *directoryPath) {
        std::lock_guard<std::mutex> guard(lock_);
        if (attempted_) return false;
        attempted_ = true;
        if (!directoryPath) return false;
        int directory = open(directoryPath, O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
        if (directory < 0) return false;
        struct stat st;
        if (fstat(directory,&st) || !S_ISDIR(st.st_mode) || st.st_uid!=geteuid() || (st.st_mode&07777)!=0700) {
            close(directory); return false;
        }
        char name[64]; snprintf(name,sizeof(name),"run-%d.log",getpid());
        file_ = openat(directory,name,O_WRONLY|O_APPEND|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK,0600);
        close(directory);
        if (file_ < 0) return false;
        if (fstat(file_,&st) || !S_ISREG(st.st_mode) || st.st_uid!=geteuid() ||
            (st.st_mode&07777)!=0600 || st.st_nlink!=1 || st.st_size!=0) {
            close(file_); file_=-1; return false;
        }
        device_=st.st_dev; inode_=st.st_ino;
        return true;
    }
    bool Append(const char *text) {
        std::lock_guard<std::mutex> guard(lock_);
        if (file_<0 || !text || lines_>=MaxLines) return false;
        char line[MaxLine];
        size_t n=std::min(strnlen(text,MaxLine),MaxLine-2);
        for(size_t i=0;i<n;++i) {
            unsigned char c=text[i];
            line[i]=(c>=32 && c<127) ? c : '?';
        }
        line[n++]='\n';
        struct stat st;
        if (bytes_+n>MaxBytes || fstat(file_,&st) || st.st_dev!=device_ || st.st_ino!=inode_ ||
            !S_ISREG(st.st_mode) || st.st_uid!=geteuid() || (st.st_mode&07777)!=0600 ||
            st.st_nlink!=1 || st.st_size<0 || static_cast<size_t>(st.st_size)!=bytes_) {
            close(file_);file_=-1;return false;
        }
        ssize_t written=write(file_,line,n);
        if (written!=static_cast<ssize_t>(n)) {close(file_);file_=-1;return false;}
        bytes_+=n; ++lines_;
        return true;
    }
};
}
#endif
