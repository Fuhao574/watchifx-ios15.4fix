# Sleep Sync host tests

Run from the WatchFix repository root on macOS. These tests do not connect to a
phone, run a real launchctl action, or send IDS/Focus messages.

```sh
mkdir -p reports
python3 Tests/SleepSync/test_sleep_sync_coordinator.py
python3 Tests/SleepSync/test_sleep_module_session.py
python3 Tests/SleepSync/test_root_launcher.py
python3 Tests/SleepSync/test_postload_digest.py
# After building Runtime/Focus and Runtime/Identity locally:
python3 Tests/SleepSync/test_runtime_staging.py
xcrun swiftc -warnings-as-errors App/Models/SleepSync.swift Tests/SleepSync/test_sleep_sync_state.swift -o reports/sleep-sync-state-test
reports/sleep-sync-state-test
```

- Coordinator tests translate all fixed paths into private temporary fixtures.
  Every external command is mocked. Unexpected executable paths fail closed.
- Module session tests include the actual production header with mocked boot /
  jbroot and marker owner. They require the actual macOS user UID/EUID 501 and
  do not chown files or execute root commands.
- Swift tests check status projection: ACK is not user-verified success, and an
  unresolved cleanup prevents starting another session.

Generated artifacts stay under ignored `reports/`. No captured user policy,
device diagnostics or firmware is required or included.

Host success does not establish device launch permissions, RootHide post-load
hash acceptance, Watch identity recovery, persistence or notification behavior.
Default builds keep `enabledForDevice=false`. A maintainer may explicitly build a
brand-bound test candidate for a separately authorized device acceptance test;
this is not a public-ready release or implicit permission to install/send.
