#!/usr/bin/env python3
"""Compile/include production ModuleSession.h and exec isolated macOS fixtures.

No device, launchctl, root/chown, production file changes or fork-inheritance tests.
Generated roothide stub, binary and fixture trees live temporarily under reports/.
Only identity-enabled's fstatat owner and kern.bootsessionuuid are simulated.
"""
import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path(__file__).with_suffix(".mm")
HEADER = ROOT / "Modules/SleepSync/ModuleSession.h"
REPORT = ROOT / "reports/sleep-module-session-tests.json"
SCENARIOS = (
    "valid", "selector_switch", "missing_after", "corrupt_after", "empty_after",
    "missing_startup", "corrupt_startup", "invalid_boot", "invalid_uuid",
    "invalid_lowercase_uuid", "invalid_schema", "invalid_extra_key", "invalid_expired",
    "invalid_future", "invalid_long_lease", "invalid_time_type", "selector_mode",
    "selector_symlink", "selector_hardlink", "root_mode", "sessions_mode", "session_mode",
    "directory_replace", "session_symlink", "sessions_symlink", "root_symlink",
    "child_symlink", "cancel", "closed", "marker_bad_mode", "marker_bad_owner",
    "marker_mobile_owner", "marker_symlink", "marker_hardlink", "marker_directory",
    "identity_once", "receipt_existing",
)
STUB = """#pragma once
// Host fixture mapping, implemented in test_sleep_module_session.mm.
const char *WFHostJBRoot(const char *path);
#define jbroot(path) WFHostJBRoot(path)
"""


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def snapshot(directory):
    """Failure-only lstat snapshot: no symlink traversal, no secret file contents."""
    records = []
    for parent, dirs, files in os.walk(directory, followlinks=False):
        for name in sorted(dirs + files):
            path = Path(parent) / name
            st = path.lstat()
            records.append({"path": str(path.relative_to(directory)), "uid": st.st_uid,
                            "mode": oct(st.st_mode), "inode": st.st_ino,
                            "nlink": st.st_nlink, "size": st.st_size,
                            "symlink": os.readlink(path) if path.is_symlink() else None})
    return records


def main():
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    before = digest(HEADER)
    report = {
        "generatedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "scope": "offline macOS host; production header directly included; independent exec per scenario",
        "productionHeader": str(HEADER.relative_to(ROOT)), "productionHeaderSHA256": before,
        "testSourceSHA256": digest(SOURCE), "uid": os.getuid(), "euid": os.geteuid(),
        "simulations": ["jbroot maps only SleepSync root to the scenario fixture",
                        "sysctlbyname returns fixed boot UUID",
                        "fstatat changes only identity-enabled st_uid; all modes/types/links remain real"],
        "notTested": ["device execution", "bridge snapshot/launcher", "fork inheritance",
                      "adversarial concurrent TOCTOU", "real root-owned marker access"],
        "scenarios": [], "errors": [],
    }
    try:
        if os.getuid() != 501 or os.geteuid() != 501:
            raise RuntimeError("requires actual uid/euid 501; will not chown or fake session ownership")
        sdk_result = subprocess.run(["xcrun", "--sdk", "macosx", "--show-sdk-path"],
                                    capture_output=True, text=True, timeout=30)
        if sdk_result.returncode:
            raise RuntimeError(f"SDK lookup failed: {sdk_result.stderr}")
        sdk = sdk_result.stdout.strip()
        report["sdk"] = sdk
        with tempfile.TemporaryDirectory(prefix="sleep-module-session-", dir=REPORT.parent) as temp:
            work = Path(temp)
            (work / "roothide.h").write_text(STUB)
            binary = work / "module-session-host"
            command = ["xcrun", "--sdk", "macosx", "clang++", "-std=c++17", "-fobjc-arc",
                       "-fblocks", "-isysroot", sdk, "-I", str(work), "-framework", "Foundation",
                       str(SOURCE), "-o", str(binary)]
            compiled = subprocess.run(command, capture_output=True, text=True, timeout=120)
            report["compile"] = {"command": command, "returncode": compiled.returncode,
                                 "stdout": compiled.stdout, "stderr": compiled.stderr}
            if compiled.returncode:
                raise RuntimeError("host harness compilation failed; see compile.stderr")
            for scenario in SCENARIOS:
                fixture = work / scenario
                fixture.mkdir(mode=0o700)
                try:
                    completed = subprocess.run([str(binary), scenario, str(fixture / "SleepSync")],
                                               capture_output=True, text=True, timeout=15)
                    try:
                        result = json.loads(completed.stdout)
                    except json.JSONDecodeError:
                        result = {"scenario": scenario, "passed": False,
                                  "errors": ["invalid/missing JSON result"], "stdout": completed.stdout}
                    result["returncode"] = completed.returncode
                    result["stderr"] = completed.stderr
                    result["passed"] = bool(result.get("passed") and completed.returncode == 0)
                except subprocess.TimeoutExpired as exc:
                    result = {"scenario": scenario, "passed": False, "errors": [str(exc)]}
                if not result["passed"]:
                    result["filesystemSnapshot"] = snapshot(fixture)
                report["scenarios"].append(result)
                print(f"{'PASS' if result['passed'] else 'FAIL'} {scenario}")
    except Exception as exc:
        report["errors"].append(f"{type(exc).__name__}: {exc}")
    report["productionHeaderUnchanged"] = digest(HEADER) == before
    report["total"] = len(report["scenarios"])
    report["passedCount"] = sum(item["passed"] for item in report["scenarios"])
    report["passed"] = (not report["errors"] and report["productionHeaderUnchanged"]
                        and report["total"] == len(SCENARIOS)
                        and report["passedCount"] == report["total"])
    REPORT.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(f"{report['passedCount']}/{len(SCENARIOS)} passed; report: {REPORT.relative_to(ROOT)}")
    for error in report["errors"]:
        print(error)
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
