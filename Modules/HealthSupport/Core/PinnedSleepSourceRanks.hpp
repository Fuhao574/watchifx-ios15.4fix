// Rebuild audited insert-only unique-source traversal using external SDK libc++.
// Do not reserve, copy a live set, erase or persist this temporary container.
#ifndef WFHS_PINNED_SLEEP_SOURCE_RANKS_HPP
#define WFHS_PINNED_SLEEP_SOURCE_RANKS_HPP
#include "SleepBucketAdmission.hpp"
#include "PinnedSleepPendingOrder.hpp"
#include <unordered_set>
#include <memory>
#if !defined(WATCHFIX_HEALTHSUPPORT_AUDITED_HASH_HEADERS) || WATCHFIX_HEALTHSUPPORT_AUDITED_HASH_HEADERS != 1
#error "HealthSupport source ranks require explicit audited hash header verification"
#endif
#if !defined(_LIBCPP_VERSION) || _LIBCPP_VERSION != 15006
#error "HealthSupport source ranks require audited libc++15006"
#endif

namespace watchfix { namespace healthsupport {
using SourceRankProvider = std::function<std::vector<std::int64_t>(const std::vector<std::int64_t> &)>;
namespace detail {
struct SourcePreferenceLess {
    const std::map<std::int64_t,std::size_t> &rank;
    std::size_t operatorRank(std::int64_t source) const {
        const auto found=rank.find(source);
        return found==rank.end()?std::numeric_limits<std::size_t>::max():found->second;
    }
    bool operator()(std::int64_t a,std::int64_t b) const {return operatorRank(a)<operatorRank(b);}
};
}

class PinnedSleepSourceRanks {
public:
    const std::vector<std::int64_t> &refresh(const std::vector<std::int64_t> &history,
        bool provider_present, const SourceRankProvider &provider, std::size_t maximum_sources) {
        if (!maximum_sources || history.size() > maximum_sources) throw std::length_error("source rank limit");
        // Only additions allowed in a bucket; validate history prefix without
        // disturbing the cached rank order produced by the earlier provider.
        if (history.size() < history_.size() || !std::equal(history_.begin(), history_.end(), history.begin()))
            throw std::invalid_argument("source history is not append-only");
        if (history.size() == ranks_.size()) return ranks_;
        std::unordered_set<std::int64_t> sources;
        for (const auto source : history) if (!sources.insert(source).second)
            throw std::invalid_argument("duplicate source registration");
        std::vector<std::int64_t> ranks(sources.begin(), sources.end());
        if (provider_present) {
            if (!provider) throw std::invalid_argument("source provider missing");
            auto ordered = provider(ranks);
            if (ordered.size() > ranks.size()) throw std::invalid_argument("source rank size");
            // Membership verification must not alter the reconstructed set's
            // traversal before it is delivered to the provider above.
            for (auto source : ordered) if (sources.erase(source) != 1)
                throw std::invalid_argument("source rank membership");
            // Provider may return a subset or empty preference. Native retains
            // the WHOLE original vector, nonstably sorted by indexOfObject.
            // Missing IDs tie at NSNotFound; no stable append or numeric tie-break.
            std::map<std::int64_t,std::size_t> preference;
            for(std::size_t i=0;i<ordered.size();++i)preference.emplace(ordered[i],i);
            detail::SourcePreferenceLess compare{preference};
            static_assert(std::is_trivially_copy_constructible<std::int64_t>::value &&
                          std::is_trivially_copy_assignable<std::int64_t>::value,"Source ID sort threshold30");
            static_assert(!std::__use_branchless_sort<detail::SourcePreferenceLess &,std::int64_t *>::value,
                          "Native source preference sort is branchy");
            if(!ranks.empty())std::__introsort<std::_ClassicAlgPolicy,detail::SourcePreferenceLess &>(
                ranks.data(),ranks.data()+ranks.size(),compare,static_cast<std::ptrdiff_t>(ranks.size()));
        }
        auto remembered = history;
        history_ = std::move(remembered); ranks_ = std::move(ranks);
        return ranks_;
    }
private:
    std::vector<std::int64_t> history_, ranks_;
};
} }
#endif
