#include "PinnedSleepSourceRanks.hpp"
#include <cassert>
#include <cstdio>
#include <limits>
using namespace watchfix::healthsupport;
int main() {
    PinnedSleepSourceRanks ranks;
    std::size_t calls=0;
    std::vector<std::int64_t> seen;
    SourceRankProvider reverse=[&](const std::vector<std::int64_t> &input) {
        ++calls;seen=input;return std::vector<std::int64_t>(input.rbegin(),input.rend());
    };
    std::vector<std::int64_t> history;
    // Include collisions, negative hashes and rehash growth. Reference replays
    // external SDK directly; parity isn't an independent native oracle.
    for(std::int64_t source:std::vector<std::int64_t>{0,2,4,-1,8,16,32,64,128,256,512,1024}) {
        history.push_back(source);
        std::unordered_set<std::int64_t> reference;
        for(auto value:history)reference.insert(value);
        const std::vector<std::int64_t> expected(reference.begin(),reference.end());
        auto refreshed=ranks.refresh(history,true,reverse,100);
        assert(seen==expected);
        assert(refreshed==std::vector<std::int64_t>(expected.rbegin(),expected.rend()));
        const auto before=calls;
        assert(ranks.refresh(history,true,{},100)==refreshed&&calls==before); // no provider call at same size
        SourceRankProvider changed=[&](const std::vector<std::int64_t> &input) { ++calls;return input; };
        assert(ranks.refresh(history,true,changed,100)==refreshed&&calls==before);
    }
    assert(std::hash<std::int64_t>{}(-1)==static_cast<std::size_t>(-1));
    PinnedSleepSourceRanks absent;
    const auto initially=absent.refresh({8,9},false,{},10);
    const auto before=calls;
    assert(absent.refresh({8,9},true,reverse,10)==initially&&calls==before); // appearing provider no refresh
    absent.refresh({8,9,10},true,reverse,10);assert(calls==before+1);
    auto original=ranks;
    bool failed=false;
    try {ranks.refresh({1},true,reverse,100);}catch(const std::invalid_argument &){failed=true;}
    assert(failed);
    assert(ranks.refresh(history,true,{},100)==original.refresh(history,true,{},100));
    PinnedSleepSourceRanks invalid;
    failed=false;try {invalid.refresh({8,8},false,{},10);}catch(const std::invalid_argument &){failed=true;}
    assert(failed);
    failed=false;try {invalid.refresh({8,9},true,[](const std::vector<std::int64_t> &){return std::vector<std::int64_t>{8,8};},10);}
    catch(const std::invalid_argument &){failed=true;}assert(failed);
    assert(invalid.refresh({8,9},false,{},10).size()==2); // failed provider didn't commit cache
    PinnedSleepSourceRanks fresh;
    fresh.refresh(history,true,reverse,100);assert(calls>before+1); // fresh bucket refreshes
    for(std::size_t count:std::vector<std::size_t>{2,30,31,1001}) {
        std::vector<std::int64_t> many;for(std::size_t i=0;i<count;++i)many.push_back(i*64);
        for(bool empty: {false,true}) {
            PinnedSleepSourceRanks partial;
            std::vector<std::int64_t> preference=empty?std::vector<std::int64_t>{}:std::vector<std::int64_t>{64};
            const auto &all=partial.refresh(many,true,[&](const std::vector<std::int64_t> &){return preference;},2000);
            assert(all.size()==count);
            std::unordered_set<std::int64_t> reconstructed;
            for(auto source:many)reconstructed.insert(source);
            std::vector<std::int64_t> expected(reconstructed.begin(),reconstructed.end());
            auto compare=[&](std::int64_t a,std::int64_t b) {
                return std::find(preference.begin(),preference.end(),a)-preference.begin()<
                       std::find(preference.begin(),preference.end(),b)-preference.begin();
            };
            std::__introsort<std::_ClassicAlgPolicy,decltype(compare)&>(expected.data(),expected.data()+expected.size(),
                compare,static_cast<std::ptrdiff_t>(expected.size()));
            assert(all==expected);
            if(!empty)assert(all.front()==64);
            auto sorted=all;std::sort(sorted.begin(),sorted.end());assert(sorted==many);
        }
    }
    puts("PASS pinned source set traversal/insert replay/rank refresh only on registration growth/failure no commit");
}
