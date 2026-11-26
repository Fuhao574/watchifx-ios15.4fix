"""Actual guard body with owned dyld/sysctl/header fixtures; no iOS execution."""
from pathlib import Path
import json
import struct
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[1]
LOAD = PROJECT / 'Modules/HealthSupport/LoadCheck'

PREFIX = r'''
#include <mach-o/loader.h>
#include <mach/machine.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <assert.h>
#include <stdio.h>
#include "LoadCheck.h"
#include "HostArchitectureObservation.h"
typedef int BOOL;
#define YES 1
#define NO 0
#if defined(WFHS_FIXTURE_ARM64E)
#define __arm64e__ 1
#endif
static WFHSLoadCheckReport report;
static struct {uint32_t compiledArm64e,runtimeObserved,observedFields,present,magic,filetype,cpu,subtype,pathObserved,pathExact;} hostObservation;
static struct {struct mach_header_64 header;struct uuid_command uuid;} owned;
static int scenario,systemCalls;
static const struct mach_header *FixtureHeader(uint32_t index) {
#if defined(WFHS_LOAD_CHECK_EXECUTABLE_SOURCE)
 assert(!"executable-source host gate must not use dyld index enumeration");
#endif
 assert(index==0);return scenario==1?NULL:(const struct mach_header *)&owned;
}
static const char *FixtureName(uint32_t index) {
#if defined(WFHS_LOAD_CHECK_EXECUTABLE_SOURCE)
 assert(!"executable-source host gate must not use dyld name enumeration");
#endif
 assert(index==0);return scenario==9?"/wrong/host":"/System/Library/Frameworks/HealthKit.framework/healthd";
}
static int FixtureSystem(const char *name,void *buffer,size_t *size,void *value,size_t length) {
 assert(!strcmp(name,"kern.osversion")&&!value&&!length&&*size>=7);++systemCalls;
 memcpy(buffer,scenario==8?"20A362":"19E241",7);*size=7;return 0;
}
#define _dyld_get_image_header(...) FixtureHeader(__VA_ARGS__)
#define _dyld_get_image_name(...) FixtureName(__VA_ARGS__)
#define sysctlbyname(...) FixtureSystem(__VA_ARGS__)
'''
SUFFIX = r'''
int main(void) {
 const uint8_t uuid[16]={0x6d,0xf2,0x88,0x54,0x8c,0xfc,0x3e,0x05,0x9b,0xd2,0xb6,0xd4,0x05,0xb0,0x68,0x5f};
 for(scenario=0;scenario<=11;++scenario) {
  memset(&report,0,sizeof(report));memset(&hostObservation,0,sizeof(hostObservation));memset(&owned,0,sizeof(owned));systemCalls=0;
  owned.header.magic=MH_MAGIC_64;owned.header.cputype=CPU_TYPE_ARM64;owned.header.cpusubtype=(cpu_subtype_t)0x80000002;
  owned.header.filetype=MH_EXECUTE;owned.header.ncmds=1;owned.header.sizeofcmds=sizeof(owned.uuid);
  owned.uuid.cmd=LC_UUID;owned.uuid.cmdsize=sizeof(owned.uuid);memcpy(owned.uuid.uuid,uuid,16);
  if(scenario==2)owned.header.magic=MH_CIGAM_64;
  if(scenario==3)owned.header.filetype=MH_DYLIB;
  if(scenario==4)owned.header.cputype=CPU_TYPE_X86_64;
  if(scenario==5)owned.header.cpusubtype=CPU_SUBTYPE_ARM64_ALL;
  if(scenario==6)owned.header.cpusubtype=CPU_SUBTYPE_ARM64E;
  if(scenario==7)owned.header.cpusubtype=CPU_SUBTYPE_ARM64_V8;
  if(scenario==10)owned.uuid.uuid[0]^=1;
  if(scenario==11)owned.uuid.cmdsize=7;
  BOOL pass=WFHSLoadCheckHost();
#if !defined(WFHS_FIXTURE_ARM64E)
  assert(!pass&&report.status==1&&systemCalls==0);
#if defined(WFHS_LOAD_CHECK_HOST_DIAGNOSTICS)
  assert(report.reserved==32&&hostObservation.runtimeObserved==0&&hostObservation.compiledArm64e==0);
#else
  assert(report.reserved==0);
#endif
#else
  assert(pass==(scenario==0||scenario==6));
  assert(report.status==(scenario>=1&&scenario<=7&&scenario!=6?1:(scenario==8?2:(scenario>=9?3:0))));
  assert(report.checkedBoundaries==0&&report.matchedBoundaries==0&&report.receiveEnabled==0&&report.hooksInstalled==0&&report.healthSamplesRead==0);
#if defined(WFHS_LOAD_CHECK_HOST_DIAGNOSTICS)
  uint32_t expected=scenario==1?1:(scenario==2?2:(scenario==3?4:(scenario==4?8:((scenario==5||scenario==7)?16:0))));
  assert(report.reserved==expected);
  assert(hostObservation.compiledArm64e==1&&hostObservation.runtimeObserved==1);
  assert(hostObservation.observedFields==(scenario==1?0:(scenario==2?1:(scenario==3?3:(scenario==4?7:15)))));
  assert(hostObservation.pathObserved==(scenario>=9||scenario==0||scenario==6));
  assert(hostObservation.pathExact==(scenario>=10||scenario==0||scenario==6));
#else
  assert(report.reserved==0);
#endif
  assert(systemCalls==((scenario>=1&&scenario<=7&&scenario!=6)?0:1));
#endif
 }
 // Exhaustively compare representative scalar combinations against old gate.
 uint32_t magics[]={0,0xfeedfacf,0xcffaedfe},types[]={0,2,6},cpus[]={0,0x100000c,0x1000007},subs[]={0,1,2,0x80000002,0xff000002,0x80000000};
 for(unsigned p=0;p<2;++p)for(unsigned m=0;m<3;++m)for(unsigned f=0;f<3;++f)for(unsigned c=0;c<3;++c)for(unsigned s=0;s<6;++s) {
  int oldReject=!p||magics[m]!=MH_MAGIC_64||types[f]!=MH_EXECUTE||cpus[c]!=CPU_TYPE_ARM64||((subs[s]&~(uint32_t)CPU_SUBTYPE_MASK)!=(uint32_t)CPU_SUBTYPE_ARM64E);
  assert((WFHSHostArchitectureMismatchBits(p,magics[m],types[f],cpus[c],subs[s])!=0)==oldReject);
 }
 puts("PASS actual host guard branches; exact arm64e+ABI-v2 passes; diagnostic unchanged gate; capabilities zero");
}
'''

