#import "FocusWireConverter.h"
#import <objc/runtime.h>

NSString *const WFFocusConverterErrorDomain = @"cn.fkj233.watchfix.FocusConfigCompatibility";

static NSString *const kWFFocusRecordData = @"DNDSModeConfigurationsRecordData";
static NSString *const kWFFocusRecordPartitionedData = @"DNDSModeConfigurationsRecordPartitionedData";
static NSString *const kWFFocusRecordVersion = @"DNDSModeConfigurationsVersion";
static NSString *const kWFFocusRecordMinimumVersion = @"DNDSModeConfigurationsMinimumRequiredVersion";
static NSString *const kWFFocusSleepIdentifier = @"com.apple.sleep.sleep-mode";
static NSString *const kWFFocusModeZone = @"DNDSModeConfigurations";

typedef NS_ENUM(NSInteger, WFFocusWireKind) {
    WFFocusWireMalformed = -1,
    WFFocusWireLegacy = 0,
    WFFocusWireOtherZone,
    WFFocusWireMode,
};

static NSError *WFFocusError(NSInteger code, NSString *description) {
    return [NSError errorWithDomain:WFFocusConverterErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description ?: @"Focus conversion failed"}];
}

static BOOL WFFocusSetError(NSError **error, NSInteger code, NSString *description) {
    if (error) {
        *error = WFFocusError(code, description);
    }
    return NO;
}

static WFFocusWireKind WFFocusClassifyWireRecord(id record, NSString **modeIdentifier, NSError **error) {
    if (![record isKindOfClass:[NSDictionary class]]) return WFFocusWireLegacy;
    NSDictionary *wire = record;
    if (!wire[@"metadata"] && !wire[@"data"]) return WFFocusWireLegacy;
    NSDictionary *metadata = wire[@"metadata"];
    NSDictionary *recordID = [metadata isKindOfClass:[NSDictionary class]] ? metadata[@"recordID"] : nil;
    if (wire.count != 2 || ![wire[@"data"] isKindOfClass:[NSDictionary class]] ||
        ![metadata isKindOfClass:[NSDictionary class]] || metadata.count != 3 ||
        ![recordID isKindOfClass:[NSDictionary class]] || recordID.count != 2 ||
        ![recordID[@"identifier"] isKindOfClass:[NSString class]] || ![recordID[@"identifier"] length] ||
        ![recordID[@"zone"] isKindOfClass:[NSString class]] || ![recordID[@"zone"] length] ||
        ![metadata[@"lastModified"] isKindOfClass:[NSNumber class]] ||
        ![metadata[@"deleted"] isKindOfClass:[NSNumber class]] || ![metadata[@"deleted"] isEqualToNumber:@0]) {
        WFFocusSetError(error, 1070, @"Malformed or deleted native wire record metadata");
        return WFFocusWireMalformed;
    }
    if (![recordID[@"zone"] isEqualToString:kWFFocusModeZone]) return WFFocusWireOtherZone;
    if (modeIdentifier) *modeIdentifier = recordID[@"identifier"];
    return WFFocusWireMode;
}

static id WFFocusRecordValue(id record, NSString *key) {
    if ([record isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dictionary = record;
        // Native DNDSIDSRecord dictionaryRepresentationWithContext: wraps the
        // backing fields under data and separately serializes metadata.
        if (dictionary[@"data"] || dictionary[@"metadata"]) {
            id data = dictionary[@"data"];
            if (![data isKindOfClass:[NSDictionary class]] ||
                ![dictionary[@"metadata"] isKindOfClass:[NSDictionary class]] || dictionary[key]) return nil;
            return data[key];
        }
        return dictionary[key]; // Legacy flat host/record backing fixture.
    }
    SEL selector = @selector(objectForKey:);
    if ([record respondsToSelector:selector]) {
        return [record objectForKey:key];
    }
    return nil;
}

NSString *WFFocusDeletedMetadataSummary(id deletedMetadata) {
    if (![deletedMetadata isKindOfClass:[NSArray class]]) return @"tombstones=INVALID";
    NSUInteger sleep = 0, otherMode = 0, otherZone = 0, invalid = 0;
    for (id entry in deletedMetadata) {
        NSDictionary *metadata = [entry isKindOfClass:[NSDictionary class]] ? entry : nil;
        NSDictionary *recordID = [metadata[@"recordID"] isKindOfClass:[NSDictionary class]] ? metadata[@"recordID"] : nil;
        if (!metadata || metadata.count != 3 || !recordID || recordID.count != 2 ||
            ![recordID[@"identifier"] isKindOfClass:[NSString class]] || ![recordID[@"identifier"] length] ||
            ![recordID[@"zone"] isKindOfClass:[NSString class]] || ![recordID[@"zone"] length] ||
            ![metadata[@"lastModified"] isKindOfClass:[NSNumber class]] ||
            ![metadata[@"deleted"] isKindOfClass:[NSNumber class]] || ![metadata[@"deleted"] isEqualToNumber:@1]) {
            ++invalid; continue;
        }
        if (![recordID[@"zone"] isEqualToString:kWFFocusModeZone]) ++otherZone;
        else if ([recordID[@"identifier"] isEqualToString:kWFFocusSleepIdentifier]) ++sleep;
        else ++otherMode;
    }
    return [NSString stringWithFormat:@"tombstones=%lu sleepConflict=%@ otherMode=%lu otherZone=%lu invalid=%lu sendAuthorized=NO",
        (unsigned long)[deletedMetadata count], sleep ? @"YES" : @"NO",
        (unsigned long)otherMode, (unsigned long)otherZone, (unsigned long)invalid];
}

static BOOL WFFocusSetRecordValue(id record, NSString *key, id value) {
    if ([record isKindOfClass:[NSMutableDictionary class]]) {
        NSMutableDictionary *dictionary = record;
        if (dictionary[@"data"] || dictionary[@"metadata"]) {
            if (![dictionary[@"data"] isKindOfClass:[NSDictionary class]] ||
                ![dictionary[@"metadata"] isKindOfClass:[NSDictionary class]] || dictionary[key]) return NO;
            // Copy-on-write: shallow copying the envelope must not mutate the
            // original native backing dictionary or serialized metadata.
            NSMutableDictionary *data = [dictionary[@"data"] mutableCopy];
            data[key] = value;
            dictionary[@"data"] = data;
        } else dictionary[key] = value;
        return YES;
    }
    SEL selector = @selector(setObject:forKey:);
    if ([record respondsToSelector:selector]) {
        [record setObject:value forKey:key];
        return YES;
    }
    return NO;
}

static NSMutableDictionary *WFFocusJSONDictionary(NSData *data, NSError **error) {
    if (![data isKindOfClass:[NSData class]] || data.length == 0) {
        if (WFFocusSetError(error, 1001, @"Missing Focus JSON partition")) {
            return nil;
        }
        return nil;
    }
    NSError *jsonError = nil;
    id value = [NSJSONSerialization JSONObjectWithData:data
                                               options:NSJSONReadingMutableContainers
                                                 error:&jsonError];
    if (![value isKindOfClass:[NSMutableDictionary class]]) {
        WFFocusSetError(error, 1002, @"Focus JSON partition is not a dictionary");
        return nil;
    }
    return value;
}

static NSData *WFFocusJSONData(NSDictionary *dictionary, NSError **error) {
    NSError *jsonError = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:dictionary
                                                   options:NSJSONWritingSortedKeys
                                                     error:&jsonError];
    if (!data) {
        WFFocusSetError(error, 1003, @"Unable to serialize converted Focus JSON");
    }
    return data;
}

