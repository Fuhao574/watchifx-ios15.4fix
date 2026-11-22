# Sleep Sync host tests

Run from the WatchFix repository root on macOS. These tests do not connect to a
phone, run a real launchctl action, or send IDS/Focus messages.

```sh
mkdir -p reports
python3 Tests/SleepSync/test_sleep_sync_coordinator.py
python3 Tests/SleepSync/test_sleep_module_session.py
python3 Tests/SleepSync/test_root_launcher.py
python3 Tests/SleepSync/test_postload_digest.py
python3 Tests/SleepSync/test_log_directory_owner.py
python3 Tests/SleepSync/test_no_ssh_dependency.py
python3 Tests/SleepSync/test_once3_source_parity.py
python3 Tests/SleepSync/test_actual_module_permit.py
python3 Tests/SleepSync/test_module_registration.py
python3 Tests/SleepSync/test_progress_ui.py
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
  The stage progress is phase-based, not elapsed-time estimation; only finished
  with matched ACK and verified cleanup reaches the final stage.
- Clean-baseline fixtures verify that the module can run without legacy experiment
  files, then quarantine only exact per-session bytes rather than leave them installed.
- Log tests compile both actual production headers. Only effective UID and regular
  file fstat UID are modeled for the root-daemon/mobile-directory case; no host chown.
- No-SSH tests scan the module, App entry path and package dependencies. They assert
  a local launch chain, not real-device acceptance after uninstalling OpenSSH.
- once3 parity tests pin the unchanged converter, identity clone and send/ACK core;
  only diagnostic label normalization is permitted for the wrapper comparison.
- Actual permit tests include the production session and policy headers together,
  with real UID 501 filesystem access, fixed host clocks/boot and mapped root.
  They do not use the coordinator's mock to stand in for the native lease gate.
- Registration tests include the production bridge with mocked plugin state and
  denied persona setup; active/dirty/residual cases cannot unregister the module.
  Settings/remove actions are scoped to Sleep; no normal module is removed.

Generated artifacts stay under ignored `reports/`. No captured user policy,
device diagnostics or firmware is required or included.

Host success does not establish device launch permissions, RootHide post-load
hash acceptance, Watch identity recovery, persistence or notification behavior.
Default builds keep `enabledForDevice=false`. A maintainer may explicitly build a
brand-bound test candidate for a separately authorized device acceptance test;
this is not a public-ready release or implicit permission to install/send.