EXECUTABLE_FIXTURES = r'''
typedef struct {const char *dli_fname;void *dli_fbase;const char *dli_sname;void *dli_saddr;} Dl_info;
static int executableHeaderCalls;
static struct mach_header_64 differentHeader;
static struct mach_header_64 *FixtureExecuteHeader(void) {
 ++executableHeaderCalls;
 if(scenario==17&&(executableHeaderCalls%2)==0)return &differentHeader;
 return scenario==1?NULL:&owned.header;
}
static int FixtureDladdr(const void *address,Dl_info *info) {
 assert(address==&owned.header);
 if(scenario==12)return 0;
 info->dli_fbase=scenario==13?&differentHeader:(void *)&owned.header;
 info->dli_fname=scenario==14?NULL:(scenario==9?"/wrong/host":"/System/Library/Frameworks/HealthKit.framework/healthd");
 return 1;
}
static int FixtureExecutablePath(char *path,uint32_t *size) {
 assert(*size>=128);
 if(scenario==15)return -1;
 strcpy(path,scenario==16?"/wrong/host":"/System/Library/Frameworks/HealthKit.framework/healthd");return 0;
}
#define _NSGetMachExecuteHeader(...) FixtureExecuteHeader(__VA_ARGS__)
#define _NSGetExecutablePath(...) FixtureExecutablePath(__VA_ARGS__)
#define dladdr(...) FixtureDladdr(__VA_ARGS__)
'''


