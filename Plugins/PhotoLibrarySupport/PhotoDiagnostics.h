#pragma once
#import <Foundation/Foundation.h>
#ifndef WF_PHOTO_CONTEXT_DIAGNOSTICS
#define WF_PHOTO_CONTEXT_DIAGNOSTICS 0
#endif
#if WF_PHOTO_CONTEXT_DIAGNOSTICS
#include <roothide.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <mutex>
#include <cstdio>
// Explicit local test only. Closed event vocabulary/numeric values, no payloads.
static void WFPhotoEvent(const char *event, unsigned long value) {
    static std::mutex lock;std::lock_guard<std::mutex> guard(lock);
    static bool attempted=false;static int fd=-1;static unsigned count=0;
    if(!attempted) {
        attempted=true;
        const char *path=jbroot("/var/mobile/WatchFix-photo-context1");
        int dir=path?open(path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC):-1;
        struct stat s;
        if(dir>=0) {
            if(!fstat(dir,&s)&&S_ISDIR(s.st_mode)&&s.st_uid==501&&(s.st_mode&07777)==0700) {
                char name[64];snprintf(name,sizeof(name),"run-%d.log",getpid());
                fd=openat(dir,name,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
                if(fd>=0&&(fstat(fd,&s)||!S_ISREG(s.st_mode)||s.st_uid!=geteuid()||s.st_nlink!=1||(s.st_mode&07777)!=0600)) {close(fd);fd=-1;}
            }
            close(dir);
        }
    }
    if(fd<0||count>=96)return;
    char line[160];int n=snprintf(line,sizeof(line),"event=%s value=%lu uptime=%.3f\n",event,value,NSProcessInfo.processInfo.systemUptime);
    if(n>0&&n<(int)sizeof(line)&&write(fd,line,n)==n)++count;
    else {close(fd);fd=-1;}
}
#else
static inline void WFPhotoEvent(const char *, unsigned long) {}
#endif
