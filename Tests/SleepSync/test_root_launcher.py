#!/usr/bin/env python3
"""Offline RootLauncher contracts; no root, device, or real launchctl required.

Only an audited, path-translated copy executes, with all commands redirected to
stdlib stubs. Fixtures live under reports/ and are removed after each case.
Run: python3 Tests/SleepSync/test_root_launcher.py
"""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import stat
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Modules/SleepSync/RootLauncher.sh"
# Fail closed if new production commands/paths need an additional safety review.
REVIEWED_SHA256 = "aff4f905b3d354931cc566042a34eb200d575a208b312e3ad455d89c00338322"
UUID = "12345678-1234-1234-1234-123456789ABC"
LABEL = "cn.fkj233.watchfix.sleepsync." + UUID
COMMANDS = ("id", "stat", "cat", "chmod", "mv", "launchctl")

STUB = r'''
import json, os, pathlib, stat, sys
root = pathlib.Path(__file__).resolve().parent
fs = root / "fs"
state = json.loads((root / "state.json").read_text())
name, args = pathlib.Path(sys.argv[1]).name, sys.argv[2:]
session = fs / "var/mobile/Library/Application Support/WatchFix/SleepSync/Sessions" / state["uuid"]
job = fs / "Library/LaunchDaemons" / ("cn.fkj233.watchfix.sleepsync." + state["uuid"] + ".plist")
event = dict(command=name, args=args,
             recovery=(session / "recovery-requested").exists(),
             cancel=(session / "cancel-requested").exists(), job_exists=job.exists())
with (root / "commands.jsonl").open("a") as out:
    out.write(json.dumps(event) + "\n")
def local(value):
    p = pathlib.Path(value)
    # Refuse both lexical escapes and symlinks resolving outside the fixture.
    p.relative_to(fs)
    p.resolve().relative_to(fs.resolve())
    return p
try:
    if name == "id":
        assert args == ["-u"]
        print(state.get("uid", 0))
    elif name == "stat":
        assert len(args) == 3 and args[0] in ("-c", "-f")
        p = local(args[2]); info = p.lstat()
        key = str(p.relative_to(fs))
        owner = state.get("owners", {}).get(key, 501 if key.startswith("var/mobile/") else 0)
        mode = "%o" % stat.S_IMODE(info.st_mode)
        values = {"%u": str(owner), "%h": str(info.st_nlink), "%a": mode,
                  "%u:%h": "%s:%s" % (owner, info.st_nlink),
                  "%u:%a": "%s:%s" % (owner, mode),
                  "%d:%i": "%s:%s" % (info.st_dev, info.st_ino), "%s": str(info.st_size)}
        # Keep BSD aliases for reviewed historical sources; neither invokes host stat.
        values.update({"%l": values["%h"], "%Lp": values["%a"],
                       "%u:%l": values["%u:%h"], "%u:%Lp": values["%u:%a"],
                       "%z": values["%s"]})
        print(values[args[1]])
    elif name == "cat":
        assert not args
        sys.stdout.buffer.write(sys.stdin.buffer.read())
    elif name == "chmod":
        assert len(args) == 2 and args[0] == "644"
        os.chmod(local(args[1]), 0o644)
    elif name == "mv":
        assert len(args) == 2
        os.replace(local(args[0]), local(args[1]))
    elif name == "launchctl":
        assert args in (["print", "system/" + state["label"]],
                        ["kickstart", "system/" + state["label"]],
                        ["bootstrap", "system", str(job)])
        if args[0] == "print":
            sys.exit(0 if state.get("loaded") else 1)
        if args[0] == "bootstrap":
            assert local(args[2]).is_file()
    else:
        raise AssertionError("unmocked command: " + name)
except Exception as error:
    print("mock failure: " + repr(error), file=sys.stderr)
    sys.exit(125)
'''


def translate(source, fs, tools):
    if hashlib.sha256(source.encode()).hexdigest() != REVIEWED_SHA256:
        raise ValueError("RootLauncher changed: review command/path isolation before execution")
    original = "PATH=/usr/bin:/bin:/usr/sbin:/sbin:/basebin"
    if source.count(original) != 1:
        raise ValueError("unreviewed PATH")
    source = source.replace(original, "PATH=" + shlex.quote(str(tools)))
    # One pass: /Library inside the mobile path must not be translated twice.
    source = re.sub(r"/var/mobile/Library|/Applications|/Library",
                    lambda match: str(fs) + match[0], source)
    # /bin/sh remains data in ProgramArguments, not a caller-selected executable.
    return source


