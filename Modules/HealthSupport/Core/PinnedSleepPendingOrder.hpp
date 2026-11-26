// Native16 ordering-shape adapter, using an externally supplied SDK algorithm.
// NO copied Apple sorting implementation. The build driver must verify the
// audited sort.h SHA256 before defining the opt-in macro. Not a runtime gate.
#ifndef WATCHFIX_HEALTH_SUPPORT_PINNED_SLEEP_PENDING_ORDER_HPP
#define WATCHFIX_HEALTH_SUPPORT_PINNED_SLEEP_PENDING_ORDER_HPP

#include "SleepMultiSourceAdvance.hpp"
#include <__algorithm/sort.h>
#include <cstddef>
#include <limits>
#include <map>
#include <new>
#include <numeric>
#include <stdexcept>
#include <type_traits>
#include <utility>
#include <vector>

#if !defined(WATCHFIX_HEALTHSUPPORT_AUDITED_SORT_HEADER) || WATCHFIX_HEALTHSUPPORT_AUDITED_SORT_HEADER != 1
#error "HealthSupport pending order requires explicit audited SDK sort header verification"
#endif
#if !defined(_LIBCPP_VERSION) || _LIBCPP_VERSION != 15006
#error "HealthSupport pending order requires the audited libc++15006 algorithm"
#endif
#ifdef _LIBCPP_DEBUG_RANDOMIZE_UNSPECIFIED_STABILITY
#error "HealthSupport cannot randomize equivalent pending order"
#endif

namespace watchfix { namespace healthsupport {

enum class PendingSortStatus { complete, input_limit, invalid_start, allocation_failure };
class PendingSortResult;
PendingSortResult orderSleepPending(const std::vector<MappedPendingStage> &, bool,
                                    const std::vector<std::int64_t> &, std::size_t);
class PendingSortResult {
public:
    PendingSortStatus status() const noexcept { return status_; }
    bool complete() const noexcept { return status_ == PendingSortStatus::complete; }
    const std::vector<std::size_t> *permutation() const noexcept { return complete() ? &indices_ : nullptr; }
private:
    PendingSortStatus status_ = PendingSortStatus::input_limit;
    std::vector<std::size_t> indices_;
    friend PendingSortResult orderSleepPending(const std::vector<MappedPendingStage> &, bool,
                                               const std::vector<std::int64_t> &, std::size_t);
};

namespace detail {
template<class Compare>
inline void auditedPendingSort(std::vector<std::size_t> &indices, Compare compare) {
    static_assert(std::is_trivially_copy_constructible<std::size_t>::value &&
                  std::is_trivially_copy_assignable<std::size_t>::value,
                  "Audited branchy insertion threshold requires trivial index type");
    static_assert(!std::__use_branchless_sort<Compare &, std::size_t *>::value,
                  "Audited pending ordering requires the branchy comparator path");
    // Custom comparator disables libc++'s arithmetic branchless special case.
    // N depth cannot be exhausted along a strictly shrinking partition path
    // while >30 elements remain; this leaves the audited non-heap skeleton.
    if (indices.empty()) return;
    std::__introsort<std::_ClassicAlgPolicy, Compare &>(indices.data(), indices.data() + indices.size(),
        compare, static_cast<std::ptrdiff_t>(indices.size()));
}
struct PendingSourceRankLess {
    const std::vector<std::size_t> &ranks;
    bool operator()(std::size_t a, std::size_t b) const noexcept { return ranks[a] < ranks[b]; }
};
struct PendingStartLess {
    const std::vector<MappedPendingStage> &items;
    bool operator()(std::size_t a, std::size_t b) const noexcept {
        return items[a].pending.fragment.start < items[b].pending.fragment.start;
    }
};
}

// Ordered source IDs must be obtained afresh at each native-equivalent ranking
// refresh. Duplicate IDs use FIRST index; missing IDs rank after all listed IDs.
// Source sort then start-only sort are separate NONSTABLE operations. No index,
// category, end or numeric source ID tie-break is invented.
inline PendingSortResult orderSleepPending(const std::vector<MappedPendingStage> &items,
                                            bool provider_present,
                                            const std::vector<std::int64_t> &ordered_source_ids,
                                            std::size_t maximum_items = 100000) {
    PendingSortResult result;
    if (!maximum_items || items.size() > maximum_items || ordered_source_ids.size() > maximum_items ||
        items.size() > static_cast<std::size_t>(std::numeric_limits<std::ptrdiff_t>::max())) return result;
    for (const auto &item : items) if (!std::isfinite(item.pending.fragment.start)) {
        result.status_ = PendingSortStatus::invalid_start; return result;
    }
    try {
        std::vector<std::size_t> indices(items.size());
        std::iota(indices.begin(), indices.end(), std::size_t(0));
        if (provider_present) {
            std::map<std::int64_t, std::size_t> first_rank;
            for (std::size_t i = 0; i < ordered_source_ids.size(); ++i)
                first_rank.emplace(ordered_source_ids[i], i);
            std::vector<std::size_t> ranks; ranks.reserve(items.size());
            for (const auto &item : items) {
                const auto found = first_rank.find(item.pending.fragment.source_id);
                ranks.push_back(found == first_rank.end() ? ordered_source_ids.size() : found->second);
            }
            detail::auditedPendingSort(indices, detail::PendingSourceRankLess{ranks});
        }
        detail::auditedPendingSort(indices, detail::PendingStartLess{items});
        result.indices_ = std::move(indices);
        result.status_ = PendingSortStatus::complete;
    } catch (const std::bad_alloc &) { result.status_ = PendingSortStatus::allocation_failure; }
    catch (const std::length_error &) { result.status_ = PendingSortStatus::allocation_failure; }
    return result;
}

} }
#endif
