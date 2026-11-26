#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
typedef NS_ENUM(NSInteger, WFHSDaySnapshotStatus) {
    WFHSDaySnapshotUnverified, WFHSDaySnapshotComplete, WFHSDaySnapshotInvalidMetadata,
    WFHSDaySnapshotInvalidValue, WFHSDaySnapshotResourceLimit, WFHSDaySnapshotCandidateException
};
@interface WFHSDaySnapshot : NSObject
@property(nonatomic,readonly) WFHSDaySnapshotStatus status;
@property(nonatomic,strong,readonly,nullable) NSArray *sleepAnalysisSamples;
@property(nonatomic,strong,readonly,nullable) NSArray *sleepScheduleSamples;
@property(nonatomic,strong,readonly,nullable) NSArray *sleepDurationGoalSamples;
@property(nonatomic,strong,readonly,nullable) NSDateInterval *dateInterval;
@property(nonatomic,strong,readonly,nullable) id calendarCache;
@property(nonatomic,readonly) int64_t morningIndex;
@property(nonatomic,readonly) uint64_t weekday;
@end

// Offline private-layout adapter for the EXACT audited15.4 day builder, not a
// generic arbitrary ivar reader. No saved offsets, mutations or init/add hooks.
// Caller MUST verify actual image/classes/strong ownership/method identity and
// exclusive synchronous create boundary before use. This function provides no
// native synchronization; array shallow copies don't freeze elements or make
// multi-field reads atomic. Never call on a live device without authorization.
FOUNDATION_EXPORT WFHSDaySnapshot *WFHSReadDayBuilderSnapshot(id builder,
    Class auditedBuilderClass, Class auditedCalendarCacheClass, NSUInteger maximumTotalSamples);
NS_ASSUME_NONNULL_END
