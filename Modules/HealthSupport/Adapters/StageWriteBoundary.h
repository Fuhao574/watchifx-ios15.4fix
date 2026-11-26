#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

// Exact15.4 -[HDDataManager
// insertDataObjects:withProvenance:creationDate:skipInsertionFilter:
// updateSourceOrder:resolveAssociations:error:] ABI. Original is caller supplied
// after independent exact-image/owner/IMP audit; this function installs NO hook.
typedef BOOL (^WFHSOriginalStageInsert)(id manager, NSArray *objects, id provenance, double creationDate,
    BOOL skipInsertionFilter, BOOL updateSourceOrder, BOOL resolveAssociations, NSError * _Nullable __autoreleasing * _Nullable error);

// Invocation lives INSIDE the separately verified receive lease: allowNewStages
// is not a preference snapshot sufficient for concurrency-safe stop. Caller must
// persist the read-compatibility dependency BEFORE granting that lease, keep it
// through original completion and account for every in-flight original call.
// Read/decode acceptance stays separate. No HealthKit validation policy changes.
// No sample filtering, mutation, journal/anchor writes, synthetic ACK or
// impersonated HealthKit error. Refusals use this adapter's own NSError domain.
// Unknown adapter context refuses this call explicitly; caller may not call a
// dangerous original as a fallback and claim receiving is disabled.
FOUNDATION_EXPORT BOOL WFHSInsertWithStageWriteBoundary(id manager, Class auditedManagerClass,
    NSArray *objects, id provenance, double creationDate, BOOL skipInsertionFilter,
    BOOL updateSourceOrder, BOOL resolveAssociations, NSError * _Nullable __autoreleasing * _Nullable error,
    Class auditedCategorySampleClass, Class auditedCategoryTypeClass, BOOL allowNewStages,
    NSUInteger maximumObjects, WFHSOriginalStageInsert original);

NS_ASSUME_NONNULL_END
