"""Build own load-only candidate, inspect iOS bytes, execute ONLY own host dylib.

No Apple payload execution, device connection, Health data, injection or install.
The host constructor is expected to stop at architecture mismatch.
"""
from pathlib import Path
import ctypes
import json
import re
import struct
import subprocess
import tempfile
import unittest
import uuid

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[1]
MODULE = PROJECT / 'Modules/HealthSupport'
LOAD = MODULE / 'LoadCheck'
ADAPTER = MODULE / 'Adapters'
SDK = Path('/Users/fuhao574/theos/sdks/iPhoneOS16.5.sdk')


def commands(binary):
    data = binary.read_bytes()
    header = struct.unpack_from('<8I', data)
    if header[0] != 0xFEEDFACF:
        raise AssertionError('Expected thin64 Mach-O')
    offset = 32
    rows = []
    for _ in range(header[4]):
        command, size = struct.unpack_from('<II', data, offset)
        if size < 8 or offset + size > 32 + header[5]:
            raise AssertionError('Invalid load command')
        rows.append((command, data[offset:offset + size]))
        offset += size
    if offset != 32 + header[5]:
        raise AssertionError('Load-command length mismatch')
    return header, rows


class LoadCheckCandidateTests(unittest.TestCase):
    def test_explicit_receipt_variant_is_bounded_status_only(self):
        built = subprocess.run(['python3', '-B', str(LOAD / 'build_receipt_candidate.py')],
                               capture_output=True, text=True, timeout=120, cwd=PROJECT)
        self.assertEqual(built.returncode, 0, built.stderr)
        line = next(line for line in built.stdout.splitlines() if line.startswith('BUILT local unsigned'))
        output = Path(line.split(': ', 1)[1])
        manifest = json.loads((output / 'build-local.json').read_text())
        self.assertIs(manifest['receiptLogging'], True)
        self.assertEqual(manifest['receiptMarker'], 'WFHSLC_20261124_A1')
        for entry in manifest['artifacts']:
            binary = output / entry['file']
            imported = subprocess.run(['xcrun', 'nm', '-u', str(binary)], check=True,
                                      capture_output=True, text=True).stdout
            self.assertIn('__os_log_error_impl', imported)
            for forbidden in ('MSHook', 'method_setImplementation', 'object_getIvar', 'class_addMethod',
                              '_dlopen', '_sqlite3', '_connect', '_socket', '_open', '_write', '_NSLog'):
                self.assertNotIn(forbidden, imported)
            self.assertIn(b'WFHSLC_20261124_A1', binary.read_bytes())
        source = (LOAD / 'LoadCheck.m').read_text()
        self.assertEqual(source.count('os_log_error('), 3)  # mutually exclusive receipt variants
        self.assertIn('receive=0 hooks=0 samples=0', source)
        self.assertIs(manifest['receiveEnabled'], False)
        self.assertIs(manifest['hooksInstalled'], False)
        self.assertIs(manifest['healthSamplesRead'], False)

    def test_fixed_uuid_bytes_match_exact_firmware_contract(self):
        source = (LOAD / 'LoadCheck.m').read_text()
        values = {}
        for name, contents in re.findall(r'const uint8_t (\w+)\[16\]=\{([^}]+)\};', source):
            raw = bytes(int(part.strip(), 16) for part in contents.split(','))
            values[name] = str(uuid.UUID(bytes=raw)).upper()
        self.assertEqual(values, {
            'hostUUID': '6DF28854-8CFC-3E05-9BD2-B6D405B0685F',
            'hdUUID': '5C7508EA-8D04-3313-BAD4-A5A30202A475',
            'hkUUID': '5763C6BF-DFDD-3615-80F5-F709A77E83D9',
        })
        root = PROJECT.parent
        firmware = json.loads((root / 'reports/health-host-firmware-identities-local.json').read_text())
        host = next(item for item in firmware['hosts'] if item['path'].endswith('/healthd'))
        self.assertEqual(host['uuid'], values['hostUUID'])
        self.assertIn(values['hdUUID'], (ADAPTER / 'IOS154BoundaryIdentity.m').read_text())

    def test_explicit_ios_build_has_no_hook_or_health_write_dependencies(self):
        # Reviewed builder has exact allowlisted sources/SDK, exclusively creates
        # module-local outputs, never signs/stages/packages/installs the result.
        built = subprocess.run(['python3', '-B', str(LOAD / 'build_load_check.py')],
                               capture_output=True, text=True, timeout=120, cwd=PROJECT)
        self.assertEqual(built.returncode, 0, built.stderr)
        line = next(line for line in built.stdout.splitlines() if line.startswith('BUILT local unsigned'))
        output = Path(line.split(': ', 1)[1])
        self.assertEqual(output.parent, LOAD / 'Artifacts')
        manifest = json.loads((output / 'build-local.json').read_text())
        for key in ('receiveEnabled', 'hooksInstalled', 'healthSamplesRead', 'signed', 'packaged', 'installed'):
            self.assertIs(manifest[key], False)
        self.assertEqual(set(manifest['sources']), {'LoadCheck/LoadCheck.m', 'Adapters/LoadedMethodIdentity.m',
                                                   'Adapters/IOS154BoundaryIdentity.m'})
        for entry in manifest['artifacts']:
            binary = output / entry['file']
            header, rows = commands(binary)
            self.assertEqual(header[3], 6)  # MH_DYLIB
            self.assertEqual(header[1], 0x100000C)  # CPU_TYPE_ARM64
            self.assertEqual(header[2] & 0xFFFFFF, 2 if entry['architecture'] == 'arm64e' else 0)
            self.assertFalse(any(cmd == 0x1D for cmd, _ in rows))  # no LC_CODE_SIGNATURE
            dependencies = []
            for cmd, payload in rows:
                if cmd in (0xC, 0x80000018, 0x8000001F, 0x80000023):
                    name_offset = struct.unpack_from('<I', payload, 8)[0]
                    dependencies.append(payload[name_offset:].split(b'\0', 1)[0].decode())
            self.assertTrue(dependencies)
            self.assertTrue(all('Foundation.framework/Foundation' in name or
                                'CoreFoundation.framework/CoreFoundation' in name or
                                name in ('/usr/lib/libobjc.A.dylib', '/usr/lib/libSystem.B.dylib')
                                for name in dependencies), dependencies)
            imported = subprocess.run(['xcrun', 'nm', '-u', str(binary)], capture_output=True, text=True, check=True).stdout
            for forbidden in ('MSHook', 'method_setImplementation', 'class_addMethod', 'method_exchangeImplementations',
                              '_dlopen', '_sqlite3', '_connect', '_socket', '_open', '_write', '_NSLog', '_os_log'):
                self.assertNotIn(forbidden, imported)
            exports = subprocess.run(['xcrun', 'nm', '-gU', str(binary)], capture_output=True, text=True, check=True).stdout
            names = re.findall(r'\S+$', exports, flags=re.M)
            self.assertEqual(names, ['_WFHSReadLoadCheckReport'])

    def test_own_host_load_refuses_before_native_class_lookup(self):
        with tempfile.TemporaryDirectory(prefix='load-check-host-', dir=HERE) as temporary:
            work = Path(temporary)
            binary = work / 'host-load-check.dylib'
            built = subprocess.run([
                'xcrun', 'clang', '-dynamiclib', '-fobjc-arc', '-fobjc-arc-exceptions', '-O2',
                '-Wall', '-Wextra', '-Werror', '-fvisibility=hidden', '-framework', 'Foundation',
                '-I', str(ADAPTER), str(LOAD / 'LoadCheck.m'), str(ADAPTER / 'LoadedMethodIdentity.m'),
                str(ADAPTER / 'IOS154BoundaryIdentity.m'), '-o', str(binary),
            ], capture_output=True, text=True, timeout=60)
            self.assertEqual(built.returncode, 0, built.stderr)
            class Report(ctypes.Structure):
                _fields_ = [(name, ctypes.c_uint32) for name in ('schema', 'size', 'status', 'checked', 'matched',
                                                               'receive', 'hooks', 'samples', 'reserved')]
            # Loads OUR macOS build only, never the iOS output or Health frameworks.
            library = ctypes.CDLL(str(binary))
            getter = library.WFHSReadLoadCheckReport
            getter.argtypes = []
            getter.restype = Report
            for _ in range(2):
                report = getter()
                self.assertEqual((report.schema, report.status), (1, 1))  # wrong architecture
                self.assertEqual(report.size, ctypes.sizeof(Report))
                self.assertEqual((report.checked, report.matched, report.receive, report.hooks,
                                  report.samples, report.reserved), (0, 0, 0, 0, 0, 0))

    def test_no_enable_deployment_or_automatic_integration(self):
        result = subprocess.run(['python3', '-B', str(LOAD / 'build_load_check.py'), '--install'],
                                capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('No deployment/enable arguments', result.stderr)
        source = (LOAD / 'LoadCheck.m').read_text()
        self.assertIn('objc_lookUpClass', source)
        self.assertNotIn('NSClassFromString', source.replace('// Existing registered classes ONLY. No objc_getClass/NSClassFromString,', ''))
        for forbidden in ('MSHook', 'method_setImplementation(', 'class_addMethod(', 'dlopen(',
                          'HKHealthStore', 'object_getIvar(', 'ReceiveGate', 'NSLog(', 'dispatch_after('):
            self.assertNotIn(forbidden, source)
        self.assertIn('#if defined(WFHS_LOAD_CHECK_RECEIPT_LOG)', source)
        for name in ('Makefile', 'App/Makefile'):
            self.assertNotIn('LoadCheck', (PROJECT / name).read_text())
        self.assertFalse((LOAD / 'Makefile').exists())
        self.assertFalse(list(LOAD.glob('*.plist')))
        self.assertFalse((MODULE / 'Runtime').exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
