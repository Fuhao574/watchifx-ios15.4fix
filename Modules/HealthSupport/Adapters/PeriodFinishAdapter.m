#import "PeriodFinishAdapter.h"
#import "RuntimeTypeChecks.h"
#include <stdlib.h>
#include <string.h>

@interface WFHSPeriodFinishAttempt ()
@property(nonatomic,readwrite) WFHSPeriodFinishStatus status;
@property(nonatomic,strong,readwrite,nullable) NSArray *periods;
@end
@implementation WFHSPeriodFinishAttempt @end

WFHSPeriodFinishAttempt *WFHSFinishPeriodWithEmptyGuard(id builder,Class auditedBuilderClass,
    Class auditedMutableArrayClass,Class auditedEmptyCopyClass,WFHSOriginalPeriodFinish original) {
    WFHSPeriodFinishAttempt *result=[WFHSPeriodFinishAttempt new];
    if(!auditedBuilderClass||!auditedMutableArrayClass||!auditedEmptyCopyClass||!original||
       object_getClass(builder)!=auditedBuilderClass)return result;
    BOOL matchedEmpty=NO;
    @try {
        const char *names[]={"_periods","_segments","_minDate","_maxDate"};
        const char *types[]={"@\"NSMutableArray\"","@\"NSMutableArray\"","@\"NSDate\"","@\"NSDate\""};
        Ivar fields[4]={NULL};unsigned count=0;
        Ivar *declared=class_copyIvarList(auditedBuilderClass,&count);
        BOOL valid=count==4;
        for(unsigned i=0;i<count&&valid;++i) {
            const char *name=ivar_getName(declared[i]),*type=ivar_getTypeEncoding(declared[i]);
            BOOL found=NO;
            for(unsigned j=0;j<4;++j)if(name&&type&&!strcmp(name,names[j])&&!strcmp(type,types[j])) {
                if(fields[j]){valid=NO;break;}fields[j]=declared[i];found=YES;break;
            }
            if(!found)valid=NO;
        }
        free(declared);
        for(unsigned i=0;i<4;++i)if(!fields[i])valid=NO;
        if(!valid)return result;
        // Caller-proven exclusivity required for all four reads. Strong locals
        // aren't a lock for the native builder, nor a deep immutable snapshot.
        id periods=object_getIvar(builder,fields[0]),segments=object_getIvar(builder,fields[1]);
        id minDate=object_getIvar(builder,fields[2]),maxDate=object_getIvar(builder,fields[3]);
        if(object_getClass(periods)!=auditedMutableArrayClass||object_getClass(segments)!=auditedMutableArrayClass||
           !WFHSActuallyInheritsFrom(periods,NSMutableArray.class)||!WFHSActuallyInheritsFrom(segments,NSMutableArray.class)||
           (minDate&&!WFHSActuallyInheritsFrom(minDate,NSDate.class))||
           (maxDate&&!WFHSActuallyInheritsFrom(maxDate,NSDate.class)))return result;
        matchedEmpty=![periods count]&&![segments count]&&!minDate&&!maxDate;
        if(matchedEmpty) {
            id copy=[periods copy];
            if(object_getClass(copy)!=auditedEmptyCopyClass||!WFHSActuallyInheritsFrom(copy,NSArray.class)||
               WFHSActuallyInheritsFrom(copy,NSMutableArray.class)||[copy count]) {
                result.status=WFHSPeriodFinishCandidateFailed;return result;
            }
            result.periods=copy;result.status=WFHSPeriodFinishProtectedEmpty;return result;
        }
    } @catch(NSException *candidateException) {
        (void)candidateException;result.periods=nil;
        result.status=WFHSPeriodFinishCandidateFailed;return result;
    }
    // Crucially outside @try: do not turn original exceptions into an empty
    // successful result or silently swallow the original failure.
    NSArray *periods=original(builder);
    @try {
        if(!WFHSActuallyInheritsFrom(periods,NSArray.class)) {
            result.status=WFHSPeriodFinishCandidateFailed;return result;
        }
        result.periods=periods;result.status=WFHSPeriodFinishOriginalComplete;
    } @catch(NSException *candidateException) {
        (void)candidateException;result.periods=nil;result.status=WFHSPeriodFinishCandidateFailed;
    }
    return result;
}