class LauncherFixture:
    def __init__(self):
        (ROOT / "reports").mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix="root-launcher-", dir=ROOT / "reports")
        self.root = Path(self.temp.name)
        self.fs = self.root / "fs"
        self.tools = self.root / "commands"
        self.tools.mkdir()
        self.base = self.fs / "var/mobile/Library/Application Support/WatchFix/SleepSync"
        self.session = self.base / "Sessions" / UUID
        self.runtime = self.fs / "Applications/WatchFix.app/SleepSyncRuntime"
        self.jobs = self.fs / "Library/LaunchDaemons"
        self.job = self.jobs / (LABEL + ".plist")
        for directory in (self.runtime, self.jobs, self.session / "focus", self.session / "identity"):
            directory.mkdir(parents=True)
        for directory in (self.fs / "Applications", self.runtime.parent, self.runtime,
                          self.fs / "Library", self.jobs):
            directory.chmod(0o755)
        for directory in (self.base, self.base / "Sessions", self.session,
                          self.session / "focus", self.session / "identity"):
            directory.chmod(0o700)
        self.coordinator = self.runtime / "SleepSyncCoordinator.sh"
        self.coordinator.write_text("# fixture data only; never executed\n")
        self.coordinator.chmod(0o644)
        self.state = dict(uuid=UUID, label=LABEL, loaded=False, owners={})
        (self.root / "stub.py").write_text(STUB)
        wrapper = self.root / "command-wrapper"
        wrapper.write_text("#!/bin/sh\nexec " + shlex.quote(sys.executable) + " -S " +
                           shlex.quote(str(self.root / "stub.py")) + ' "$0" "$@"\n')
        wrapper.chmod(0o755)
        for command in COMMANDS:
            (self.tools / command).symlink_to(wrapper)
        self.launcher = self.root / "RootLauncher.sh"
        self.launcher.write_text(translate(SOURCE.read_text(), self.fs, self.tools))

    def close(self):
        self.temp.cleanup()

    def run(self, *args):
        (self.root / "state.json").write_text(json.dumps(self.state))
        return subprocess.run(["/bin/sh", str(self.launcher), *args], cwd=self.root,
                              env={"PATH": str(self.tools), "LC_ALL": "C"},
                              stdin=subprocess.DEVNULL, capture_output=True, text=True,
                              timeout=5)

    def events(self):
        trace = self.root / "commands.jsonl"
        return [json.loads(line) for line in trace.read_text().splitlines()] if trace.exists() else []

    def snapshot(self):
        entries = {}
        for path in sorted(self.fs.rglob("*")):
            info = path.lstat()
            content = (os.readlink(path) if path.is_symlink() else
                       path.read_bytes() if path.is_file() else None)
            entries[str(path.relative_to(self.fs))] = (info.st_mode, info.st_nlink, content)
        return entries


