#!/usr/bin/env python3
"""Offline worker contracts and filesystem/command simulation. Never runs device tools.

Production has NO test-root environment override. Only a reviewed copy under reports/
has its fixed paths and baseline digests translated to fixture files. Every external
command is redirected to a fixture-local client and persistent Python dispatcher;
shell builtins execute in /bin/sh on the host. No device command is executed.
Run from repo: python3 Tests/SleepSync/test_sleep_sync_coordinator.py
"""
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import re
import socket
import struct
import subprocess
import tempfile
import threading
import time
import types
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Modules/SleepSync/SleepSyncCoordinator.sh"
UUID = "12345678-1234-1234-1234-123456789ABC"
HELLO = "WatchFix_HelloReadOnlyObserver"
FOCUS = "WatchFix_FocusConfigCompatibility"
NAMES = [f"{stem}.{ext}" for stem in (HELLO, FOCUS) for ext in ("dylib", "plist")]
BASELINES = [
    "d68e8f6d975229167566fc0a8b81d5068d11ea30a63b1b989ffeced2db17a2cf",
    "7a0735ef9b15554e41a7ec835567795bbf18c4f5716551ddd1a837ab5856b790",
    "1f4fb3cff36e2293607c3ae686e9ada3cb492d7fab43372132e631a05e3b8b4a",
    "10d0ed6e2671c0be7ac4dedda4ba4aa890a5103581208ec383dfd1d9b2c8346a",
]
TOOLS = ("/usr/bin/id", "/usr/bin/stat", "/usr/bin/sha256sum", "/usr/bin/date",
         "/usr/sbin/sysctl", "/bin/mkdir", "/bin/cat", "/bin/chmod", "/bin/mv",
         "/bin/cp", "/bin/ps", "/usr/bin/head", "/bin/sleep", "/usr/sbin/chown")

