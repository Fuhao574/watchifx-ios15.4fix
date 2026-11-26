#import <Foundation/Foundation.h>
#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN
// Metadata only, for valid, already-loaded, static audited classes supplied by
// the caller. No class discovery, framework loading, target method invocation or
// hook installation. Neither this helper nor an observed UUID grants production
// authorization; process/OS/image policy remains the caller's responsibility.
// Pass an address in a currently mapped image (strip signed function pointers
// before passing them). The method checker strips its own IMP for image/offset
// queries; no arbitrary Mach-O files or payloads are parsed here.
FOUNDATION_EXPORT NSString * _Nullable WFHSLoadedImageUUIDForAddress(const void * _Nullable address);

@interface WFHSLoadedMethodIdentity : NSObject
- (nullable instancetype)initWithClass:(Class)actualClass
                    expectedClassName:(NSString *)className
                             selector:(SEL)selector
                        isClassMethod:(BOOL)isClassMethod
                  expectedMethodOwner:(Class)methodOwner
                    expectedIMPOffset:(NSNumber * _Nullable)auditedOffset
                          expectedABI:(NSString *)abi
                        classImagePath:(NSString *)classImagePath
                        classImageUUID:(NSString *)classImageUUID
                       methodImagePath:(NSString *)methodImagePath
                       methodImageUUID:(NSString *)methodImageUUID;
// Detects current ABI/IMP/owner/origin changes, not behavioral purity. This does
// NOT lock runtime dispatch or close a check-use race: caller-proven exclusivity
// against method/image mutation must span verification and any later use. The
// supplied classes/images must remain loaded and valid throughout that interval.
// nil auditedOffset is OBSERVATION ONLY; it accepts initial same-image drift.
- (BOOL)stillMatches;
@end
NS_ASSUME_NONNULL_END
