#import "IOS154BoundaryIdentity.h"

WFHSLoadedMethodIdentity *WFHSCheckIOS154Boundary(WFHSIOS154Boundary boundary,Class actualClass) {
    NSString *name=nil,*selector=nil,*abi=nil;uint64_t offset=0;
    switch(boundary) {
        case WFHSIOS154EnumeratorInitialize:
            name=@"HDSleepDaySummaryEnumerator";
            selector=@"initWithProfile:calendarCache:morningIndexRange:ascending:requireSleepAnalysis:onlySleepAnalysis:debugIdentifier:";
            abi=@"@68@0:8@16@24{?=qq}32B48B52B56@60";offset=0x668980;break;
        case WFHSIOS154EnumeratorEnumerate:
            name=@"HDSleepDaySummaryEnumerator";selector=@"enumerateWithError:handler:";
            abi=@"B32@0:8^@16@?24";offset=0x6692f8;break;
        case WFHSIOS154DayInitialize:
            name=@"HDSleepDaySummaryBuilder";selector=@"initWithMorningIndex:weekday:calendarCache:";
            abi=@"@40@0:8q16Q24@32";offset=0x6b2074;break;
        case WFHSIOS154DayAddSample:
            name=@"HDSleepDaySummaryBuilder";selector=@"addOrderedSample:";
            abi=@"v24@0:8@16";offset=0x6b21b8;break;
        case WFHSIOS154DayCreate:
            name=@"HDSleepDaySummaryBuilder";selector=@"createDaySummary";
            abi=@"@16@0:8";offset=0x6b24f4;break;
        case WFHSIOS154PeriodFinish:
            name=@"HDSleepPeriodArrayBuilder";selector=@"finish";
            abi=@"@16@0:8";offset=0x6b1fa0;break;
        case WFHSIOS154StageInsert:
            name=@"HDDataManager";
            selector=@"insertDataObjects:withProvenance:creationDate:skipInsertionFilter:updateSourceOrder:resolveAssociations:error:";
            abi=@"B60@0:8@16@24d32B40B44B48^@52";offset=0x441ba8;break;
        default:return nil;
    }
    NSString *path=@"/System/Library/PrivateFrameworks/HealthDaemon.framework/HealthDaemon";
    NSString *uuid=@"5C7508EA-8D04-3313-BAD4-A5A30202A475";
    return [[WFHSLoadedMethodIdentity alloc]initWithClass:actualClass expectedClassName:name
        selector:NSSelectorFromString(selector) isClassMethod:NO expectedMethodOwner:actualClass
        expectedIMPOffset:@(offset) expectedABI:abi classImagePath:path classImageUUID:uuid
        methodImagePath:path methodImageUUID:uuid];
}