# Executed in a persistent fixture-local dispatcher, never as a subprocess.
STUB = r'''
import hashlib, json, os, pathlib, shutil, stat
root = pathlib.Path(__file__).resolve().parent.parent
statefile = root / "state.json"
s = json.loads(statefile.read_text())
name = pathlib.Path(sys.argv[0]).name
a = sys.argv[1:]
def save(): statefile.write_text(json.dumps(s))
def log(text):
    with (root / "commands.jsonl").open("a") as f:
        f.write(json.dumps([name, *a, text]) + "\n")
def fail(): save(); sys.exit(1)
session = root / "fs/var/mobile/Library/Application Support/WatchFix/SleepSync/Sessions" / s["uuid"]
def identity():
    enabled = (session / "identity-enabled").exists()
    event = "identity-result" if enabled else "neutral-result"
    detail = 15 if enabled else 7
    if s.get("no_identity"): return
    (session / "identity" / ("run-%s.log" % s["identity_pid"])).write_text(
        "event=%s seq=1 depth=1 count=1 route=2 detail=%s returned=1\n" % (event, detail))
def focus():
    path = session / "focus" / ("run-%s.log" % s["focus_pid"])
    scenario = s.get("scenario", "success")
    if scenario == "no_source": return
    if scenario == "oversized": path.write_text("x" * 32769); return
    if scenario == "other_session":
        (root / "old-session.log").write_text("SLEEPMODULE1 adding ONE Sleep v11 update; original native batch/completion preserved\n")
        return
    text = ""
    if scenario != "ack_only":
        text += "SLEEPMODULE1 adding ONE Sleep v11 update; original native batch/completion preserved\n"
    if scenario != "no_ack":
        text += "SLEEPMODULE1 real v11/12 ACK metadata matched; observation only, native acceptance/storage and transaction causality unverified\n"
    if scenario == "success": text += "WATCH-SLEEP-EXPORT status=OBSERVED\n"
    path.write_text(text)
try:
    if name == "id": print(0)
    elif name == "stat":
        p = pathlib.Path(a[-1]); st = p.lstat(); fmt = a[1]
        mobile = p in (session, session / "identity", session / "focus",
                       session / "start-unix", session / "deadline-unix")
        uid = 501 if mobile else 0
        uid = s.get("owners", {}).get(str(p.relative_to(root)), uid)
        values = {"%u": str(uid), "%l": str(st.st_nlink), "%Lp": oct(stat.S_IMODE(st.st_mode))[2:],
                  "%u:%Lp": "%s:%o" % (uid, stat.S_IMODE(st.st_mode)),
                  "%d:%i": "%s:%s" % (st.st_dev, st.st_ino), "%z": str(st.st_size)}
        print(values[fmt])
    elif name == "sha256sum":
        p = pathlib.Path(a[0]); print(hashlib.sha256(p.read_bytes()).hexdigest(), str(p))
    elif name == "date": print(s["now"])
    elif name == "sysctl": print("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
    elif name == "mkdir": pathlib.Path(a[0]).mkdir(mode=0o700)
    elif name == "chmod": os.chmod(a[1], int(a[0], 8))
    elif name == "chown": log("mock mobile ownership")
    elif name == "cat":
        if a: sys.stdout.buffer.write(pathlib.Path(a[0]).read_bytes())
        else: sys.stdout.buffer.write(sys.stdin.buffer.read())
    elif name == "cp":
        log("copy")
        if s.get("fail_cp") and s["fail_cp"] in a[0]: fail()
        shutil.copyfile(a[0], a[1])
    elif name == "mv":
        log("move"); src, dst = a[-2:]; os.replace(src, dst)
    elif name == "ps":
        print("%s /usr/libexec/identityservicesd" % s["identity_pid"])
        print("%s /usr/sbin/donotdisturbd" % s["focus_pid"])
        print("900 /usr/libexec/notidentityservicesd")
    elif name == "head":
        if len(a) > 2: data = pathlib.Path(a[2]).read_bytes()
        else: data = sys.stdin.buffer.read()
        data = data[:int(a[1])] if a[0] == "-c" else b"".join(data.splitlines(keepends=True)[:int(a[1])])
        sys.stdout.buffer.write(data)
    elif name == "sleep": s["now"] += int(a[0]) * 30; save()
    elif name == "launchctl":
        log("restart")
        daemon = a[-1].split("/")[-1]
        s["restarts"].append(daemon)
        if len(s["restarts"]) == s.get("fail_restart"): fail()
        if daemon == "com.apple.identityservicesd":
            s["identity_pid"] += 1; identity()
        elif daemon == "com.apple.donotdisturbd":
            s["focus_pid"] += 1
            if (session / "focus/policy-grant.plist").exists(): focus()
        else: raise RuntimeError("non-whitelisted daemon")
        save()
    else: raise RuntimeError("unmocked executable " + name)
except (OSError, KeyError) as e:
    print(str(e), file=sys.stderr); sys.exit(1)
'''


# A tiny host-only transport avoids hundreds of interpreter startups per worker.
# All filesystem/daemon semantics still live in STUB above; this client can only
# connect to the fixture socket. It never execs launchctl, sleep, or another tool.
CLIENT = r'''
#include <arpa/inet.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>
static void die(void) { perror("mock transport"); exit(125); }
static void transfer(int fd, void *p, size_t n, int writing) {
    char *b = p;
    while (n) {
        ssize_t k = writing ? write(fd, b, n) : read(fd, b, n);
        if (k < 0 && errno == EINTR) continue;
        if (k <= 0) die();
        b += k; n -= (size_t)k;
    }
}
static void number(int fd, uint32_t n) {
    n = htonl(n); transfer(fd, &n, sizeof n, 1);
}
static uint32_t receive_number(int fd) {
    uint32_t n; transfer(fd, &n, sizeof n, 0); return ntohl(n);
}
static void output(int fd, int dest) {
    uint32_t n = receive_number(fd);
    if (n > 1048576) exit(125);
    char buf[8192];
    while (n) {
        size_t k = n < sizeof buf ? n : sizeof buf;
        transfer(fd, buf, k, 0); transfer(dest, buf, k, 1); n -= k;
    }
}
int main(int argc, char **argv) {
    const char *path = getenv("WF_MOCK_SOCKET");
    struct sockaddr_un addr = {0}; addr.sun_family = AF_UNIX;
    if (!path || strlen(path) >= sizeof addr.sun_path) return 125;
    strcpy(addr.sun_path, path);
    const char *name = strrchr(argv[0], '/'); name = name ? name + 1 : argv[0];
    char *input = malloc(1048576); size_t used = 0;
    if (!input) die();
    if ((!strcmp(name, "cat") && argc == 1) ||
        (!strcmp(name, "head") && argc == 3)) {
        while (used < 1048576) {
            ssize_t k = read(STDIN_FILENO, input + used, 1048576 - used);
            if (k < 0 && errno == EINTR) continue;
            if (k < 0) die();
            if (!k) break;
            used += (size_t)k;
        }
        if (used == 1048576) return 125;
    }
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) die();
    struct timeval timeout = {10, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof timeout);
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof timeout);
    if (connect(fd, (struct sockaddr *)&addr, sizeof addr)) die();
    number(fd, (uint32_t)argc);
    for (int i = 0; i < argc; ++i) {
        number(fd, (uint32_t)strlen(argv[i]));
        transfer(fd, argv[i], strlen(argv[i]), 1);
    }
    number(fd, (uint32_t)used); transfer(fd, input, used, 1); free(input);
    int code = (int)receive_number(fd);
    output(fd, STDOUT_FILENO); output(fd, STDERR_FILENO);
    close(fd); return code;
}
'''
CLIENT_BYTES = None
STUB_CODE = compile(STUB, "<offline-command-dispatcher>", "exec")


