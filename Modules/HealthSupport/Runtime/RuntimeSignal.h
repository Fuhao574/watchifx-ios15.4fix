#ifndef WFHS_RUNTIME_SIGNAL
#define WFHS_RUNTIME_SIGNAL

#ifdef __cplusplus
extern "C" {
#endif

// Publishes the status line where an external observer can read it.
//
// The healthd sandbox rejects every file write and outbound UDP, the device
// has no log reader, proc_pidinfo refuses other processes' descriptors even
// as root, and writing into this dylib's own data segment gets healthd killed
// with OS_REASON_CODESIGNING (all observed on 15.4). A later A/B with the same
// sources showed that kill is caused by injecting a fat (arm64+arm64e) file
// after ldid; a thin arm64e slice loads cleanly. The line is therefore kept on
// the heap (associated object) rather than in static storage; a root helper
// reads it through the task port (task_for_pid as plain arm64, then
// mach_vm_read over private/COW memory looking for "WFHS-STATUS-V1").
void WFHSPublishRuntimeSignal(NSString *line);

#ifdef __cplusplus
}
#endif

#endif
