"""Compile actual bridge for offline register/remove checks; all spawn denied."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent


class RegistrationTests(unittest.TestCase):
    def test_bridge_refuses_dirty_or_active_removal(self):
        self.assertEqual(os.geteuid(), 501)
        (ROOT/'reports').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='module-register-', dir=ROOT/'reports') as tmp:
            work = Path(tmp)
            (work/'roothide.h').write_text('#pragma once\nconst char *HostJBRoot(const char *);\n#define jbroot(p) HostJBRoot(p)\n')
            (work/'UIKit').mkdir()
            (work/'UIKit/UIKit.h').write_text('#import <Foundation/Foundation.h>\n@class UIViewController, UIImage;\n')
            binary = work/'host-test'
            command = ['xcrun', 'clang++', '-x', 'objective-c++', '-std=c++17', '-fobjc-arc',
                       '-fblocks', '-Wno-incomplete-implementation', '-Wno-objc-property-implementation',
                       '-I', str(work), '-I', str(ROOT/'Utils'), '-framework', 'Foundation',
                       str(HERE/'test_module_registration.mm'), '-o', str(binary)]
            built = subprocess.run(command, capture_output=True, text=True, timeout=60)
            self.assertEqual(built.returncode, 0, built.stderr)
            for scenario in ('idle', 'clean-terminal', 'active', 'dirty', 'missing-status',
                             'residual', 'dangling-filter', 'reinstall'):
                with self.subTest(scenario=scenario):
                    result = subprocess.run([str(binary), scenario, str(work/scenario)],
                                            capture_output=True, text=True, timeout=5)
                    self.assertEqual(result.returncode, 0, result.stdout+result.stderr)

    def test_card_has_settings_delete_and_only_registration_install(self):
        view = (ROOT/'App/Views/FeatureViewController.swift').read_text()
        self.assertIn('configurationTitle: L("features.plugins.configure")', view)
        self.assertIn('self?.store.removePlugin(identifier: plugin.id)', view)
        self.assertNotIn('L("sleepSync.module.open")', view)
        provider = (ROOT/'Plugins/FocusConfigCompatibility/FocusConfigCompatibilityPluginConfiguration.xm').read_text()
        self.assertIn('setRegistered:YES context:context', provider)
        self.assertIn('setRegistered:NO context:context', provider)
        types = (ROOT/'App/Models/Types.swift').read_text()
        self.assertIn('identifier == "FocusConfigCompatibility" ? stateValue : true', types)


if __name__ == '__main__':
    unittest.main(verbosity=2)
