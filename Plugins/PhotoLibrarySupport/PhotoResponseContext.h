#import <Foundation/Foundation.h>

@protocol WFPhotoResponseContext <NSObject>
- (id)outgoingResponseIdentifier;
@end

@protocol WFPhotoProtobufContext <NSObject>
- (id)context;
@end

// iOS 15.4: outgoingResponseIdentifier belongs to IDSMessageContext, NOT
// IDSProtobuf. Prefer the callback's context; only use the protobuf's context
// when the callback did not supply a usable context. Never invent an identifier.
static inline id WFPhotoOutgoingResponseIdentifier(id callbackContext, id protobuf) {
    if ([callbackContext respondsToSelector:@selector(outgoingResponseIdentifier)]) {
        return [(id<WFPhotoResponseContext>)callbackContext outgoingResponseIdentifier];
    }
    if (![protobuf respondsToSelector:@selector(context)]) return nil;
    id context = [(id<WFPhotoProtobufContext>)protobuf context];
    return [context respondsToSelector:@selector(outgoingResponseIdentifier)]
        ? [(id<WFPhotoResponseContext>)context outgoingResponseIdentifier] : nil;
}