static BOOL WFFocusReadPartitions(id record, NSMutableDictionary **publicOut,
                                  NSMutableDictionary **secureOut, NSError **error) {
    id version = WFFocusRecordValue(record, kWFFocusRecordVersion);
    id minimum = WFFocusRecordValue(record, kWFFocusRecordMinimumVersion);
    if (![version isKindOfClass:[NSNumber class]] || ![minimum isKindOfClass:[NSNumber class]] ||
        ![version isEqualToNumber:@2] || ![minimum isEqualToNumber:@2]) {
        return WFFocusSetError(error, 1010, @"Unsupported Focus record envelope version");
    }
    NSData *publicData = WFFocusRecordValue(record, kWFFocusRecordData);
    NSData *secureData = WFFocusRecordValue(record, kWFFocusRecordPartitionedData);
    NSMutableDictionary *publicJSON = WFFocusJSONDictionary(publicData, error);
    NSMutableDictionary *secureJSON = WFFocusJSONDictionary(secureData, error);
    if (!publicJSON || !secureJSON) {
        return NO;
    }
    if (publicOut) *publicOut = publicJSON;
    if (secureOut) *secureOut = secureJSON;
    return YES;
}

static BOOL WFFocusExactKeys(NSDictionary *dictionary, NSSet *expected, NSError **error) {
    NSSet *actual = [NSSet setWithArray:dictionary.allKeys];
    if (![actual isEqualToSet:expected]) {
        return WFFocusSetError(error, 1020, @"Unexpected or missing Focus partition keys");
    }
    return YES;
}

static BOOL WFFocusKeysSubset(NSDictionary *dictionary, NSSet *allowed, NSError **error) {
    NSMutableSet *unknown = [NSMutableSet setWithArray:dictionary.allKeys];
    [unknown minusSet:allowed];
    if (unknown.count) {
        return WFFocusSetError(error, 1021, @"Unknown Focus mode keys");
    }
    return YES;
}

static BOOL WFFocusValidateTriggers(id value, NSError **error) {
    // DNDSModeConfigurationTriggersRecord wraps its list in a dictionary.
    // An array here was a host-fixture mistake, not the native wire shape.
    if (![value isKindOfClass:[NSDictionary class]] ||
        !WFFocusExactKeys(value, [NSSet setWithObject:@"triggers"], error) ||
        ![value[@"triggers"] isKindOfClass:[NSArray class]]) {
        return WFFocusSetError(error, 1026, @"Invalid native trigger container");
    }
    return YES;
}

