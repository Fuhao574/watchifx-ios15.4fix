#ifndef WF_SLEEP_RETURN_OBSERVATION_H
#define WF_SLEEP_RETURN_OBSERVATION_H

#import <Foundation/Foundation.h>
#include <math.h>

// Offline/read-only observation of the actual native h/d new-wire dictionary.
// No native parsing, downconversion, ACK, send, persistence or input mutation.
// "accepted" means only that this bounded observer accepted a unique Sleep
// update. It is NOT proof of storage, native parse success or effective policy.
// expectedPublic/expectedSecure must be the actual converted models saved before
// sending, NOT a rebuilt wire model. Current callers may supply host fixtures;
// equality with a host fixture is not device/runtime evidence.
// Even complete structural equality is not adoption or secure-policy semantic
// equivalence. No fresh native resolver is invoked or proven by this observer.
// All output keys and status strings are fixed; no IDs, arbitrary keys, JSON,
// exception text, error bodies, hashes or user values are returned.

static BOOL WFSROIsBoolean(id value) {
    return [value isKindOfClass:[NSNumber class]] &&
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

static BOOL WFSROIsNumber(id value) {
    return [value isKindOfClass:[NSNumber class]] && !WFSROIsBoolean(value) &&
        isfinite([value doubleValue]);
}

static BOOL WFSROIsUnsignedInteger(id value) {
    if (!WFSROIsNumber(value)) return NO;
    double number = [value doubleValue];
    return number >= 0 && trunc(number) == number;
}

// Bounds apply to decoded JSON and expected models, including recursive work
// before equality. Depth bounds also reject cyclic expected containers.
static BOOL WFSROBoundedJSON(id value, NSUInteger depth, NSUInteger *remaining) {
    if (!value || depth > 32 || !*remaining) return NO;
    --*remaining;
    if ([value isKindOfClass:[NSDictionary class]]) {
        if ([value count] > 4096) return NO;
        for (id key in value) {
            if (![key isKindOfClass:[NSString class]] || [key length] > 512 ||
                !WFSROBoundedJSON(value[key], depth + 1, remaining)) return NO;
        }
        return YES;
    }
    if ([value isKindOfClass:[NSArray class]]) {
        if ([value count] > 4096) return NO;
        for (id child in value)
            if (!WFSROBoundedJSON(child, depth + 1, remaining)) return NO;
        return YES;
    }
    if ([value isKindOfClass:[NSString class]]) return [value length] <= 1024 * 1024;
    return value == [NSNull null] || WFSROIsBoolean(value) || WFSROIsNumber(value);
}

static BOOL WFSROBoundedRoot(id value) {
    NSUInteger remaining = 16384;
    return [value isKindOfClass:[NSDictionary class]] && [value count] <= 128 &&
        WFSROBoundedJSON(value, 0, &remaining);
}

static NSDictionary *WFSROParsePartition(id bytes) {
    if (![bytes isKindOfClass:[NSData class]] || ![bytes length] ||
        [bytes length] > 1024 * 1024) return nil;
    id root = [NSJSONSerialization JSONObjectWithData:bytes options:0 error:NULL];
    return WFSROBoundedRoot(root) ? root : nil;
}

// Semantic JSON equality (dictionary key order is irrelevant, arrays ordered).
// Unlike NSNumber's default equality, JSON true is never equal to numeric 1.
// Call only after both trees have passed the bounded JSON validation.
static BOOL WFSROEqualJSON(id a, id b) {
    if (WFSROIsBoolean(a) || WFSROIsBoolean(b))
        return WFSROIsBoolean(a) && WFSROIsBoolean(b) && [a isEqual:b];
    if ([a isKindOfClass:[NSNumber class]] || [b isKindOfClass:[NSNumber class]])
        return WFSROIsNumber(a) && WFSROIsNumber(b) && [a isEqualToNumber:b];
    if ([a isKindOfClass:[NSDictionary class]]) {
        if (![b isKindOfClass:[NSDictionary class]] || [a count] != [b count]) return NO;
        for (NSString *key in a)
            if (!b[key] || !WFSROEqualJSON(a[key], b[key])) return NO;
        return YES;
    }
    if ([a isKindOfClass:[NSArray class]]) {
        if (![b isKindOfClass:[NSArray class]] || [a count] != [b count]) return NO;
        for (NSUInteger i = 0; i < [a count]; ++i)
            if (!WFSROEqualJSON(a[i], b[i])) return NO;
        return YES;
    }
    return ([a isKindOfClass:[NSString class]] && [b isKindOfClass:[NSString class]] &&
            [a isEqualToString:b]) || (a == [NSNull null] && b == [NSNull null]);
}

static NSMutableDictionary *WFSROEmptyResult(void) {
    NSMutableDictionary *r = [@{
        @"status": @"refused", @"reason": @"malformed-envelope",
        @"uniqueSleep": @NO, @"modifiedCount": @0, @"deletedCount": @0,
        @"sleepCount": @0, @"tombstonePresent": @NO,
        @"nativeParseProven": @NO, @"storedProven": @NO,
        @"effectivePolicyProven": @NO, @"sendAuthorized": @NO,
        @"freshResolverProven": @NO, @"secureSemanticComparison": @"unknown",
        @"configurationScalarsEqual": @NO, @"configurationScalarsComparisonStatus": @"not-observed",
        @"publicExpectedStatus": @"not-provided", @"secureExpectedStatus": @"not-provided"
    } mutableCopy];
    for (NSString *prefix in @[
        @"version", @"recordEnvelopeVersion", @"recordEnvelopeMinimum",
        @"observedContentCompatibility", @"rootCompatibilityVersion",
        @"rootResolvedCompatibilityVersion", @"rootRawCompatibilityVersion",
        @"rootEffectiveCompatibilityVersion", @"configurationType",
        @"applicationConfigurationType", @"senderConfigurationType",
        @"suppressionType", @"suppressionMode", @"minimumBreakthroughUrgency",
        @"hideApplicationBadges", @"allowIntelligentManagement",
        @"configurationCompatibilityVersion", @"configurationResolvedCompatibilityVersion",
        @"configurationRawCompatibilityVersion", @"configurationEffectiveCompatibilityVersion",
        @"hasSecureData", @"impactsAvailability", @"dimsLockScreen", @"automaticallyGenerated"
    ]) {
        r[[prefix stringByAppendingString:@"Present"]] = @NO;
        r[[prefix stringByAppendingString:@"Status"]] = @"not-observed";
        // Zero is only a placeholder; Present and Status must be consulted.
        r[prefix] = @0;
    }
    for (NSString *prefix in @[
        @"public", @"secure", @"configuration", @"suppressionMode", @"secureConfiguration",
        @"allowedApps", @"platforms", @"sender", @"publicTriggers", @"secureTriggers"
    ]) {
        r[[prefix stringByAppendingString:@"EqualsExpected"]] = @NO;
        r[[prefix stringByAppendingString:@"ComparisonStatus"]] = @"not-observed";
    }
    return r;
}

// Only allow-listed scalar paths reach this function. No semantic enum mapping.
// Enum/version/flag observations are finite, non-boolean, nonnegative integers.
// Future integer values are observable; no supported-enum/version cap is imposed.
static BOOL WFSROScalar(NSMutableDictionary *r, NSString *prefix, id value, BOOL allowBool) {
    (void)allowBool; // Retained helper signature; no output scalar permits bool.
    r[[prefix stringByAppendingString:@"Present"]] = @(value != nil);
    r[[prefix stringByAppendingString:@"Status"]] = value ? @"invalid-type" : @"absent";
    if (!value) return YES;
    if (!WFSROIsUnsignedInteger(value)) return NO;
    r[prefix] = [value copy];
    r[[prefix stringByAppendingString:@"Status"]] = @"observed";
    return YES;
}

// Fixed projection of configuration scalar fields ONLY: excludes suppressionMode
// (compared separately), all root fields, and arbitrary/unknown configuration keys.
// This is diagnostic structural equality, never a native adoption assertion.
static void WFSROCompareConfigurationScalars(NSMutableDictionary *r, NSDictionary *actual,
                                            id expected, NSString *expectedStatus) {
    NSString *status = expectedStatus;
    if ([status isEqualToString:@"available"]) {
        if (!expected) status = @"missing-expected-field";
        else if (![expected isKindOfClass:[NSDictionary class]]) status = @"invalid-expected-field";
        else {
            NSMutableDictionary *a = [NSMutableDictionary dictionary];
            NSMutableDictionary *e = [NSMutableDictionary dictionary];
            BOOL valid = YES;
            for (NSString *field in @[@"configurationType", @"applicationConfigurationType",
                @"senderConfigurationType", @"suppressionType", @"minimumBreakthroughUrgency",
                @"hideApplicationBadges", @"allowIntelligentManagement", @"compatibilityVersion",
                @"resolvedCompatibilityVersion", @"rawCompatibilityVersion", @"effectiveCompatibilityVersion"]) {
                if (actual[field]) a[field] = actual[field];
                if (expected[field]) {
                    if (!WFSROIsUnsignedInteger(expected[field])) valid = NO;
                    e[field] = expected[field];
                }
            }
            if (!valid) status = @"invalid-expected-field";
            else if (!a.count) status = @"missing-observed-field";
            else if (!e.count) status = @"missing-expected-field";
            else {
                BOOL equal = WFSROEqualJSON(a, e);
                r[@"configurationScalarsEqual"] = @(equal);
                status = equal ? @"equal" : @"different";
            }
        }
    }
    r[@"configurationScalarsComparisonStatus"] = status;
}

static void WFSROCompare(NSMutableDictionary *r, NSString *prefix,
                         id actual, id expected, NSString *expectedStatus) {
    NSString *status = expectedStatus;
    if ([status isEqualToString:@"available"]) {
        if (!actual) status = @"missing-observed-field";
        else if (!expected) status = @"missing-expected-field";
        else {
            BOOL equal = WFSROEqualJSON(actual, expected);
            status = equal ? @"equal" : @"different";
            r[[prefix stringByAppendingString:@"EqualsExpected"]] = @(equal);
        }
    }
    r[[prefix stringByAppendingString:@"ComparisonStatus"]] = status;
}

static NSDictionary *WFSROMetadata(id entry, BOOL deleted) {
    if (![entry isKindOfClass:[NSDictionary class]] || [entry count] != 3) return nil;
    NSDictionary *rid = entry[@"recordID"];
    if (![rid isKindOfClass:[NSDictionary class]] || rid.count != 2 ||
        ![rid[@"zone"] isKindOfClass:[NSString class]] || ![rid[@"zone"] length] ||
        [rid[@"zone"] length] > 512 ||
        ![rid[@"identifier"] isKindOfClass:[NSString class]] || ![rid[@"identifier"] length] ||
        [rid[@"identifier"] length] > 512 ||
        !WFSROIsNumber(entry[@"lastModified"]) || [entry[@"lastModified"] doubleValue] < 0 ||
        (!WFSROIsNumber(entry[@"deleted"]) && !WFSROIsBoolean(entry[@"deleted"])) ||
        ![entry[@"deleted"] isEqualToNumber:(deleted ? @1 : @0)]) return nil;
    return rid;
}

static NSDictionary *WFSROObserveImpl(id envelope, NSDictionary *expectedPublic,
                                     NSDictionary *expectedSecure, NSMutableDictionary *r) {
    NSString *ps = !expectedPublic ? @"not-provided" :
        (WFSROBoundedRoot(expectedPublic) ? @"available" : @"invalid-expected");
    NSString *ss = !expectedSecure ? @"not-provided" :
        (WFSROBoundedRoot(expectedSecure) ? @"available" : @"invalid-expected");
    r[@"publicExpectedStatus"] = ps;
    r[@"secureExpectedStatus"] = ss;
    for (NSString *prefix in @[@"public", @"configuration", @"suppressionMode", @"publicTriggers"])
        WFSROCompare(r, prefix, nil, nil, ps);
    r[@"configurationScalarsComparisonStatus"] = [ps isEqualToString:@"available"] ? @"not-observed" : ps;
    for (NSString *prefix in @[@"secure", @"secureConfiguration", @"allowedApps", @"platforms", @"sender", @"secureTriggers"])
        WFSROCompare(r, prefix, nil, nil, ss);

    if (![envelope isKindOfClass:[NSDictionary class]] || [envelope count] > 32) return [r copy];
    NSDictionary *h = envelope[@"h"], *d = envelope[@"d"];
    if (![h isKindOfClass:[NSDictionary class]] || h.count > 32 ||
        ![d isKindOfClass:[NSDictionary class]] || d.count > 32) return [r copy];
    if (!WFSROScalar(r, @"version", h[@"r"], NO) ||
        (![h[@"r"] isEqualToNumber:@11] && ![h[@"r"] isEqualToNumber:@12]) ||
        !WFSROIsNumber(h[@"v"]) || ![h[@"v"] isEqualToNumber:@1] ||
        ![h[@"y"] isKindOfClass:[NSString class]] || ![h[@"y"] isEqualToString:@"syncEngine"] ||
        ![d[@"action"] isKindOfClass:[NSString class]] || ![d[@"action"] isEqualToString:@"update"]) {
        r[@"reason"] = @"unsupported-header-or-action"; return [r copy];
    }
    NSArray *modified = d[@"modifiedRecords"], *deleted = d[@"deletedMetadata"];
    if (![modified isKindOfClass:[NSArray class]] || [modified count] > 32 ||
        ![deleted isKindOfClass:[NSArray class]] || [deleted count] > 32) {
        r[@"reason"] = @"malformed-or-unbounded-batch"; return [r copy];
    }
    r[@"modifiedCount"] = @(modified.count);
    r[@"deletedCount"] = @(deleted.count);
    r[@"tombstonePresent"] = @(deleted.count != 0);
    // Conservatively refuse every tombstone, even an unrelated well-formed one.
    // This early return intentionally skips modified-record/partition evidence;
    // the output is not a partial content observation of that transaction.
    for (id metadata in deleted) {
        if (!WFSROMetadata(metadata, YES)) {
            r[@"reason"] = @"malformed-tombstone"; return [r copy];
        }
    }
    if (deleted.count) { r[@"reason"] = @"tombstone"; return [r copy]; }

    NSDictionary *sleepData = nil, *publicJSON = nil;
    NSUInteger sleeps = 0;
    NSMutableArray *seen = [NSMutableArray array];
    for (id record in modified) {
        if (![record isKindOfClass:[NSDictionary class]] || [record count] != 2 ||
            ![record[@"data"] isKindOfClass:[NSDictionary class]] || [record[@"data"] count] > 128) {
            r[@"reason"] = @"malformed-record"; return [r copy];
        }
        NSDictionary *rid = WFSROMetadata(record[@"metadata"], NO);
        if (!rid) { r[@"reason"] = @"malformed-metadata"; return [r copy]; }
        BOOL sleepID = [rid[@"zone"] isEqualToString:@"DNDSModeConfigurations"] &&
            [rid[@"identifier"] isEqualToString:@"com.apple.sleep.sleep-mode"];
        if (sleepID) { ++sleeps; r[@"sleepCount"] = @(sleeps); }
        if ([seen containsObject:rid]) {
            r[@"reason"] = sleeps > 1 ? @"multiple-sleep" : @"duplicate-record";
            return [r copy];
        }
        [seen addObject:rid];
        if (![rid[@"zone"] isEqualToString:@"DNDSModeConfigurations"]) continue;
        NSDictionary *data = record[@"data"];
        NSDictionary *p = WFSROParsePartition(data[@"DNDSModeConfigurationsRecordData"]);
        NSDictionary *mode = p[@"mode"];
        if (![mode isKindOfClass:[NSDictionary class]] ||
            ![mode[@"modeIdentifier"] isKindOfClass:[NSString class]] || ![mode[@"modeIdentifier"] length]) {
            r[@"reason"] = @"malformed-public-partition"; return [r copy];
        }
        if (![mode[@"modeIdentifier"] isEqualToString:rid[@"identifier"]]) {
            r[@"reason"] = @"identity-conflict"; return [r copy];
        }
        if (sleepID) { sleepData = data; publicJSON = p; }
    }
    if (sleeps != 1) {
        r[@"status"] = sleeps ? @"refused" : @"no-sleep";
        r[@"reason"] = sleeps ? @"multiple-sleep" : @"no-sleep";
        return [r copy];
    }
    r[@"uniqueSleep"] = @YES;
    r[@"reason"] = @"malformed-sleep-partition";
    BOOL scalarsOK = WFSROScalar(r, @"recordEnvelopeVersion", sleepData[@"DNDSModeConfigurationsVersion"], NO);
    scalarsOK = WFSROScalar(r, @"recordEnvelopeMinimum", sleepData[@"DNDSModeConfigurationsMinimumRequiredVersion"], NO) && scalarsOK;
    if (!scalarsOK || !sleepData[@"DNDSModeConfigurationsVersion"] ||
        !sleepData[@"DNDSModeConfigurationsMinimumRequiredVersion"]) return [r copy];
    NSDictionary *secureJSON = WFSROParsePartition(sleepData[@"DNDSModeConfigurationsRecordPartitionedData"]);
    NSDictionary *c = publicJSON[@"configuration"], *sc = secureJSON[@"secureConfiguration"];
    NSDictionary *pt = publicJSON[@"triggers"], *st = secureJSON[@"secureTriggers"];
    if (![c isKindOfClass:[NSDictionary class]] || ![sc isKindOfClass:[NSDictionary class]] ||
        ![pt isKindOfClass:[NSDictionary class]] || ![pt[@"triggers"] isKindOfClass:[NSArray class]] ||
        ![st isKindOfClass:[NSDictionary class]] || ![st[@"triggers"] isKindOfClass:[NSArray class]]) return [r copy];
    // Do not infer or resolve content compatibility from enum/flag combinations.
    for (NSString *field in @[@"compatibilityVersion", @"resolvedCompatibilityVersion",
                              @"rawCompatibilityVersion", @"effectiveCompatibilityVersion"]) {
        NSString *suffix = [field stringByReplacingCharactersInRange:NSMakeRange(0, 1)
                                                        withString:[[field substringToIndex:1] uppercaseString]];
        scalarsOK = WFSROScalar(r, [@"root" stringByAppendingString:suffix], publicJSON[field], NO) && scalarsOK;
        scalarsOK = WFSROScalar(r, [@"configuration" stringByAppendingString:suffix], c[field], NO) && scalarsOK;
    }
    scalarsOK = WFSROScalar(r, @"observedContentCompatibility", c[@"compatibilityVersion"], NO) && scalarsOK;
    for (NSString *field in @[@"configurationType", @"applicationConfigurationType", @"senderConfigurationType",
                              @"suppressionType", @"suppressionMode", @"minimumBreakthroughUrgency",
                              @"hideApplicationBadges", @"allowIntelligentManagement"])
        scalarsOK = WFSROScalar(r, field, c[field], NO) && scalarsOK;
    for (NSString *field in @[@"hasSecureData", @"automaticallyGenerated"])
        scalarsOK = WFSROScalar(r, field, publicJSON[field], NO) && scalarsOK;
    for (NSString *field in @[@"impactsAvailability", @"dimsLockScreen"])
        scalarsOK = WFSROScalar(r, field, publicJSON[field], NO) && scalarsOK;
    // Known numeric fields that are deliberately not returned (timestamps and
    // display/mode details). Type checking does not assign them enum semantics.
    for (NSString *field in @[@"created", @"lastModified"])
        if (publicJSON[field] && !WFSROIsNumber(publicJSON[field])) scalarsOK = NO;
    NSDictionary *mode = publicJSON[@"mode"];
    for (NSString *field in @[@"semanticType", @"visibility"])
        if (mode[field] && !WFSROIsNumber(mode[field])) scalarsOK = NO;
    // Validate known numeric maps without emitting their keys or values.
    id apps = sc[@"allowedApplications"], platforms = sc[@"platforms"], sender = sc[@"senderConfiguration"];
    if ((apps && ![apps isKindOfClass:[NSDictionary class]]) ||
        (platforms && ![platforms isKindOfClass:[NSDictionary class]]) ||
        (sender && ![sender isKindOfClass:[NSDictionary class]])) return [r copy];
    for (id key in apps) if (![apps[key] isKindOfClass:[NSDictionary class]]) return [r copy];
    for (id key in platforms) if (!WFSROIsNumber(platforms[key])) return [r copy];
    if (!scalarsOK) { r[@"reason"] = @"invalid-scalar"; return [r copy]; }

    NSDictionary *ep = [ps isEqualToString:@"available"] ? expectedPublic : nil;
    NSDictionary *es = [ss isEqualToString:@"available"] ? expectedSecure : nil;
    NSDictionary *esc = [es[@"secureConfiguration"] isKindOfClass:[NSDictionary class]] ? es[@"secureConfiguration"] : nil;
    WFSROCompare(r, @"public", publicJSON, ep, ps);
    WFSROCompare(r, @"secure", secureJSON, es, ss);
    WFSROCompare(r, @"configuration", c, ep[@"configuration"], ps);
    WFSROCompareConfigurationScalars(r, c, ep[@"configuration"], ps);
    NSDictionary *ec = [ep[@"configuration"] isKindOfClass:[NSDictionary class]] ? ep[@"configuration"] : nil;
    NSString *suppressionExpectedStatus = ps;
    if ([ps isEqualToString:@"available"] && ep[@"configuration"] && !ec)
        suppressionExpectedStatus = @"invalid-expected-field";
    else if (ec[@"suppressionMode"] && !WFSROIsUnsignedInteger(ec[@"suppressionMode"]))
        suppressionExpectedStatus = @"invalid-expected-field";
    WFSROCompare(r, @"suppressionMode", c[@"suppressionMode"], ec[@"suppressionMode"], suppressionExpectedStatus);
    WFSROCompare(r, @"secureConfiguration", sc, es[@"secureConfiguration"], ss);
    WFSROCompare(r, @"allowedApps", apps, esc[@"allowedApplications"], ss);
    WFSROCompare(r, @"platforms", platforms, esc[@"platforms"], ss);
    WFSROCompare(r, @"sender", sender, esc[@"senderConfiguration"], ss);
    WFSROCompare(r, @"publicTriggers", pt, ep[@"triggers"], ps);
    WFSROCompare(r, @"secureTriggers", st, es[@"secureTriggers"], ss);
    r[@"status"] = @"accepted";
    r[@"reason"] = @"unique-sleep-observed";
    return [r copy];
}

static NSDictionary *WFSleepReturnObserve(id envelope, NSDictionary *expectedPublic,
                                          NSDictionary *expectedSecure) {
    @try {
        return WFSROObserveImpl(envelope, expectedPublic, expectedSecure, WFSROEmptyResult());
    } @catch (NSException *exception) {
        (void)exception;
        // Discard partial observation; never expose exception class/name/body.
        @try {
            NSMutableDictionary *r = WFSROEmptyResult();
            r[@"reason"] = @"exception";
            return [r copy];
        } @catch (NSException *fallbackException) {
            (void)fallbackException;
            // EmptyResult uses only fixed Foundation literals/local allocations.
            // As with all ObjC code, process-level OOM/termination is not caught.
            return nil;
        }
    }
}

#endif /* WF_SLEEP_RETURN_OBSERVATION_H */
