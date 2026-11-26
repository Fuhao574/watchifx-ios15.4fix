"""Audit review-only kit, not device deployment or activation readiness."""
from pathlib import Path
import hashlib
import json
import plistlib
import subprocess
import unittest

HERE=Path(__file__).resolve().parent
PROBE=HERE.parents[1]/'Modules/HealthSupport/QueryRouteProbe'


class ReviewKitTests(unittest.TestCase):
    def test_blocked_kit_has_no_activation_or_grant(self):
        run=subprocess.run(['python3','-B',str(PROBE/'prepare_device_review_kit.py')],capture_output=True,text=True,timeout=120)
        self.assertEqual(run.returncode,0,run.stderr)
        folder=Path(next(l.split(': ',1)[1] for l in run.stdout.splitlines() if l.startswith('PREPARED local BLOCKED')))
        manifest=json.loads((folder/'review-kit.json').read_text())
        self.assertFalse(manifest['readyForActivation'])
        for key in ('productionPrivateConfigIncluded','activatedPayloadIncluded','grantIncluded','deploymentScriptIncluded','signingPerformed'):
            self.assertIs(manifest[key],False)
        self.assertEqual({p.name for p in folder.iterdir()},{'README.md','review-kit.json','preparation-plan.json','healthd-only-filter.plist.draft'})
        draft=folder/'healthd-only-filter.plist.draft'
        self.assertEqual(plistlib.loads(draft.read_bytes()),{'Filter':{'Executables':['healthd']}})
        self.assertEqual(hashlib.sha256(draft.read_bytes()).hexdigest(),manifest['draftFilterSHA256'])
        baseline=PROBE/manifest['baselineDirectory']
        self.assertEqual(hashlib.sha256((baseline/'build-local.json').read_bytes()).hexdigest(),manifest['baselineManifestSHA256'])
        for row in manifest['artifacts']:
            self.assertEqual(hashlib.sha256((baseline/row['file']).read_bytes()).hexdigest(),row['sha256'])
        plan=json.loads((folder/'preparation-plan.json').read_text())
        self.assertFalse(plan['deviceActionsPerformed'])
        self.assertTrue(any('single-writer' in item for item in plan['blockers']))
        self.assertTrue(any('revoke' in item for item in plan['possibleFutureTestRequiresSeparateApproval']))


if __name__=='__main__':unittest.main(verbosity=2)
