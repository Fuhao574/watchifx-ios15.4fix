#import <Foundation/Foundation.h>
#include <cassert>
@interface HostReader : NSObject
@property(nonatomic,strong) NSArray<NSDictionary *> *fields;
@property(nonatomic) NSUInteger index;
@property(nonatomic) BOOL error;
@property(nonatomic) NSUInteger dataReads, boolReads, skips;
- (BOOL)hasMoreData;
- (BOOL)hasError;
- (void)readTag:(uint32_t *)tag type:(uint8_t *)type;
- (NSData *)readData;
- (BOOL)readBOOL;
- (BOOL)skipValueWithTag:(uint32_t)tag type:(uint8_t)type;
@end
#include "../../Plugins/PhotoLibrarySupport/PhotoAssetRequest.h"
@implementation HostReader
- (BOOL)hasMoreData {return self.index<self.fields.count;}
- (BOOL)hasError {return self.error;}
- (void)readTag:(uint32_t *)tag type:(uint8_t *)type {
    NSDictionary *field=self.fields[self.index++];
    *tag=[field[@"tag"] unsignedIntValue];*type=[field[@"type"] unsignedCharValue];
    if([field[@"readError"] boolValue])self.error=YES;
}
- (NSData *)readData {++_dataReads;return self.fields[self.index-1][@"value"];}
- (BOOL)readBOOL {++_boolReads;return YES;}
- (BOOL)skipValueWithTag:(uint32_t)tag type:(uint8_t)type {
    (void)tag;(void)type;++_skips;return ![self.fields[self.index-1][@"skipError"] boolValue];
}
@end
static HostReader *Reader(NSArray *fields) {HostReader *r=[HostReader new];r.fields=fields;return r;}
int main(void) {
    @autoreleasepool {
        NSData *uuid=[NSMutableData dataWithLength:16];
        NSDictionary *valid=@{@"tag":@1,@"type":@2,@"value":uuid};
        HostReader *r=Reader(@[valid]);assert(WFPhotoReadAssetUUID(r)==uuid);
        r=Reader(@[@{@"tag":@2,@"type":@0},valid,@{@"tag":@3,@"type":@2}]);
        assert(WFPhotoReadAssetUUID(r)==uuid&&r.boolReads==1&&r.skips==1);
        for(NSArray *fields in @[@[],@[valid,valid],@[@{@"tag":@1,@"type":@0,@"value":uuid}],
              @[@{@"tag":@1,@"type":@2,@"value":[NSData data]}],
              @[@{@"tag":@1,@"type":@2,@"value":@"wrong"}],
              @[@{@"tag":@2,@"type":@2}],@[@{@"tag":@0,@"type":@0}],
              @[@{@"tag":@1,@"type":@2,@"readError":@YES}],
              @[valid,@{@"tag":@3,@"type":@2,@"skipError":@YES}]]) {
            r=Reader(fields);assert(!WFPhotoReadAssetUUID(r));
        }
        r=Reader(@[@{@"tag":@1,@"type":@0,@"value":uuid}]);
        assert(!WFPhotoReadAssetUUID(r)&&r.dataReads==0);
        NSMutableArray *many=[NSMutableArray arrayWithObject:valid];
        for(int i=0;i<64;++i)[many addObject:@{@"tag":@3,@"type":@0}];
        assert(!WFPhotoReadAssetUUID(Reader(many)));
        assert(!WFPhotoReadAssetUUID(nil));
        puts("PASS actual asset request parser: valid UUID, wire types, malformed fields and bounds");
    }
}
