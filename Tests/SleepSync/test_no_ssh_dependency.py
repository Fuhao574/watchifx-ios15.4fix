"""Offline source/package contract, not a replacement for device acceptance."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


class NoSSHTests(unittest.TestCase):
    def test_entire_module_and_app_path_has_no_remote_transport(self):
        paths = list((ROOT / 'Modules/SleepSync').rglob('*'))
        paths += list((ROOT / 'App/Bridge/SleepSync').rglob('*'))
        paths += [ROOT / 'App/Models/SleepSync.swift', ROOT / 'App/Views/SleepSyncViewController.swift', ROOT / 'control']
        extensions = {'.sh', '.py', '.xm', '.mm', '.h', '.swift', '.plist'}
        for path in paths:
            if not path.is_file() or '.theos' in path.parts or 'packages' in path.parts:
                continue
            if path.suffix not in extensions and path.name not in ('control', 'Makefile'):
                continue
            with self.subTest(path=str(path.relative_to(ROOT))):
                text = path.read_text()
                self.assertNotRegex(text, r'(?i)\b(?:ssh|sshd|scp|sftp|libssh\w*|openssh(?:-\w+)?)\b')
                self.assertNotRegex(text, r'(?i)\b(?:paramiko|sshpass)\b|(?:localhost|127\.0\.0\.1):22\b')

    def test_app_invokes_only_local_fixed_operations(self):
        bridge = (ROOT / 'App/Bridge/SleepSync/SleepSyncBridge.xm').read_text()
        self.assertIn('SSRunLauncher(@"start",identifier,error)', bridge)
        self.assertIn('SSRunLauncher(@"recover",identifier,error)', bridge)
        self.assertIn('posix_spawn(&pid,program.fileSystemRepresentation', bridge)
        self.assertIn('RootLauncher.sh', bridge)


if __name__ == '__main__':
    unittest.main(verbosity=2)
