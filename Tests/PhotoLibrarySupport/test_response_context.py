"""Offline actual helper test; no Photos library, device or IDS messages."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class PhotoContextTests(unittest.TestCase):
    def test_native_like_protobuf_never_receives_context_selector(self):
        (ROOT/'reports').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='photo-context-', dir=ROOT/'reports') as tmp:
            binary = Path(tmp)/'host-test'
            result = subprocess.run(['xcrun', 'clang++', '-std=c++17', '-fobjc-arc',
                                     '-Wall', '-Wextra', '-Werror', '-framework', 'Foundation',
                                     str(Path(__file__).with_suffix('.mm')), '-o', str(binary)],
                                    capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_both_reply_paths_use_callback_context_without_protocol_changes(self):
        source = (ROOT/'Plugins/PhotoLibrarySupport/PhotoLibrarySupport.xm').read_text()
        self.assertNotIn('[protobuf outgoingResponseIdentifier]', source)
        self.assertEqual(source.count('WFPhotoOutgoingResponseIdentifier(context, protobuf)'), 2)
        for name, value in (('Signal', 101), ('Snapshot', 102), ('AssetRequest', 103)):
            self.assertIn(f'kWFPhotoSync{name}ProtobufType = {value};', source)

    def test_diagnostic_objects_are_isolated_from_default_build(self):
        makefile = (ROOT/'Plugins/PhotoLibrarySupport/Makefile').read_text()
        self.assertIn('WATCHFIX_PHOTO_DIAGNOSTICS ?= 0', makefile)
        self.assertIn('override THEOS_OBJ_DIR_NAME := obj/photo-context$(WATCHFIX_PHOTO_DIAGNOSTICS)', makefile)
        header = (ROOT/'Plugins/PhotoLibrarySupport/PhotoDiagnostics.h').read_text()
        self.assertIn('count>=96', header)
        self.assertIn('O_EXCL|O_NOFOLLOW', header)
        self.assertIn('static inline void WFPhotoEvent(const char *, unsigned long) {}', header)


if __name__ == '__main__':
    unittest.main(verbosity=2)
