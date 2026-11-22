"""Directly compile both production log headers; no root/device operations.

geteuid and only a regular file's fstat UID are modeled to represent a root
daemon in an actual mobile-owned directory. All modes/links and I/O remain real.
"""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = r'''
#include <sys/types.h>
#include <unistd.h>
#include <sys/stat.h>
#include <string>
static uid_t modeled_euid;
static uid_t test_euid() { return modeled_euid; }
static int test_fstat(int fd, struct stat *st) {
    int result = fstat(fd, st);
    if (!result && S_ISREG(st->st_mode)) st->st_uid = modeled_euid;
    return result;
}
#define geteuid test_euid
#define fstat test_fstat
#include "BoundedLog.h"
#undef geteuid
#undef fstat
int main(int argc, char **argv) {
    if (argc != 3) return 1;
    const uid_t owner = getuid();
    modeled_euid = owner == 0 ? 501 : 0;
    WFSleepDiagnostic::BoundedLog implicit;
    if (implicit.Open(argv[1])) return 2; // foreign directory, old failure
    // Keep the modeled daemon UID distinct from the real directory owner.
    WFSleepDiagnostic::BoundedLog wrong;
    if (wrong.Open(argv[1], owner == 0 ? 501 : 0)) return 3;
    WFSleepDiagnostic::BoundedLog valid;
    if (!valid.Open(argv[1], owner) || !valid.Append("bounded event")) return 4;
    if (valid.Open(argv[1], owner)) return 5; // no retry/overwrite
    WFSleepDiagnostic::BoundedLog duplicate;
    if (duplicate.Open(argv[1], owner)) return 6;
    WFSleepDiagnostic::BoundedLog linked;
    if (linked.Open(argv[2], owner)) return 7;
    return 0;
}
'''


class LogOwnerTests(unittest.TestCase):
    def test_both_headers_keep_explicit_directory_owner_and_exclusive_log(self):
        (ROOT / 'reports').mkdir(exist_ok=True)
        for component in ('Focus', 'Identity'):
            with self.subTest(component=component), tempfile.TemporaryDirectory(
                    prefix='log-owner-', dir=ROOT / 'reports') as tmp:
                work = Path(tmp)
                directory = work / 'session-child'
                directory.mkdir(mode=0o700)
                link = work / 'linked-child'
                link.symlink_to(directory, target_is_directory=True)
                source, binary = work / 'test.cpp', work / 'host-test'
                source.write_text(SOURCE)
                include = ROOT / 'Modules/SleepSync/Runtime' / component
                subprocess.run(['/usr/bin/clang++', '-std=c++17', '-Wall', '-Wextra',
                                '-I', str(include), str(source), '-o', str(binary)],
                               check=True, capture_output=True, timeout=30)
                result = subprocess.run([str(binary), str(directory), str(link)],
                                        capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 0, result.stderr)
                logs = list(directory.glob('run-*.log'))
                self.assertEqual(len(logs), 1)
                self.assertEqual(logs[0].read_bytes(), b'bounded event\n')
                self.assertEqual(logs[0].stat().st_mode & 0o777, 0o600)


if __name__ == '__main__':
    unittest.main(verbosity=2)
