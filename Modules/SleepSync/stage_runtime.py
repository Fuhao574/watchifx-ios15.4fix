"""Bundle fixed module runtime; never installs or enables device execution."""
from pathlib import Path
import hashlib,json,plistlib,shutil,sys,subprocess
ROOT=Path(__file__).resolve().parent
target=Path(sys.argv[1]).resolve()
workspace=ROOT.parents[2]
target.relative_to(workspace)
target.mkdir(parents=True,exist_ok=True)
files={
 'WatchFix_FocusConfigCompatibility.dylib':ROOT/'Runtime/Focus/.theos/obj/WatchFix_FocusConfigCompatibility.dylib',
 'WatchFix_FocusConfigCompatibility.plist':ROOT/'Runtime/Focus/WatchFix_FocusConfigCompatibility.plist',
 'WatchFix_HelloReadOnlyObserver.dylib':ROOT/'Runtime/Identity/.theos/obj/WatchFix_HelloReadOnlyObserver.dylib',
 'WatchFix_HelloReadOnlyObserver.plist':ROOT/'Runtime/Identity/WatchFix_HelloReadOnlyObserver.plist',
 'SleepSyncCoordinator.sh':ROOT/'SleepSyncCoordinator.sh',
 'RootLauncher.sh':ROOT/'RootLauncher.sh',
}
hashes={}
for name,source in files.items():
    assert source.is_file() and not source.is_symlink(),source
    raw=source.read_bytes();(target/name).write_bytes(raw)
    if name.endswith('.plist'):
        # Theos binary-converts staged plists; normalize BEFORE recording bytes.
        subprocess.run(['/usr/bin/plutil','-convert','binary1',str(target/name)],check=True)
        raw=(target/name).read_bytes()
    (target/name).chmod(0o644)
    hashes[name]=hashlib.sha256(raw).hexdigest()
(target/'payload.sha256').write_text(''.join(f'{hashes[name]}  {name}\n' for name in sorted(hashes) if name.endswith(('.dylib','.plist'))))
# App UI integration can be reviewed/installed while execution remains unavailable.
# Enable only after fault-injection/cleanup and real launcher verification of this
# new coordinator, NOT by reusing the historical SSH trial's successful ACK.
(target/'module-info.plist').write_bytes(plistlib.dumps({'schema':1,'moduleVersion':'1.0.0~sleepmodule1',
 'enabledForDevice':False,'scope':'one Sleep update; explicit identity session; supervised recovery',
 'payloadSHA256':hashes,'blockedReason':'App/coordinator device acceptance pending'}))
print('Staged private SleepSync runtime with enabledForDevice=false:',target)
