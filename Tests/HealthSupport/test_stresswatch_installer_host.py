"""Exercise actual bridge installer methods against fake root commands on macOS.

Does not connect devices or run payload code. Mach-O headers are read as data.
"""
from pathlib import Path
import hashlib
import struct
import subprocess
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[2]


class InstallerHostTest(unittest.TestCase):
    def test_actual_installer_success_disable_rejection_and_rollback(self):
        source = (PROJECT / 'App/Bridge/Plugin/PluginBridge.xm').read_text()
        helper = source[source.index('static NSString *StressWatchTextDigest('):]
        helper = helper[:helper.index('\n}\n') + 3]
        methods = source[source.index('+ (BOOL)healthSupportStressWatchEnabled {'):]
        methods = methods[:methods.index('\n+ (UIImage *)')]
        # Synthetic Mach-O data only: clean clones need neither a built iOS
        # library nor the private accepted device readback.
        def macho_fixture(code):
            header = struct.pack('<8I', 0xfeedfacf, 0x0100000c, 0, 6, 1, 152, 0, 0)
            segment = struct.pack('<II16sQQQQiiII', 0x19, 152, b'__TEXT', 0, 4096,
                                  0, 184 + len(code), 5, 5, 1, 0)
            section = struct.pack('<16s16sQQIIIIIIII', b'__text', b'__TEXT',
                                  184, len(code), 184, 2, 0, 0, 0, 0, 0, 0)
            return header + segment + section + code

        current_code, legacy_code = b'current-test-code-not-executable', b'legacy-test-code-not-executable'
        legacy_digest = hashlib.sha256(legacy_code).hexdigest()
        methods = methods.replace('b64e4ae25fd829efd456a9a633502a3bf6bc540f2c809908d94fd24f82a6c918', legacy_digest)
        prelude = r'''
#import <Foundation/Foundation.h>
#include <CommonCrypto/CommonDigest.h>
#include <mach-o/loader.h>
#include <sys/stat.h>
#include <errno.h>
static NSString *base;
static NSString *const kDynamicLibrariesRelativePath = @"/injection";
static int failAt, calls;
static BOOL failForever;
static NSString *JBRootPath(NSString *path) { return [base stringByAppendingString:path]; }
static NSURL *PluginBundleURLNamed(NSString *name) {
    (void)name; return [NSURL fileURLWithPath:[base stringByAppendingPathComponent:@"HealthSupport.wffix"]];
}
static NSError *BridgeError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"test" code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}
static BOOL Fail(NSError **error) {
    ++calls;
    if (failAt && (calls == failAt || (failForever && calls >= failAt))) {
        if (error) *error = BridgeError(99, @"injected root command failure");
        return YES;
    }
    return NO;
}
static BOOL RunRootCommand(NSString *command, NSArray *args, NSInteger code, NSString *message, NSError **error) {
    (void)code; (void)message;
    if (Fail(error)) return NO;
    if ([command isEqual:@"/bin/cp"]) {
        NSString *src = args[args.count - 2], *dest = args.lastObject;
        NSFileManager *fm = NSFileManager.defaultManager;
        if ([fm fileExistsAtPath:dest] && ![fm removeItemAtPath:dest error:error]) return NO;
        return [fm copyItemAtPath:src toPath:dest error:error];
    }
    // Only ownership/mode commands may otherwise be requested; no service restart.
    NSCAssert(([@[@"/usr/sbin/chown", @"/usr/bin/chmod"] containsObject:command]), @"unexpected command");
    return YES;
}
static BOOL RemoveItemAsRoot(NSURL *url, NSInteger code, NSString *message, NSError **error) {
    (void)code; (void)message;
    if (Fail(error)) return NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:url.path]) return YES;
    return [NSFileManager.defaultManager removeItemAtURL:url error:error];
}
@interface WFPluginBridge : NSObject
+ (BOOL)healthSupportStressWatchEnabled;
+ (BOOL)healthSupportStressWatchNeedsMigration;
+ (BOOL)setHealthSupportStressWatchEnabled:(BOOL)enabled error:(NSError **)error;
@end
'''
        main = r'''
static void Check(BOOL condition, const char *label) {
    if (!condition) { fprintf(stderr, "FAILED: %s\n", label); exit(1); }
}
static NSString *Target(NSString *ext) {
    return [JBRootPath(kDynamicLibrariesRelativePath) stringByAppendingPathComponent:[@"WatchFix_HealthSupportStressWatch" stringByAppendingPathExtension:ext]];
}
static NSDictionary *Snapshot(void) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSString *dir = JBRootPath(kDynamicLibrariesRelativePath);
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:NULL])
        result[name] = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:name]];
    return result;
}
int main(int argc, char **argv) {
    @autoreleasepool {
        Check(argc == 4, "arguments"); base = @(argv[1]);
        NSString *payload = [[PluginBundleURLNamed(@"HealthSupport") path] stringByAppendingPathComponent:@"StressWatch"];
        NSFileManager *fm = NSFileManager.defaultManager;
        [fm createDirectoryAtPath:payload withIntermediateDirectories:YES attributes:nil error:NULL];
        [fm createDirectoryAtPath:JBRootPath(kDynamicLibrariesRelativePath) withIntermediateDirectories:YES attributes:nil error:NULL];
        NSString *lib = [payload stringByAppendingPathComponent:@"StressWatchCompatibility.dylib"];
        Check([fm copyItemAtPath:@(argv[2]) toPath:lib error:NULL], "copy binary data fixture");
        NSDictionary *filter = @{@"Filter": @{@"Bundles": @[@"com.ideation.Stress"]}};
        [filter writeToFile:[payload stringByAppendingPathComponent:@"Filter.plist"] atomically:YES];
        NSMutableDictionary *hashes = [NSMutableDictionary dictionary];
        for (NSString *name in @[@"StressWatchCompatibility.dylib", @"Filter.plist"]) {
            NSData *d = [NSData dataWithContentsOfFile:[payload stringByAppendingPathComponent:name]];
            unsigned char hash[32]; CC_SHA256(d.bytes, (CC_LONG)d.length, hash);
            NSMutableString *hex = [NSMutableString string];
            for (int i=0;i<32;++i) [hex appendFormat:@"%02x", hash[i]];
            hashes[name] = hex;
        }
        [@{@"schema": @1, @"sha256": hashes} writeToFile:[payload stringByAppendingPathComponent:@"Identity.plist"] atomically:YES];
        // Fake root metadata for the owned regular file check only. Real root
        // commands never run in this test and payload bytes are never loaded.
        NSError *error = nil;
        Check([WFPluginBridge setHealthSupportStressWatchEnabled:YES error:&error], "fresh enable");
        Check([WFPluginBridge healthSupportStressWatchEnabled], "state on");
        NSDictionary *before = Snapshot();
        for (int point = 1; point <= 12; ++point) {
            calls = 0; failAt = point; error = nil;
            Check(![WFPluginBridge setHealthSupportStressWatchEnabled:YES error:&error], "injected install failure");
            Check(error != nil && [before isEqual:Snapshot()], "file rollback exact at every root command");
        }
        calls = 0; failAt = 0;
        Check([WFPluginBridge setHealthSupportStressWatchEnabled:NO error:&error], "disable");
        Check(![WFPluginBridge healthSupportStressWatchEnabled], "state off");
        NSString *legacyStem = [JBRootPath(kDynamicLibrariesRelativePath) stringByAppendingPathComponent:@"WatchFix_StressWatchSleepModelGate"];
        Check([fm copyItemAtPath:@(argv[3]) toPath:[legacyStem stringByAppendingPathExtension:@"dylib"] error:NULL], "legacy fixture");
        [filter writeToFile:[legacyStem stringByAppendingPathExtension:@"plist"] atomically:YES];
        Check([WFPluginBridge healthSupportStressWatchNeedsMigration], "legacy detected");
        Check([WFPluginBridge setHealthSupportStressWatchEnabled:YES error:&error], "legacy migrate");
        Check(![WFPluginBridge healthSupportStressWatchNeedsMigration] && [WFPluginBridge healthSupportStressWatchEnabled], "legacy retired new enabled");
        Check([WFPluginBridge setHealthSupportStressWatchEnabled:NO error:&error], "migrated disable");
        [@{@"Filter": @{@"Bundles": @[@"foreign.app"]}} writeToFile:Target(@"plist") atomically:YES];
        before = Snapshot(); calls=0;
        Check(![WFPluginBridge setHealthSupportStressWatchEnabled:YES error:&error], "foreign filter refused");
        Check(calls == 0 && [before isEqual:Snapshot()], "foreign filter untouched");
        [fm removeItemAtPath:Target(@"plist") error:NULL];
        [fm createSymbolicLinkAtPath:Target(@"dylib") withDestinationPath:lib error:NULL];
        calls=0;
        Check(![WFPluginBridge setHealthSupportStressWatchEnabled:YES error:&error] && calls==0, "symlink refused");
        [fm removeItemAtPath:Target(@"dylib") error:NULL];
        Check([WFPluginBridge setHealthSupportStressWatchEnabled:YES error:&error], "enable again");
        calls=0; failAt=7; failForever=YES; error=nil;
        Check(![WFPluginBridge setHealthSupportStressWatchEnabled:YES error:&error], "persistent failure");
        Check([error.localizedDescription containsString:@"rollback incomplete"], "rollback error visible");
        puts("PASS: actual bridge fresh enable/disable, injected failure rollback, foreign filter and symlink refusal, incomplete rollback reporting");
    }
}
'''
        # Simulate root ownership on host fixtures, leaving real mode/link checks.
        methods = methods.replace('st.st_uid != 0', 'st.st_uid != getuid()')
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fixture = root / 'current-fixture.bin'
            fixture.write_bytes(macho_fixture(current_code))
            legacy = root / 'legacy-fixture.bin'
            legacy.write_bytes(macho_fixture(legacy_code))
            mm = root / 'test.mm'
            mm.write_text(prelude + helper + '\n@implementation WFPluginBridge\n' + methods + '\n@end\n' + main)
            binary = root / 'test-installer'
            subprocess.run(['xcrun', 'clang++', '-fobjc-arc', '-std=c++17', '-framework', 'Foundation',
                            '-Wno-deprecated-declarations', str(mm), '-o', str(binary)], check=True)
            subprocess.run([str(binary), str(root / 'fake-root'), str(fixture), str(legacy)], check=True)


if __name__ == '__main__':
    unittest.main(verbosity=2)
