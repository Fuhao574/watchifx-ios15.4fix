#ifndef WF_FOCUS_PROCESS_SESSION_H
#define WF_FOCUS_PROCESS_SESSION_H
#include <array>
#include <cstdint>
#include <cstdlib>
#include <unistd.h>

namespace WFFocusPermit {
// Local process capability identity, not a device-side grant issuer. No PID-only
// matching and no disk/env restoration. A fresh exec receives a fresh nonce;
// an inherited instance fails closed in a fork child rather than rearming.
class ProcessSession final {
    const pid_t creator_;
    std::array<uint8_t, 16> nonce_{};
public:
    ProcessSession() : creator_(getpid()) { arc4random_buf(nonce_.data(), nonce_.size()); }
    ProcessSession(const ProcessSession &) = delete;
    ProcessSession &operator=(const ProcessSession &) = delete;
    bool Snapshot(std::array<uint8_t,16> &output) const {
        output.fill(0);
        if (getpid() != creator_) return false;
        bool nonzero = false;
        for (uint8_t byte : nonce_) nonzero |= byte != 0;
        if (!nonzero) return false;
        output = nonce_;
        return true;
    }
};
} // namespace WFFocusPermit
#endif
