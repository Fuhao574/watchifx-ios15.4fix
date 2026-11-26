#include "SleepSampleAdapter.hpp"
#import "RuntimeTypeChecks.h"
#include <cmath>
#include <cstring>
#include <new>
#include <stdexcept>

@protocol WFHSSleepSample
- (NSInteger)value;
- (id)sampleType;
- (NSDate *)startDate;
- (NSDate *)endDate;
- (id)sourceRevision;
@end
@protocol WFHSSleepType
- (NSInteger)code;
@end
@protocol WFHSSleepRevision
- (id)source;
@end
@protocol WFHSSleepSource
- (NSNumber *)_sourceID;
@end

namespace watchfix { namespace healthsupport {
namespace {
bool existingABI(Class cls, SEL selector, const char *encoding) {
    Class seen[64]; unsigned depth=0;
    while (cls && depth<64) {
        for (unsigned i=0;i<depth;++i) if (seen[i]==cls) return false;
        seen[depth++]=cls;
        unsigned count=0;Method *methods=class_copyMethodList(cls,&count);
        unsigned matches=0;bool valid=false;
        for(unsigned i=0;i<count;++i) if(sel_isEqual(method_getName(methods[i]),selector)) {
            ++matches;const char *actual=method_getTypeEncoding(methods[i]);
            valid=actual&&!std::strcmp(actual,encoding);
        }
        free(methods);
        if(matches)return matches==1&&valid;
        cls=class_getSuperclass(cls);
    }
    return false;
}
}

SleepStagePresenceAttempt inspectSleepStagePresence(NSArray *samples, Class sample_class,
    Class category_type_class, std::size_t maximum_samples) {
    SleepStagePresenceAttempt result;
    if (!sample_class || !category_type_class || !maximum_samples) return result;
    @try {
        if (!existingABI(sample_class,@selector(value),"q16@0:8") ||
            !existingABI(sample_class,@selector(sampleType),"@16@0:8") ||
            !existingABI(category_type_class,@selector(code),"q16@0:8")) return result;
        if (!WFHSActuallyInheritsFrom(samples,NSArray.class) || samples.count>maximum_samples) {
            result.status=SleepSampleStatus::resource_limit;return result;
        }
        bool stages=false;
        for (id sample in samples) {
            if (object_getClass(sample)!=sample_class) {result.status=SleepSampleStatus::invalid_sample;return result;}
            id type=[(id<WFHSSleepSample>)sample sampleType];
            if (object_getClass(type)!=category_type_class || [(id<WFHSSleepType>)type code]!=63) {
                result.status=SleepSampleStatus::invalid_sample;return result;
            }
            NSInteger value=[(id<WFHSSleepSample>)sample value];
            if (value<0 || value>5) {result.status=SleepSampleStatus::invalid_sample;return result;}
            stages=stages || value>=3;
        }
        result.has_stages=stages;result.status=SleepSampleStatus::complete;
    } @catch (NSException *candidateException) {
        (void)candidateException;result.status=SleepSampleStatus::candidate_exception;
    }
    return result;
}

SleepSampleAttempt readSleepSampleSnapshot(NSArray *samples, Class sample_class,
    Class category_type_class, Class source_revision_class, Class source_class, std::size_t maximum_samples) {
    SleepSampleAttempt result;
    if(!maximum_samples) {result.status=SleepSampleStatus::invalid_configuration;return result;}
    if(!sample_class||!category_type_class||!source_revision_class||!source_class)return result;
    try {
        @try {
            if(!existingABI(sample_class,@selector(value),"q16@0:8")||
               !existingABI(sample_class,@selector(sampleType),"@16@0:8")||
               !existingABI(sample_class,@selector(startDate),"@16@0:8")||
               !existingABI(sample_class,@selector(endDate),"@16@0:8")||
               !existingABI(sample_class,@selector(sourceRevision),"@16@0:8")||
               !existingABI(category_type_class,@selector(code),"q16@0:8")||
               !existingABI(source_revision_class,@selector(source),"@16@0:8")||
               !existingABI(source_class,@selector(_sourceID),"@16@0:8"))return result;
            if(!WFHSActuallyInheritsFrom(samples,NSArray.class)||samples.count>maximum_samples) {
                result.status=SleepSampleStatus::resource_limit;return result;
            }
            std::vector<StageFragment> converted;
            NSMutableArray *inBed=[NSMutableArray array];
            if(!inBed){result.status=SleepSampleStatus::allocation_failure;return result;}
            bool has_previous=false;double previous_start=0;
            for(id sample in samples) {
                if(object_getClass(sample)!=sample_class){result.status=SleepSampleStatus::invalid_sample;return result;}
                id type=[(id<WFHSSleepSample>)sample sampleType];
                if(object_getClass(type)!=category_type_class||[(id<WFHSSleepType>)type code]!=63) {
                    result.status=SleepSampleStatus::invalid_sample;return result;
                }
                const NSInteger value=[(id<WFHSSleepSample>)sample value];
                id start=[(id<WFHSSleepSample>)sample startDate],end=[(id<WFHSSleepSample>)sample endDate];
                if(value<0||value>5||!WFHSActuallyInheritsFrom(start,NSDate.class)||!WFHSActuallyInheritsFrom(end,NSDate.class)) {
                    result.status=SleepSampleStatus::invalid_sample;return result;
                }
                const double s=[start timeIntervalSinceReferenceDate],e=[end timeIntervalSinceReferenceDate];
                if(!std::isfinite(s)||!std::isfinite(e)||e<=s||!std::isfinite(e-s)) {
                    result.status=SleepSampleStatus::invalid_sample;return result;
                }
                if(has_previous&&s<previous_start){result.status=SleepSampleStatus::unordered_samples;return result;}
                has_previous=true;previous_start=s;
                if(value==0){[inBed addObject:sample];continue;}
                id revision=[(id<WFHSSleepSample>)sample sourceRevision];
                if(object_getClass(revision)!=source_revision_class){result.status=SleepSampleStatus::invalid_sample;return result;}
                id source=[(id<WFHSSleepRevision>)revision source];
                if(object_getClass(source)!=source_class){result.status=SleepSampleStatus::invalid_sample;return result;}
                id number=[(id<WFHSSleepSource>)source _sourceID];
                if(!WFHSActuallyInheritsFrom(number,NSNumber.class)) {result.status=SleepSampleStatus::invalid_sample;return result;}
                const char *encoding=[number objCType];
                if(!encoding||!encoding[0]||encoding[1]||!std::strchr("csilqCSILQ",encoding[0])||
                   (std::strchr("CSILQ",encoding[0])&&[number unsignedLongLongValue]>INT64_MAX)) {
                    result.status=SleepSampleStatus::invalid_sample;return result;
                }
                converted.push_back({value,s,e,[number longLongValue]});
            }
            NSArray *retained=[[NSArray alloc]initWithArray:inBed];
            if(!retained||retained.count!=inBed.count){result.status=SleepSampleStatus::allocation_failure;return result;}
            result.non_in_bed=std::move(converted);result.original_in_bed=retained;
            result.status=SleepSampleStatus::complete;
        } @catch(NSException *candidateException) {
            (void)candidateException;result.non_in_bed.clear();result.original_in_bed=nil;
            result.status=SleepSampleStatus::candidate_exception;
        }
    } catch(const std::bad_alloc &) {result.status=SleepSampleStatus::allocation_failure;}
    catch(const std::length_error &) {result.status=SleepSampleStatus::allocation_failure;}
    return result;
}
} }
