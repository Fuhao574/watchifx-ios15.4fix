"""Bundle fixed module runtime; never installs or enables device execution."""
from pathlib import Path
import hashlib,json,plistlib,shutil,sys,subprocess,os
from postload_digest import allowed_hashes
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
brand_text=os.environ.get('WATCHFIX_SLEEP_SYNC_BRAND','')
brand=int(brand_text,16) if brand_text else None
device_candidate=os.environ.get('WATCHFIX_SLEEP_SYNC_TEST_CANDIDATE','0')=='1'
if device_candidate and brand is None:
    raise SystemExit('A device test candidate requires an explicit nonzero build brand; no unbound enable.')
postload={}
for name,source in files.items():
    assert source.is_file() and not source.is_symlink(),source
    raw=source.read_bytes();(target/name).write_bytes(raw)
    if name.endswith('.plist'):
        # Theos binary-converts staged plists; normalize BEFORE recording bytes.
        subprocess.run(['/usr/bin/plutil','-convert','binary1',str(target/name)],check=True)
        raw=(target/name).read_bytes()
    (target/name).chmod(0o644)
    hashes[name]=hashlib.sha256(raw).hexdigest()
    if name.endswith('.dylib'):
        allowed=allowed_hashes(raw,brand)
        if brand is not None:postload[name]=allowed[-1]
    else:postload[name]=hashes[name]
(target/'payload.sha256').write_text(''.join(f'{hashes[name]}  {name}\n' for name in sorted(hashes) if name.endswith(('.dylib','.plist'))))
(target/'postload.sha256').write_text(''.join(f'{postload[name]}  {name}\n' for name in sorted(postload) if name.endswith(('.dylib','.plist'))))
# Default builds stay disabled. A brand-bound test build is a separate explicit
# maintainer action, not a UI preference or proof of device acceptance.
(target/'module-info.plist').write_bytes(plistlib.dumps({'schema':1,'moduleVersion':'1.0.0~sleepmodule1',
 'enabledForDevice':device_candidate,'scope':'one Sleep update; explicit identity session; supervised recovery',
 'payloadSHA256':hashes,'postloadSHA256':postload,'brandHex':format(brand,'016X') if brand is not None else '',
 'buildKind':'brand-bound-device-test' if device_candidate else 'disabled-development-preview',
 'blockedReason':'App/coordinator device acceptance pending'}))
print('Staged private SleepSync runtime; enabledForDevice='+str(device_candidate).lower()+':',target)
