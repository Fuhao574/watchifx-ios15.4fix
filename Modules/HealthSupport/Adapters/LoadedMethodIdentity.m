#import "LoadedMethodIdentity.h"
#include <dlfcn.h>
#include <mach-o/loader.h>
#include <stdlib.h>
#include <string.h>
#if __has_feature(ptrauth_calls)
#include <ptrauth.h>
#endif

static const void *WFHSUnsignedMethodAddress(IMP imp) {
#if __has_feature(ptrauth_calls)
    return ptrauth_strip((void *)imp,ptrauth_key_function_pointer);
#else
    return (const void *)imp;
#endif
}

static NSString *WFHSUUIDFromLoadedHeader(const struct mach_header *header) {
    // Only callers with a dyld/dladdr returned loaded header may call here.
    // No arbitrary file/payload parsing or guessed addresses.
    if (!header || header->magic!=MH_MAGIC_64) return nil;
    const struct mach_header_64 *h=(const struct mach_header_64 *)header;
    if (h->sizeofcmds>16*1024*1024 || h->ncmds>65536) return nil;
    const unsigned char *cursor=(const unsigned char *)(h+1);
    size_t remaining=h->sizeofcmds;NSString *found=nil;
    for (uint32_t i=0;i<h->ncmds;++i) {
        if (remaining<sizeof(struct load_command)) return nil;
        const struct load_command *command=(const struct load_command *)cursor;
        if (command->cmdsize<sizeof(*command) || command->cmdsize>remaining || command->cmdsize%8) return nil;
        if (command->cmd==LC_UUID) {
            if (found || command->cmdsize!=sizeof(struct uuid_command)) return nil;
            const struct uuid_command *uuid=(const struct uuid_command *)command;
            found=[[[NSUUID alloc] initWithUUIDBytes:uuid->uuid] UUIDString];
        }
        remaining-=command->cmdsize;cursor+=command->cmdsize;
    }
    return remaining==0?found:nil;
}

NSString *WFHSLoadedImageUUIDForAddress(const void *address) {
    Dl_info info;
    if (!address || !dladdr(address,&info) || !info.dli_fbase) return nil;
    return WFHSUUIDFromLoadedHeader(info.dli_fbase);
}

static Method WFHSFindExistingMethod(Class cls,SEL selector,BOOL classMethod,Class *owner) {
    Class cursor=classMethod?object_getClass(cls):cls;
    Class seen[64];unsigned depth=0;
    while(cursor && depth<64) {
        for(unsigned i=0;i<depth;++i)if(seen[i]==cursor)return NULL;
        seen[depth++]=cursor;
        unsigned count=0;Method *methods=class_copyMethodList(cursor,&count);
        Method found=NULL;
        for(unsigned i=0;i<count;++i)if(sel_isEqual(method_getName(methods[i]),selector)) {
            if(found){free(methods);return NULL;} // ambiguous category entries
            found=methods[i];
        }
        free(methods);
        if(found){*owner=cursor;return found;}
        cursor=class_getSuperclass(cursor);
    }
    return NULL;
}

@interface WFHSLoadedMethodIdentity ()
// Static audited loaded classes only. ARC-retaining an uninitialized Class can
// itself trigger +initialize on the host runtime; do not send ownership messages.
@property(nonatomic,assign) Class actualClass;
@property(nonatomic) SEL selector;
@property(nonatomic) BOOL isClassMethod;
@property(nonatomic,assign) Class methodOwner;
@property(nonatomic,copy,nullable) NSNumber *auditedOffset;
@property(nonatomic) IMP originalIMP;
@property(nonatomic,copy) NSString *expectedClassName;
@property(nonatomic,copy) NSString *expectedABI;
@property(nonatomic,copy) NSString *classImagePath;
@property(nonatomic,copy) NSString *classImageUUID;
@property(nonatomic,copy) NSString *methodImagePath;
@property(nonatomic,copy) NSString *methodImageUUID;
@end

@implementation WFHSLoadedMethodIdentity
- (instancetype)initWithClass:(Class)actualClass expectedClassName:(NSString *)className selector:(SEL)selector
                isClassMethod:(BOOL)isClassMethod expectedMethodOwner:(Class)methodOwner
            expectedIMPOffset:(NSNumber *)auditedOffset expectedABI:(NSString *)abi
               classImagePath:(NSString *)classImagePath classImageUUID:(NSString *)classImageUUID
              methodImagePath:(NSString *)methodImagePath methodImageUUID:(NSString *)methodImageUUID {
    if (!actualClass || class_isMetaClass(actualClass) || !methodOwner || !selector || !className.length || !abi.length || !classImagePath.length ||
        !classImageUUID.length || !methodImagePath.length || !methodImageUUID.length) return nil;
    if ((self=[super init])) {
        _actualClass=actualClass;_selector=selector;_isClassMethod=isClassMethod;
        _methodOwner=methodOwner;_auditedOffset=[auditedOffset copy];
        _expectedClassName=[className copy];_expectedABI=[abi copy];
        _classImagePath=[classImagePath copy];_classImageUUID=[classImageUUID.uppercaseString copy];
        _methodImagePath=[methodImagePath copy];_methodImageUUID=[methodImageUUID.uppercaseString copy];
        Class foundOwner=Nil;Method method=WFHSFindExistingMethod(actualClass,selector,isClassMethod,&foundOwner);
        if(foundOwner!=methodOwner)return nil;
        _originalIMP=method?method_getImplementation(method):NULL;
        if (![self stillMatches]) return nil;
    }
    return self;
}

- (BOOL)stillMatches {
    const char *name=class_getName(self.actualClass),*classPath=class_getImageName(self.actualClass);
    Dl_info classInfo;
    if (!name || !classPath || strcmp(name,self.expectedClassName.UTF8String) ||
        strcmp(classPath,self.classImagePath.UTF8String) ||
        !dladdr((__bridge const void *)self.actualClass,&classInfo) || !classInfo.dli_fname ||
        strcmp(classInfo.dli_fname,self.classImagePath.UTF8String) ||
        ![WFHSLoadedImageUUIDForAddress((__bridge const void *)self.actualClass) isEqualToString:self.classImageUUID]) return NO;
    Class owner=Nil;Method method=WFHSFindExistingMethod(self.actualClass,self.selector,self.isClassMethod,&owner);
    if(owner!=self.methodOwner)return NO;
    const char *abi=method?method_getTypeEncoding(method):NULL;
    IMP current=method?method_getImplementation(method):NULL;
    if (!abi || strcmp(abi,self.expectedABI.UTF8String) || !current || current!=self.originalIMP) return NO;
    const void *address=WFHSUnsignedMethodAddress(current);Dl_info info;
    if (!dladdr(address,&info) || !info.dli_fbase || !info.dli_fname) return NO;
    uintptr_t pointer=(uintptr_t)address,base=(uintptr_t)info.dli_fbase;
    if(self.auditedOffset && (pointer<base || pointer-base!=self.auditedOffset.unsignedLongLongValue))return NO;
    return
           !strcmp(info.dli_fname,self.methodImagePath.UTF8String) &&
           [WFHSLoadedImageUUIDForAddress(address) isEqualToString:self.methodImageUUID];
}
@end
