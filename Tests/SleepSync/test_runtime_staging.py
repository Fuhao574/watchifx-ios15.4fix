"""Build-resource checks only: no root/device command or policy grant."""
from pathlib import Path
import hashlib
import os
import plistlib
import subprocess
import tempfile
import shutil
import unittest

ROOT = Path(__file__).resolve().parents[2]
MODULE = ROOT / "Modules/SleepSync"


class RuntimeStagingTests(unittest.TestCase):
    def stage(self, candidate=False, brand=None):
        (ROOT / "reports").mkdir(exist_ok=True)
        temp = tempfile.TemporaryDirectory(prefix="module-stage-", dir=ROOT / "reports")
        self.addCleanup(temp.cleanup)
        target = Path(temp.name)
        environment = dict(os.environ)
        for key in ("WATCHFIX_SLEEP_SYNC_BRAND", "WATCHFIX_SLEEP_SYNC_TEST_CANDIDATE"):
            environment.pop(key, None)
        if candidate:
            environment["WATCHFIX_SLEEP_SYNC_TEST_CANDIDATE"] = "1"
        if brand:
            environment["WATCHFIX_SLEEP_SYNC_BRAND"] = brand
        result = subprocess.run(["python3", str(MODULE / "stage_runtime.py"), str(target)],
                                env=environment, capture_output=True, text=True, timeout=30)
        return result, target

    def test_default_preview_is_disabled(self):
        result, target = self.stage()
        self.assertEqual(result.returncode, 0, result.stderr)
        info = plistlib.loads((target / "module-info.plist").read_bytes())
        self.assertIs(info["enabledForDevice"], False)
        self.assertEqual(info["brandHex"], "")

    def test_test_candidate_requires_explicit_brand(self):
        result, _ = self.stage(candidate=True)
        self.assertNotEqual(result.returncode, 0)

    def test_stale_local_artifact_is_rejected_instead_of_packaging_it(self):
        with tempfile.TemporaryDirectory(prefix='stale-stage-', dir=ROOT/'reports') as tmp:
            module = Path(tmp)/'Modules/SleepSync'
            module.mkdir(parents=True)
            for name in ('stage_runtime.py', 'postload_digest.py', 'ModuleSession.h',
                         'RootLauncher.sh', 'SleepSyncCoordinator.sh'):
                shutil.copyfile(MODULE/name, module/name)
            for component, stem in (('Focus', 'FocusConfigCompatibility'), ('Identity', 'HelloReadOnlyObserver')):
                source = MODULE/'Runtime'/component
                target = module/'Runtime'/component
                (target/'.theos/obj').mkdir(parents=True)
                for path in source.iterdir():
                    if path.is_file() and path.suffix in ('.h', '.mm', '.xm', '.plist'):
                        shutil.copyfile(path, target/path.name)
                binary = target/'.theos/obj'/('WatchFix_'+stem+'.dylib')
                shutil.copyfile(source/'.theos/obj'/binary.name, binary)
                os.utime(binary, (1, 1))
            result = subprocess.run(['python3', str(module/'stage_runtime.py'), str(Path(tmp)/'out')],
                                    capture_output=True, text=True, timeout=30)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Stale or missing runtime artifact', result.stderr)

    def test_brand_bound_candidate_hashes(self):
        result, target = self.stage(candidate=True, brand="123456789ABCDEF0")
        self.assertEqual(result.returncode, 0, result.stderr)
        info = plistlib.loads((target / "module-info.plist").read_bytes())
        self.assertIs(info["enabledForDevice"], True)
        self.assertEqual(info["brandHex"], "123456789ABCDEF0")
        for name, digest in info["payloadSHA256"].items():
            if name.endswith(".plist"):
                subprocess.run(["/usr/bin/plutil", "-convert", "binary1", str(target / name)], check=True)
            self.assertEqual(hashlib.sha256((target / name).read_bytes()).hexdigest(), digest)
        for filename in ("payload.sha256", "postload.sha256"):
            rows = [line.split() for line in (target / filename).read_text().splitlines()]
            self.assertEqual(len(rows), 4)
            self.assertEqual({name for _, name in rows}, {
                "WatchFix_FocusConfigCompatibility.dylib", "WatchFix_FocusConfigCompatibility.plist",
                "WatchFix_HelloReadOnlyObserver.dylib", "WatchFix_HelloReadOnlyObserver.plist"})
        for name in ("WatchFix_FocusConfigCompatibility.dylib", "WatchFix_HelloReadOnlyObserver.dylib"):
            self.assertNotEqual(info["payloadSHA256"][name], info["postloadSHA256"][name])


if __name__ == "__main__":
    unittest.main(verbosity=2)
