#import "StageWriteBoundary.h"
#import "RuntimeTypeChecks.h"
#include <stdlib.h>
#include <string.h>

@protocol WFHSWriteCategory
- (id)sampleType;
- (NSInteger)value;
@end
@protocol WFHSWriteType
- (NSInteger)code;
@end

static BOOL WFHSWriteABI(Class cls,SEL selector,const char *expected) {
    Class seen[64];unsigned depth=0;
    while(cls&&depth<64) {
        for(unsigned i=0;i<depth;++i)if(seen[i]==cls)return NO;
        seen[depth++]=cls;
        unsigned count=0;Method *methods=class_copyMethodList(cls,&count);
        unsigned matches=0;BOOL valid=NO;
        for(unsigned i=0;i<count;++i)if(sel_isEqual(method_getName(methods[i]),selector)) {
            ++matches;const char *actual=method_getTypeEncoding(methods[i]);valid=actual&&!strcmp(actual,expected);
        }
        free(methods);if(matches)return matches==1&&valid;cls=class_getSuperclass(cls);
    }
    return NO;
}
static BOOL WFHSRefuseStageInsert(NSError * __autoreleasing *error,NSInteger code) {
    // Own error namespace; never impersonates HealthKit or its special900 code.
    if(error)*error=[NSError errorWithDomain:@"WatchFix.HealthSupport.StageWriteBoundary" code:code userInfo:nil];
    return NO;
}

BOOL WFHSInsertWithStageWriteBoundary(id manager,Class auditedManagerClass,
    NSArray *objects,id provenance,double creationDate,BOOL skipInsertionFilter,
    BOOL updateSourceOrder,BOOL resolveAssociations,NSError * __autoreleasing *error,
    Class auditedCategorySampleClass,Class auditedCategoryTypeClass,BOOL allowNewStages,
    NSUInteger maximumObjects,WFHSOriginalStageInsert original) {
    if(!auditedManagerClass||object_getClass(manager)!=auditedManagerClass||!auditedCategorySampleClass||
       !auditedCategoryTypeClass||!original||!maximumObjects)return WFHSRefuseStageInsert(error,1);
    @try {
        SEL insertion=sel_registerName("insertDataObjects:withProvenance:creationDate:skipInsertionFilter:updateSourceOrder:resolveAssociations:error:");
        if(!WFHSWriteABI(auditedManagerClass,insertion,"B60@0:8@16@24d32B40B44B48^@52")||
           !WFHSWriteABI(auditedCategorySampleClass,@selector(sampleType),"@16@0:8")||
           !WFHSWriteABI(auditedCategorySampleClass,@selector(value),"q16@0:8")||
           !WFHSWriteABI(auditedCategoryTypeClass,@selector(code),"q16@0:8"))return WFHSRefuseStageInsert(error,1);
        if(!WFHSActuallyInheritsFrom(objects,NSArray.class)||objects.count>maximumObjects)return WFHSRefuseStageInsert(error,2);
        for(id object in objects) {
            if(!WFHSActuallyInheritsFrom(object,auditedCategorySampleClass))continue;
            // Do not let an unaudited category subclass evade the stage check.
            if(object_getClass(object)!=auditedCategorySampleClass)return WFHSRefuseStageInsert(error,1);
            id type=[(id<WFHSWriteCategory>)object sampleType];
            if(object_getClass(type)!=auditedCategoryTypeClass)return WFHSRefuseStageInsert(error,1);
            if([(id<WFHSWriteType>)type code]!=63)continue;
            const NSInteger value=[(id<WFHSWriteCategory>)object value];
            if(value>=3&&value<=5&&!allowNewStages)return WFHSRefuseStageInsert(error,3);
        }
    } @catch(NSException *candidateException) {
        (void)candidateException;return WFHSRefuseStageInsert(error,4);
    }
    // Outside candidate catch: preserve original BOOL, NSError and exceptions.
    // All arguments and the batch identity are passed unchanged, exactly once.
    return original(manager,objects,provenance,creationDate,skipInsertionFilter,
                    updateSourceOrder,resolveAssociations,error);
}
