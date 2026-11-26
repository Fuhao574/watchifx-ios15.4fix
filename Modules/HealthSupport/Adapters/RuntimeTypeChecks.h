// Loaded, valid ObjC objects only. This avoids overridable -isKindOfClass: but
// is NOT object-pointer validity, immutable-value, image or IMP verification.
#ifndef WFHS_RUNTIME_TYPE_CHECKS_H
#define WFHS_RUNTIME_TYPE_CHECKS_H
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static inline BOOL WFHSActuallyInheritsFrom(id object, Class base) {
    if (!object || !base) return NO;
    Class cursor = object_getClass(object);
    Class seen[64]; unsigned depth = 0;
    while (cursor && depth < 64) {
        for (unsigned i = 0; i < depth; ++i) if (seen[i] == cursor) return NO;
        seen[depth++] = cursor;
        if (cursor == base) return YES;
        cursor = class_getSuperclass(cursor);
    }
    return NO;
}
#endif
