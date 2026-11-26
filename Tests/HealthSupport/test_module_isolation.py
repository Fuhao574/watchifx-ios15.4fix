"""Static source isolation only; never builds an app/package or uses a device."""
from pathlib import Path
import json
import unittest
import re

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[1]
MODULE = PROJECT / 'Modules/HealthSupport'


class ModuleIsolationTests(unittest.TestCase):
    def test_status_is_runtime_integrated_but_default_disabled(self):
        status = json.loads((MODULE / 'module.json').read_text())
        self.assertIs(status['enabledByDefault'], False)
        self.assertIs(status['runtimeEnabled'], False)
        self.assertIs(status['installable'], True)
        self.assertIs(status['automaticBuildIntegration'], True)
        self.assertEqual(status['status'], 'runtime-integrated-device-verified')
        self.assertIs(status['integratedInWatchFixSource'], True)
        self.assertIs(status['ordinaryPackageIncluded'], True)
        self.assertIs(status['ordinaryInstallable'], True)
        self.assertEqual(status['buildEntry'], 'Plugins/HealthSupport')
        self.assertEqual(status['runtime']['target'], 'healthd-only')
        self.assertEqual(status['runtime']['architectures'], ['arm64e'])
        self.assertIs(status['runtime']['defaultEnabled'], False)
        self.assertEqual(status['runtime']['verifiedSignal'], 10)
        self.assertIs(status['loadCheckCandidate']['hooksInstalled'], False)
        self.assertIs(status['loadCheckCandidate']['deviceLoaded'], True)
        self.assertEqual(status['loadCheckCandidate']['receiptStatus'], 1)
        self.assertEqual(status['loadCheckCandidate']['checkedBoundaries'], 0)
        self.assertEqual(status['loadCheckCandidate']['matchedBoundaries'], 0)
        self.assertEqual(status['hostDiagnosticCandidate']['architectureMismatchBits'], 4)
        self.assertEqual(status['hostDiagnosticCandidate']['observedFileType'], 6)
        self.assertEqual(status['hostDiagnosticCandidate']['checkedBoundaries'], 0)
        self.assertEqual(status['executableSourceCandidate']['receiptStatus'], 7)
        self.assertEqual(status['executableSourceCandidate']['matchedBoundaries'], 7)
        self.assertIs(status['executableSourceCandidate']['injectorCompletionVerified'], False)
        self.assertIs(status['deploymentSafety']['existingInjectorApprovedForFurtherLoads'], False)
        self.assertIs(status['deploymentSafety']['targetThreadRecoveryVerified'], False)
        self.assertIs(status['deploymentSafety']['recoveryActionPerformed'], True)
        self.assertIs(status['deploymentSafety']['recovery']['oldProcessExited'], True)
        self.assertIs(status['deploymentSafety']['recovery']['candidateReloaded'], False)
        for key in ('hooksInstalled', 'receiveEnabled', 'healthSamplesRead'):
            self.assertIs(status['executableSourceCandidate'][key], False)
        self.assertIs(status['appDiagnosticVariant']['explicitOptInOnly'], True)
        self.assertIs(status['appDiagnosticVariant']['extraEntitlements'], False)
        self.assertEqual(status['appDiagnosticVariant']['deviceState'], 'D3-user-summary-screenshot-confirms-complete')
        self.assertIs(status['appDiagnosticVariant']['compatibilityValidated'], False)
        self.assertEqual(status['deviceValidation'], 'runtime-healthd-signal10-on-19E241')
        self.assertTrue(status['missing'])
        self.assertFalse((MODULE / 'Makefile').exists())
        self.assertFalse((MODULE / 'manifest.plist').exists())
        self.assertTrue((PROJECT / 'Plugins/HealthSupport').exists())
        self.assertTrue((MODULE / 'Runtime/HealthSupportRuntime.mm').exists())
        self.assertTrue((PROJECT / 'Plugins/HealthSupport/manifest.plist').exists())

    def test_no_automatic_source_or_staging_reference(self):
        top_make = (PROJECT / 'Makefile').read_text()
        self.assertIn('healthsupport-offline-check', top_make)
        self.assertNotIn('Modules/HealthSupport', top_make.split('SUBPROJECTS =', 1)[1].split('\n', 1)[0])
        for name in ('Modules/SleepSync/Makefile', 'Modules/SleepSync/stage_runtime.py'):
            self.assertNotIn('HealthSupport', (PROJECT / name).read_text())
        app_make = (PROJECT / 'App/Makefile').read_text()
        optin = re.search(r'ifeq \(\$\(WATCHFIX_HEALTH_DIAGNOSTICS\),1\).*?\nendif\n', app_make, re.S)
        # The first endif closes the missing-private-config guard; the outer
        # block is checked to contain only this single diagnostics source.
        self.assertIsNotNone(optin)
        begin = app_make.index('ifeq ($(WATCHFIX_HEALTH_DIAGNOSTICS),1)')
        finish = app_make.index('\nendif\n\ninclude ', begin) + len('\nendif')
        block = app_make[begin:finish]
        self.assertIn('AppDiagnostics/FixedMappingDiagnostic.m', block)
        self.assertIn('$(error "Diagnostics opt-in requires', block)
        self.assertNotIn('Modules/HealthSupport', app_make[:begin] + app_make[finish:])
        # Current top-level scanner only discovers Plugins, not Modules/*.
        self.assertIn('$(wildcard Plugins/*/Makefile)', (PROJECT / 'Makefile').read_text())
        production = [PROJECT / 'App', PROJECT / 'Plugins', PROJECT / 'Preferences', PROJECT / 'Utils']
        for directory in production:
            for path in directory.rglob('*'):
                if path.is_file() and path.suffix in ('.m', '.mm', '.xm', '.swift', '.h', '.plist', '.mk'):
                    text = path.read_text()
                    if path == PROJECT / 'App/App-Bridging-Header.h':
                        text = re.sub(r'#if defined\(WATCHFIX_HEALTH_DIAGNOSTICS\).*?#endif', '', text, flags=re.S)
                    if path.parent == PROJECT / 'Plugins/HealthSupport' or PROJECT / 'Plugins/HealthSupport' in path.parents:
                        continue
                    self.assertNotIn('Modules/HealthSupport', text, str(path))

        plugin = PROJECT / 'Plugins/HealthSupport'
        self.assertIn('HealthSupportPluginConfiguration', (plugin / 'manifest.plist').read_text())
        self.assertIn('healthd', (plugin / 'manifest.plist').read_text())
        self.assertIn('ARCHS = arm64e', (plugin / 'Makefile').read_text())

    def test_core_has_no_device_or_health_api(self):
        for path in (MODULE / 'Core').glob('*.hpp'):
            source = path.read_text()
            for forbidden in ('HKHealthStore', 'MSHook', 'dlopen(', 'sqlite3_', 'objc_msgSend',
                              'system(', 'popen(', 'ssh ', 'constructor))', 'object_setIvar'):
                self.assertNotIn(forbidden, source, str(path))

    def test_offline_adapters_do_not_discover_or_load_native_health_classes(self):
        for path in (MODULE / 'Adapters').iterdir():
            if path.suffix not in ('.h', '.hpp', '.m', '.mm'):
                continue
            source = path.read_text()
            for forbidden in ('HKHealthStore', 'MSHook', 'dlopen(', 'sqlite3_', 'objc_getClass(',
                              'NSClassFromString(', 'system(', 'popen(', 'constructor))', 'ssh '):
                self.assertNotIn(forbidden, source, str(path))


if __name__ == '__main__':
    unittest.main(verbosity=2)
