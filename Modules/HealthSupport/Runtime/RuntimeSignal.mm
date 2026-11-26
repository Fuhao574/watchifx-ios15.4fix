#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "RuntimeSignal.h"

// Nothing in the healthd sandbox lets a message out: every file write and
// outbound UDP is silently refused, there is no log reader, proc_pidinfo
// refuses other processes' descriptors even as root. Worse, every write into
// this dylib's own static storage (bss and file-backed __DATA, a plain byte
// store included) got healthd killed with OS_REASON_CODESIGNING on 15.4.
// So the line lives on the heap, retained by the Objective-C runtime's
// associative table on a class object, and a root helper reads it through the
// task port (mach_vm_read over private memory looking for "WFHS-STATUS-V1").
static const char WFHSStatusKey = 0;  // its address is the key; never written

void WFHSPublishRuntimeSignal(NSString *line) {
    if (!line.length) {
        return;
    }
    objc_setAssociatedObject([NSString class], &WFHSStatusKey, [line copy],
                             OBJC_ASSOCIATION_RETAIN);
}
