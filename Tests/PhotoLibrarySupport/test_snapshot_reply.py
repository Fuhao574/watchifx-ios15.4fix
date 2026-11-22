"""Compile the actual snapshot reply branch with Foundation transport mocks.

Only the branch under test is extracted verbatim. No device/Photos/IDS runtime.
"""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
MODULE = ROOT/'Plugins/PhotoLibrarySupport'
PREFIX = r'''
#import <Foundation/Foundation.h>
#include <cassert>
#include "PhotoResponseContext.h"
static NSUInteger prepared, signals, snapshots, submessages;
static NSString *const IDSSendMessageOptionTimeoutKey=@"timeout";
static NSString *const IDSSendMessageOptionPeerResponseIdentifierKey=@"response";
static NSUInteger const kWFPhotoSyncSnapshotProtobufType=102;
static id expectedIdentifier;
static void WFPhotoEvent(const char *, unsigned long) {}
#define Log(...) ((void)0)
static id WatchFixIDSDestinationForDevice(id device) {return device;}
@interface PBDataWriter : NSObject
- (void)writeString:(NSString *)value forTag:(uint32_t)tag;
- (NSData *)data;
@end
@implementation PBDataWriter
- (void)writeString:(NSString *)value forTag:(uint32_t)tag {assert(tag==3&&[value isEqual:@"host-hash"]);}
- (NSData *)data {return [@"host-bytes" dataUsingEncoding:NSUTF8StringEncoding];}
@end
static void PBDataWriterWriteSubmessage(id writer,id value,uint32_t tag) {
    assert(writer&&value&&(tag==1||tag==2));++submessages;
}
@interface IDSProtobuf : NSObject
- (instancetype)initWithProtobufData:(NSData *)bytes type:(NSUInteger)type isResponse:(BOOL)response;
@end
@implementation IDSProtobuf
- (instancetype)initWithProtobufData:(NSData *)bytes type:(NSUInteger)type isResponse:(BOOL)response {
    assert(bytes.length&&type==102&&response);return [super init];
}
@end
@interface HostContext : NSObject
- (id)outgoingResponseIdentifier;
@end
@implementation HostContext
- (id)outgoingResponseIdentifier {return expectedIdentifier;}
@end
@interface HostRequest : NSObject
- (id)library;
- (id)collectionTargetList;
@end
@implementation HostRequest
- (id)library {return @"host-library";}
- (id)collectionTargetList {return @"host-targets";}
@end
@interface HostService : NSObject
- (BOOL)sendProtobuf:(id)protobuf toDestinations:(NSSet *)destinations priority:(NSInteger)priority options:(NSDictionary *)options identifier:(id *)identifier error:(NSError **)error;
@end
static NSInteger const kWFSendPriorityHigh=200;
@implementation HostService
- (BOOL)sendProtobuf:(id)protobuf toDestinations:(NSSet *)destinations priority:(NSInteger)priority options:(NSDictionary *)options identifier:(id *)identifier error:(NSError **)error {
    assert(protobuf&&destinations.count==1&&priority==200&&[options[@"timeout"] isEqual:@60]);
    assert(options[@"response"]==expectedIdentifier);(void)identifier;(void)error;++snapshots;return YES;
}
@end
@interface HostHelper : NSObject
@property(nonatomic,strong) dispatch_queue_t syncQueue;
@property(nonatomic,strong) HostRequest *syncRequest;
@property(nonatomic,strong) HostService *service;
@property(nonatomic,strong) id idsDevice;
@property(nonatomic,copy) NSString *syncHash;
- (void)reply:(id)protobuf context:(id)context;
- (void)preparePhotoSyncRequest;
- (void)sendPhotoSyncSignalIfNeeded;
@end
@implementation HostHelper
- (void)preparePhotoSyncRequest {++prepared;self.syncRequest=[HostRequest new];self.syncHash=@"host-hash";}
- (void)sendPhotoSyncSignalIfNeeded {++signals;assert(false&&"snapshot must not start a new handshake");}
- (void)reply:(id)protobuf context:(id)context {
'''
SUFFIX = r'''
}
@end
int main(void) {
    @autoreleasepool {
        HostHelper *helper=[HostHelper new];helper.service=[HostService new];helper.idsDevice=@"host-peer";
        expectedIdentifier=[NSObject new];HostContext *context=[HostContext new];
        // Repeated requests must each get one response and never another signal.
        for(int queued=0;queued<2;++queued) {
            helper.syncQueue=queued?dispatch_queue_create("host.photo.sync",DISPATCH_QUEUE_SERIAL):nil;
            for(int i=0;i<10;++i)[helper reply:[NSObject new] context:context];
        }
        assert(prepared==20&&snapshots==20&&signals==0&&submessages==40);
        puts("PASS 20 actual snapshot replies, serial/no queue, no handshake feedback");
    }
}
'''


class SnapshotReplyTests(unittest.TestCase):
    def test_actual_reply_does_not_restart_handshake(self):
        source = (MODULE/'PhotoLibrarySupport.xm').read_text()
        branch = source.split('if (protobufType != kWFPhotoSyncSnapshotProtobufType)',1)[1]
        branch = branch[branch.index('    if (self.syncQueue)'):]
        branch = branch.split('\n}\n\n- (void)controllerDidInvalidateContent:',1)[0]
        self.assertNotIn('sendPhotoSyncSignalIfNeeded', branch)
        self.assertEqual(branch.count('preparePhotoSyncRequest'), 2)
        (ROOT/'reports').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='photo-snapshot-',dir=ROOT/'reports') as tmp:
            work=Path(tmp);fixture=work/'fixture.mm';binary=work/'host-test'
            fixture.write_text(PREFIX+branch+SUFFIX)
            result=subprocess.run(['xcrun','clang++','-std=c++17','-fobjc-arc','-fblocks',
                                   '-Wall','-Wextra','-Werror','-I',str(MODULE),'-framework','Foundation',
                                   str(fixture),'-o',str(binary)],capture_output=True,text=True,timeout=60)
            self.assertEqual(result.returncode,0,result.stderr)
            result=subprocess.run([str(binary)],capture_output=True,text=True,timeout=5)
            self.assertEqual(result.returncode,0,result.stderr)


if __name__ == '__main__':
    unittest.main(verbosity=2)
