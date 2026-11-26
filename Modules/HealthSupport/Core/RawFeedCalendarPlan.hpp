// Native fresh ordered-feed calendar routing. Only raw carry determines finish
// rollover; pending48 bookkeeping is deliberately not used for this plan.
#ifndef WFHS_RAW_FEED_CALENDAR_PLAN_HPP
#define WFHS_RAW_FEED_CALENDAR_PLAN_HPP
#include "SleepRawAdmission.hpp"
#include <functional>
#include <vector>
#include <new>
#include <stdexcept>
#include <limits>

namespace watchfix { namespace healthsupport {
struct IndexedCalendarBucket {
    bool resolved = false;
    std::int64_t index = 0;
    CalendarBucketBounds bounds{0,0};
};
using CalendarContaining = std::function<IndexedCalendarBucket(double)>;
using CalendarAtIndex = std::function<IndexedCalendarBucket(std::int64_t)>;
enum class RawFeedPlanStatus { complete, invalid_input, invalid_calendar, resource_limit, split_failed, allocation_failure, adapter_failure };
class RawFeedCalendarPlan {
public:
    RawFeedPlanStatus status() const noexcept {return status_;}
    const std::vector<IndexedCalendarBucket> *buckets() const noexcept {
        return status_==RawFeedPlanStatus::complete?&buckets_:nullptr;
    }
    static RawFeedCalendarPlan calculate(const std::vector<StageFragment> &samples,
        const CalendarContaining &containing,const CalendarAtIndex &at,
        std::size_t maximum_samples,std::size_t maximum_buckets,std::size_t maximum_carry) {
        RawFeedCalendarPlan result;
        if(!maximum_samples||!maximum_buckets||!maximum_carry||!containing||!at)return result;
        if(samples.size()>maximum_samples){result.status_=RawFeedPlanStatus::resource_limit;return result;}
        for(std::size_t i=0;i<samples.size();++i) {
            const auto &raw=samples[i];
            if(raw.category<1||raw.category>5||!std::isfinite(raw.start)||!std::isfinite(raw.end)||raw.end<=raw.start||
               !std::isfinite(raw.end-raw.start)||(i&&raw.start<samples[i-1].start))return result;
        }
        try {
            std::vector<IndexedCalendarBucket> buckets;
            std::vector<StageFragment> carry;
            auto valid=[](const IndexedCalendarBucket &bucket) {
                return bucket.resolved&&std::isfinite(bucket.bounds.start)&&std::isfinite(bucket.bounds.end)&&
                    bucket.bounds.end>bucket.bounds.start&&std::isfinite(bucket.bounds.end-bucket.bounds.start);
            };
            auto admit=[&](const StageFragment &raw,const IndexedCalendarBucket &bucket,std::vector<StageFragment> &tail) {
                auto planned=planRawStageAdmission(raw,bucket.bounds,false,SplitOrder::numeric_one);
                if(!planned.complete()){result.status_=RawFeedPlanStatus::split_failed;return false;}
                if(planned.data()->has_carry) {
                    if(tail.size()>=maximum_carry){result.status_=RawFeedPlanStatus::resource_limit;return false;}
                    tail.push_back(planned.data()->carry);
                }
                return true;
            };
            auto move=[&](double target,bool drain) {
                if(buckets.size()>=maximum_buckets) {result.status_=RawFeedPlanStatus::resource_limit;return false;}
                const auto previous=buckets.back();
                IndexedCalendarBucket next;
                if(!carry.empty()) {
                    if(previous.index==std::numeric_limits<std::int64_t>::max()) {
                        result.status_=RawFeedPlanStatus::invalid_calendar;return false;
                    }
                    next=at(previous.index+1);
                    if(!valid(next)||next.index!=previous.index+1||next.bounds.start!=previous.bounds.end) {
                        result.status_=RawFeedPlanStatus::invalid_calendar;return false;
                    }
                } else {
                    if(drain)return false; // finish never manufactures next empty bucket
                    next=containing(target);
                    if(!valid(next)||next.index<=previous.index||next.bounds.start<previous.bounds.end||
                       target<next.bounds.start||target>=next.bounds.end) {
                        result.status_=RawFeedPlanStatus::invalid_calendar;return false;
                    }
                }
                std::vector<StageFragment> nextCarry;
                for(const auto &raw:carry)if(!admit(raw,next,nextCarry)) {
                    return false;
                }
                buckets.push_back(next);carry=std::move(nextCarry);return true;
            };
            for(const auto &raw:samples) {
                if(buckets.empty()) {
                    const auto first=containing(raw.start);
                    if(!valid(first)||raw.start<first.bounds.start||raw.start>=first.bounds.end) {
                        result.status_=RawFeedPlanStatus::invalid_calendar;return result;
                    }
                    buckets.push_back(first);
                }
                while(raw.start>=buckets.back().bounds.end)if(!move(raw.start,false))return result;
                if(!admit(raw,buckets.back(),carry))return result;
            }
            while(!carry.empty())if(!move(0,true))return result;
            result.buckets_=std::move(buckets);result.status_=RawFeedPlanStatus::complete;
        } catch(const std::bad_alloc &) {result.status_=RawFeedPlanStatus::allocation_failure;}
        catch(const std::length_error &) {result.status_=RawFeedPlanStatus::allocation_failure;}
        catch(...) {result.status_=RawFeedPlanStatus::adapter_failure;}
        return result;
    }
private:
    RawFeedPlanStatus status_=RawFeedPlanStatus::invalid_input;
    std::vector<IndexedCalendarBucket> buckets_;
};
} }
#endif
