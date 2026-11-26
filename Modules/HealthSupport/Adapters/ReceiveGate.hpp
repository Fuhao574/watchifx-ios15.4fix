// Actual local metadata persistence and in-flight leases, NOT runtime readiness.
// Caller supplies an already-open, owned0700 metadata directory. No path lookup
// to Health data, device access, hook installation or read-policy disable exists.
// Metadata namespace continuity/ACL security are caller responsibilities. No
// rename/unlink/replacement/rollback is permitted while owned. This cannot detect
// replacement of the WHOLE directory with a fresh namespace. Single cooperative
// owner, not cross-process stop IPC. Fork is unsupported while a gate/lease lives;
// child must not use OR destruct inherited state before controlled exec/_exit.
#ifndef WFHS_RECEIVE_GATE_HPP
#define WFHS_RECEIVE_GATE_HPP
#include <chrono>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <cstddef>
#include <sys/types.h>

namespace watchfix { namespace healthsupport {
enum class ReceiveGateStatus {
    complete, invalid_directory, unavailable, invalid_metadata, persistence_failed,
    disabled, wrong_process, draining, resource_limit
};
class ReceiveLease;
struct ReceiveGateState;

class ReceiveGate {
public:
    // Fresh initialization is explicit and exclusively creates the journal; it
    // must NEVER be used to recover missing/corrupt existing installation state.
    // Existing open never resumes persisted enablement: restart is disabled.
    static std::shared_ptr<ReceiveGate> initializeFresh(int directory_fd, ReceiveGateStatus &status);
    static std::shared_ptr<ReceiveGate> openExisting(int directory_fd, ReceiveGateStatus &status);
    // Actual runtime readiness is separately required BEFORE calling enable.
    // Success is a local receive permission, not permission to install hooks.
    ReceiveGateStatus enable();
    ReceiveLease acquire();
    // Closes memory gate immediately, durably appends stop, then waits at most
    // timeout for leases (which may include native callbacks) to finish. Never
    // call while holding this thread's own lease; zero timeout is nonblocking.
    ReceiveGateStatus stop(std::chrono::milliseconds timeout);
    bool enabled() const;
    std::size_t inFlight() const;
    // Own-history evidence only, NOT proof the Health DB contains no stages.
    // False forever after the first enable attempt created dependency marker,
    // even if no native sample was ultimately inserted. Unknown also false.
    bool ownHistoryHasNoReadDependency() const;
private:
    explicit ReceiveGate(std::shared_ptr<ReceiveGateState> state) : state_(std::move(state)) {}
    static std::shared_ptr<ReceiveGate> open(int, bool, ReceiveGateStatus &);
    std::shared_ptr<ReceiveGateState> state_;
};

class ReceiveLease {
public:
    ReceiveLease() = default;
    ReceiveLease(const ReceiveLease &) = delete;
    ReceiveLease &operator=(const ReceiveLease &) = delete;
    ReceiveLease(ReceiveLease &&other) noexcept : state_(std::move(other.state_)) {}
    ReceiveLease &operator=(ReceiveLease &&other) noexcept;
    ~ReceiveLease();
    bool allowed() const noexcept;
private:
    explicit ReceiveLease(std::shared_ptr<ReceiveGateState> state) : state_(std::move(state)) {}
    void release() noexcept;
    std::shared_ptr<ReceiveGateState> state_;
    friend class ReceiveGate;
};
} }
#endif