static BOOL WFFocusValidateMode(NSDictionary *publicJSON, NSError **error) {
    NSSet *rootKeys = [NSSet setWithArray:@[
        @"mode", @"configuration", @"triggers", @"impactsAvailability", @"dimsLockScreen",
        @"created", @"lastModified", @"automaticallyGenerated", @"hasSecureData",
    ]];
    if (!WFFocusExactKeys(publicJSON, rootKeys, error)) return NO;

    NSDictionary *mode = publicJSON[@"mode"];
    if (![mode isKindOfClass:[NSDictionary class]]) {
        return WFFocusSetError(error, 1022, @"Missing Focus mode record");
    }
    NSSet *modeKeys = [NSSet setWithArray:@[
        @"name", @"modeIdentifier", @"semanticType", @"visibility", @"identifier",
        @"tintColorName", @"symbolImageName",
    ]];
    if (!WFFocusKeysSubset(mode, modeKeys, error)) return NO;
    if (![mode[@"modeIdentifier"] isEqual:kWFFocusSleepIdentifier] ||
        ![mode[@"semanticType"] isKindOfClass:[NSNumber class]] ||
        [mode[@"semanticType"] integerValue] != 1 ||
        ![mode[@"name"] isKindOfClass:[NSString class]] ||
        ![mode[@"identifier"] isKindOfClass:[NSString class]] ||
        ![mode[@"visibility"] isKindOfClass:[NSNumber class]]) {
        return WFFocusSetError(error, 1023, @"Record is not the supported Sleep mode");
    }
    if ((mode[@"tintColorName"] && ![mode[@"tintColorName"] isKindOfClass:[NSString class]]) ||
        (mode[@"symbolImageName"] && ![mode[@"symbolImageName"] isKindOfClass:[NSString class]])) {
        return WFFocusSetError(error, 1024, @"Unexpected Sleep display field type");
    }

    if (![publicJSON[@"dimsLockScreen"] isKindOfClass:[NSNumber class]] ||
        [publicJSON[@"dimsLockScreen"] integerValue] != 2 ||
        ![publicJSON[@"impactsAvailability"] isKindOfClass:[NSNumber class]] ||
        [publicJSON[@"impactsAvailability"] integerValue] != 2 ||
        ![publicJSON[@"hasSecureData"] isKindOfClass:[NSNumber class]] ||
        [publicJSON[@"hasSecureData"] integerValue] != 1 ||
        ![publicJSON[@"automaticallyGenerated"] isKindOfClass:[NSNumber class]] ||
        [publicJSON[@"automaticallyGenerated"] integerValue] != 0 ||
        ![publicJSON[@"created"] isKindOfClass:[NSNumber class]] ||
        ![publicJSON[@"lastModified"] isKindOfClass:[NSNumber class]]) {
        return WFFocusSetError(error, 1025, @"Sleep record is outside the verified scalar subset");
    }
    return WFFocusValidateTriggers(publicJSON[@"triggers"], error);
}

static NSMutableDictionary *WFFocusConvertConfiguration(NSDictionary *configuration, NSError **error) {
    if (![configuration isKindOfClass:[NSDictionary class]]) {
        if (WFFocusSetError(error, 1030, @"Missing Sleep configuration")) return nil;
        return nil;
    }
    NSSet *allowed = [NSSet setWithArray:@[
        @"configurationType", @"suppressionType", @"minimumBreakthroughUrgency", @"hideApplicationBadges",
    ]];
    if (!WFFocusKeysSubset(configuration, allowed, error)) return nil;
    NSNumber *type = configuration[@"configurationType"];
    NSNumber *suppression = configuration[@"suppressionType"];
    if (![type isKindOfClass:[NSNumber class]] || type.integerValue != 0 ||
        ![suppression isKindOfClass:[NSNumber class]] || suppression.integerValue != 1) {
        if (WFFocusSetError(error, 1031, @"Unsupported Sleep configuration enum")) return nil;
        return nil;
    }
    NSNumber *urgency = configuration[@"minimumBreakthroughUrgency"];
    NSNumber *badges = configuration[@"hideApplicationBadges"];
    if ((urgency && ![urgency isKindOfClass:[NSNumber class]]) ||
        (badges && ![badges isKindOfClass:[NSNumber class]])) {
        if (WFFocusSetError(error, 1032, @"Unexpected Sleep configuration field type")) return nil;
        return nil;
    }
    return [NSMutableDictionary dictionaryWithDictionary:@{
        @"applicationConfigurationType": @0,
        @"senderConfigurationType": @0,
        @"suppressionType": suppression,
        @"suppressionMode": @0,
        @"minimumBreakthroughUrgency": urgency ?: @0,
        @"hideApplicationBadges": badges ?: @2,
        @"allowIntelligentManagement": @1,
        // Native DNDConfiguration.makeRecord serializes the effective content
        // version. For THIS supported subset only: app/sender/thread=0,
        // no Web exceptions, intelligent=1 -> native effective version is 3.
        // This is not the IDS header, mode-root version or record envelope.
        @"compatibilityVersion": @3,
    }];
}

