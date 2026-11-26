#import "SleepCalendarContext.h"
#import "RuntimeTypeChecks.h"
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

@protocol WFHSSleepCalendarFactories
+ (NSCalendar *)hk_gregorianCalendar;
+ (NSDate *)hk_sleepDayStartForMorningIndex:(int64_t)index calendar:(NSCalendar *)calendar;
- (NSCalendar *)currentCalendar;
- (instancetype)initWithAnchorDate:(NSDate *)anchor intervalComponents:(NSDateComponents *)components;
- (NSDateInterval *)dateIntervalContainingDate:(NSDate *)date index:(int64_t *)index;
- (NSDateInterval *)dateIntervalAtIndex:(int64_t)index;
@end
@interface WFHSSleepCalendarContext ()
@property(nonatomic,readwrite) WFHSSleepCalendarStatus status;
@property(nonatomic,strong,readwrite,nullable) id collection;
@property(nonatomic,strong,readwrite,nullable) NSCalendar *calendar;
@property(nonatomic,strong,readwrite,nullable) NSDate *anchor;
@property(nonatomic,strong,readwrite,nullable) NSArray<NSDateInterval *> *intervals;
@property(nonatomic,readwrite) int64_t firstIndex;
@end
@implementation WFHSSleepCalendarContext @end