def translate_source(source, tools, fs, originals):
    # Accept the two audited production PATH variants, not an unchecked literal
    # replacement that silently falls back to host launchctl when PATH changes.
    paths = re.findall(r"(?m)^PATH=.*$", source)
    if len(paths) != 1 or not re.fullmatch(
            r"PATH=/usr/bin:/bin:/usr/sbin:/sbin(?::/basebin)?", paths[0]):
        raise ValueError("unreviewed production PATH; refusing to execute fixture")
    executable_pattern = r"(?<![\w/])/(?:usr/(?:s?bin)|s?bin|basebin)/[\w.-]+"
    unknown = set(re.findall(executable_pattern, source)) - set(TOOLS) - {"/bin/sh"}
    if unknown:
        raise ValueError("unreviewed executable paths: " + repr(sorted(unknown)))
    source = source.replace(paths[0], "PATH=" + str(tools))
    for path in TOOLS:
        source = source.replace(path, str(tools / Path(path).name))
    source = re.sub(r"/var/mobile|/Applications|/usr/lib/TweakInject|/usr/lib|/usr(?=[ /;])",
                    lambda m: str(fs) + m[0], source)
    for old, name in zip(BASELINES, NAMES):
        source = source.replace(old, hashlib.sha256(originals[name]).hexdigest())
    remaining = re.findall(executable_pattern, source)
    if remaining != ["/bin/sh"]:
        raise ValueError("unmocked absolute executable paths: " + repr(remaining))
    return source


