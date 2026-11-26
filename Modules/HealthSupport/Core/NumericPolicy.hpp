// The audited rules depend on binary64 evaluation, finite checks and exact
// comparisons. Do not let a later build silently erase these contracts.
#ifndef WATCHFIX_HEALTH_SUPPORT_NUMERIC_POLICY_HPP
#define WATCHFIX_HEALTH_SUPPORT_NUMERIC_POLICY_HPP

#include <limits>

#if defined(__FAST_MATH__) || (defined(__FINITE_MATH_ONLY__) && __FINITE_MATH_ONLY__)
#error "HealthSupport requires finite-aware floating-point semantics; disable fast-math"
#endif

static_assert(std::numeric_limits<double>::is_iec559 &&
              std::numeric_limits<double>::digits == 53 &&
              std::numeric_limits<double>::max_exponent == 1024,
              "HealthSupport core requires IEEE754 binary64 double");

#endif
