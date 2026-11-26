#import "DayBuilderSnapshot.h"
#import "RuntimeTypeChecks.h"
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

@interface WFHSDaySnapshot ()
@property(nonatomic,readwrite) WFHSDaySnapshotStatus status;
@property(nonatomic,strong,readwrite,nullable) NSArray *sleepAnalysisSamples,*sleepScheduleSamples,*sleepDurationGoalSamples;
@property(nonatomic,strong,readwrite,nullable) NSDateInterval *dateInterval;
@property(nonatomic,strong,readwrite,nullable) id calendarCache;
@property(nonatomic,readwrite) int64_t morningIndex;
@property(nonatomic,readwrite) uint64_t weekday;
@end
@implementation WFHSDaySnapshot @end

WFHSDaySnapshot *WFHSReadDayBuilderSnapshot(id builder,Class auditedBuilderClass,
                                          Class auditedCalendarCacheClass,NSUInteger maximumTotalSamples) {
    WFHSDaySnapshot *result=[WFHSDaySnapshot new];
    if(!maximumTotalSamples){result.status=WFHSDaySnapshotResourceLimit;return result;}
    if(!auditedBuilderClass||!auditedCalendarCacheClass||object_getClass(builder)!=auditedBuilderClass)return result;
    @try {
        const char *names[]={"_dateInterval","_calendarCache","_sleepAnalysisSamples","_sleepScheduleSamples",
                             "_sleepDurationGoalSamples","_morningIndex","_weekday"};
        const char *types[]={"@\"NSDateInterval\"","@\"HKCalendarCache\"","@\"NSMutableArray\"","@\"NSMutableArray\"",
                             "@\"NSMutableArray\"","q","Q"};
        Ivar found[7]={NULL};unsigned count=0;
        Ivar *ivars=class_copyIvarList(auditedBuilderClass,&count);
        BOOL valid=count==7;
        const size_t instanceSize=class_getInstanceSize(auditedBuilderClass);
        for(unsigned i=0;i<count&&valid;++i) {
            const char *name=ivar_getName(ivars[i]),*type=ivar_getTypeEncoding(ivars[i]);
            BOOL matched=NO;
            for(unsigned j=0;j<7;++j)if(name&&type&&!strcmp(name,names[j])&&!strcmp(type,types[j])) {
                ptrdiff_t offset=ivar_getOffset(ivars[i]);
                if(found[j]||offset<(ptrdiff_t)sizeof(void *)||instanceSize<8||
                   (size_t)offset>instanceSize-8){valid=NO;break;}
                found[j]=ivars[i];matched=YES;break;
            }
            if(!matched)valid=NO;
        }
        free(ivars);
        for(unsigned i=0;i<7;++i)if(!found[i])valid=NO;
        if(!valid){result.status=WFHSDaySnapshotInvalidMetadata;return result;}
        // Strong locals keep objects alive only under caller-proven exclusivity.
        id interval=object_getIvar(builder,found[0]),cache=object_getIvar(builder,found[1]);
        id analysis=object_getIvar(builder,found[2]),schedules=object_getIvar(builder,found[3]),goals=object_getIvar(builder,found[4]);
        if(!WFHSActuallyInheritsFrom(interval,NSDateInterval.class)||object_getClass(cache)!=auditedCalendarCacheClass||
           !WFHSActuallyInheritsFrom(analysis,NSMutableArray.class)||!WFHSActuallyInheritsFrom(schedules,NSMutableArray.class)||
           !WFHSActuallyInheritsFrom(goals,NSMutableArray.class)) {
           result.status=WFHSDaySnapshotInvalidValue;return result;
        }
        id start=[interval startDate],end=[interval endDate];
        if(!WFHSActuallyInheritsFrom(start,NSDate.class)||!WFHSActuallyInheritsFrom(end,NSDate.class)) {
            result.status=WFHSDaySnapshotInvalidValue;return result;
        }
        const double s0=[start timeIntervalSinceReferenceDate],e0=[end timeIntervalSinceReferenceDate];
        if(!isfinite(s0)||!isfinite(e0)||e0<=s0||!isfinite(e0-s0)) {
            result.status=WFHSDaySnapshotInvalidValue;return result;
        }
        NSUInteger remaining=maximumTotalSamples;
        for(NSArray *array in @[analysis,schedules,goals]) {
            if(array.count>remaining){result.status=WFHSDaySnapshotResourceLimit;return result;}
            remaining-=array.count;
        }
        NSArray *a=[[NSArray alloc]initWithArray:analysis],*s=[[NSArray alloc]initWithArray:schedules],*g=[[NSArray alloc]initWithArray:goals];
        if(!a||!s||!g||a.count!=[analysis count]||s.count!=[schedules count]||g.count!=[goals count]) {
            result.status=WFHSDaySnapshotInvalidValue;return result;
        }
        // Scalars are copied from runtime-resolved declared ivars, never
        // hardcoded offsets. Exact field size/type/build was independently audited.
        int64_t index;uint64_t weekday;
        const unsigned char *bytes=(const unsigned char *)(__bridge const void *)builder;
        memcpy(&index,bytes+ivar_getOffset(found[5]),sizeof(index));
        memcpy(&weekday,bytes+ivar_getOffset(found[6]),sizeof(weekday));
        result.sleepAnalysisSamples=a;result.sleepScheduleSamples=s;result.sleepDurationGoalSamples=g;
        result.dateInterval=interval;result.calendarCache=cache;result.morningIndex=index;result.weekday=weekday;
        result.status=WFHSDaySnapshotComplete;
    } @catch(NSException *candidateException) {
        (void)candidateException;result.sleepAnalysisSamples=nil;result.sleepScheduleSamples=nil;
        result.sleepDurationGoalSamples=nil;result.dateInterval=nil;result.calendarCache=nil;
        result.status=WFHSDaySnapshotCandidateException;
    }
    return result;
}
