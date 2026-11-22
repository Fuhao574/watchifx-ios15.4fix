"""Offline presentation contract; never starts or changes a sync session."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ProgressUITests(unittest.TestCase):
    def test_stage_bar_and_short_page_preserve_required_actions(self):
        source = (ROOT/'App/Views/SleepSyncViewController.swift').read_text()
        self.assertIn('UIProgressView(progressViewStyle: .default)', source)
        self.assertIn('snapshot.progressStage', source)
        self.assertIn('progressView.accessibilityLabel = caption', source)
        self.assertNotIn('WFMakeInfoCard(text: plugin.detail)', source)
        self.assertNotIn('L("sleepSync.risks")', source)
        self.assertNotIn('footer: L("sleepSync.actions.footer")', source)
        for key in ('sleepSync.instruction.save', 'sleepSync.instruction.restoreSetting',
                    'sleepSync.confirm.message', 'sleepSync.action.recover'):
            self.assertIn('L("'+key+'")', source)


if __name__ == '__main__':
    unittest.main(verbosity=2)
