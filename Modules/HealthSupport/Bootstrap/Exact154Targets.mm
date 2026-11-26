#include "Exact154Targets.hpp"

#import <objc/runtime.h>

#include <cstring>

#include "IOS154BoundaryIdentity.h"
#include "LoadedMethodIdentity.h"

namespace {

NSString *const WFHShealthDaemonPath =
    @"/System/Library/PrivateFrameworks/HealthDaemon.framework/HealthDaemon";
NSString *const WFHShealthDaemonUUID = @"5C7508EA-8D04-3313-BAD4-A5A30202A475";
NSString *const WFHShealthKitPath = @"/System/Library/Frameworks/HealthKit.framework/HealthKit";
NSString *const WFHShealthKitUUID = @"5763C6BF-DFDD-3615-80F5-F709A77E83D9";

// HealthKit +0x18D114B18 minus the exact image base 0x18D108000.
constexpr uint64_t WFHSAcceptsValueOffset = 0xCB18;

struct WFHSClassRequirement {
    const char *name;
    bool health_kit;
};

const WFHSClassRequirement kRequirements[] = {
    {"HDSleepDaySummaryBuilder", false},
    {"HDSleepPeriodArrayBuilder", false},
    {"HDSleepPeriodSegmentArrayBuilder", false},
    {"HKCalendarCache", true},
    {"HKCategorySample", true},
    {"HKCategoryType", true},
    {"HKSourceRevision", true},
    {"HKSource", true},
    {"HKSleepPeriodSegment", true},
    {"HKSleepPeriod", true},
    {"HKSleepDaySummary", true},
};

void WFHSNote(NSMutableArray<NSString *> *failures, NSString *message) {
    if (failures) {
        [failures addObject:message];
    }
}

} // namespace

BOOL WFHSResolveExact154Targets(WFHSExact154Targets *out, NSMutableArray<NSString *> *failures) {
    if (!out) {
        return NO;
    }
    Class resolved[sizeof(kRequirements) / sizeof(kRequirements[0])] = {};
    BOOL ok = YES;
    for (size_t index = 0; index < sizeof(kRequirements) / sizeof(kRequirements[0]); ++index) {
        const WFHSClassRequirement &requirement = kRequirements[index];
        NSString *name = [NSString stringWithUTF8String:requirement.name];
        Class cls = objc_getClass(requirement.name);
        if (!cls) {
            WFHSNote(failures, [NSString stringWithFormat:@"missing class %@", name]);
            ok = NO;
            continue;
        }
        NSString *expectedPath = requirement.health_kit ? WFHShealthKitPath : WFHShealthDaemonPath;
        NSString *expectedUUID = requirement.health_kit ? WFHShealthKitUUID : WFHShealthDaemonUUID;
        const char *imagePath = class_getImageName(cls);
        if (!imagePath || strcmp(imagePath, expectedPath.UTF8String) != 0) {
            WFHSNote(failures, [NSString stringWithFormat:@"class %@ image %s != %@", name,
                                 imagePath ? imagePath : "(null)", expectedPath]);
            ok = NO;
            continue;
        }
        NSString *uuid = WFHSLoadedImageUUIDForAddress((__bridge const void *)cls);
        if (![uuid isEqualToString:expectedUUID]) {
            WFHSNote(failures, [NSString stringWithFormat:@"class %@ uuid %@ != %@", name, uuid,
                                 expectedUUID]);
            ok = NO;
            continue;
        }
        resolved[index] = cls;
    }
    if (!ok) {
        return NO;
    }

    Class builder = resolved[0];
    Class periodBuilder = resolved[1];
    Class segmentBuilder = resolved[2];
    Class calendarCache = resolved[3];
    Class sample = resolved[4];
    Class categoryType = resolved[5];
    Class sourceRevision = resolved[6];
    Class source = resolved[7];
    Class segment = resolved[8];
    Class period = resolved[9];
    Class summary = resolved[10];

    if (!WFHSCheckIOS154Boundary(WFHSIOS154DayCreate, builder)) {
        WFHSNote(failures, @"createDaySummary owner/ABI/offset mismatch");
        ok = NO;
    }
    WFHSLoadedMethodIdentity *accept = [[WFHSLoadedMethodIdentity alloc]
        initWithClass:categoryType expectedClassName:@"HKCategoryType"
              selector:@selector(_acceptsValue:) isClassMethod:NO expectedMethodOwner:categoryType
       expectedIMPOffset:@(WFHSAcceptsValueOffset) expectedABI:@"B24@0:8q16"
         classImagePath:WFHShealthKitPath classImageUUID:WFHShealthKitUUID
        methodImagePath:WFHShealthKitPath methodImageUUID:WFHShealthKitUUID];
    if (!accept) {
        WFHSNote(failures, @"_acceptsValue: owner/ABI/offset mismatch");
        ok = NO;
    }
    if (!ok) {
        return NO;
    }

    WFHSExact154Targets targets = {};
    targets.classes.builder = builder;
    targets.classes.calendar_cache = calendarCache;
    targets.classes.sample = sample;
    targets.classes.category_type = categoryType;
    targets.classes.source_revision = sourceRevision;
    targets.classes.source = source;
    targets.classes.segment = segment;
    targets.classes.period_builder = periodBuilder;
    targets.classes.period = period;
    targets.classes.summary = summary;
    targets.classes.segment_builder = segmentBuilder;
    targets.category_type = categoryType;
    *out = targets;
    return YES;
}