static BOOL WFHSCalendarABI(Class cls,SEL selector,const char *expected) {
    unsigned count=0;Method *methods=class_copyMethodList(cls,&count);unsigned matches=0;BOOL valid=NO;
    for(unsigned i=0;i<count;++i)if(sel_isEqual(method_getName(methods[i]),selector)) {
        ++matches;const char *actual=method_getTypeEncoding(methods[i]);valid=actual&&!strcmp(actual,expected);
    }
    free(methods);return matches==1&&valid;
}
static BOOL WFHSCalendarBounds(id interval,double *start,double *end) {
    if(!WFHSActuallyInheritsFrom(interval,NSDateInterval.class))return NO;
    id s=[interval startDate],e=[interval endDate];
    if(!WFHSActuallyInheritsFrom(s,NSDate.class)||!WFHSActuallyInheritsFrom(e,NSDate.class))return NO;
    *start=[s timeIntervalSinceReferenceDate];*end=[e timeIntervalSinceReferenceDate];
    return isfinite(*start)&&isfinite(*end)&&*end>*start&&isfinite(*end-*start);
}
static WFHSSleepCalendarContext *WFHSCreateCalendar(int64_t morningIndex,id calendarCache,
    Class auditedCacheClass,Class actualDateClass,Class actualCalendarClass,Class auditedCollectionClass,
    NSInteger bucketSeconds,NSDateInterval *coverage,NSUInteger maximumBuckets,NSDate *firstSampleStart) {
    WFHSSleepCalendarContext *result=[WFHSSleepCalendarContext new];
    if(!maximumBuckets||bucketSeconds<=0||bucketSeconds>86400) {
        result.status=WFHSSleepCalendarInvalidInput;return result;
    }
    if(!auditedCacheClass||!actualDateClass||!actualCalendarClass||!auditedCollectionClass||
        object_getClass(calendarCache)!=auditedCacheClass)return result;
    @try {
        if(!WFHSCalendarABI(auditedCacheClass,@selector(currentCalendar),"@16@0:8")||
           !WFHSCalendarABI(object_getClass(actualCalendarClass),@selector(hk_gregorianCalendar),"@16@0:8")||
           !WFHSCalendarABI(object_getClass(actualDateClass),@selector(hk_sleepDayStartForMorningIndex:calendar:),"@32@0:8q16@24")||
           !WFHSCalendarABI(auditedCollectionClass,@selector(initWithAnchorDate:intervalComponents:),"@32@0:8@16@24")||
           !WFHSCalendarABI(auditedCollectionClass,@selector(dateIntervalContainingDate:index:),"@32@0:8@16^q24")||
           !WFHSCalendarABI(auditedCollectionClass,@selector(dateIntervalAtIndex:),"@24@0:8q16"))return result;
        double coverageStart,coverageEnd;
        if(firstSampleStart) {
            if(!WFHSActuallyInheritsFrom(firstSampleStart,NSDate.class)||!isfinite(firstSampleStart.timeIntervalSinceReferenceDate)) {
                result.status=WFHSSleepCalendarInvalidInput;return result;
            }
            coverageStart=coverageEnd=firstSampleStart.timeIntervalSinceReferenceDate;
        } else if(!WFHSCalendarBounds(coverage,&coverageStart,&coverageEnd)) {
            result.status=WFHSSleepCalendarInvalidInput;return result;
        }
        NSCalendar *gregorian=[(id<WFHSSleepCalendarFactories>)actualCalendarClass hk_gregorianCalendar];
        if(!WFHSActuallyInheritsFrom(gregorian,NSCalendar.class)) {result.status=WFHSSleepCalendarInvalidResult;return result;}
        NSDate *anchor=[(id<WFHSSleepCalendarFactories>)actualDateClass hk_sleepDayStartForMorningIndex:morningIndex calendar:gregorian];
        if(!WFHSActuallyInheritsFrom(anchor,NSDate.class)||!isfinite(anchor.timeIntervalSinceReferenceDate)) {
            result.status=WFHSSleepCalendarInvalidResult;return result;
        }
        NSDateComponents *components=[NSDateComponents new];
        NSCalendar *calendar=[(id<WFHSSleepCalendarFactories>)calendarCache currentCalendar];
        if(!components||!WFHSActuallyInheritsFrom(calendar,NSCalendar.class)) {result.status=WFHSSleepCalendarInvalidResult;return result;}
        components.calendar=calendar;components.second=bucketSeconds;
        id allocated=[auditedCollectionClass alloc];
        if(object_getClass(allocated)!=auditedCollectionClass){result.status=WFHSSleepCalendarInvalidResult;return result;}
        id collection=[(id<WFHSSleepCalendarFactories>)allocated initWithAnchorDate:anchor intervalComponents:components];
        if(object_getClass(collection)!=auditedCollectionClass){result.status=WFHSSleepCalendarInvalidResult;return result;}
        int64_t first=INT64_MIN;
        id firstInterval=[(id<WFHSSleepCalendarFactories>)collection dateIntervalContainingDate:firstSampleStart?:coverage.startDate index:&first];
        double firstStart,firstEnd;
        if(first==INT64_MIN||!WFHSCalendarBounds(firstInterval,&firstStart,&firstEnd)||firstStart>coverageStart||firstEnd<=coverageStart) {
            result.status=WFHSSleepCalendarInvalidResult;return result;
        }
        NSMutableArray *intervals=[NSMutableArray array];
        if(!intervals){result.status=WFHSSleepCalendarInvalidResult;return result;}
        id current=firstInterval;double previousEnd=firstStart;
        int64_t index=first;
        for(NSUInteger count=0;count<maximumBuckets;++count) {
            double start,end;
            if(!WFHSCalendarBounds(current,&start,&end)||start!=previousEnd) {
                result.status=WFHSSleepCalendarInvalidResult;return result;
            }
            [intervals addObject:current];
            if(end>=coverageEnd) {
                NSArray *snapshot=[[NSArray alloc]initWithArray:intervals];
                if(!snapshot||snapshot.count!=intervals.count){result.status=WFHSSleepCalendarInvalidResult;return result;}
                result.collection=collection;result.calendar=calendar;result.anchor=anchor;
                result.firstIndex=first;result.intervals=snapshot;result.status=WFHSSleepCalendarComplete;return result;
            }
            if(count==maximumBuckets-1||index==INT64_MAX){result.status=WFHSSleepCalendarLimit;return result;}
            ++index;previousEnd=end;
            current=[(id<WFHSSleepCalendarFactories>)collection dateIntervalAtIndex:index];
        }
        result.status=WFHSSleepCalendarLimit;
    } @catch(NSException *candidateException) {
        (void)candidateException;result.status=WFHSSleepCalendarCandidateException;
    }
    return result;
}
WFHSSleepCalendarContext *WFHSCreateSleepCalendarContext(int64_t morningIndex,id calendarCache,
    Class auditedCacheClass,Class actualDateClass,Class actualCalendarClass,Class auditedCollectionClass,
    NSInteger bucketSeconds,NSDateInterval *coverage,NSUInteger maximumBuckets) {
    return WFHSCreateCalendar(morningIndex,calendarCache,auditedCacheClass,actualDateClass,actualCalendarClass,
        auditedCollectionClass,bucketSeconds,coverage,maximumBuckets,nil);
}
WFHSSleepCalendarContext *WFHSCreateSleepCalendarForFirstSample(int64_t morningIndex,id calendarCache,
    Class auditedCacheClass,Class actualDateClass,Class actualCalendarClass,Class auditedCollectionClass,
    NSInteger bucketSeconds,NSDate *firstStart) {
    return WFHSCreateCalendar(morningIndex,calendarCache,auditedCacheClass,actualDateClass,actualCalendarClass,
        auditedCollectionClass,bucketSeconds,nil,1,firstStart);
}
