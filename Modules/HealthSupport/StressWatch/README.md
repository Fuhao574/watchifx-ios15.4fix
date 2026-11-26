# StressWatch low-overhead companion (HealthSupport setting)

Preserves the two v1.3 fixes accepted on 2026-11-26: one app-local converter
availability call replacement, plus SleepAnalysis raw 3..5 decoder acceptance.
Only iOS 15.4 / build 19E241 and the audited StressWatch UUID/class offset/code
hashes. A mismatch fails closed. It does not unlock Pro.

## Removed test costs

- No sample-query hook, result/sample enumeration, per-query lock or counts.
- No JSON file, chmod, window clock checks, timer, network or Watch connection.
- No hashing the entire 29 MB app twice. Once per process it hashes three
  immutable code windows totalling 2,500 bytes, after exact UUID/header/class
  identity. Unlike v1.3 it does not assert full on-disk executable identity;
  bytes elsewhere may differ, so this is narrower code identity, not a full
  executable integrity guarantee. Do not weaken the code checks to add versions.
- Four once-set uint32 status fields remain in this app's library memory for
  bounded verification; no per-sample diagnostics. Hook overhead and native
  stage/model work remain, so this is not a claim of literally zero energy.

## Integration

The plugin Makefile bundles `StressWatchCompatibility.dylib`, `Filter.plist`
and generated `Identity.plist` below `HealthSupport.wffix/StressWatch`. None are
installed automatically by dpkg, loaded into WatchFix, or linked into healthd.
The HealthSupport settings toggle installs/removes only
`WatchFix_HealthSupportStressWatch.{dylib,plist}`. Existing v1.3 standalone pair
is recognized and migrated on explicit settings save, with code/filter checks
and rollback; an unfamiliar pair is refused rather than overwritten.

UI state reports installed/disabled, not a live-process activation receipt.
The control adopts existing v1.3's enabled state until explicitly saved. New
users default off. Switch then **Save**, fully quit/reopen StressWatch. No
automatic app or healthd restart. Turning this off preserves the healthd
HealthSupport protection/acceptance markers and SleepSync configuration.
Removing HealthSupport's new-stage reception is still its existing separate
operation; the optional StressWatch control is independent and can be disabled
from this settings page without removing healthd protection.

On failure the previous files and saved setting are restored when possible;
incomplete rollback returns an error and retains the private temporary backup.
This is not a crash-atomic filesystem transaction; keep StressWatch closed
while changing it, and do not claim power-loss recovery is tested.

## Verification status

2026-11-26: device settings Save installed the companion with matching payload
hashes and removed both legacy v1.3 injection files. User subsequently reported
“已测试stresswatch正常” after the requested app-relaunch test. Record this as
user functional acceptance; no independent new-process memory status readback
was performed. Full device off/relaunch/on cycle, next-night refresh and power
measurement remain untested.

Local build/tests do not count as new device functional acceptance. The accepted
v1.3 backup and original accepted WatchFix deb remain preserved for rollback. No
SleepSync branding, App entitlement or LaunchServices regression is acceptable.
