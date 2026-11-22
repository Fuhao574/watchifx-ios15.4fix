"""Compile actual export completion block with a URL-only temporary file mock."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
PREFIX=r'''
#import <Foundation/Foundation.h>
#include <cassert>
static NSString *const IDSSendMessageOptionTimeoutKey=@"timeout";
static NSString *const IDSSendMessageOptionPeerResponseIdentifierKey=@"response";
static NSInteger const kWFSendPriorityHigh=200;
static NSUInteger sends, deaths;
static id expectedID;
static NSDictionary *expectedMetadata;
static void WFPhotoEvent(const char *,unsigned long) {}
#define Log(...) ((void)0)
static id WatchFixIDSDestinationForDevice(id device) {return device;}
@interface NPTOTemporaryFile:NSObject
- (NSURL *)URL;
@end
@implementation NPTOTemporaryFile
- (NSURL *)URL {return [NSURL fileURLWithPath:@"/host-only-synthetic-file"];}
- (void)dealloc {++deaths;}
@end
@interface HostService:NSObject
- (BOOL)sendResourceAtURL:(NSURL *)url metadata:(NSDictionary *)metadata toDestinations:(NSSet *)destinations priority:(NSInteger)priority options:(NSDictionary *)options identifier:(id *)identifier error:(NSError **)error;
@end
@implementation HostService
- (BOOL)sendResourceAtURL:(NSURL *)url metadata:(NSDictionary *)metadata toDestinations:(NSSet *)destinations priority:(NSInteger)priority options:(NSDictionary *)options identifier:(id *)identifier error:(NSError **)error {
    assert(url.isFileURL&&[metadata isEqual:expectedMetadata]);
    assert(destinations.count==1&&priority==200&&[options[@"timeout"] isEqual:@60]);
    assert(options[@"response"]==expectedID&&deaths==0);(void)identifier;(void)error;++sends;return YES;
}
@end
@interface HostHelper:NSObject
@property(nonatomic,strong) NSOperationQueue *sendAssetsQueue;
@property(nonatomic,strong) HostService *service;
@property(nonatomic,strong) id idsDevice;
- (void (^)(NPTOTemporaryFile *,NSDictionary *,NSError *))completion;
@end
@implementation HostHelper
- (void (^)(NPTOTemporaryFile *,NSDictionary *,NSError *))completion {
    __weak __typeof__(self) weakSelf=self;
    id outgoingResponseIdentifier=expectedID;
    return [
'''
SUFFIX=r'''
    copy];
}
@end
int main(void) {
 @autoreleasepool {
    HostHelper *helper=[HostHelper new];helper.service=[HostService new];helper.idsDevice=@"host-device";
    helper.sendAssetsQueue=[NSOperationQueue new];helper.sendAssetsQueue.suspended=YES;
    expectedID=[NSObject new];expectedMetadata=@{@"host":@1};
    void (^callback)(NPTOTemporaryFile *,NSDictionary *,NSError *)=[helper completion];
    __weak NPTOTemporaryFile *weakFile;
    @autoreleasepool {
        NPTOTemporaryFile *file=[NPTOTemporaryFile new];weakFile=file;
        assert(![file respondsToSelector:@selector(metadata)]);
        NSMutableDictionary *metadata=[expectedMetadata mutableCopy];
        callback(file,metadata,nil);metadata[@"host"]=@99;
    }
    assert(weakFile&&deaths==0&&helper.sendAssetsQueue.operationCount==1);
    callback(nil,expectedMetadata,nil);
    callback(weakFile,nil,nil);
    callback(weakFile,expectedMetadata,[NSError errorWithDomain:@"host" code:1 userInfo:nil]);
    assert(helper.sendAssetsQueue.operationCount==1);
    helper.sendAssetsQueue.suspended=NO;[helper.sendAssetsQueue waitUntilAllOperationsAreFinished];
    assert(sends==1);
    puts("PASS native three-argument completion, separate metadata, delayed temporary-file lifetime and errors");
 }
}
'''


class ExportCallbackTests(unittest.TestCase):
    def test_actual_export_completion(self):
        source=(ROOT/'Plugins/PhotoLibrarySupport/PhotoLibrarySupport.xm').read_text()
        body=source.split('[asset npto_exportForDevice:pairedDevice completionHandler:',1)[1].split('\n                }];',1)[0]+'\n                }'
        self.assertIn('NSDictionary *exportMetadata, NSError *exportError',body)
        self.assertNotIn('[temporaryFile metadata]',body)
        (ROOT/'reports').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='photo-export-',dir=ROOT/'reports') as tmp:
            work=Path(tmp);f=work/'host.mm';binary=work/'test';f.write_text(PREFIX+body+SUFFIX)
            result=subprocess.run(['xcrun','clang++','-std=c++17','-fobjc-arc','-fblocks','-Wall','-Wextra','-Werror','-framework','Foundation',str(f),'-o',str(binary)],capture_output=True,text=True,timeout=60)
            self.assertEqual(result.returncode,0,result.stderr)
            result=subprocess.run([str(binary)],capture_output=True,text=True,timeout=10)
            self.assertEqual(result.returncode,0,result.stderr)


if __name__=='__main__':unittest.main(verbosity=2)
