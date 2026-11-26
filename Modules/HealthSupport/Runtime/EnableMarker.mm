#import "EnableMarker.h"

#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

static NSString *const WFHSEnablePrefix = @"WFHS-ENABLE-V1 ";
static const size_t WFHSEnableMaximumSize = 128;

NSString *WFHSEnableMarkerStateName(WFHSEnableMarkerState state) {
    switch (state) {
        case WFHSEnableMarkerAbsent: return @"absent";
        case WFHSEnableMarkerValid: return @"valid";
        case WFHSEnableMarkerNotRegular: return @"not-regular";
        case WFHSEnableMarkerWrongOwner: return @"wrong-owner";
        case WFHSEnableMarkerWrongMode: return @"wrong-mode";
        case WFHSEnableMarkerWrongSize: return @"wrong-size";
        case WFHSEnableMarkerWrongContent: return @"wrong-content";
        case WFHSEnableMarkerReadFailed: return @"read-failed";
    }
    return @"unknown";
}

WFHSEnableMarkerState WFHSReadEnableMarker(NSString *path, NSString *expectedBuild) {
    if (!path.length || !expectedBuild.length) {
        return WFHSEnableMarkerReadFailed;
    }
    const char *name = path.fileSystemRepresentation;
    if (!name) {
        return WFHSEnableMarkerReadFailed;
    }
    struct stat linkInfo;
    if (lstat(name, &linkInfo) != 0) {
        return errno == ENOENT ? WFHSEnableMarkerAbsent : WFHSEnableMarkerReadFailed;
    }
    // lstat already rejected symlinks; O_NOFOLLOW closes the replace-after-lstat
    // window, and fstat re-checks the object we actually opened.
    if (!S_ISREG(linkInfo.st_mode)) {
        return WFHSEnableMarkerNotRegular;
    }
    int descriptor = open(name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (descriptor < 0) {
        return errno == ENOENT ? WFHSEnableMarkerAbsent : WFHSEnableMarkerReadFailed;
    }
    WFHSEnableMarkerState state = WFHSEnableMarkerReadFailed;
    bool haveContent = false;
    char buffer[WFHSEnableMaximumSize + 1];
    ssize_t length = 0;
    struct stat info;
    if (fstat(descriptor, &info) == 0) {
        if (!S_ISREG(info.st_mode) || info.st_nlink != 1) {
            state = WFHSEnableMarkerNotRegular;
        } else if (info.st_uid != geteuid()) {
            state = WFHSEnableMarkerWrongOwner;
        } else if ((info.st_mode & 07777) != 0600) {
            state = WFHSEnableMarkerWrongMode;
        } else if (info.st_size <= 0 || (size_t)info.st_size > WFHSEnableMaximumSize) {
            state = WFHSEnableMarkerWrongSize;
        } else {
            length = read(descriptor, buffer, WFHSEnableMaximumSize);
            if (length > 0) {
                state = WFHSEnableMarkerWrongContent;
                haveContent = true;
            }
        }
    }
    close(descriptor);
    if (!haveContent) {
        return state;
    }
    NSString *text = [[NSString alloc] initWithBytes:buffer length:(NSUInteger)length
                                             encoding:NSUTF8StringEncoding];
    if (!text) {
        return WFHSEnableMarkerWrongContent;
    }
    NSString *expected = [WFHSEnablePrefix stringByAppendingString:expectedBuild];
    if ([text isEqualToString:expected] ||
        [text isEqualToString:[expected stringByAppendingString:@"\n"]]) {
        return WFHSEnableMarkerValid;
    }
    return WFHSEnableMarkerWrongContent;
}
