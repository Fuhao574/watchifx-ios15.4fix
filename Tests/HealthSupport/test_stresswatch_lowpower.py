"""Local-only low-overhead companion/build/settings regression checks."""
from pathlib import Path
import hashlib
import plistlib
import subprocess
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[2]
MODULE = PROJECT / 'Modules/HealthSupport/StressWatch'


class StressWatchLowPowerTests(unittest.TestCase):
    def test_no_diagnostic_or_background_runtime(self):
        source = (MODULE / 'StressWatchCompatibility.m').read_text()
        for forbidden in ('WFSaveLocked', 'HKSampleQuery', 'resultsHandler:',
                          'NSTimer', 'dispatch_after', 'dispatch_source',
                          'writeToFile:', 'writeToURL:', 'NSLog(', 'os_log(',
                          'NSJSONSerialization', 'WFFileSHA', 'clock_gettime',
                          'atomic_fetch_add', 'NSURLSession', 'HKHealthStore'):
            self.assertNotIn(forbidden, source)
        self.assertIn('value >= 3 && value <= 5', source)
        self.assertIn('self code] == 63', source)
        self.assertIn('return WFOriginalAccepts(self, selector, value)', source)
        self.assertIn('0x9435dc09', source)
        self.assertIn('0x52800020', source)
        self.assertIn('"19E241"', source)
        self.assertIn('WFHeaderMatches', source)
        self.assertIn('WFCodeMatches(base, 0x10060af68, 0x4c8', source)
        self.assertIn('WFCodeMatches(base, 0x1009f23d0, 0x458', source)
        self.assertIn('WFCodeMatches(base, 0x1003ef23c, 0xa4', source)

    def test_companion_is_not_healthd_filter_or_app_source(self):
        self.assertEqual(plistlib.loads((MODULE / 'Filter.plist').read_bytes()),
                         {'Filter': {'Bundles': ['com.ideation.Stress']}})
        manifest = plistlib.loads((PROJECT / 'Plugins/HealthSupport/manifest.plist').read_bytes())['WFPluginManifest']
        self.assertEqual(manifest['WFPluginInjectionTargets']['Bundles'], ['com.apple.healthd'])
        make = (PROJECT / 'Plugins/HealthSupport/Makefile').read_text()
        self.assertIn('Modules/HealthSupport/StressWatch', make)
        compiled = make.split('WATCHFIX_PLUGIN_FILES =', 1)[1].split('WATCHFIX_PLUGIN_CFLAGS', 1)[0]
        self.assertNotIn('StressWatchCompatibility.m', compiled)
        self.assertNotIn('StressWatchCompatibility.m', (PROJECT / 'App/Makefile').read_text())

    def test_settings_preserve_other_features(self):
        provider = (PROJECT / 'Plugins/HealthSupport/HealthSupportPluginConfiguration.xm').read_text()
        save = provider.split('+ (BOOL)didSaveConfigurationWithContext:', 1)[1].split('\n}', 1)[0]
        self.assertIn('setHealthSupportStressWatchEnabled', save)
        self.assertNotIn('restartLaunchd', save)
        self.assertNotIn('WriteMarker', save)
        self.assertIn('@"type": @"toggle"', provider)
        bridge = (PROJECT / 'App/Bridge/Plugin/PluginBridge.xm').read_text()
        setter = bridge.split('+ (BOOL)setHealthSupportStressWatchEnabled:', 1)[1].split('+ (UIImage *)', 1)[0]
        self.assertNotIn('RunRootCommand(@"/bin/launchctl"', setter)
        self.assertNotIn('restartExecutablesNamed:', setter)
        self.assertIn('WatchFix_StressWatchSleepModelGate', setter)
        self.assertIn('b64e4ae25fd829efd456a9a633502a3bf6bc540f2c809908d94fd24f82a6c918', setter)
        self.assertIn('rollback incomplete', setter)
        self.assertIn('previousConfiguration', bridge)
        for lang in ('en', 'zh-Hans', 'zh-Hant'):
            strings = (PROJECT / f'Plugins/HealthSupport/Resources/{lang}.lproj/Localizable.strings').read_text()
            for key in ('stress.title', 'stress.detail', 'stress.saved', 'stress.disabled'):
                self.assertIn(f'plugin.HealthSupport.{key}', strings)

    def test_staged_identity_uses_exact_payload(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'StressWatchCompatibility.dylib').write_bytes(b'fixture-not-executable')
            (root / 'Filter.plist').write_bytes((MODULE / 'Filter.plist').read_bytes())
            subprocess.run(['python3', str(MODULE / 'stage_identity.py'), str(root)], check=True)
            identity = plistlib.loads((root / 'Identity.plist').read_bytes())
            for name, digest in identity['sha256'].items():
                self.assertEqual(digest, hashlib.sha256((root / name).read_bytes()).hexdigest())


if __name__ == '__main__':
    unittest.main(verbosity=2)
