#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const WFFocusConverterErrorDomain;

// Convert only one native Sleep update. A native replace may be used as the
// source snapshot, but the returned message is always an update containing only
// Sleep. Deleted metadata and unsupported schemas fail closed.
FOUNDATION_EXPORT NSDictionary * _Nullable WFFocusConvertSleepMessage(NSDictionary *message, NSError **error);

// All-mode task gate: expected instance IDs must come from a separately verified
// full phone snapshot, never inferred from this (possibly incremental) batch.
// Every record must convert; no filtering, omissions, deletes or partial result.
// Non-Sleep adapters are not yet implemented and fail closed.
FOUNDATION_EXPORT NSDictionary * _Nullable WFFocusConvertAllModesMessage(
    NSDictionary *message, NSSet<NSString *> *expectedInstanceIDs, NSError **error);

// Convert a real Watch ACK/resync envelope to the phone's native v10 envelope.
// Other Focus policy messages from the Watch are rejected, not imported.
FOUNDATION_EXPORT NSDictionary * _Nullable WFFocusDownconvertIncomingMessage(NSDictionary *message, BOOL * _Nullable changed, NSError **error);

// Safe protocol-only summary for diagnostics. Never includes record IDs, peer
// IDs, names, contact/app identifiers, thread identifiers or raw JSON values.
FOUNDATION_EXPORT NSString *WFFocusRecordSchemaSummary(id record);

// Diagnostic classification only: never removes tombstones or authorizes a send.
FOUNDATION_EXPORT NSString *WFFocusDeletedMetadataSummary(id deletedMetadata);

// Pure diagnostic: converts only an identified Sleep record, discards output.
// Does not remove tombstones or validate/authorize the enclosing transaction.
FOUNDATION_EXPORT NSString *WFFocusSleepConversionPreflightSummary(id message);

// Offline planning only; NOT the behavior send gate. Explicitly reports source
// records omitted, never treats this projection as completion of native replace.
// Returns a plan containing candidateMessage and sendAuthorized=NO.
FOUNDATION_EXPORT NSDictionary * _Nullable WFFocusPlanIndependentSleepUpdate(NSDictionary *source, NSError **error);

NS_ASSUME_NONNULL_END
