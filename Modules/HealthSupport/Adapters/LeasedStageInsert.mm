#include "LeasedStageInsert.hpp"
namespace watchfix { namespace healthsupport {
BOOL insertWithReceiveLease(const std::shared_ptr<ReceiveGate> &gate,
    id manager,Class manager_class,NSArray *objects,id provenance,double creation_date,
    BOOL skip_filter,BOOL update_source_order,BOOL resolve_associations,NSError * __autoreleasing *error,
    Class category_sample_class,Class category_type_class,NSUInteger maximum_objects,
    WFHSOriginalStageInsert original) {
    if(!gate) {
        if(error)*error=[NSError errorWithDomain:@"WatchFix.HealthSupport.ReceiveGate" code:1 userInfo:nil];
        return NO;
    }
    // RAII must survive candidate checks AND original. Original exceptions keep
    // their semantics, and both ObjC/C++ unwind release the lease in this TU.
    auto lease=gate->acquire();
    return WFHSInsertWithStageWriteBoundary(manager,manager_class,objects,provenance,creation_date,
        skip_filter,update_source_order,resolve_associations,error,category_sample_class,category_type_class,
        lease.allowed(),maximum_objects,original);
}
} }
