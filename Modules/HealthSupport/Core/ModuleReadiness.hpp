// No compatibility runtime loader is implemented. Independent LoadCheck only
// inspects loaded metadata, never installs hooks or enables this core. States
// report capability gaps, not
// authorization to install hooks or expand the accepted persistent value domain.
#ifndef WATCHFIX_HEALTH_SUPPORT_MODULE_READINESS_HPP
#define WATCHFIX_HEALTH_SUPPORT_MODULE_READINESS_HPP

#include <cstdint>

namespace watchfix { namespace healthsupport {

enum class MissingCapability : std::uint32_t {
    source_and_time_pipeline = 1u << 0,
    native_adapters = 1u << 1,
    live_identity = 1u << 2,
    query_error_coverage = 1u << 3,
    safe_disable_remove = 1u << 4,
    device_validation = 1u << 5
};

struct ModuleReadiness {
    static constexpr bool runtime_implemented = false;
    static constexpr bool installable = false;
    static constexpr bool enabled_by_default = false;
    static constexpr std::uint32_t missing_capabilities = (1u << 6) - 1;

    // No mutable preference, environment variable or caller-supplied booleans
    // can convert this core-only build into a runtime-enabled compatibility fix.
    static constexpr bool may_expand_sleep_acceptance() noexcept { return false; }
};

// The future runtime must preserve native behavior while this gate is closed.
// Core calculations can still be tested offline independently.
inline bool moduleAcceptanceDecision(bool native_decision, bool /*is_sleep*/,
                                     std::int64_t /*value*/) noexcept {
    return native_decision;
}

} }
#endif
