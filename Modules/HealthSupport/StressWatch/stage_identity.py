"""Generate trusted bundled payload hashes. No device access or executable loading."""
from pathlib import Path
import hashlib
import plistlib
import subprocess
import sys

root = Path(sys.argv[1])
files = ('StressWatchCompatibility.dylib', 'Filter.plist')
for name in files:
    if not (root / name).is_file():
        raise SystemExit(f'Missing staged payload: {name}')
# Theos converts staged plists after instance staging. Normalize first so the
# recorded checksum is of the same filter bytes that will ship in the package.
subprocess.run(['/usr/bin/plutil', '-convert', 'binary1', str(root / 'Filter.plist')], check=True)
(root / 'Identity.plist').write_bytes(plistlib.dumps({
    'schema': 1,
    'runtime': '1.0.0-stresswatch-lowpower1',
    'sha256': {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in files},
}))