class WorkerFixture:
    def __init__(self, **state):
        global CLIENT_BYTES
        # Short enough for macOS sockaddr_un.sun_path's 104-byte limit.
        self.temp = tempfile.TemporaryDirectory(prefix="ssc-", dir=ROOT / "reports")
        self.root = Path(self.temp.name)
        self.fs = self.root / "fs"
        self.session = self.fs / "var/mobile/Library/Application Support/WatchFix/SleepSync/Sessions" / UUID
        self.target = self.fs / "usr/lib/TweakInject"
        self.runtime = self.fs / "Applications/WatchFix.app/SleepSyncRuntime"
        for p in (self.session / "identity", self.session / "focus", self.target, self.runtime):
            p.mkdir(parents=True, mode=0o755)
        for p in (self.session, self.session / "identity", self.session / "focus"):
            p.chmod(0o700)
        self.originals = {n: ("baseline-" + n).encode() for n in NAMES}
        for n in NAMES:
            (self.target / n).write_bytes(self.originals[n])
            (self.runtime / n).write_bytes(("candidate-" + n).encode())
        self.manifest = self.runtime / "payload.sha256"
        self.manifest.write_text("".join(hashlib.sha256((self.runtime / n).read_bytes()).hexdigest() + "  " + n + "\n" for n in NAMES))
        self.postload_manifest = self.runtime / "postload.sha256"
        self.postload_manifest.write_bytes(self.manifest.read_bytes())
        initial = dict(uuid=UUID, now=1800000000, identity_pid=100, focus_pid=200, restarts=[])
        initial.update(state)
        self.set_state(initial)
        for name, value in (("start-unix", initial["now"]),
                            ("deadline-unix", initial["now"] + 420)):
            path = self.session / name
            path.write_text(str(value) + "\n")
            path.chmod(0o600)
        tools = self.root / "tools"
        tools.mkdir()
        stub = tools / "dispatcher"
        if CLIENT_BYTES is None:
            client_source = tools / "client.c"
            client_source.write_text(CLIENT)
            subprocess.run(["/usr/bin/clang", "-O2", "-Wall", "-Wextra", str(client_source),
                            "-o", str(stub)], check=True, capture_output=True, timeout=15)
            CLIENT_BYTES = stub.read_bytes()
        else:
            stub.write_bytes(CLIENT_BYTES)
        stub.chmod(0o755)
        for name in [Path(p).name for p in TOOLS] + ["launchctl"]:
            (tools / name).symlink_to(stub.name)
        source = translate_source(SCRIPT.read_text(), tools, self.fs, self.originals)
        self.worker = self.root / "translated-worker.sh"
        # Test-only logical clock advances faster; bounded production polls unchanged.
        self.worker.write_text(source)
        self.socket_path = self.root / "mock.sock"
        self.socket_bind_path = os.path.relpath(self.socket_path, Path.cwd())
        if len(os.fsencode(self.socket_bind_path)) >= 104:
            raise ValueError("fixture socket path too long")
        self.command_counts = {}
        self.dispatch_errors = []

    def dispatch(self, connection):
        def receive(n):
            chunks = bytearray()
            while len(chunks) < n:
                data = connection.recv(n - len(chunks))
                if not data:
                    raise RuntimeError("truncated mock request")
                chunks.extend(data)
            return bytes(chunks)

        def number():
            return struct.unpack("!I", receive(4))[0]

        def blob():
            size = number()
            if size > 1048576:
                raise RuntimeError("oversized mock request")
            return receive(size)

        argc = number()
        if not 1 <= argc <= 16:
            raise RuntimeError("invalid mock argc")
        argv = [os.fsdecode(blob()) for _ in range(argc)]
        name = Path(argv[0]).name
        if name not in {Path(p).name for p in TOOLS} | {"launchctl"}:
            raise RuntimeError("unmocked command " + name)
        self.command_counts[name] = self.command_counts.get(name, 0) + 1
        stdin = io.TextIOWrapper(io.BytesIO(blob()), encoding="utf-8")
        stdout = io.TextIOWrapper(io.BytesIO(), encoding="utf-8")
        stderr = io.TextIOWrapper(io.BytesIO(), encoding="utf-8")

        def exit_stub(code=0):
            raise SystemExit(code)

        mock_sys = types.SimpleNamespace(argv=argv, stdin=stdin, stdout=stdout,
                                         stderr=stderr, exit=exit_stub)
        code = 0
        try:
            exec(STUB_CODE, {"__file__": str(self.root / "tools/dispatcher"),
                             "sys": mock_sys, "print": lambda *a, **kw:
                             print(*a, **({"file": stdout} | kw))})
        except SystemExit as e:
            code = e.code
        stdout.flush()
        stderr.flush()
        out, err = stdout.buffer.getvalue(), stderr.buffer.getvalue()
        connection.sendall(struct.pack("!II", code, len(out)) + out +
                           struct.pack("!I", len(err)) + err)

    def set_state(self, value):
        (self.root / "state.json").write_text(json.dumps(value))

    @property
    def state(self):
        return json.loads((self.root / "state.json").read_text())

    @property
    def status(self):
        return plistlib.loads((self.session / "status.plist").read_bytes())

    def run(self, *args):
        stop = threading.Event()
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
            listener.bind(self.socket_bind_path)
            listener.listen(8)
            listener.settimeout(0.1)

            def serve():
                while not stop.is_set():
                    try:
                        connection, _ = listener.accept()
                    except socket.timeout:
                        continue
                    with connection:
                        connection.settimeout(5)
                        try:
                            self.dispatch(connection)
                        except Exception as e:
                            self.dispatch_errors.append(repr(e))

            thread = threading.Thread(target=serve, daemon=True)
            thread.start()
            started = time.monotonic()
            try:
                result = subprocess.run(
                    ["/bin/sh", str(self.worker), *(args or [UUID])], cwd=self.root,
                    env={"PATH": str(self.root / "tools"),
                         "WF_MOCK_SOCKET": self.socket_path.name},
                    capture_output=True, text=True, timeout=25)
                if self.dispatch_errors:
                    raise AssertionError(self.dispatch_errors)
                return result
            finally:
                self.elapsed = time.monotonic() - started
                stop.set()
                thread.join(timeout=6)
                self.socket_path.unlink()
                if thread.is_alive():
                    raise RuntimeError("mock dispatcher did not stop")

    def close(self):
        self.temp.cleanup()