class HostGuardTests(unittest.TestCase):
    def test_strict_executable_source_rejects_cross_binding(self):
        text = (LOAD / 'LoadCheck.m').read_text()
        uuid_function = text.split('static BOOL WFHSHeaderUUIDMatches(', 1)[1].split('static const struct mach_header *WFHSFindLoadedImage', 1)[0]
        guard_function = text.split('static BOOL WFHSLoadCheckHost(', 1)[1].split('static void WFHSCheckLoadedMetadata', 1)[0]
        suffix = SUFFIX.replace('scenario<=11', 'scenario<=17').replace('systemCalls=0;', 'systemCalls=0;executableHeaderCalls=0;')
        suffix = suffix.replace('scenario>=10||scenario==0||scenario==6', '(scenario>=10&&scenario<=11)||scenario==0||scenario==6')
        source = PREFIX + EXECUTABLE_FIXTURES + 'static BOOL WFHSHeaderUUIDMatches(' + uuid_function + '\nstatic BOOL WFHSLoadCheckHost(' + guard_function + suffix
        with tempfile.TemporaryDirectory(prefix='executable-source-', dir=HERE) as temp:
            work = Path(temp)
            (work / 'main.c').write_text(source)
            for optimization in ('-O0', '-O2'):
                command = ['xcrun', 'clang', '-std=c11', '-Wall', '-Wextra', '-Werror', '-Wno-unused-function', optimization,
                           '-fsanitize=address,undefined', '-DWFHS_FIXTURE_ARM64E=1', '-DWFHS_LOAD_CHECK_HOST_DIAGNOSTICS=1',
                           '-DWFHS_LOAD_CHECK_EXECUTABLE_SOURCE=1', '-I', str(LOAD), str(work / 'main.c'), '-o', str(work / 'test')]
                result = subprocess.run(command, capture_output=True, text=True, timeout=60)
                self.assertEqual(result.returncode, 0, result.stderr)
                run = subprocess.run([str(work / 'test')], capture_output=True, text=True, timeout=10)
                self.assertEqual(run.returncode, 0, run.stderr)

    def test_actual_host_guard_and_observation(self):
        text = (LOAD / 'LoadCheck.m').read_text()
        uuid_function = text.split('static BOOL WFHSHeaderUUIDMatches(', 1)[1].split('static const struct mach_header *WFHSFindLoadedImage', 1)[0]
        guard_function = text.split('static BOOL WFHSLoadCheckHost(', 1)[1].split('static void WFHSCheckLoadedMetadata', 1)[0]
        source = PREFIX + 'static BOOL WFHSHeaderUUIDMatches(' + uuid_function + '\nstatic BOOL WFHSLoadCheckHost(' + guard_function + SUFFIX
        with tempfile.TemporaryDirectory(prefix='host-guard-', dir=HERE) as temp:
            work = Path(temp)
            (work / 'main.c').write_text(source)
            for diagnostics in (False, True):
                for arm64e in (False, True):
                  for optimization in ('-O0', '-O2'):
                    with self.subTest(diagnostics=diagnostics, arm64e=arm64e, optimization=optimization):
                        command = ['xcrun', 'clang', '-std=c11', '-Wall', '-Wextra', '-Werror', '-Wno-unused-function', optimization,
                                   '-fsanitize=address,undefined', '-I', str(LOAD), str(work / 'main.c'), '-o', str(work / 'test')]
                        if diagnostics:
                            command += ['-DWFHS_LOAD_CHECK_HOST_DIAGNOSTICS=1']
                        if arm64e:
                            command += ['-DWFHS_FIXTURE_ARM64E=1']
                        result = subprocess.run(command, capture_output=True, text=True, timeout=60)
                        self.assertEqual(result.returncode, 0, result.stderr)
                        run = subprocess.run([str(work / 'test')], capture_output=True, text=True, timeout=10)
                        self.assertEqual(run.returncode, 0, run.stderr)

    def test_exact_host_disk_header_is_not_inherently_rejected(self):
        data = (PROJECT.parent / 'reports/health-host-firmware-local/System/Library/Frameworks/HealthKit.framework/healthd').read_bytes()
        magic, cpu, subtype, filetype = struct.unpack_from('<4I', data)
        self.assertEqual((magic, cpu, subtype, filetype), (0xfeedfacf, 0x100000c, 0x80000002, 2))
        self.assertEqual(subtype & 0xffffff, 2)

    def test_explicit_local_diagnostic_build(self):
        result = subprocess.run(['python3', '-B', str(LOAD / 'build_host_diagnostic_candidate.py')],
                                capture_output=True, text=True, cwd=PROJECT, timeout=120)
        self.assertEqual(result.returncode, 0, result.stderr)
        output = Path(next(line.split(': ', 1)[1] for line in result.stdout.splitlines() if line.startswith('BUILT local unsigned')))
        manifest = json.loads((output / 'build-local.json').read_text())
        self.assertIs(manifest['hostDiagnostics'], True)
        self.assertEqual(manifest['objcClassNamespace'], {'WFHSLoadedMethodIdentity': 'WFHSHostDiagV1LoadedMethodIdentity'})
        self.assertEqual(manifest['receiptMarker'], 'WFHSLC_HOSTDIAG_V1')
        for key in ('signed', 'installed', 'packaged', 'receiveEnabled', 'hooksInstalled', 'healthSamplesRead'):
            self.assertIs(manifest[key], False)
        for artifact in manifest['artifacts']:
            binary = output / artifact['file']
            self.assertIn(b'WFHSLC_HOSTDIAG_V1', binary.read_bytes())
            self.assertNotIn(b'WFHSLC_20261124_A1', binary.read_bytes())
            imports = subprocess.check_output(['xcrun', 'nm', '-u', str(binary)], text=True)
            symbols = subprocess.check_output(['xcrun', 'nm', str(binary)], text=True)
            for prefix in ('_OBJC_CLASS_$_', '_OBJC_METACLASS_$_'):
                self.assertIn(prefix + 'WFHSHostDiagV1LoadedMethodIdentity', symbols)
                self.assertNotIn(prefix + 'WFHSLoadedMethodIdentity\n', symbols)
            for name in ('_dlopen', '_open', '_write', '_sqlite3', '_task_for_pid', '_vm_read', '_connect', '_sandbox_extension'):
                self.assertNotIn(name, imports)

    def test_executable_source_local_build_and_namespace(self):
        result = subprocess.run(['python3', '-B', str(LOAD / 'build_executable_source_candidate.py')],
                                capture_output=True, text=True, cwd=PROJECT, timeout=120)
        self.assertEqual(result.returncode, 0, result.stderr)
        output = Path(next(line.split(': ', 1)[1] for line in result.stdout.splitlines() if line.startswith('BUILT local unsigned')))
        manifest = json.loads((output / 'build-local.json').read_text())
        self.assertTrue(manifest['executableSource'])
        self.assertEqual(manifest['receiptMarker'], 'WFHSLC_EXEC_SOURCE_V1')
        self.assertEqual(manifest['hostHeaderSource'], '_NSGetMachExecuteHeader+dladdr+_NSGetExecutablePath')
        for key in ('signed', 'installed', 'packaged', 'receiveEnabled', 'hooksInstalled', 'healthSamplesRead'):
            self.assertIs(manifest[key], False)
        for artifact in manifest['artifacts']:
            binary = output / artifact['file']
            symbols = subprocess.check_output(['xcrun', 'nm', str(binary)], text=True)
            self.assertIn('_OBJC_CLASS_$_WFHSExecSourceV1LoadedMethodIdentity', symbols)
            self.assertNotIn('_OBJC_CLASS_$_WFHSHostDiagV1LoadedMethodIdentity\n', symbols)
            self.assertNotIn('_OBJC_CLASS_$_WFHSLoadedMethodIdentity\n', symbols)
            if artifact['architecture'] == 'arm64e':
                self.assertIn('__NSGetMachExecuteHeader', symbols)
                self.assertIn('__NSGetExecutablePath', symbols)
            raw = binary.read_bytes()
            self.assertIn(b'WFHSLC_EXEC_SOURCE_V1', raw)
            self.assertNotIn(b'WFHSLC_HOSTDIAG_V1', raw)
            self.assertNotIn(b'WFHSLC_20261124_A1', raw)
            imports = subprocess.check_output(['xcrun', 'nm', '-u', str(binary)], text=True)
            for name in ('_dlopen', '_open', '_write', '_sqlite3', '_task_for_pid', '_vm_read', '_connect', '_sandbox_extension'):
                self.assertNotIn(name, imports)


if __name__ == '__main__':
    unittest.main(verbosity=2)
