#ifndef WFHS_LEASED_STAGE_INSERT_HPP
#define WFHS_LEASED_STAGE_INSERT_HPP
#include "ReceiveGate.hpp"
#import "StageWriteBoundary.h"

namespace watchfix { namespace healthsupport {
// No hook installation. Runtime must pass the SAME owner gate to every covered
// insertion route and verify immutable input/exact original. Lease spans the
// full synchronous original call, not merely value checks. It does not cover
// asynchronous DB work without an independently proven native completion chain.
BOOL insertWithReceiveLease(const std::shared_ptr<ReceiveGate> &gate,
    id manager, Class manager_class, NSArray *objects, id provenance, double creation_date,
    BOOL skip_filter, BOOL update_source_order, BOOL resolve_associations, NSError * __autoreleasing *error,
    Class category_sample_class, Class category_type_class, NSUInteger maximum_objects,
    WFHSOriginalStageInsert original);
} }
#endif
