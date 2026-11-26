#include "SleepSourceConsumptionContext.hpp"
#include "SleepBucketAdvance.hpp"
#include "ModuleReadiness.hpp"
#include <cassert>
#include <cstdio>
using namespace watchfix::healthsupport;

int main() {
    bool present = true;
    std::size_t calls = 0;
    SleepSourceConsumptionContext context;
    auto consumption = context.callbacks([&] { return present; }, [&](std::int64_t) {
        ++calls; return SourceBundleLookup{BundleLookupKind::nonnull_bundle, "same.bundle"};
    });
    // Merely observing source8's bundle must NOT select8 as key representative.
    auto bundle8 = consumption.bundle(8);
    assert(bundle8.resolved && bundle8.nonnull && calls == 1);
    assert(context.mapping().nonnull_bundle_groups() == 0);
    auto key9 = consumption.key(9);
    assert(key9.resolved && key9.key == 9 && calls == 2);
    auto key8 = consumption.key(8);
    assert(key8.resolved && key8.key == 9 && calls == 2); // nonnil cache reused
    present = false;
    assert(consumption.key(8).key == 8 && calls == 2);
    assert(!consumption.bundle(8).nonnull && calls == 2);
    present = true;
    assert(consumption.key(8).key == 9 && calls == 2); // provider loss didn't destroy cache
    // Same call: outer sourceKey provider exists, inner bundle helper sees nil.
    // Must ignore old nonnil cache for this observation, without deleting it.
    std::size_t presence_reads = 0;
    auto nested_loss = context.callbacks([&] { return ++presence_reads == 1; },
        [](std::int64_t) -> SourceBundleLookup { assert(false); return {}; });
    assert(nested_loss.key(8).key == 8 && presence_reads == 2);
    assert(consumption.key(8).key == 9 && calls == 2);
    SleepSourceConsumptionContext getter_loss;
    presence_reads = 0;
    auto missing_getter = getter_loss.callbacks([&] { return ++presence_reads < 3; },
        [](std::int64_t) -> SourceBundleLookup { assert(false); return {}; });
    assert(missing_getter.key(11).key == 11 && presence_reads == 3);
    assert(getter_loss.mapping().cached_sources() == 0);

    SleepSourceConsumptionContext changes;
    bool nonnull = false;
    calls = 0;
    auto dynamic = changes.callbacks([] { return true; }, [&](std::int64_t) {
        ++calls; return SourceBundleLookup{nonnull ? BundleLookupKind::nonnull_bundle : BundleLookupKind::nil_bundle,
                                          nonnull ? "new.bundle" : ""};
    });
    assert(dynamic.key(8).key == 8 && dynamic.key(9).key == 8 && calls == 2);
    assert(!dynamic.bundle(9).nonnull && calls == 3); // nil isn't cached
    nonnull = true;
    assert(dynamic.key(9).key == 9 && calls == 4);
    assert(dynamic.key(8).key == 9 && calls == 5);
    assert(dynamic.bundle(8).nonnull && calls == 5);

    // Run actual multi->single dispatch using a private dynamic mapping context.
    SleepSourceConsumptionContext staged;
    std::size_t lookup_calls = 0;
    auto stagedCallbacks = staged.callbacks([] { return true; }, [&](std::int64_t) {
        ++lookup_calls; return SourceBundleLookup{BundleLookupKind::nonnull_bundle, "fixture.bundle"};
    });
    SleepBucketState bucket; bucket.interval_end = 120;
    bucket.pending = {
        {{{3,0,45,8},false,false,false},false,0,false,0},
        {{{4,15,90,9},false,false,false},false,0,false,0}
    };
    BucketAdvanceConfiguration config; config.mask_is_empty = true;
    auto result = advanceSleepBucket(bucket,120,config,PendingOrderState::native_equivalent_source_then_start_order,
        SourceKeyState::canonicalized_in_one_mapping_session,
        [](const std::vector<MappedPendingStage> &) { return std::vector<std::size_t>{0,1}; }, &stagedCallbacks);
    assert(result.complete() && result.data()->state.ledger.size() == 1 && result.data()->state.ledger.find(8));
    assert(lookup_calls == 2 && bucket.ledger.size() == 0);
    // Context copy is the rollback boundary; discard on any later operation failure.
    SleepSourceConsumptionContext failed_stage = staged;
    auto failing = failed_stage.callbacks([] { return true; }, [](std::int64_t) -> SourceBundleLookup { return {}; });
    assert(!failing.key(10).resolved);
    assert(staged.mapping().cached_sources() == 2);
    SleepSourceConsumptionContext byte_limit(10,1,2);
    auto limited = byte_limit.callbacks([] { return true; }, [](std::int64_t) {
        return SourceBundleLookup{BundleLookupKind::nonnull_bundle,"too-long"};
    });
    assert(!limited.key(1).resolved && !limited.bundle(1).resolved);
    assert(!ModuleReadiness::may_expand_sleep_acceptance());
    std::puts("PASS native consumption-point bundle cache/key representative/nil relookup/provider change/no frozen admission key");
}