class RootLauncherTests(unittest.TestCase):
    def setUp(self):
        self.fixture = LauncherFixture()
        self.addCleanup(self.fixture.close)

    def assert_rejected_without_writes(self, *args, expected=None):
        fixture = self.fixture
        before = fixture.snapshot()
        result = fixture.run(*args)
        self.assertNotEqual(result.returncode, 0,
                            "launcher accepted unsafe input; trace=" + repr(fixture.events()) +
                            "\n" + result.stdout + result.stderr)
        if expected is not None:
            self.assertEqual(result.returncode, expected, result.stderr)
        self.assertEqual(fixture.snapshot(), before)
        self.assertFalse(any(e["command"] in ("cat", "chmod", "mv", "launchctl")
                             for e in fixture.events()))

    def assert_fixed_job(self):
        fixture = self.fixture
        job = plistlib.loads(fixture.job.read_bytes())
        self.assertEqual(job, {
            "Label": LABEL,
            "ProgramArguments": ["/bin/sh", str(fixture.coordinator), UUID],
            "RunAtLoad": True,
            "KeepAlive": {"SuccessfulExit": False},
            "ThrottleInterval": 3,
        })
        self.assertEqual(stat.S_IMODE(fixture.job.stat().st_mode), 0o644)
        self.assertEqual(fixture.job.parent, fixture.fs / "Library/LaunchDaemons")
        self.assertFalse(list(fixture.jobs.glob(".*.new")))
        return job

    def test_invalid_operation_rejected_before_writes(self):
        for operation in ("stop", "start;touch injected", "../recover"):
            with self.subTest(operation=operation):
                self.assert_rejected_without_writes(operation, UUID, expected=64)
        self.assertTrue(all(e["command"] == "id" for e in self.fixture.events()))

    def test_existing_library_775_does_not_relax_job_directory(self):
        fixture = self.fixture
        (fixture.fs / 'Library').chmod(0o775)
        result = fixture.run('start', UUID)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_fixed_job()
        (fixture.root / 'commands.jsonl').write_text('')
        fixture.jobs.chmod(0o775)
        self.assert_rejected_without_writes('start', UUID)

    def test_invalid_uuid_rejected_before_writes(self):
        for identifier in ("../escape", UUID.lower(), "Z" + UUID[1:], UUID + "/x"):
            with self.subTest(identifier=identifier):
                self.assert_rejected_without_writes("start", identifier, expected=64)
        self.assertTrue(all(e["command"] == "id" for e in self.fixture.events()))

    def test_extra_arguments_and_nonroot_rejected(self):
        self.assert_rejected_without_writes("start", UUID, "/mobile/job.plist")
        self.fixture.state["uid"] = 501
        self.assert_rejected_without_writes("start", UUID)

    def test_mobile_job_is_never_consumed(self):
        fixture = self.fixture
        malicious = plistlib.dumps({"Label": "attacker", "ProgramArguments": ["/evil", "-c", "payload"]})
        for name in ("job.plist", LABEL + ".plist", "request.plist"):
            (fixture.session / name).write_bytes(malicious)
        self.assertEqual(fixture.run("start", UUID).returncode, 0)
        self.assert_fixed_job()
        self.assertFalse((fixture.session / "recovery-requested").exists())
        self.assertEqual([e["args"] for e in fixture.events() if e["command"] == "cat"], [[]])
        self.assertEqual(fixture.events()[-1]["args"], ["bootstrap", "system", str(fixture.job)])
        for name in ("job.plist", LABEL + ".plist", "request.plist"):
            self.assertEqual((fixture.session / name).read_bytes(), malicious)

    def test_recover_before_bootstrap_marks_recovery_and_fixes_program(self):
        fixture = self.fixture
        self.assertEqual(fixture.run("recover", UUID).returncode, 0)
        self.assert_fixed_job()
        events = [e for e in fixture.events() if e["command"] == "launchctl"]
        self.assertEqual([e["args"][0] for e in events], ["print", "bootstrap"])
        self.assertTrue(all(e["recovery"] for e in events))
        self.assertFalse(events[0]["job_exists"])
        marker = fixture.session / "recovery-requested"
        self.assertEqual(marker.read_bytes(), b"")
        self.assertEqual(stat.S_IMODE(marker.stat().st_mode), 0o600)
        self.assertFalse((fixture.session / "cancel-requested").exists())

    def test_loaded_recover_kickstarts_without_killing_live_worker(self):
        fixture = self.fixture
        fixture.state["loaded"] = True
        fixture.job.write_bytes(b"existing trusted root job stays untouched")
        self.assertEqual(fixture.run("recover", UUID).returncode, 0)
        self.assertEqual(fixture.job.read_bytes(), b"existing trusted root job stays untouched")
        events = [e for e in fixture.events() if e["command"] == "launchctl"]
        self.assertEqual([e["args"] for e in events],
                         [["print", "system/" + LABEL], ["kickstart", "system/" + LABEL]])
        self.assertTrue(events[0]["recovery"])
        self.assertTrue(events[1]["recovery"] and events[1]["cancel"])
        self.assertFalse(any(e["command"] in ("cat", "chmod", "mv") for e in fixture.events()))
        self.assertEqual(stat.S_IMODE((fixture.session / "cancel-requested").stat().st_mode), 0o600)

    def test_existing_root_job_is_reused_without_mobile_override(self):
        fixture = self.fixture
        fixture.job.write_bytes(b"root-owned job fixture")
        before = fixture.snapshot()
        self.assertEqual(fixture.run("start", UUID).returncode, 0)
        self.assertEqual(fixture.snapshot(), before)
        self.assertEqual(fixture.events()[-1]["args"], ["bootstrap", "system", str(fixture.job)])

    def test_existing_job_symlink_rejected(self):
        # Regression expectation, not a claim current production already meets it:
        # a non-final failure in line 46's && list can bypass `set -e`.
        fixture = self.fixture
        target = fixture.session / "mobile.plist"
        target.write_bytes(b"untrusted")
        fixture.job.symlink_to(target)
        self.assert_rejected_without_writes("start", UUID)

    def test_existing_job_bad_owner_rejected(self):
        fixture = self.fixture
        fixture.job.write_bytes(b"untrusted")
        fixture.state["owners"][str(fixture.job.relative_to(fixture.fs))] = 501
        self.assert_rejected_without_writes("start", UUID)

    def test_existing_job_hardlink_rejected(self):
        fixture = self.fixture
        target = fixture.session / "mobile.plist"
        target.write_bytes(b"untrusted")
        os.link(target, fixture.job)
        self.assert_rejected_without_writes("start", UUID)

    def test_runtime_bad_mode_rejected(self):
        self.fixture.runtime.chmod(0o777)
        self.assert_rejected_without_writes("start", UUID, expected=78)

    def test_runtime_bad_owner_rejected(self):
        fixture = self.fixture
        fixture.state["owners"][str(fixture.runtime.relative_to(fixture.fs))] = 501
        self.assert_rejected_without_writes("start", UUID)

    def test_runtime_symlink_path_rejected(self):
        fixture = self.fixture
        target = fixture.runtime.with_name("other-runtime")
        fixture.runtime.rename(target)
        fixture.runtime.symlink_to(target, target_is_directory=True)
        self.assert_rejected_without_writes("start", UUID)

    def test_missing_coordinator_path_rejected(self):
        self.fixture.coordinator.unlink()
        self.assert_rejected_without_writes("start", UUID)

    def test_coordinator_bad_owner_rejected(self):
        fixture = self.fixture
        fixture.state["owners"][str(fixture.coordinator.relative_to(fixture.fs))] = 501
        self.assert_rejected_without_writes("start", UUID)

    def test_recovery_marker_symlink_rejected_before_writes(self):
        fixture = self.fixture
        (fixture.session / "recovery-requested").symlink_to(fixture.coordinator)
        self.assert_rejected_without_writes("recover", UUID)


if __name__ == "__main__":
    unittest.main(verbosity=2)
