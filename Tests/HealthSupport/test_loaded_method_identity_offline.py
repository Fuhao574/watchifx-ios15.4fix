"""Loaded metadata checks on own cold fixtures only; no HealthKit or native hooks."""
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[1]
ADAPTER = PROJECT / 'Modules/HealthSupport/Adapters'
MAIN = r'''
#import "LoadedMethodIdentity.h"
#import "IOS154BoundaryIdentity.h"
#include <assert.h>
#include <dlfcn.h>
#include <stdio.h>
#if __has_feature(ptrauth_calls)
#include <ptrauth.h>
#endif

static NSUInteger calls,initializes,instanceResolves,classResolves;
@interface WFHSMIColdFixture : NSObject
- (NSInteger)number;
+ (NSInteger)classNumber;
@end
@implementation WFHSMIColdFixture
+ (void)initialize {++initializes;}
+ (BOOL)resolveInstanceMethod:(SEL)selector {(void)selector;++instanceResolves;return NO;}
+ (BOOL)resolveClassMethod:(SEL)selector {(void)selector;++classResolves;return NO;}
- (NSInteger)number {++calls;return 1;}
+ (NSInteger)classNumber {++calls;return 2;}
@end
@interface WFHSMIChildFixture : WFHSMIColdFixture @end
@implementation WFHSMIChildFixture @end

static NSInteger replacement(id receiver,SEL selector) {
    (void)receiver;(void)selector;++calls;return 3;
}
static const void *unsignedAddress(IMP imp) {
#if __has_feature(ptrauth_calls)
    return ptrauth_strip((void *)imp,ptrauth_key_function_pointer);
#else
    return (const void *)imp;
#endif
}
// Test-only borrowed inputs. In particular no ownership message to a cold Class.
typedef struct {
    Class __unsafe_unretained actual,owner;
    SEL selector;
    BOOL classMethod;
    NSString *__unsafe_unretained name,*__unsafe_unretained abi;
    NSString *__unsafe_unretained classPath,*__unsafe_unretained classUUID;
    NSString *__unsafe_unretained methodPath,*__unsafe_unretained methodUUID;
    NSNumber *__unsafe_unretained offset;
} Specification;
static WFHSLoadedMethodIdentity *identity(Specification s) {
    return [[WFHSLoadedMethodIdentity alloc] initWithClass:s.actual expectedClassName:s.name
        selector:s.selector isClassMethod:s.classMethod expectedMethodOwner:s.owner
        expectedIMPOffset:s.offset expectedABI:s.abi classImagePath:s.classPath
        classImageUUID:s.classUUID methodImagePath:s.methodPath methodImageUUID:s.methodUUID];
}
static void assertCold(void) {
    assert(calls==0&&initializes==0&&instanceResolves==0&&classResolves==0);
}
#define REJECT(field,value) do {Specification bad=spec;bad.field=(value);assert(!identity(bad));assertCold();} while(0)

int main(void) {
 @autoreleasepool {
    // Discovery is confined to these executable-owned fixtures, never the module.
    Class __unsafe_unretained cold=objc_lookUpClass("WFHSMIColdFixture");
    Class __unsafe_unretained child=objc_lookUpClass("WFHSMIChildFixture");
    assert(cold&&child);assertCold();
    for(NSInteger boundary=WFHSIOS154EnumeratorInitialize;boundary<=WFHSIOS154StageInsert;++boundary) {
        assert(!WFHSCheckIOS154Boundary((WFHSIOS154Boundary)boundary,cold));assertCold();
    }
    SEL number=sel_registerName("number"),classNumber=sel_registerName("classNumber");
    unsigned count=0;Method *methods=class_copyMethodList(cold,&count);Method method=NULL;
    for(unsigned i=0;i<count;++i)if(sel_isEqual(method_getName(methods[i]),number))method=methods[i];
    free(methods);assert(method);
    IMP original=method_getImplementation(method);const void *address=unsignedAddress(original);
    Dl_info info;assert(dladdr(address,&info)&&info.dli_fbase&&info.dli_fname);
    NSString *path=@(class_getImageName(cold));
    NSString *classUUID=WFHSLoadedImageUUIDForAddress((__bridge const void *)cold);
    NSString *methodUUID=WFHSLoadedImageUUIDForAddress(address);
    NSString *methodPath=@(info.dli_fname),*abi=@(method_getTypeEncoding(method));
    NSNumber *offset=@((uintptr_t)address-(uintptr_t)info.dli_fbase);
    assert(classUUID.length==36&&methodUUID.length==36&&[abi isEqualToString:@"q16@0:8"]);
    Specification spec={cold,cold,number,NO,@"WFHSMIColdFixture",abi,path,classUUID,methodPath,methodUUID,offset};
    WFHSLoadedMethodIdentity *guard=identity(spec);
    assert(guard&&guard.stillMatches);assertCold();
    NSString *wrongUUID=@"00000000-0000-0000-0000-000000000000";
    REJECT(actual,Nil);
    REJECT(actual,object_getClass(cold));
    REJECT(owner,Nil);
    REJECT(owner,child);
    REJECT(owner,object_getClass(cold));
    REJECT(name,@"NotTheFixture");
    REJECT(name,@"");
    REJECT(selector,NULL);
    REJECT(selector,sel_registerName("missingInstanceSelector"));
    REJECT(abi,@"i16@0:8");
    REJECT(abi,@"");
    REJECT(classPath,@"/not/the/loaded/class/image");
    REJECT(methodPath,@"/not/the/loaded/method/image");
    REJECT(classUUID,wrongUUID);
    REJECT(methodUUID,wrongUUID);
    REJECT(offset,@(offset.unsignedLongLongValue+1));
    Specification lowercase=spec;
    NSString *lowerClassUUID=classUUID.lowercaseString,*lowerMethodUUID=methodUUID.lowercaseString;
    lowercase.classUUID=lowerClassUUID;lowercase.methodUUID=lowerMethodUUID;
    assert(identity(lowercase).stillMatches);assertCold();

    Specification classSpec=spec;
    classSpec.classMethod=YES;classSpec.selector=classNumber;
    classSpec.owner=object_getClass(cold);classSpec.offset=nil;
    WFHSLoadedMethodIdentity *classGuard=identity(classSpec);
    assert(classGuard&&classGuard.stillMatches);assertCold();
    Specification wrongClassOwner=classSpec;wrongClassOwner.owner=cold;
    assert(!identity(wrongClassOwner));assertCold();
    Specification missingClass=classSpec;missingClass.selector=sel_registerName("missingClassSelector");
    assert(!identity(missingClass));assertCold();

    // Fixture mutation is deliberately sequential. No claim about racing users.
    method_setImplementation(method,(IMP)replacement);
    assert(!guard.stillMatches&&classGuard.stillMatches);
    assert(!identity(spec)); // offset pins the originally audited implementation
    Specification observed=spec;observed.offset=nil;
    WFHSLoadedMethodIdentity *observation=identity(observed);
    assert(observation&&observation.stillMatches); // nil accepts initial same-image drift
    method_setImplementation(method,original); // only our own fixture is restored
    assert(guard.stillMatches&&!observation.stillMatches);assertCold();

    Specification inherited=spec;
    inherited.actual=child;inherited.name=@"WFHSMIChildFixture";
    WFHSLoadedMethodIdentity *inheritedGuard=identity(inherited);
    assert(inheritedGuard&&inheritedGuard.stillMatches);
    Specification wrongInherited=inherited;wrongInherited.owner=child;
    assert(!identity(wrongInherited));assertCold();
    assert(class_addMethod(child,number,original,abi.UTF8String));
    assert(!inheritedGuard.stillMatches&&guard.stillMatches); // same ABI/IMP, changed owner
    inherited.owner=child;
    assert(identity(inherited).stillMatches);assertCold();

    Specification inheritedClass=classSpec;
    inheritedClass.actual=child;inheritedClass.name=@"WFHSMIChildFixture";
    WFHSLoadedMethodIdentity *inheritedClassGuard=identity(inheritedClass);
    assert(inheritedClassGuard&&inheritedClassGuard.stillMatches);assertCold();
    assert(!WFHSLoadedImageUUIDForAddress(NULL));
    // Explicitly release every retained guard while the fixtures are still cold.
    guard=nil;classGuard=nil;observation=nil;inheritedGuard=nil;inheritedClassGuard=nil;
    assertCold();
    puts("PASS cold class/ABI/owner/path/UUID/offset/IMP drift; no target method invocation");
 }
 assertCold(); // includes guard destruction and autorelease-pool drain
 return 0;
}
'''


