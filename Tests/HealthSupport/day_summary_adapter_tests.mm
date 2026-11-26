#include "DaySummaryAdapter.hpp"
#include "ConsumptionSleepSeries.hpp"
#include "DayStatisticsAdapter.hpp"
#import "PeriodFinishAdapter.h"
#import <objc/runtime.h>
#include <cassert>
#include <cstdio>
using namespace watchfix::healthsupport;
static NSUInteger nativeFactoryCalls;
@interface HKCalendarCache : NSObject
- (NSCalendar *)currentCalendar;
@end
@implementation HKCalendarCache
- (NSCalendar *)currentCalendar{return [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];}
@end
@interface DayAnchorFactory : NSObject
+ (NSDate *)hk_sleepDayStartForMorningIndex:(int64_t)index calendar:(NSCalendar *)calendar;
@end
@implementation DayAnchorFactory
+ (NSDate *)hk_sleepDayStartForMorningIndex:(int64_t)index calendar:(NSCalendar *)calendar {
 ++nativeFactoryCalls;assert(index==42&&calendar);return [NSDate dateWithTimeIntervalSinceReferenceDate:0];
}
@end
@interface DayCalendarFactory : NSObject
+ (NSCalendar *)hk_gregorianCalendar;
@end
@implementation DayCalendarFactory
+ (NSCalendar *)hk_gregorianCalendar{return [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];}
@end
@interface DayIntervalCollection : NSObject
@property(nonatomic,strong) NSDate *anchor;
@property(nonatomic) NSInteger seconds;
- (instancetype)initWithAnchorDate:(NSDate *)anchor intervalComponents:(NSDateComponents *)components;
- (NSDateInterval *)dateIntervalContainingDate:(NSDate *)date index:(int64_t *)index;
- (NSDateInterval *)dateIntervalAtIndex:(int64_t)index;
@end
@implementation DayIntervalCollection
- (instancetype)initWithAnchorDate:(NSDate *)anchor intervalComponents:(NSDateComponents *)components {
 if((self=[super init])){self.anchor=anchor;self.seconds=components.second;}return self;
}
- (NSDateInterval *)dateIntervalAtIndex:(int64_t)index {
 return [[NSDateInterval alloc]initWithStartDate:[self.anchor dateByAddingTimeInterval:index*self.seconds] duration:self.seconds];
}
- (NSDateInterval *)dateIntervalContainingDate:(NSDate *)date index:(int64_t *)index {
 *index=(int64_t)floor([date timeIntervalSinceDate:self.anchor]/self.seconds);return [self dateIntervalAtIndex:*index];
}
@end
@interface DayInputType : NSObject
@property(nonatomic) NSInteger code;
@end
@implementation DayInputType @end
@interface DayInputSource : NSObject
- (NSNumber *)_sourceID;
- (NSString *)bundleIdentifier;
@end
@implementation DayInputSource
- (NSNumber *)_sourceID{return @8;}
- (NSString *)bundleIdentifier{return @"fixture.watch.bundle";}
@end
@interface DaySourceManager : NSObject
- (id)clientSourceForPersistentID:(NSNumber *)identifier error:(NSError **)error;
@end
@implementation DaySourceManager
- (id)clientSourceForPersistentID:(NSNumber *)identifier error:(NSError **)error {
 assert(identifier.longLongValue==8);if(error)*error=nil;return [DayInputSource new];
}
@end
@interface DayOrderManager : NSObject
- (NSArray *)orderedSourceIDsForObjectType:(id)type bundleIdentifierMapping:(id)mapping userOrdered:(BOOL *)ordered error:(NSError **)error;
@end
@implementation DayOrderManager
- (NSArray *)orderedSourceIDsForObjectType:(id)type bundleIdentifierMapping:(id)mapping userOrdered:(BOOL *)ordered error:(NSError **)error {
 assert(type&&!mapping&&!ordered);if(error)*error=nil;return @[@8];
}
@end
@interface DayProfile : NSObject
- (id)sourceOrderManager;
- (id)sourceManager;
@end
@implementation DayProfile
- (id)sourceOrderManager{return [DayOrderManager new];}
- (id)sourceManager{return [DaySourceManager new];}
@end
@interface DayInputRevision : NSObject
@property(nonatomic,strong) id source;
@end
@implementation DayInputRevision @end
@interface DayInputSample : NSObject
@property(nonatomic) NSInteger value;
@property(nonatomic,strong) id sampleType,sourceRevision;
@property(nonatomic,strong) NSDate *startDate,*endDate;
@end
@implementation DayInputSample @end
@interface DayInputBuilder : NSObject {
@public
 NSDateInterval *_dateInterval;
 HKCalendarCache *_calendarCache;
 NSMutableArray *_sleepAnalysisSamples,*_sleepScheduleSamples,*_sleepDurationGoalSamples;
 int64_t _morningIndex;
 uint64_t _weekday;
}
@end
@implementation DayInputBuilder @end
@interface DaySegment : NSObject
@property(nonatomic,strong) NSDateInterval *dateInterval;
@property(nonatomic,strong) NSArray *sampleIntervals;
@property(nonatomic) NSInteger category;
@property(nonatomic) BOOL containsAppleSleepTrackingData;
+ (id)sleepPeriodSegmentWithDateInterval:(NSDateInterval *)interval sampleIntervals:(NSArray *)samples category:(NSInteger)category containsAppleSleepTrackingData:(BOOL)apple;
@end
@implementation DaySegment
+ (id)sleepPeriodSegmentWithDateInterval:(NSDateInterval *)interval sampleIntervals:(NSArray *)samples category:(NSInteger)category containsAppleSleepTrackingData:(BOOL)apple {
 DaySegment *s=[self new];s.dateInterval=interval;s.sampleIntervals=[samples copy];s.category=category;s.containsAppleSleepTrackingData=apple;return s;
}
@end
@interface DayPeriod : NSObject
@property(nonatomic,strong) NSDateInterval *dateInterval;
@property(nonatomic,strong) NSArray *segments;
@end
@implementation DayPeriod @end
@interface DayPeriodBuilder : NSObject
@property(nonatomic,strong) NSMutableArray *segments;
- (void)addOrderedSegment:(id)segment;
- (NSArray *)finish;
@end
@implementation DayPeriodBuilder
- (instancetype)init{if((self=[super init]))self.segments=[NSMutableArray array];return self;}
- (void)addOrderedSegment:(id)segment{[self.segments addObject:segment];}
- (NSArray *)finish {
 assert(self.segments.count);DayPeriod *p=[DayPeriod new];p.segments=[self.segments copy];
 NSDate *start=nil,*end=nil;for(DaySegment *s in self.segments){start=start?[start earlierDate:s.dateInterval.startDate]:s.dateInterval.startDate;end=end?[end laterDate:s.dateInterval.endDate]:s.dateInterval.endDate;}
 p.dateInterval=[[NSDateInterval alloc]initWithStartDate:start endDate:end];return @[p];
}
@end
@interface DayResult : NSObject
@property(nonatomic) NSInteger morningIndex;
@property(nonatomic,strong) NSDateInterval *dateInterval;
@property(nonatomic,strong) NSCalendar *calendar;
@property(nonatomic,strong) NSArray *periods,*schedules;
@property(nonatomic,strong) id sleepDurationGoal;
+ (id)daySummaryWithMorningIndex:(NSInteger)index dateInterval:(NSDateInterval *)interval calendar:(NSCalendar *)calendar periods:(NSArray *)periods schedules:(NSArray *)schedules sleepDurationGoal:(id)goal;
@end
@implementation DayResult
+ (id)daySummaryWithMorningIndex:(NSInteger)index dateInterval:(NSDateInterval *)interval calendar:(NSCalendar *)calendar periods:(NSArray *)periods schedules:(NSArray *)schedules sleepDurationGoal:(id)goal {
 DayResult *r=[self new];r.morningIndex=index;r.dateInterval=interval;r.calendar=[calendar copy];r.periods=[periods copy];r.schedules=[schedules copy];r.sleepDurationGoal=goal;return r;
}
@end
@interface WrongSummaryABI : NSObject
- (int)morningIndex;
@end
@implementation WrongSummaryABI
- (int)morningIndex{abort();}
@end
@interface OriginalPeriodState : NSObject {
@public NSMutableArray *_periods,*_segments;NSDate *_minDate,*_maxDate;
}
@end
@implementation OriginalPeriodState @end
int main() {
 @autoreleasepool {
  id enumerator=[NSObject new],profile=[DayProfile new];HKCalendarCache *cache=[HKCalendarCache new];
  DayInputBuilder *builder=[DayInputBuilder new];builder->_calendarCache=cache;builder->_morningIndex=42;
  builder->_dateInterval=[[NSDateInterval alloc]initWithStartDate:[NSDate dateWithTimeIntervalSinceReferenceDate:0] duration:120];
  builder->_sleepAnalysisSamples=[NSMutableArray array];builder->_sleepScheduleSamples=[NSMutableArray array];builder->_sleepDurationGoalSamples=[NSMutableArray array];
  DayInputSample *sample=[DayInputSample new];sample.value=4;DayInputType *type=[DayInputType new];type.code=63;
  DayInputRevision *revision=[DayInputRevision new];revision.source=[DayInputSource new];sample.sourceRevision=revision;sample.sampleType=type;
  sample.startDate=builder->_dateInterval.startDate;sample.endDate=builder->_dateInterval.endDate;[builder->_sleepAnalysisSamples addObject:sample];
  WFHSQueryBinding *binding=[[WFHSQueryBinding alloc]initWithActualEnumerator:enumerator profile:profile freshCalendarCache:cache maximumBuilders:10];
  assert([binding beginEnumerationFor:enumerator actualProfile:profile actualCache:cache]);
  assert([binding bindActualReturnedBuilder:builder initializationCache:cache verifiedFactoryForThisEnumeration:YES]);
  DaySummaryClasses classes;classes.builder=DayInputBuilder.class;classes.calendar_cache=HKCalendarCache.class;classes.sample=DayInputSample.class;
  classes.category_type=DayInputType.class;classes.source_revision=DayInputRevision.class;classes.source=DayInputSource.class;
  classes.segment=DaySegment.class;classes.period_builder=DayPeriodBuilder.class;classes.period=DayPeriod.class;classes.summary=DayResult.class;
  NSUInteger originalCalls=0,statsCalls=0;
  DayStatistics statistics=[&](const std::vector<StageFragment> &raw,WFHSDaySnapshot *snapshot,WFHSBoundDayContext *context) {
   ++statsCalls;assert(context.profile==profile&&snapshot.dateInterval==builder->_dateInterval);
   StableSeriesConfiguration config;config.bucket.mask_is_empty=true;
   DayStatisticsFactories factories;factories.date=DayAnchorFactory.class;factories.calendar=DayCalendarFactory.class;
   factories.collection=DayIntervalCollection.class;factories.cache=HKCalendarCache.class;
   DayProfileClasses profileClasses;profileClasses.profile=DayProfile.class;profileClasses.category=DayInputType.class;
   profileClasses.source_order_manager=DayOrderManager.class;profileClasses.source_manager=DaySourceManager.class;
   const auto beforeFactories=nativeFactoryCalls;
   auto invalid=config;invalid.bucket.mask_is_empty=false;
   assert(!calculateBoundDayStatisticsUsingProfile(raw,snapshot,context,type,profileClasses,factories,60,invalid).complete());
   assert(!calculateBoundDayStatisticsUsingProfile({{3,60,90,8},{4,0,60,8}},snapshot,context,type,
       profileClasses,factories,60,config).complete());
   ProjectionConfiguration badProjection;badProjection.maximum_intervals=0;
   assert(!calculateBoundDayStatisticsUsingProfile(raw,snapshot,context,type,profileClasses,factories,60,config,badProjection).complete());
   assert(nativeFactoryCalls==beforeFactories);
   auto projection=calculateBoundDayStatisticsUsingProfile(raw,snapshot,context,type,profileClasses,factories,60,config);
   assert(projection.complete());return projection;
  };
  NativeInBedSegments bed=[](NSArray *input)->NSArray *{assert(input.count==0);return @[];};
  id schedule=[NSObject new],goal=[NSObject new];
  DayResult *native=[DayResult daySummaryWithMorningIndex:42 dateInterval:builder->_dateInterval calendar:[NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian] periods:@[] schedules:@[schedule] sleepDurationGoal:goal];
  GuardedOriginalDayCreate original=[&](id b)->id{assert(b==builder);++originalCalls;return native;};
  auto attempt=createCompatibleDaySummary(builder,binding,classes,100,true,true,statistics,bed,original);
  assert(attempt.complete()&&attempt.summary!=native&&originalCalls==1&&statsCalls==1);
  DayResult *output=attempt.summary;assert(output.schedules[0]==schedule&&output.sleepDurationGoal==goal&&output.periods.count==1&&sample.value==4);
  DayPeriod *period=output.periods[0];DaySegment *segment=period.segments[0];assert(segment.category==1&&segment.sampleIntervals.count==1&&segment.dateInterval.duration==120);
  DayStatistics failing=[](const std::vector<StageFragment>&,WFHSDaySnapshot*,WFHSBoundDayContext*){return LegacyProjection{};};
  attempt=createCompatibleDaySummary(builder,binding,classes,100,true,true,failing,bed,original);
  assert(attempt.status==DaySummaryStatus::statistics_failed&&!attempt.summary&&originalCalls==1);
  auto nilOriginal=[&](id)->id{++originalCalls;return nil;};
  attempt=createCompatibleDaySummary(builder,binding,classes,100,true,true,statistics,bed,nilOriginal);
  assert(attempt.status==DaySummaryStatus::nil_original_unsupported&&!attempt.complete()&&originalCalls==2);
  // Connect the actual MODULE guard to a fake original-create control flow.
  // No fabricated schedule/goal on exact empty metadata input, and no unsafe
  // finish invoked merely because raw stages produced zero old segments.
  NSUInteger unsafeFinishes=0,metadataWork=0;
  GuardedOriginalDayCreate guardedNil=[&](id)->id {
   ++originalCalls;OriginalPeriodState *state=[OriginalPeriodState new];
   state->_periods=[NSMutableArray array];state->_segments=[NSMutableArray array];
   auto finished=WFHSFinishPeriodWithEmptyGuard(state,OriginalPeriodState.class,
       object_getClass(state->_periods),object_getClass(@[]),^NSArray *(id unused){(void)unused;++unsafeFinishes;return nil;});
   assert(finished.status==WFHSPeriodFinishProtectedEmpty&&finished.periods.count==0);
   ++metadataWork;return nil; // fake shape of the audited empty-metadata native branch
  };
  NSCalendar *calendar=[NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
  StableDayCalendar stableCalendar=[&](id actual)->NSCalendar *{assert(actual==cache);return calendar;};
  attempt=createCompatibleDaySummary(builder,binding,classes,100,true,true,statistics,bed,guardedNil,stableCalendar);
  assert(attempt.complete()&&attempt.summary&&unsafeFinishes==0&&metadataWork==1);
  output=attempt.summary;assert(output.periods.count==1&&output.schedules.count==0&&!output.sleepDurationGoal);
  assert(output.morningIndex==42&&output.dateInterval==builder->_dateInterval);
  // An actual metadata input rules this narrow nil route out, even if original
  // filters it away. Do not claim all original-nil states now supported.
  [builder->_sleepScheduleSamples addObject:[NSObject new]];
  attempt=createCompatibleDaySummary(builder,binding,classes,100,true,true,statistics,bed,guardedNil,stableCalendar);
  assert(attempt.status==DaySummaryStatus::nil_original_unsupported&&!attempt.complete());
  [builder->_sleepScheduleSamples removeAllObjects];
  NSUInteger calendarReads=0;
  StableDayCalendar drift=[&](id)->NSCalendar *{
   ++calendarReads;NSCalendar *changed=[calendar copy];changed.timeZone=[NSTimeZone timeZoneForSecondsFromGMT:calendarReads==1?0:3600];return changed;
  };
  attempt=createCompatibleDaySummary(builder,binding,classes,100,true,true,statistics,bed,guardedNil,drift);
  assert(attempt.status==DaySummaryStatus::original_context_mismatch&&!attempt.summary);
  // Same mutable calendar object changes in original: before value was copied,
  // otherwise pointer reuse would make this drift invisible.
  auto mutatingOriginal=[&](id)->id{calendar.timeZone=[NSTimeZone timeZoneForSecondsFromGMT:3600];return nil;};
  calendar.timeZone=[NSTimeZone timeZoneForSecondsFromGMT:0];
  attempt=createCompatibleDaySummary(builder,binding,classes,100,true,true,statistics,bed,mutatingOriginal,stableCalendar);
  assert(attempt.status==DaySummaryStatus::original_context_mismatch&&!attempt.summary);
  auto missingClass=classes;missingClass.summary=Nil;auto beforeOriginal=originalCalls;
  attempt=createCompatibleDaySummary(builder,binding,missingClass,100,true,true,statistics,bed,original);
  assert(!attempt.complete()&&originalCalls==beforeOriginal);
  missingClass=classes;missingClass.summary=WrongSummaryABI.class;
  attempt=createCompatibleDaySummary(builder,binding,missingClass,100,true,true,statistics,bed,original);
  assert(!attempt.complete()&&originalCalls==beforeOriginal); // ABI rejects before getter/original
  NSException *sentinel=[NSException exceptionWithName:@"NativeOriginal" reason:nil userInfo:nil];BOOL caught=NO;
  @try {createCompatibleDaySummary(builder,binding,classes,100,true,true,statistics,bed,[&](id)->id{@throw sentinel;});}
  @catch(NSException *exception){caught=exception==sentinel;}assert(caught);
  sample.value=1;auto prior=statsCalls;
  attempt=createCompatibleDaySummary(builder,binding,classes,100,true,true,statistics,bed,nilOriginal);
  assert(attempt.status==DaySummaryStatus::native_no_summary&&attempt.complete()&&statsCalls==prior);
  sample.sourceRevision=nil;
  auto legacyClasses=classes;legacyClasses.source_revision=Nil;legacyClasses.source=Nil;
  legacyClasses.segment=Nil;legacyClasses.period=Nil;legacyClasses.period_builder=Nil;
  attempt=createCompatibleDaySummary(builder,binding,legacyClasses,100,false,false,{},{},original);
  assert(attempt.complete()&&attempt.summary==native&&statsCalls==prior); // legacy doesn't require stage source chain
  sample.value=4;sample.sourceRevision=revision;
  DayStatistics reenters=[&](const std::vector<StageFragment> &raw,WFHSDaySnapshot *snapshot,WFHSBoundDayContext *context) {
   auto value=statistics(raw,snapshot,context);[binding endEnumeration];return value;
  };
  beforeOriginal=originalCalls;
  attempt=createCompatibleDaySummary(builder,binding,classes,100,true,true,reenters,bed,original);
  assert(!attempt.complete()&&!attempt.summary&&originalCalls==beforeOriginal);
  assert([binding beginEnumerationFor:enumerator actualProfile:profile actualCache:cache]);
  // A builder from an old generation may not be silently reused: use a fresh
  // binding to represent an independently validated next operation.
  binding=[[WFHSQueryBinding alloc]initWithActualEnumerator:enumerator profile:profile freshCalendarCache:cache maximumBuilders:10];
  assert([binding beginEnumerationFor:enumerator actualProfile:profile actualCache:cache]);
  assert([binding bindActualReturnedBuilder:builder initializationCache:cache verifiedFactoryForThisEnumeration:YES]);
  auto originalEnds=[&](id b)->id{assert(b==builder);[binding endEnumeration];return native;};
  attempt=createCompatibleDaySummary(builder,binding,classes,100,true,true,statistics,bed,originalEnds);
  assert(!attempt.complete()&&!attempt.summary); // original reentry invalidation cannot publish
  binding=[[WFHSQueryBinding alloc]initWithActualEnumerator:enumerator profile:profile freshCalendarCache:cache maximumBuilders:10];
  __block NSUInteger delivered=0;
  NSError *queryError=nil;
  BOOL querySuccess=WFHSEnumerateBoundSleepSummaries(binding,enumerator,profile,cache,42,1,10,&queryError,
   ^(id result,BOOL *stop){assert(result&&stop);++delivered;},
   ^BOOL(NSError **error,WFHSSleepSummaryHandler handler,WFHSEnumerationFailure *failure) {
    assert([binding bindActualReturnedBuilder:builder initializationCache:cache verifiedFactoryForThisEnumeration:YES]);
    id result=createCompatibleDaySummaryForEnumeration(builder,cache,binding,failure,classes,100,true,true,statistics,bed,original);
    assert(result);BOOL stop=NO;handler(result,&stop);assert(!stop);
    result=createCompatibleDaySummaryForEnumeration(builder,cache,binding,failure,classes,100,true,true,failing,bed,original);
    assert(!result); // original enum would skip this nil; outer must terminate error
    if(error)*error=nil;return YES;
   });
  assert(!querySuccess&&queryError&&delivered==1);
  assert([queryError.domain isEqual:@"WatchFix.HealthSupport.SleepEnumeration"]);
  // Admission is checked before any statistics/original work, not only when a
  // candidate fails. Foreign channels and stale operations cannot publish.
  WFHSEnumerationFailure *__block closedFailure=nil;
  for(NSUInteger scenario=0;scenario<8;++scenario) {
   binding=[[WFHSQueryBinding alloc]initWithActualEnumerator:enumerator profile:profile freshCalendarCache:cache maximumBuilders:10];
   WFHSQueryBinding *foreign=[[WFHSQueryBinding alloc]initWithActualEnumerator:enumerator profile:profile freshCalendarCache:cache maximumBuilders:10];
   assert([foreign beginEnumerationFor:enumerator actualProfile:profile actualCache:cache]);
   assert([foreign bindActualReturnedBuilder:builder initializationCache:cache verifiedFactoryForThisEnumeration:YES]);
   const auto beforeStats=statsCalls,beforeCalls=originalCalls;
   querySuccess=WFHSEnumerateBoundSleepSummaries(binding,enumerator,profile,cache,42,1,10,&queryError,
    ^(id result,BOOL *stop){(void)result;(void)stop;abort();},
    ^BOOL(NSError **error,WFHSSleepSummaryHandler handler,WFHSEnumerationFailure *failure) {
     (void)handler;
     assert([binding bindActualReturnedBuilder:builder initializationCache:cache verifiedFactoryForThisEnumeration:YES]);
     id result=nil;
     if(scenario==0) {
      result=createCompatibleDaySummaryForEnumeration(builder,cache,foreign,failure,classes,100,true,true,statistics,bed,original);
     } else if(scenario==1) {
      result=createCompatibleDaySummaryForEnumeration(builder,[NSObject new],binding,failure,classes,100,true,true,statistics,bed,original);
     } else if(scenario==2) {
      result=createCompatibleDaySummaryForEnumeration(builder,cache,binding,failure,classes,100,true,true,failing,bed,original);
      assert(!result);const auto failedStats=statsCalls,failedCalls=originalCalls;
      result=createCompatibleDaySummaryForEnumeration(builder,cache,binding,failure,classes,100,true,true,statistics,bed,original);
      assert(statsCalls==failedStats&&originalCalls==failedCalls);
     } else if(scenario==3) {
      DayStatistics marksFailure=[&](const std::vector<StageFragment> &raw,WFHSDaySnapshot *snapshot,WFHSBoundDayContext *context) {
       auto projection=statistics(raw,snapshot,context);[failure recordOperationProtocolFailure];return projection;
      };
      result=createCompatibleDaySummaryForEnumeration(builder,cache,binding,failure,classes,100,true,true,marksFailure,bed,original);
     } else if(scenario==4) {
      closedFailure=failure; // Retain for the next independently valid operation.
      if(error)*error=nil;return YES;
     } else if(scenario==5) {
      assert(closedFailure);
      result=createCompatibleDaySummaryForEnumeration(builder,cache,binding,closedFailure,classes,100,true,true,statistics,bed,original);
      // A closed old channel cannot poison this operation's channel.
      assert(!result&&statsCalls==beforeStats&&originalCalls==beforeCalls);
      result=createCompatibleDaySummaryForEnumeration(builder,cache,binding,failure,classes,100,true,true,statistics,bed,original);
      assert(result);if(error)*error=nil;return YES;
     } else if(scenario==6) {
      NativeInBedSegments marksBedFailure=[&](NSArray *input)->NSArray *{
       [failure recordOperationProtocolFailure];return bed(input);
      };
      result=createCompatibleDaySummaryForEnumeration(builder,cache,binding,failure,classes,100,true,true,statistics,marksBedFailure,original);
     } else {
      GuardedOriginalDayCreate marksOriginalFailure=[&](id actual)->id{
       id value=original(actual);[failure recordOperationProtocolFailure];return value;
      };
      result=createCompatibleDaySummaryForEnumeration(builder,cache,binding,failure,classes,100,true,true,statistics,bed,marksOriginalFailure);
     }
     assert(!result);if(error)*error=nil;return YES;
    });
   if(scenario<4||scenario>=6)assert(!querySuccess&&queryError);
   else assert(querySuccess&&!queryError);
   if(scenario<=2||scenario==4)assert(statsCalls==beforeStats&&originalCalls==beforeCalls);
   // Work already done inside callbacks is not claimed to be rolled back.
   if(scenario==3||scenario==6)assert(statsCalls==beforeStats+1&&originalCalls==beforeCalls);
   if(scenario==7)assert(statsCalls==beforeStats+1&&originalCalls==beforeCalls+1);
   [foreign endEnumeration];
  }
  // Normal legacy nil is a skip, not a candidate error, through this same join.
  sample.value=1;
  binding=[[WFHSQueryBinding alloc]initWithActualEnumerator:enumerator profile:profile freshCalendarCache:cache maximumBuilders:10];
  querySuccess=WFHSEnumerateBoundSleepSummaries(binding,enumerator,profile,cache,42,1,10,&queryError,
   ^(id result,BOOL *stop){(void)result;(void)stop;abort();},
   ^BOOL(NSError **error,WFHSSleepSummaryHandler handler,WFHSEnumerationFailure *failure) {
    (void)handler;assert([binding bindActualReturnedBuilder:builder initializationCache:cache verifiedFactoryForThisEnumeration:YES]);
    assert(!createCompatibleDaySummaryForEnumeration(builder,cache,binding,failure,classes,100,false,false,{},{},nilOriginal));
    if(error)*error=nil;return YES;
   });
  assert(querySuccess&&!queryError);sample.value=4;
  // Original exception identity is preserved through the operation wrapper too.
  binding=[[WFHSQueryBinding alloc]initWithActualEnumerator:enumerator profile:profile freshCalendarCache:cache maximumBuilders:10];
  caught=NO;
  @try {
   WFHSEnumerateBoundSleepSummaries(binding,enumerator,profile,cache,42,1,10,&queryError,
    ^(id result,BOOL *stop){(void)result;(void)stop;abort();},
    ^BOOL(NSError **error,WFHSSleepSummaryHandler handler,WFHSEnumerationFailure *failure) {
     (void)error;(void)handler;assert([binding bindActualReturnedBuilder:builder initializationCache:cache verifiedFactoryForThisEnumeration:YES]);
     createCompatibleDaySummaryForEnumeration(builder,cache,binding,failure,classes,100,true,true,statistics,bed,[&](id)->id{@throw sentinel;});
     return YES;
    });
  } @catch(NSException *exception){caught=exception==sentinel;}
  assert(caught&&[binding activeEnumerationGeneration]==0);
  // A direct caller's admission failure/exception is candidate failure; it must
  // not swallow original exceptions or pretend the original work was undone.
  binding=[[WFHSQueryBinding alloc]initWithActualEnumerator:enumerator profile:profile freshCalendarCache:cache maximumBuilders:10];
  assert([binding beginEnumerationFor:enumerator actualProfile:profile actualCache:cache]);
  assert([binding bindActualReturnedBuilder:builder initializationCache:cache verifiedFactoryForThisEnumeration:YES]);
  beforeOriginal=originalCalls;prior=statsCalls;
  attempt=createCompatibleDaySummary(builder,binding,classes,100,true,true,statistics,bed,original,{},[](){return false;});
  assert(attempt.status==DaySummaryStatus::operation_rejected&&originalCalls==beforeOriginal&&statsCalls==prior);
  attempt=createCompatibleDaySummary(builder,binding,classes,100,true,true,statistics,bed,original,{},[]()->bool{throw 17;});
  assert(attempt.status==DaySummaryStatus::candidate_exception&&originalCalls==beforeOriginal&&statsCalls==prior);
  const auto beforeAdmissionOriginal=originalCalls;
  attempt=createCompatibleDaySummary(builder,binding,classes,100,true,true,statistics,bed,original,{},[&](){
   if(originalCalls!=beforeAdmissionOriginal)throw 19;
   return true;
  });
  assert(attempt.status==DaySummaryStatus::candidate_exception&&!attempt.summary&&originalCalls==beforeAdmissionOriginal+1);
  [binding endEnumeration];
  attempt=createCompatibleDaySummary(builder,binding,classes,100,true,true,statistics,bed,original);
  assert(!attempt.complete());
  puts("PASS bound day snapshot/sample/statistics/period/summary orchestration/native metadata preserved/failure not empty success");
 }
}