class CoordinatorTests(unittest.TestCase):
    def fixture(self, **state):
        f = WorkerFixture(**state)
        self.addCleanup(f.close)
        return f

    def assert_restored(self, f):
        for n in NAMES:
            self.assertEqual((f.target / n).read_bytes(), f.originals[n])
        self.assertFalse((f.session / "identity-enabled").exists())
        self.assertFalse((f.session / "focus/policy-grant.plist").exists())

    def test_production_static_boundaries(self):
        s = SCRIPT.read_text()
        self.assertNotRegex(s, r"(?m)^\s*(?:eval|source|\.\s|rm\s|ssh\s|scp\s|sudo\s)")
        for forbidden in ("hello-identity-shadow.plist", "sqlite3", "WF_SLEEP_SYNC_TEST_ROOT", "launchctl reboot"):
            self.assertNotIn(forbidden, s)
        self.assertNotIn('deadline=$((started + 420))', s)
        self.assertNotIn('$work/started-unix', s)
        self.assertIn('"$session/start-unix"', s)
        self.assertIn('"$session/deadline-unix"', s)
        self.assertIn('"$((bridge_deadline - bridge_start))" -le 420', s)
        self.assertIn('"$ticks" -lt 180', s)
        self.assertIn('"$((wall - source_at))" -lt 90', s)
        self.assertIn('"$log_size" -le 32768', s)
        self.assertEqual(subprocess.run(["/bin/sh", "-n", str(SCRIPT)]).returncode, 0)

    def test_fixture_path_translation_is_fail_closed(self):
        f = self.fixture()
        source = SCRIPT.read_text()
        for suffix in ("", ":/basebin"):
            with self.subTest(suffix=suffix):
                variant = re.sub(r"(?m)^PATH=.*$",
                                 "PATH=/usr/bin:/bin:/usr/sbin:/sbin" + suffix, source)
                translated = translate_source(variant, f.root / "tools", f.fs, f.originals)
                self.assertIn("\nPATH=" + str(f.root / "tools") + "\n", translated)
                self.assertNotIn("/bin/sleep", translated)
        for variant in (source.replace("PATH=", "PATH=/unexpected:"),
                        source + "\n/usr/bin/unreviewed-tool\n"):
            with self.assertRaises(ValueError):
                translate_source(variant, f.root / "tools", f.fs, f.originals)

    def test_success_is_protocol_only_with_exact_restart_budget(self):
        f = self.fixture()
        # Both trusted owners are accepted; an EOF-terminated decimal is canonical
        # too. The other fixture tests exercise mobile-owned LF-terminated files.
        (f.session / "start-unix").write_text("1800000000")
        state = f.state
        state["owners"] = {str((f.session / "start-unix").relative_to(f.root)): 0}
        f.set_state(state)
        p = f.run()
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(f.status["phase"], "finished")
        self.assertTrue(f.status["ackMatched"])
        self.assertTrue(f.status["cleanupVerified"])
        self.assertFalse(f.status["userVerified"])
        self.assertEqual(f.status["addedSendCount"], 1)
        self.assertEqual(f.status["sends"], 1)
        self.assertEqual(f.status["deadline"] - f.status["startedAt"], 420)
        self.assertEqual(f.state["restarts"].count("com.apple.identityservicesd"), 4)
        self.assertEqual(f.state["restarts"].count("com.apple.donotdisturbd"), 2)
        self.assertEqual(f.command_counts["launchctl"], 6)
        self.assert_restored(f)
        self.assertEqual((f.session / "status.plist").stat().st_mode & 0o777, 0o644)

    def test_duplicate_entry_only_restores_never_arms(self):
        f = self.fixture()
        f.run()
        before = f.state["restarts"][:]
        timing = (f.status["startedAt"], f.status["deadlineUnix"])
        state = f.state
        state["now"] += 900
        f.set_state(state)
        f.run()
        self.assertEqual(f.state["restarts"], before)
        self.assertEqual(f.status["phase"], "failed")
        self.assertTrue(f.status["cleanupVerified"])
        self.assertEqual((f.status["startedAt"], f.status["deadlineUnix"]), timing)
        self.assert_restored(f)

    def test_delayed_worker_uses_bridge_deadline_without_activation(self):
        f = self.fixture()
        # The selector may give less than 420 seconds; even start+420 would be
        # wrong here, not just recomputing worker-entry+420.
        (f.session / "deadline-unix").write_text("1800000120\n")
        state = f.state
        state["now"] += 121
        f.set_state(state)
        before = {n: (f.target / n).stat().st_ino for n in NAMES}
        p = f.run()
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(f.state["restarts"], [])
        self.assertEqual(f.status["phase"], "failed")
        self.assertEqual(f.status["messageCode"], "deadlineExceeded")
        self.assertEqual(f.status["startedAt"], 1800000000)
        self.assertEqual(f.status["deadlineUnix"], 1800000120)
        self.assertTrue(f.status["cleanupVerified"])
        self.assertFalse(f.status["ackMatched"])
        self.assertEqual(f.status["sends"], 0)
        self.assertNotIn("launchctl", f.command_counts)
        self.assertNotIn("cp", f.command_counts)
        self.assertFalse((f.session / "worker-entered/backup").exists())
        self.assertEqual({n: (f.target / n).stat().st_ino for n in NAMES}, before)
        self.assert_restored(f)

    def test_bad_bridge_times_never_activate_or_change_baseline(self):
        for kind in ("missing-start", "missing-deadline", "zero", "leading-zero",
                     "expression", "extra-line", "nul", "overlong", "reversed",
                     "over-budget", "mode", "owner", "symlink", "hardlink"):
            with self.subTest(kind=kind):
                f = self.fixture()
                path = f.session / "deadline-unix"
                if kind == "missing-start": (f.session / "start-unix").unlink()
                elif kind == "missing-deadline": path.unlink()
                elif kind == "zero": path.write_text("0\n")
                elif kind == "leading-zero": path.write_text("01800000420\n")
                elif kind == "expression": path.write_text("1800000000+420")
                elif kind == "extra-line": path.write_text("1800000420\n\n")
                elif kind == "nul": path.write_bytes(b"1800000420\0\n")
                elif kind == "overlong": path.write_text("1" * 17)
                elif kind == "reversed": path.write_text("1800000000\n")
                elif kind == "over-budget": path.write_text("1800000421\n")
                elif kind == "mode": path.chmod(0o644)
                elif kind == "owner":
                    state = f.state
                    state["owners"] = {str(path.relative_to(f.root)): 502}
                    f.set_state(state)
                else:
                    original = f.session / "number-source"
                    path.rename(original)
                    if kind == "symlink": path.symlink_to(original)
                    else: os.link(original, path)
                before = {n: (f.target / n).stat().st_ino for n in NAMES}
                p = f.run()
                self.assertEqual(p.returncode, 0, p.stderr)
                self.assertEqual(f.state["restarts"], [])
                self.assertEqual(f.status["phase"], "failed")
                self.assertEqual(f.status["startedAt"], 0)
                self.assertEqual(f.status["deadlineUnix"], 0)
                self.assertTrue(f.status["cleanupVerified"])
                self.assertFalse(f.status["ackMatched"])
                self.assertNotIn("cp", f.command_counts)
                self.assertEqual({n: (f.target / n).stat().st_ino for n in NAMES}, before)
                self.assert_restored(f)

    def test_bad_times_do_not_block_dirty_recovery(self):
        f = self.fixture()
        work = f.session / "worker-entered"
        (work / "identity-dirty").mkdir(parents=True, mode=0o700)
        work.chmod(0o700)
        (work / "backup").mkdir(mode=0o700)
        for name in NAMES:
            (work / "backup" / name).write_bytes(f.originals[name])
        for name in NAMES[:2]:
            (f.target / name).write_bytes((f.runtime / name).read_bytes())
        (f.session / "start-unix").write_text("broken\n")
        (f.session / "deadline-unix").unlink()
        state = f.state
        state["now"] += 900
        f.set_state(state)
        p = f.run()
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(f.status["phase"], "failed")
        self.assertEqual(f.status["startedAt"], 0)
        self.assertEqual(f.status["deadlineUnix"], 0)
        self.assertTrue(f.status["cleanupVerified"])
        self.assertFalse(f.status["ackMatched"])
        self.assertEqual(f.state["restarts"], ["com.apple.identityservicesd"])
        self.assertTrue((work / "identity-original-done").is_dir())
        self.assertFalse((work / "identity-baseline-reserved").exists())
        self.assert_restored(f)

    def test_all_payloads_validated_before_any_install(self):
        for kind in ("hash", "manifest-code", "unknown-name", "duplicate", "symlink", "baseline",
                     "postload-missing", "postload-incomplete", "postload-unknown",
                     "postload-duplicate", "postload-code", "postload-trailing"):
            with self.subTest(kind=kind):
                f = self.fixture()
                if kind == "hash": (f.runtime / NAMES[-1]).write_bytes(b"tampered")
                elif kind == "manifest-code": f.manifest.write_text("$(touch SENTINEL) payload\n")
                elif kind == "unknown-name": f.manifest.write_text(f.manifest.read_text().replace(NAMES[-1], "../../bad"))
                elif kind == "duplicate": f.manifest.write_text(f.manifest.read_text().replace(NAMES[-1], NAMES[0]))
                elif kind == "symlink":
                    (f.runtime / NAMES[-1]).unlink()
                    (f.runtime / NAMES[-1]).symlink_to(f.target / NAMES[-1])
                elif kind == "postload-missing": f.postload_manifest.unlink()
                elif kind == "postload-incomplete":
                    f.postload_manifest.write_text("".join(f.postload_manifest.read_text().splitlines(keepends=True)[:2]))
                elif kind == "postload-unknown":
                    f.postload_manifest.write_text(f.postload_manifest.read_text().replace(NAMES[-1], "../../bad"))
                elif kind == "postload-duplicate":
                    f.postload_manifest.write_text(f.postload_manifest.read_text().replace(NAMES[-1], NAMES[0]))
                elif kind == "postload-code": f.postload_manifest.write_text("$(touch SENTINEL) payload\n")
                elif kind == "postload-trailing":
                    f.postload_manifest.write_text(f.postload_manifest.read_text() + "unterminated-extra")
                else: (f.target / NAMES[-1]).write_bytes(b"unexpected baseline")
                p = f.run()
                self.assertEqual(p.returncode, 0, p.stderr)
                self.assertEqual(f.state["restarts"], [])
                self.assertFalse((f.root / "SENTINEL").exists())
                self.assertEqual(f.status["phase"], "recoveryRequired" if kind == "baseline" else "failed")

    def assert_no_ack_failure(self, f):
        p = f.run()
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(f.status["phase"], "failed")
        self.assertFalse(f.status["ackMatched"])
        self.assertTrue(f.status["cleanupVerified"])
        self.assertLessEqual(f.state["now"] - 1800000000, 180)
        self.assert_restored(f)

    def test_no_source_is_bounded_and_never_becomes_ack(self):
        f = self.fixture(scenario="no_source")
        self.assert_no_ack_failure(f)
        self.assertEqual(f.command_counts["sleep"], 6)
        self.assertEqual(f.command_counts["launchctl"], 6)
        self.assertEqual(f.status["sends"], 0)

    def test_missing_unknown_or_unrelated_evidence_never_becomes_ack(self):
        for scenario in ("ack_only", "oversized", "other_session", "no_ack"):
            with self.subTest(scenario=scenario):
                f = self.fixture(scenario=scenario)
                self.assert_no_ack_failure(f)

    def test_missing_baseline_logs_stop_before_identity_enable(self):
        f = self.fixture(no_identity=True)
        p = f.run()
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(f.status["phase"], "failed")
        self.assertEqual(f.state["restarts"], ["com.apple.identityservicesd"] * 2)
        self.assert_restored(f)

    def test_partial_install_and_unresolved_restore_restart_are_fail_closed(self):
        f = self.fixture(fail_restart=5)
        f.run()
        self.assertEqual(f.status["phase"], "recoveryRequired")
        self.assertFalse(f.status["cleanupVerified"])
        before = f.state["restarts"][:]
        f.run()
        self.assertEqual(f.state["restarts"], before)
        self.assertEqual(f.status["phase"], "recoveryRequired")
        self.assert_restored(f)

    def test_cancel_before_install_never_restarts(self):
        f = self.fixture()
        (f.session / "cancel-requested").write_text("cancel")
        f.run()
        self.assertEqual(f.status["phase"], "cancelled")
        self.assertTrue(f.status["cleanupVerified"])
        self.assertEqual(f.state["restarts"], [])

    def test_recovery_request_before_first_entry_never_activates(self):
        f = self.fixture()
        (f.session / "recovery-requested").write_text("recover")
        (f.session / "deadline-unix").write_text("broken\n")
        f.run()
        self.assertEqual(f.status["phase"], "failed")
        self.assertTrue(f.status["cleanupVerified"])
        self.assertEqual(f.status["startedAt"], 0)
        self.assertEqual(f.status["deadlineUnix"], 0)
        self.assertEqual(f.state["restarts"], [])
        self.assert_restored(f)

    def test_unknown_installed_bytes_are_not_overwritten_on_recovery(self):
        f = self.fixture()
        work = f.session / "worker-entered"
        (work / "identity-dirty").mkdir(parents=True, mode=0o700)
        work.chmod(0o700)
        (work / "backup").mkdir(mode=0o700)
        for name in NAMES:
            (work / "backup" / name).write_bytes(f.originals[name])
        (f.target / NAMES[0]).write_bytes(b"unreviewed-postload-or-external-change")
        f.run()
        self.assertEqual(f.status["phase"], "recoveryRequired")
        self.assertFalse(f.status["cleanupVerified"])
        self.assertEqual((f.target / NAMES[0]).read_bytes(), b"unreviewed-postload-or-external-change")
        self.assertEqual(f.state["restarts"], [])

    def test_exact_postload_hash_allows_original_restore(self):
        f = self.fixture()
        work = f.session / "worker-entered"
        (work / "identity-dirty").mkdir(parents=True, mode=0o700)
        work.chmod(0o700)
        (work / "backup").mkdir(mode=0o700)
        for name in NAMES:
            (work / "backup" / name).write_bytes(f.originals[name])
        transformed = b"audited-postload-transformed-identity"
        (f.target / NAMES[0]).write_bytes(transformed)
        prehash = hashlib.sha256((f.runtime / NAMES[0]).read_bytes()).hexdigest()
        posthash = hashlib.sha256(transformed).hexdigest()
        f.postload_manifest.write_text(f.postload_manifest.read_text().replace(prehash, posthash))
        p = f.run()
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(f.status["phase"], "failed")
        self.assertTrue(f.status["cleanupVerified"])
        self.assertEqual(f.state["restarts"], ["com.apple.identityservicesd"])
        self.assertFalse((work / "identity-baseline-reserved").exists())
        self.assert_restored(f)

    def test_rejects_unsafe_paths_uuid_and_linked_status(self):
        f = self.fixture()
        p = f.run("../../wrong")
        self.assertEqual(p.returncode, 64)
        self.assertFalse((f.session / "worker-entered").exists())
        sentinel = f.root / "sentinel"
        sentinel.write_text("untouched")
        (f.session / "status.plist").symlink_to(sentinel)
        f.run()
        self.assertEqual(sentinel.read_text(), "untouched")
        self.assertEqual(f.state["restarts"], [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