class LoadedMethodIdentityTests(unittest.TestCase):
    def test_metadata_only_module_contract(self):
        implementation = (ADAPTER / 'LoadedMethodIdentity.m').read_text()
        header = (ADAPTER / 'LoadedMethodIdentity.h').read_text()
        for forbidden in ('reports/', 'SleepMethodIdentity', 'objc_lookUpClass',
                          'objc_getClass(', 'NSClassFromString', 'dlopen(',
                          'method_setImplementation', 'class_addMethod',
                          'class_getInstanceMethod', 'class_getClassMethod', 'HealthKit'):
            self.assertNotIn(forbidden, implementation + header)
        self.assertIn('ptrauth_strip((void *)imp,ptrauth_key_function_pointer)', implementation)
        self.assertIn('@property(nonatomic,assign) Class actualClass;', implementation)
        self.assertIn('@property(nonatomic,assign) Class methodOwner;', implementation)
        self.assertIn('check-use race', header)
        self.assertIn('OBSERVATION ONLY', header)

    def test_actual_guard_on_own_cold_classes(self):
        # Only this exact per-test directory is written/cleaned. No existing runner,
        # deployment script, device command, network call or HealthKit is invoked.
        with tempfile.TemporaryDirectory(prefix='loaded-identity-host-', dir=HERE) as temporary:
            work = Path(temporary)
            source, binary = work / 'main.m', work / 'identity'
            source.write_text(MAIN)
            for optimization in ('-O0', '-O2'):
                with self.subTest(optimization=optimization):
                    built = subprocess.run([
                        'xcrun', 'clang', '-fobjc-arc', optimization, '-Wall', '-Wextra', '-Werror',
                        '-fsanitize=address,undefined', '-framework', 'Foundation', '-I', str(ADAPTER),
                        str(ADAPTER / 'LoadedMethodIdentity.m'), str(ADAPTER / 'IOS154BoundaryIdentity.m'),
                        str(source), '-o', str(binary),
                    ], capture_output=True, text=True, timeout=60, cwd=work)
                    self.assertEqual(built.returncode, 0, built.stderr)
                    result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10, cwd=work)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn('no target method invocation', result.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
