#include "SleepSourceIdentityMap.hpp"
#include "SleepSourceLedger.hpp"
#include "ModuleReadiness.hpp"
#include <cassert>
#include <cstdio>

using namespace watchfix::healthsupport;
static SourceBundleLookup bundle(const char *name) { return {BundleLookupKind::nonnull_bundle, name}; }
static SourceBundleLookup nil_bundle() { return {BundleLookupKind::nil_bundle, {}}; }
int main() {
    SleepSourceIdentityMap empty;
    SourceBundleLookup unknown;
    auto absent = resolveSourceIdentity(empty, 0, false, unknown);
    assert(absent.complete() && absent.data()->ledger_key == 0 && !absent.data()->has_bundle_group);
    assert(!absent.data()->mapping.needs_bundle_lookup(0, false));
    auto unobserved = resolveSourceIdentity(empty, 8, true, unknown);
    assert(unobserved.status() == SourceIdentityStatus::lookup_required && !unobserved.data());
    auto first = resolveSourceIdentity(empty, 8, true, bundle("same.bundle"));
    assert(first.complete() && first.data()->ledger_key == 8 && first.data()->has_bundle_group);
    auto second = resolveSourceIdentity(first.data()->mapping, 2, true, bundle("same.bundle"));
    assert(second.complete() && second.data()->ledger_key == 8 && second.data()->bundle_group == 8);
    assert(second.data()->mapping.cached_sources() == 2 && second.data()->mapping.nonnull_bundle_groups() == 1);
    // Nonnil bundle is cached, even if a later supplied lookup claims a change.
    auto cached = resolveSourceIdentity(second.data()->mapping, 8, true, bundle("changed.bundle"));
    assert(cached.complete() && cached.data()->ledger_key == 8 && cached.data()->mapping.nonnull_bundle_groups() == 1);
    assert(!cached.data()->mapping.needs_bundle_lookup(8, true));
    // Provider loss bypasses canonicalization rather than freezing prior key8.
    auto lost = resolveSourceIdentity(cached.data()->mapping, 2, false, unknown);
    assert(lost.complete() && lost.data()->ledger_key == 2 && !lost.data()->has_bundle_group);
    auto returned = resolveSourceIdentity(lost.data()->mapping, 2, true, unknown);
    assert(returned.complete() && returned.data()->ledger_key == 8);
    // Nil is never cached by raw source. Repeated nil shares the first nil key,
    // but a later nonnil lookup can change key without migrating old reducers.
    auto nil_first = resolveSourceIdentity(empty, -1, true, nil_bundle());
    assert(nil_first.complete() && nil_first.data()->ledger_key == -1 && !nil_first.data()->has_bundle_group);
    assert(nil_first.data()->mapping.cached_sources() == 0 && nil_first.data()->mapping.needs_bundle_lookup(-1, true));
    auto nil_second = resolveSourceIdentity(nil_first.data()->mapping, 4, true, nil_bundle());
    assert(nil_second.complete() && nil_second.data()->ledger_key == -1);
    auto other_bundle = resolveSourceIdentity(nil_second.data()->mapping, 9, true, bundle("new.bundle"));
    auto changed = resolveSourceIdentity(other_bundle.data()->mapping, 4, true, bundle("new.bundle"));
    assert(changed.complete() && changed.data()->ledger_key == 9 && changed.data()->has_bundle_group);
    assert(changed.data()->mapping.cached_sources() == 2 && empty.cached_sources() == 0);
    // Empty string is a real bundle group, distinct from nil.
    auto empty_string = resolveSourceIdentity(nil_second.data()->mapping, 0, true, bundle(""));
    assert(empty_string.complete() && empty_string.data()->has_bundle_group && empty_string.data()->ledger_key == 0);
    auto empty_string_again = resolveSourceIdentity(empty_string.data()->mapping, 7, true, bundle(""));
    assert(empty_string_again.complete() && empty_string_again.data()->ledger_key == 0);
    auto capacity = resolveSourceIdentity(first.data()->mapping, 2, true, bundle("other"), 1, 10);
    assert(capacity.status() == SourceIdentityStatus::cache_limit && !capacity.data());
    auto group_capacity = resolveSourceIdentity(first.data()->mapping, 2, true, bundle("other"), 10, 1);
    assert(group_capacity.status() == SourceIdentityStatus::cache_limit && !group_capacity.data());
    assert(first.data()->mapping.cached_sources() == 1);
    assert(!resolveSourceIdentity(empty, 1, false, unknown, 0, 1).data());
    SourceBundleLookup invalid_lookup{static_cast<BundleLookupKind>(99), {}};
    assert(resolveSourceIdentity(empty, 8, true, invalid_lookup).status() == SourceIdentityStatus::invalid_lookup_state);
    assert(resolveSourceIdentity(first.data()->mapping, 8, true, invalid_lookup).complete());
    assert(resolveSourceIdentity(empty, 8, false, invalid_lookup).complete());
    assert(resolveSourceIdentity(first.data()->mapping, 8, true, unknown, 1, 1).complete());
    auto same_group_at_limit = resolveSourceIdentity(first.data()->mapping, 2, true, bundle("same.bundle"), 2, 1);
    assert(same_group_at_limit.complete() && same_group_at_limit.data()->ledger_key == 8);
    auto retry = resolveSourceIdentity(first.data()->mapping, 2, true, bundle("same.bundle"), 10, 1);
    assert(retry.complete() && retry.data()->ledger_key == 8); // failed other-group lookup wasn't cached
    assert(resolveSourceIdentity(second.data()->mapping, 8, false, unknown, 1, 1).status() == SourceIdentityStatus::cache_limit);
    assert(resolveSourceIdentity(second.data()->mapping, 8, true, unknown, 1, 1).status() == SourceIdentityStatus::cache_limit);
    auto nil_after_regroup = resolveSourceIdentity(changed.data()->mapping, 90, true, nil_bundle());
    assert(nil_after_regroup.complete() && nil_after_regroup.data()->ledger_key == -1);
    // Lookup regrouping selects a different ledger; it does NOT rewrite/merge
    // previously accumulated time from key-1 into key9.
    SourceLedger ledger;
    auto old = accumulateSourceLedger(ledger, {{{3, 0, 10, 4}, -1, true}}, SourceKeyState::canonicalized_in_one_mapping_session);
    assert(old.complete());
    auto new_key = accumulateSourceLedger(old.data()->ledger, {{{4, 10, 20, 4}, changed.data()->ledger_key, false}},
                                          SourceKeyState::canonicalized_in_one_mapping_session);
    assert(new_key.complete() && new_key.data()->ledger.size() == 2);
    assert(new_key.data()->ledger.find(-1)->decision().category == 3 && new_key.data()->ledger.find(9)->decision().category == 4);
    assert(!ModuleReadiness::may_expand_sleep_acceptance());
    std::puts("PASS bucket source mapping/nil relookup/provider loss/nonempty cache/no raw-key freeze");
}
