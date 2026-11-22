#pragma once
#import <Foundation/Foundation.h>

// Structural validation only. No new fields, identifiers or request are made.
// Validate wire type before asking the native reader to consume a field value.
static inline NSData *WFPhotoReadAssetUUID(id reader) {
    if (!reader) return nil;
    NSData *uuidBytes=nil;
    NSUInteger fields=0;
    while ([reader hasMoreData] && ![reader hasError]) {
        if (++fields>64) return nil;
        uint32_t tag=0;uint8_t type=0;
        [reader readTag:&tag type:&type];
        if ([reader hasError] || tag==0) return nil;
        if (tag==1) {
            if (type!=2 || uuidBytes) return nil;
            id bytes=[reader readData];
            if (![bytes isKindOfClass:[NSData class]] || [bytes length]!=16) return nil;
            uuidBytes=bytes;
        } else if (tag==2) {
            if (type!=0) return nil;
            [reader readBOOL];
        } else if (![reader skipValueWithTag:tag type:type]) {
            return nil;
        }
    }
    return [reader hasError]?nil:uuidBytes;
}
