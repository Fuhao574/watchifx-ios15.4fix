"""Offline structure-only parser test, never reads user photo identifiers."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]


class AssetRequestTests(unittest.TestCase):
    def test_actual_parser(self):
        (ROOT/'reports').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='photo-request-',dir=ROOT/'reports') as tmp:
            binary=Path(tmp)/'host-test'
            result=subprocess.run(['xcrun','clang++','-std=c++17','-fobjc-arc','-Wall','-Wextra',
                                   '-Werror','-framework','Foundation',str(Path(__file__).with_suffix('.mm')),
                                   '-o',str(binary)],capture_output=True,text=True,timeout=60)
            self.assertEqual(result.returncode,0,result.stderr)
            result=subprocess.run([str(binary)],capture_output=True,text=True,timeout=5)
            self.assertEqual(result.returncode,0,result.stderr)


if __name__=='__main__':
    unittest.main(verbosity=2)
