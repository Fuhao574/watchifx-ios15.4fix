"""Maintainer-only local source generation; never runs on a device.

The checked-in Runtime sources are self-contained. This script is intentionally
not required by the build; no private research folder is needed to compile.
"""
from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / "Modules/SleepSync"
excluded = {".theos", "packages", "__pycache__"}
manifest = {}
for path in sorted((MODULE / "Runtime").rglob("*")):
    if not path.is_file() or any(part in excluded for part in path.relative_to(MODULE).parts):
        continue
    if path.suffix not in {".h", ".xm", ".mm", ".plist"} and path.name != "Makefile":
        continue
    manifest[str(path.relative_to(MODULE))] = hashlib.sha256(path.read_bytes()).hexdigest()
print(json.dumps({"runtime_source_sha256": manifest}, indent=2))
