#import <Foundation/Foundation.h>
#include <cassert>
#include "../../Plugins/PhotoLibrarySupport/PhotoResponseContext.h"

@interface HostContext : NSObject <WFPhotoResponseContext>
@property(nonatomic, strong) id identifier;
@property(nonatomic) NSUInteger reads;
@end
@implementation HostContext
- (id)outgoingResponseIdentifier { self.reads++; return self.identifier; }
@end
// Deliberately has NO outgoingResponseIdentifier method, like native IDSProtobuf.
@interface HostProtobuf : NSObject <WFPhotoProtobufContext>
@property(nonatomic, strong) id context;
@end
@implementation HostProtobuf
@end

int main(void) {
    @autoreleasepool {
        HostContext *callback=[HostContext new], *embedded=[HostContext new];
        callback.identifier=[NSObject new];embedded.identifier=[NSObject new];
        HostProtobuf *protobuf=[HostProtobuf new];protobuf.context=embedded;
        assert(![protobuf respondsToSelector:@selector(outgoingResponseIdentifier)]);
        assert(WFPhotoOutgoingResponseIdentifier(callback,protobuf)==callback.identifier);
        assert(embedded.reads==0); // authoritative callback; no duplicate lookup
        assert(WFPhotoOutgoingResponseIdentifier(nil,protobuf)==embedded.identifier);
        assert(WFPhotoOutgoingResponseIdentifier([NSObject new],protobuf)==embedded.identifier);
        callback.identifier=nil;
        assert(WFPhotoOutgoingResponseIdentifier(callback,protobuf)==nil);
        protobuf.context=[NSObject new];
        assert(WFPhotoOutgoingResponseIdentifier(nil,protobuf)==nil);
        assert(WFPhotoOutgoingResponseIdentifier(nil,[NSObject new])==nil);
        assert(WFPhotoOutgoingResponseIdentifier(nil,nil)==nil);
        puts("PASS response context: native-like protobuf, callback precedence, nil and unsupported contexts");
    }
    return 0;
}
