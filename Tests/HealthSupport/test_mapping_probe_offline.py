"""Capability audit for the authorized fixed mapping probe; no device operations."""
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[1]
SOURCE = PROJECT / 'Modules/HealthSupport/LoadCheck/MappingProbe.c'
SDK = Path('/Users/fuhao574/theos/sdks/iPhoneOS16.5.sdk')


class MappingProbeTests(unittest.TestCase):
    def test_fixed_probe_import_allowlist(self):
        with tempfile.TemporaryDirectory(prefix='mapping-probe-host-', dir=HERE) as temporary:
            work = Path(temporary)
            (work / 'MappingProbePrivate.h').write_text(
                '#define WFHS_PROBE_PID 1\n#define WFHS_PROBE_SIZE 90928\n'
                '#define WFHS_PROBE_PATH "/private/invalid-fixture-only.dylib"\n')
            binary = work / 'probe'
            built = subprocess.run([
                'xcrun', 'clang', '-target', 'arm64-apple-ios15.0', '-isysroot', str(SDK),
                '-O2', '-Wall', '-Wextra', '-Werror', '-I', str(work), str(SOURCE),
                '-Wl,-no_adhoc_codesign', '-o', str(binary),
            ], capture_output=True, text=True, timeout=60)
            self.assertEqual(built.returncode, 0, built.stderr)
            imports = subprocess.check_output(['xcrun', 'nm', '-u', str(binary)], text=True)
            actual = {line.strip().split()[-1] for line in imports.splitlines() if line.strip()}
            allowed = {'_SANDBOX_CHECK_NO_REPORT', '___chkstk_darwin', '___error', '___stack_chk_fail',
                       '___stack_chk_guard', '_bzero', '_close', '_fcntl', '_fstat', '_geteuid', '_memchr',
                       '_open', '_printf', '_proc_pidpath', '_putchar', '_realpath$DARWIN_EXTSN',
                       '_sandbox_check', '_stat', '_strcmp', '_sysctlbyname', '_putc', '___stdoutp', '_fwrite',
                       'dyld_stub_binder'}
            self.assertLessEqual(actual, allowed)
            traditional = work / 'probe-traditional'
            built = subprocess.run([
                'xcrun', 'clang', '-target', 'arm64-apple-ios15.0', '-isysroot', str(SDK),
                '-O2', '-Wall', '-Wextra', '-Werror', '-I', str(work), str(SOURCE),
                '-Wl,-no_fixup_chains', '-Wl,-no_adhoc_codesign', '-o', str(traditional),
            ], capture_output=True, text=True, timeout=60)
            self.assertEqual(built.returncode, 0, built.stderr)
            imports = subprocess.check_output(['xcrun', 'nm', '-u', str(traditional)], text=True)
            self.assertLessEqual({line.strip().split()[-1] for line in imports.splitlines() if line.strip()}, allowed)
            data = traditional.read_bytes()
            commands, offset = [], 32
            for _ in range(struct.unpack_from('<I', data, 16)[0]):
                command, size = struct.unpack_from('<II', data, offset)
                commands.append(command)
                offset += size
            self.assertIn(0x80000022, commands)  # LC_DYLD_INFO_ONLY
            self.assertNotIn(0x80000034, commands)  # LC_DYLD_CHAINED_FIXUPS
            source = SOURCE.read_text()
            self.assertIn('O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC', source)
            self.assertIn('F_GETPATH', source)
            self.assertIn('1|SANDBOX_CHECK_NO_REPORT', source)
            self.assertIn('if(argc!=1)', source)
            for forbidden in ('task_for_pid(', 'mach_vm_read(', 'sandbox_extension_issue', 'sandbox_extension_consume(',
                              'dlopen(', 'mmap(', 'read(fd', 'fread(', 'write(', 'system(', 'posix_spawn(', 'execve('):
                self.assertNotIn(forbidden, source)


if __name__ == '__main__':
    unittest.main(verbosity=2)