static id WFFocusConvertSecureValue(id value, NSError **error) {
    if ([value isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *converted = [NSMutableDictionary dictionaryWithCapacity:[value count]];
        for (id key in (NSDictionary *)value) {
            if (![key isKindOfClass:[NSString class]]) {
                WFFocusSetError(error, 1040, @"Non-string secure Focus key");
                return nil;
            }
            NSString *sourceKey = key;
            NSString *targetKey = sourceKey;
            NSString *lower = sourceKey.lowercaseString;
            if ([lower containsString:@"web"]) {
                WFFocusSetError(error, 1041, @"Web App exceptions require a separate converter");
                return nil;
            }
            if ([sourceKey isEqualToString:@"deniedApplications"]) {
                targetKey = @"silencedApplications";
            } else if ([sourceKey isEqualToString:@"deniedContacts"]) {
                targetKey = @"silencedContacts";
            } else if ([lower containsString:@"denied"] &&
                       ![sourceKey isEqualToString:@"deniedContactTypes"] &&
                       ![sourceKey isEqualToString:@"deniedContactGroups"] &&
                       ![sourceKey isEqualToString:@"deniedThreads"]) {
                WFFocusSetError(error, 1042, @"Unknown denied Focus exception field");
                return nil;
            }
            if (![targetKey isEqualToString:sourceKey] && [value objectForKey:targetKey]) {
                WFFocusSetError(error, 1043, @"Conflicting denied/silenced Focus fields");
                return nil;
            }
            id child = WFFocusConvertSecureValue(value[sourceKey], error);
            if (!child) return nil;
            converted[targetKey] = child;
        }
        return converted;
    }
    if ([value isKindOfClass:[NSArray class]]) {
        NSMutableArray *converted = [NSMutableArray arrayWithCapacity:[value count]];
        for (id childValue in (NSArray *)value) {
            id child = WFFocusConvertSecureValue(childValue, error);
            if (!child) return nil;
            [converted addObject:child];
        }
        return converted;
    }
    if ([value isKindOfClass:[NSString class]] || [value isKindOfClass:[NSNumber class]]) {
        return value;
    }
    WFFocusSetError(error, 1044, @"Unsupported secure Focus JSON value");
    return nil;
}

static NSMutableDictionary *WFFocusConvertSecurePartition(NSMutableDictionary *secureJSON, NSError **error) {
    NSSet *rootKeys = [NSSet setWithArray:@[@"secureConfiguration", @"secureTriggers"]];
    if (!WFFocusExactKeys(secureJSON, rootKeys, error)) return nil;
    if (![secureJSON[@"secureConfiguration"] isKindOfClass:[NSDictionary class]]) {
        if (WFFocusSetError(error, 1050, @"Invalid Sleep secure partition")) return nil;
        return nil;
    }
    if (!WFFocusValidateTriggers(secureJSON[@"secureTriggers"], error)) return nil;
    NSDictionary *secureConfiguration = secureJSON[@"secureConfiguration"];
    id apps = secureConfiguration[@"allowedApplications"];
    if (apps && ![apps isKindOfClass:[NSDictionary class]]) {
        WFFocusSetError(error, 1051, @"Native allowed applications must be a dictionary"); return nil;
    }
    for (id key in apps) {
        if (![key isKindOfClass:[NSString class]] || ![apps[key] isKindOfClass:[NSDictionary class]]) {
            WFFocusSetError(error, 1051, @"Invalid native allowed application entry"); return nil;
        }
    }
    id platforms = secureConfiguration[@"platforms"];
    if (platforms && ![platforms isKindOfClass:[NSDictionary class]]) {
        WFFocusSetError(error, 1051, @"Native application platforms must be a dictionary"); return nil;
    }
    for (id key in platforms) {
        if (![key isKindOfClass:[NSString class]] || ![platforms[key] isKindOfClass:[NSNumber class]]) {
            WFFocusSetError(error, 1051, @"Invalid native application platform entry"); return nil;
        }
    }
    for (NSString *key in @[@"deniedApplications", @"allowedContactTypes",
                            @"deniedContactTypes", @"allowedContactGroups", @"deniedContactGroups"]) {
        id value = secureConfiguration[key];
        if (value && ![value isKindOfClass:[NSArray class]]) {
            if (WFFocusSetError(error, 1051, @"Unexpected secure exception collection type")) return nil;
            return nil;
        }
    }
    id convertedConfiguration = WFFocusConvertSecureValue(secureConfiguration, error);
    id convertedTriggers = WFFocusConvertSecureValue(secureJSON[@"secureTriggers"], error);
    if (!convertedConfiguration || !convertedTriggers) return nil;
    // iOS 15.4 has no Web App exception collections in this source schema. Make
    // the empty target collections explicit rather than inheriting Watch values.
    convertedConfiguration[@"allowedWebApplications"] = @[];
    convertedConfiguration[@"silencedWebApplications"] = @[];
    return [NSMutableDictionary dictionaryWithDictionary:@{
        @"secureConfiguration": convertedConfiguration,
        @"secureTriggers": convertedTriggers,
    }];
}

// This behavior candidate is limited to the actually retained Sleep
// trigger subset. Do not claim arbitrary trigger compatibility from containers.
static BOOL WFSleep3TriggerSubset(NSDictionary *publicJSON,NSDictionary *secureJSON,NSError **error) {
    id pub=publicJSON[@"triggers"], sec=secureJSON[@"secureTriggers"];
    if (![pub isKindOfClass:[NSDictionary class]] || [pub count]!=1 ||
        ![pub[@"triggers"] isKindOfClass:[NSArray class]] || [pub[@"triggers"] count]!=1 ||
        ![sec isKindOfClass:[NSDictionary class]] || [sec count]!=1 ||
        ![sec[@"triggers"] isKindOfClass:[NSArray class]] || [sec[@"triggers"] count]!=0)
        return WFFocusSetError(error,1080,@"Unverified Sleep trigger partition");
    id trigger=[pub[@"triggers"] firstObject], setting=[trigger isKindOfClass:[NSDictionary class]] ? trigger[@"enabledSetting"]:nil;
    if (![trigger isKindOfClass:[NSDictionary class]] || [trigger count]!=2 ||
        ![trigger[@"class"] isEqual:@"DNDModeConfigurationSleepingTrigger"] ||
        ![setting isKindOfClass:[NSNumber class]] ||
        CFGetTypeID((__bridge CFTypeRef)setting)==CFBooleanGetTypeID() || ![setting isEqualToNumber:@2])
        return WFFocusSetError(error,1081,@"Only enabled native SleepingTrigger supported");
    return YES;
}

static id WFFocusConvertSleepRecord(id record, NSError **error) {
    NSMutableDictionary *publicJSON = nil;
    NSMutableDictionary *secureJSON = nil;
    if (!WFFocusReadPartitions(record, &publicJSON, &secureJSON, error)) return nil;
    if (!WFFocusValidateMode(publicJSON, error) || !WFSleep3TriggerSubset(publicJSON,secureJSON,error)) return nil;

    NSMutableDictionary *convertedConfiguration = WFFocusConvertConfiguration(publicJSON[@"configuration"], error);
    NSMutableDictionary *convertedSecure = WFFocusConvertSecurePartition(secureJSON, error);
    if (!convertedConfiguration || !convertedSecure) return nil;
    publicJSON[@"configuration"] = convertedConfiguration;

    NSData *publicData = WFFocusJSONData(publicJSON, error);
    NSData *secureData = WFFocusJSONData(convertedSecure, error);
    if (!publicData || !secureData) return nil;

    id convertedRecord = [record isKindOfClass:[NSDictionary class]] ? [record mutableCopy] : [record copy];
    if (!convertedRecord ||
        !WFFocusSetRecordValue(convertedRecord, kWFFocusRecordData, publicData) ||
        !WFFocusSetRecordValue(convertedRecord, kWFFocusRecordPartitionedData, secureData)) {
        WFFocusSetError(error, 1060, @"Unable to preserve native Focus record type");
        return nil;
    }
    return convertedRecord;
}

NSDictionary *WFFocusConvertSleepMessage(NSDictionary *message, NSError **error) {
    if (![message isKindOfClass:[NSDictionary class]]) {
        WFFocusSetError(error, 2001, @"Missing outgoing Focus message");
        return nil;
    }
    NSSet *keys = [NSSet setWithArray:@[@"action", @"modifiedRecords", @"deletedMetadata"]];
    if (!WFFocusExactKeys(message, keys, error)) return nil;
    NSString *action = [message[@"action"] isKindOfClass:[NSString class]] ? message[@"action"] : nil;
    NSArray *modified = message[@"modifiedRecords"];
    NSArray *deleted = message[@"deletedMetadata"];
    if ((![action isEqualToString:@"update"] && ![action isEqualToString:@"replace"]) ||
        ![modified isKindOfClass:[NSArray class]] || ![deleted isKindOfClass:[NSArray class]] || deleted.count != 0) {
        WFFocusSetError(error, 2002, @"Only a deletion-free Sleep update is supported");
        return nil;
    }

    id convertedSleep = nil;
    for (id record in modified) {
        NSString *metadataModeIdentifier = nil;
        WFFocusWireKind kind = WFFocusClassifyWireRecord(record, &metadataModeIdentifier, error);
        if (kind == WFFocusWireMalformed) return nil;
        if (kind == WFFocusWireOtherZone) continue;
        // Non-Sleep mode records need no payload parse in a Sleep-only task.
        if (kind == WFFocusWireMode && ![metadataModeIdentifier isEqualToString:kWFFocusSleepIdentifier]) continue;
        NSMutableDictionary *publicJSON = nil;
        NSMutableDictionary *secureJSON = nil;
        if (!WFFocusReadPartitions(record, &publicJSON, &secureJSON, error)) return nil;
        id mode = publicJSON[@"mode"];
        if (![mode isKindOfClass:[NSDictionary class]]) {
            WFFocusSetError(error, 2003, @"Malformed Focus mode in outgoing batch");
            return nil;
        }
        if (metadataModeIdentifier && ![mode[@"modeIdentifier"] isEqual:metadataModeIdentifier]) {
            WFFocusSetError(error, 1071, @"Mode payload identity conflicts with native metadata"); return nil;
        }
        if (![mode[@"modeIdentifier"] isEqual:kWFFocusSleepIdentifier]) continue;
        if (convertedSleep) {
            WFFocusSetError(error, 2004, @"Multiple Sleep records in one transaction");
            return nil;
        }
        convertedSleep = WFFocusConvertSleepRecord(record, error);
        if (!convertedSleep) return nil;
    }
    if (!convertedSleep) {
        WFFocusSetError(error, 2005, @"No Sleep record in outgoing batch");
        return nil;
    }
    return @{@"action": @"update", @"modifiedRecords": @[convertedSleep], @"deletedMetadata": @[]};
}

NSDictionary *WFFocusPlanIndependentSleepUpdate(NSDictionary *source, NSError **error) {
    if (![source isKindOfClass:[NSDictionary class]] ||
        !WFFocusExactKeys(source, [NSSet setWithArray:@[@"action", @"modifiedRecords", @"deletedMetadata"]], error)) return nil;
    if (![source[@"action"] isEqual:@"replace"] ||
        ![source[@"modifiedRecords"] isKindOfClass:[NSArray class]] ||
        ![source[@"deletedMetadata"] isKindOfClass:[NSArray class]] ||
        [source[@"modifiedRecords"] count] == 0 || [source[@"modifiedRecords"] count] > 32 ||
        [source[@"deletedMetadata"] count] > 32) {
        WFFocusSetError(error, 2200, @"Independent Sleep plan requires a bounded native replace source"); return nil;
    }
    NSMutableSet *modifiedIDs = [NSMutableSet set];
    id sleep = nil;
    for (id record in source[@"modifiedRecords"]) {
        NSString *identifier = nil;
        WFFocusWireKind kind = WFFocusClassifyWireRecord(record, &identifier, error);
        if (kind == WFFocusWireMalformed || kind == WFFocusWireLegacy) {
            WFFocusSetError(error, 2201, @"Plan requires fully classified wire records"); return nil;
        }
        NSDictionary *recordID = record[@"metadata"][@"recordID"];
        if ([modifiedIDs containsObject:recordID]) {
            WFFocusSetError(error, 2202, @"Duplicate source record identity"); return nil;
        }
        // Dictionary equality, not string concatenation: zone/id cannot collide.
        [modifiedIDs addObject:[recordID copy]];
        if (kind == WFFocusWireMode && [identifier isEqual:kWFFocusSleepIdentifier]) sleep = record;
    }
    if (!sleep) { WFFocusSetError(error, 2005, @"No Sleep source record"); return nil; }
    NSMutableSet *deletedIDs = [NSMutableSet set];
    for (id entry in source[@"deletedMetadata"]) {
        NSDictionary *metadata = [entry isKindOfClass:[NSDictionary class]] ? entry : nil;
        NSDictionary *recordID = [metadata[@"recordID"] isKindOfClass:[NSDictionary class]] ? metadata[@"recordID"] : nil;
        if (!metadata || metadata.count != 3 || !recordID || recordID.count != 2 ||
            ![recordID[@"identifier"] isKindOfClass:[NSString class]] || ![recordID[@"identifier"] length] ||
            ![recordID[@"zone"] isEqual:kWFFocusModeZone] ||
            ![metadata[@"lastModified"] isKindOfClass:[NSNumber class]] ||
            ![metadata[@"deleted"] isKindOfClass:[NSNumber class]] || ![metadata[@"deleted"] isEqualToNumber:@1]) {
            WFFocusSetError(error, 2203, @"Unknown or malformed tombstone scope"); return nil;
        }
        if ([recordID[@"identifier"] isEqual:kWFFocusSleepIdentifier] ||
            [modifiedIDs containsObject:recordID] || [deletedIDs containsObject:recordID]) {
            WFFocusSetError(error, 2204, @"Tombstone conflicts with selected or modified source identity"); return nil;
        }
        [deletedIDs addObject:[recordID copy]];
    }
    NSMutableDictionary *publicJSON = nil;
    if (!WFFocusReadPartitions(sleep, &publicJSON, NULL, error)) return nil;
    id mode = publicJSON[@"mode"];
    if (![mode isKindOfClass:[NSDictionary class]] || ![mode[@"modeIdentifier"] isEqual:kWFFocusSleepIdentifier]) {
        WFFocusSetError(error, 1071, @"Sleep source metadata/payload conflict"); return nil;
    }
    id converted = WFFocusConvertSleepRecord(sleep, error);
    if (!converted) return nil;
    return @{@"candidateMessage": @{@"action": @"update", @"modifiedRecords": @[converted], @"deletedMetadata": @[]},
        @"sourceModifiedCount": @([source[@"modifiedRecords"] count]),
        @"omittedModifiedCount": @([source[@"modifiedRecords"] count]-1),
        @"omittedOtherModeTombstones": @([source[@"deletedMetadata"] count]),
        @"nativeReplaceCompleted": @NO, @"sendAuthorized": @NO};
}

NSString *WFFocusSleepConversionPreflightSummary(id message) {
    @try {
        NSDictionary *body = [message isKindOfClass:[NSDictionary class]] ? message : nil;
        NSArray *records = body[@"modifiedRecords"];
        if (![records isKindOfClass:[NSArray class]] || records.count > 32)
            return @"sleepDryRun=INVALID batchSendAuthorized=NO";
        NSUInteger sleeps = 0, other = 0, invalid = 0;
        id selected = nil;
        for (id record in records) {
            NSString *identifier = nil;
            WFFocusWireKind kind = WFFocusClassifyWireRecord(record, &identifier, NULL);
            if (kind == WFFocusWireMalformed || kind == WFFocusWireLegacy) { ++invalid; continue; }
            if (kind == WFFocusWireMode && [identifier isEqualToString:kWFFocusSleepIdentifier]) {
                ++sleeps; selected = record;
            } else ++other;
        }
        if (sleeps != 1 || invalid)
            return [NSString stringWithFormat:@"sleepDryRun=REFUSED sleepCount=%lu other=%lu invalid=%lu batchSendAuthorized=NO",
                (unsigned long)sleeps, (unsigned long)other, (unsigned long)invalid];
        for (NSString *key in @[kWFFocusRecordData, kWFFocusRecordPartitionedData]) {
            id partition = WFFocusRecordValue(selected, key);
            if (![partition isKindOfClass:[NSData class]] || [partition length] > 1024 * 1024)
                return @"sleepDryRun=REFUSED partitionBound=NO batchSendAuthorized=NO";
        }
        NSError *error = nil;
        // Record-level calculation, not a fabricated deletion-free source batch.
        // The enclosing transaction's delete rejection is NOT consulted or reset.
        id candidate = WFFocusConvertSleepRecord(selected, &error);
        if (candidate) {
            candidate = nil;
            return @"sleepDryRun=PASS candidateDiscarded=YES batchSendAuthorized=NO";
        }
        return [NSString stringWithFormat:@"sleepDryRun=REFUSED code=%ld batchSendAuthorized=NO", (long)error.code];
    } @catch (NSException *exception) {
        (void)exception;
        return @"sleepDryRun=EXCEPTION batchSendAuthorized=NO";
    }
}

NSDictionary *WFFocusConvertAllModesMessage(NSDictionary *message, NSSet<NSString *> *expectedInstanceIDs,
                                           NSError **error) {
    if (![expectedInstanceIDs isKindOfClass:[NSSet class]] || expectedInstanceIDs.count == 0) {
        WFFocusSetError(error, 2101, @"Verified full phone inventory is required");
        return nil;
    }
    for (id identifier in expectedInstanceIDs) {
        if (![identifier isKindOfClass:[NSString class]] || [identifier length] == 0) {
            WFFocusSetError(error, 2101, @"Invalid full inventory identifier"); return nil;
        }
    }
    if (![message isKindOfClass:[NSDictionary class]] ||
        !WFFocusExactKeys(message, [NSSet setWithArray:@[@"action", @"modifiedRecords", @"deletedMetadata"]], error)) return nil;
    id action = message[@"action"];
    NSArray *records = message[@"modifiedRecords"];
    if (![action isKindOfClass:[NSString class]] ||
        (![action isEqualToString:@"update"] && ![action isEqualToString:@"replace"]) ||
        ![records isKindOfClass:[NSArray class]] ||
        ![message[@"deletedMetadata"] isKindOfClass:[NSArray class]] || [message[@"deletedMetadata"] count]) {
        WFFocusSetError(error, 2102, @"Full-mode input must be a deletion-free native snapshot"); return nil;
    }
    NSMutableSet *observed = [NSMutableSet set];
    // Validate completeness before invoking any adapter. Mode identifiers such
    // as canonical Sleep are not a substitute for per-instance identity.
    for (id record in records) {
        NSMutableDictionary *publicJSON = nil;
        if (!WFFocusReadPartitions(record, &publicJSON, NULL, error)) return nil;
        id mode = publicJSON[@"mode"];
        id identifier = [mode isKindOfClass:[NSDictionary class]] ? mode[@"identifier"] : nil;
        if (![identifier isKindOfClass:[NSString class]] || [identifier length] == 0 || [observed containsObject:identifier]) {
            WFFocusSetError(error, 2103, @"Missing or duplicate Focus instance identity"); return nil;
        }
        [observed addObject:identifier];
    }
    if (![observed isEqualToSet:expectedInstanceIDs]) {
        WFFocusSetError(error, 2104, @"Native batch does not cover the verified complete inventory"); return nil;
    }
    NSMutableArray *output = [NSMutableArray arrayWithCapacity:records.count];
    for (id record in records) {
        NSMutableDictionary *publicJSON = nil;
        if (!WFFocusReadPartitions(record, &publicJSON, NULL, error)) return nil;
        if (![publicJSON[@"mode"][@"modeIdentifier"] isEqual:kWFFocusSleepIdentifier]) {
            WFFocusSetError(error, 2105, @"Non-Sleep mode adapter is not yet verified; full task refused"); return nil;
        }
        id converted = WFFocusConvertSleepRecord(record, error);
        if (!converted) return nil;
        [output addObject:converted];
    }
    if (output.count != 1) {
        WFFocusSetError(error, 2106, @"Multi-record ACK transaction is not implemented; full task refused");
        return nil;
    }
    return @{@"action": @"update", @"modifiedRecords": output, @"deletedMetadata": @[]};
}

NSDictionary *WFFocusDownconvertIncomingMessage(NSDictionary *message, BOOL *changed, NSError **error) {
    if (changed) *changed = NO;
    if (![message isKindOfClass:[NSDictionary class]]) {
        WFFocusSetError(error, 3001, @"Missing incoming Focus message");
        return nil;
    }
    NSDictionary *envelope = message[@"h"];
    if (![envelope isKindOfClass:[NSDictionary class]]) {
        WFFocusSetError(error, 3002, @"Missing incoming Focus envelope");
        return nil;
    }
    if (![envelope[@"v"] isKindOfClass:[NSNumber class]] || ![envelope[@"v"] isEqualToNumber:@1] ||
        ![envelope[@"y"] isKindOfClass:[NSString class]] ||
        ![envelope[@"y"] isEqualToString:@"syncEngine"]) {
        return message;
    }
    NSNumber *version = envelope[@"r"];
    if (![version isKindOfClass:[NSNumber class]]) {
        WFFocusSetError(error, 3003, @"Missing incoming Focus protocol version");
        return nil;
    }
    // Native DNDSIDSSyncService separates header h from business body d.
    // Never fall back to action/ACK fields supplied in the header.
    NSDictionary *body = message[@"d"];
    if (![body isKindOfClass:[NSDictionary class]]) {
        WFFocusSetError(error, 3007, @"Missing incoming Focus body");
        return nil;
    }
    NSString *action = [body[@"action"] isKindOfClass:[NSString class]] ? body[@"action"] : nil;
    if ([action isEqualToString:@"resync"] || [action isEqualToString:@"unlock"]) {
        // Real control messages may produce a new native outgoing batch. All
        // policy batches still pass through the update-only converter.
    } else if ([action isEqualToString:@"ack"]) {
        if (![body[@"ackAction"] isKindOfClass:[NSString class]] ||
            ![body[@"ackAction"] isEqualToString:@"update"] ||
            ![body[@"metadataAck"] isKindOfClass:[NSArray class]] ||
            (body[@"syncDate"] && ![body[@"syncDate"] isKindOfClass:[NSNumber class]])) {
            WFFocusSetError(error, 3005, @"Only a real update ACK is supported");
            return nil;
        }
    } else {
        WFFocusSetError(error, 3006, @"Watch-originated policy actions are not imported");
        return nil;
    }
    if ([version isEqualToNumber:@10]) return message;
    if (![version isEqualToNumber:@11] && ![version isEqualToNumber:@12]) {
        WFFocusSetError(error, 3004, @"Unsupported incoming Focus protocol version");
        return nil;
    }
    NSMutableDictionary *convertedEnvelope = [envelope mutableCopy];
    convertedEnvelope[@"r"] = @10;
    NSMutableDictionary *convertedMessage = [message mutableCopy];
    convertedMessage[@"h"] = convertedEnvelope;
    if (changed) *changed = YES;
    return convertedMessage;
}

static NSString *WFFocusSafeKeys(NSDictionary *dictionary) {
    if (![dictionary isKindOfClass:[NSDictionary class]]) return @"<missing>";
    NSMutableArray *keys = [NSMutableArray array];
    for (id key in dictionary) {
        if (![key isKindOfClass:[NSString class]]) return @"<non-string-key>";
        [keys addObject:[@[@"mode", @"configuration", @"triggers", @"secureConfiguration", @"secureTriggers", @"impactsAvailability", @"dimsLockScreen", @"created", @"lastModified", @"automaticallyGenerated", @"hasSecureData", @"configurationType", @"suppressionType", @"minimumBreakthroughUrgency", @"hideApplicationBadges", @"senderConfiguration", @"allowedApplications", @"deniedApplications", @"platforms"] containsObject:key] ? key : @"<other-key>"];
    }
    [keys sortUsingSelector:@selector(compare:)];
    return [keys componentsJoinedByString:@","];
}

NSString *WFFocusRecordSchemaSummary(id record) {
    @try {
        NSError *error = nil;
        NSString *metadataModeIdentifier = nil;
        WFFocusWireKind kind = WFFocusClassifyWireRecord(record, &metadataModeIdentifier, &error);
        if (kind == WFFocusWireMalformed) return @"wire=YES metadata=INVALID";
        if (kind == WFFocusWireOtherZone) return @"wire=YES zone=OTHER payload=NOT-PARSED";
        if (kind == WFFocusWireMode && ![metadataModeIdentifier isEqualToString:kWFFocusSleepIdentifier])
            return @"wire=YES zone=MODE sleep=NO payload=NOT-PARSED";
        NSMutableDictionary *publicJSON = nil;
        NSMutableDictionary *secureJSON = nil;
        if (!WFFocusReadPartitions(record, &publicJSON, &secureJSON, &error)) {
            return [NSString stringWithFormat:@"class=%@ invalid=%ld",
                    record ? NSStringFromClass(object_getClass(record)) : @"nil", (long)error.code];
        }
        id mode = publicJSON[@"mode"];
        BOOL sleep = [mode isKindOfClass:[NSDictionary class]] &&
                      [mode[@"modeIdentifier"] isEqual:kWFFocusSleepIdentifier];
        if (metadataModeIdentifier && ![mode[@"modeIdentifier"] isEqual:metadataModeIdentifier])
            return @"wire=YES zone=MODE identity=CONFLICT";
        id configuration = publicJSON[@"configuration"];
        id secureConfiguration = secureJSON[@"secureConfiguration"];
        id apps = [secureConfiguration isKindOfClass:[NSDictionary class]] ? secureConfiguration[@"allowedApplications"] : nil;
        id platforms = [secureConfiguration isKindOfClass:[NSDictionary class]] ? secureConfiguration[@"platforms"] : nil;
        id publicTriggers = publicJSON[@"triggers"];
        id secureTriggers = secureJSON[@"secureTriggers"];
        BOOL publicWrapped = [publicTriggers isKindOfClass:[NSDictionary class]] &&
            [publicTriggers[@"triggers"] isKindOfClass:[NSArray class]];
        BOOL secureWrapped = [secureTriggers isKindOfClass:[NSDictionary class]] &&
            [secureTriggers[@"triggers"] isKindOfClass:[NSArray class]];
        return [NSString stringWithFormat:
                @"class=%@ sleep=%@ public={%@} secure={%@} configuration={%@} secureConfiguration={%@} allowedAppMap=%@ platformsMap=%@ triggerWrappers=%@/%@",
                record ? NSStringFromClass(object_getClass(record)) : @"nil", sleep ? @"YES" : @"NO",
                WFFocusSafeKeys(publicJSON), WFFocusSafeKeys(secureJSON),
                WFFocusSafeKeys(configuration), WFFocusSafeKeys(secureConfiguration),
                [apps isKindOfClass:[NSDictionary class]] ? @"YES" : @"NO",
                [platforms isKindOfClass:[NSDictionary class]] ? @"YES" : @"NO",
                publicWrapped ? @"YES" : @"NO", secureWrapped ? @"YES" : @"NO"];
    } @catch (NSException *exception) {
        return [NSString stringWithFormat:@"schema exception=%@", exception.name];
    }
}
