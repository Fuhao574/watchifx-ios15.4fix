#ifndef WF_HELLO_IDENTITY_WIRELESS_LOG_H
#define WF_HELLO_IDENTITY_WIRELESS_LOG_H

#include "BoundedLog.h"
#include <cmath>
#include <cstdio>
#include <cstring>

namespace WFWirelessIdentity {

// Diagnostic file adapter only. No objects, identity values, payloads, request
// identifiers or device APIs belong here. The caller supplies existing private
// directories; BoundedLog owns exclusive creation, permissions and budgets.
class Writer final {
    WFSleepDiagnostic::BoundedLog log_;

    static const char *CanonicalEvent(const char *event) noexcept {
        if (!event) return nullptr;
        const size_t length = strnlen(event, MaxEventLength + 1);
        if (!length || length > MaxEventLength) return nullptr;
        for (size_t i = 0; i < length; ++i) {
            const unsigned char c = static_cast<unsigned char>(event[i]);
            if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-'))
                return nullptr;
        }
        // All WFLog first-argument literals in hello-identity-shadow's
        // Observer.mm and NeutralCopy.h, including BOTH ternary branches.
        // Also mirror the original direct identity-config log as numeric detail
        // bits (found=1, enabled=2); its four-call limit remains at the caller.
        static const char *const allowed[] = {
            "window-expired", "connect-enter", "connect-exit", "data-enter",
            "identity-failed", "neutral-failed", "data-exit", "host-matched",
            "retry-host-image", "disabled-host", "retry-classes",
            "disabled-contract", "disabled-route-symbol", "disabled-route-type",
            "disabled-neutral-contract", "disabled-clock", "install-failed-data",
            "installed-neutral", "install-failed-connect", "load-neutral2",
            "neutral-contract-failed", "neutral-bound", "neutral-fields-differ",
            "neutral-result", "identity-result", "load-identity-wireless1",
            "identity-config"
        };
        for (const char *label : allowed) {
            if (strcmp(event, label) == 0) return label;
        }
        return nullptr;
    }

public:
    static constexpr size_t MaxEventLength = 63;
    Writer() = default;
    Writer(const Writer &) = delete;
    Writer &operator=(const Writer &) = delete;

    // path is a directory, not a filename. No mkdir, retry, overwrite or fallback.
    bool Open(const char *path) noexcept {
        try {
            return log_.Open(path);
        } catch (...) {
            return false;
        }
    }

    bool Event(const char *event, unsigned int seq, unsigned int depth,
               unsigned int count, unsigned int route, unsigned int detail,
               bool returned, double uptime) noexcept {
        try {
            const char *label = CanonicalEvent(event);
            if (!label || route > 2 || !std::isfinite(uptime) || uptime < 0.0) return false;

            // Even DBL_MAX fits fixed-point in this buffer. Normalize negative zero;
            // reject non-ASCII/locale-dependent formatting rather than log free text.
            char time[384];
            const int timeLength = std::snprintf(time, sizeof(time), "%.6f", uptime == 0.0 ? 0.0 : uptime);
            if (timeLength <= 0 || static_cast<size_t>(timeLength) >= sizeof(time)) return false;
            for (int i = 0; i < timeLength; ++i) {
                if ((time[i] < '0' || time[i] > '9') && time[i] != '.') return false;
            }
            char line[WFSleepDiagnostic::BoundedLog::MaxLine];
            const int length = std::snprintf(line, sizeof(line),
                "[WFHelloIdentityWireless1] event=%s seq=%u depth=%u count=%u route=%u detail=%u returned=%u uptime=%s",
                label, seq, depth, count, route, detail, returned ? 1u : 0u, time);
            // Never allow BoundedLog's truncation to turn an event into partial data.
            if (length <= 0 || static_cast<size_t>(length) > sizeof(line) - 2) return false;
            return log_.Append(line);
        } catch (...) {
            return false;
        }
    }
};

} // namespace WFWirelessIdentity
#endif
