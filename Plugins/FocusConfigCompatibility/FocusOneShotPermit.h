#ifndef WF_FOCUS_ONE_SHOT_PERMIT_H
#define WF_FOCUS_ONE_SHOT_PERMIT_H

// Offline-tested persistence primitive, NOT wired to device configuration.
// The caller supplies an already-issued private experiment directory and exact
// process-session/peer/artifact identities. This code NEVER issues or resets one.
#include <array>
#include <cstdint>
#include <cstring>
#include <cerrno>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace WFFocusPermit {
using Grant = std::array<uint8_t, 112>;
struct Context {
    std::array<uint8_t, 16> processSession;
    std::array<uint8_t, 32> peerDigest;
    std::array<uint8_t, 32> artifactDigest;
    uint64_t nowSeconds;
};
enum class Result { Allowed, UnsafeDirectory, InvalidGrant, ContextMismatch, Expired,
                    AlreadySpent, PersistenceFailure, Revoked };

inline bool PrivateObject(const struct stat &st, bool directory) {
    return st.st_uid == geteuid() && (st.st_mode & 07777) == (directory ? 0700 : 0600) &&
        (directory ? S_ISDIR(st.st_mode) : (S_ISREG(st.st_mode) && st.st_nlink == 1));
}

inline int OpenExperimentAt(int trustedParent, const char *experimentName) {
    // Never resolve an absolute/multi-component path here. The eventual issuer
    // must establish a trusted, pinned parent FD, not merely canonicalize text.
    if (!experimentName || !*experimentName || strlen(experimentName) > 80) return -1;
    for (const unsigned char *p = (const unsigned char *)experimentName; *p; ++p)
        if (!((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z') ||
              (*p >= '0' && *p <= '9') || *p == '-' || *p == '_')) return -1;
    struct stat parentStat;
    if (fstat(trustedParent, &parentStat) != 0 || !PrivateObject(parentStat, true)) return -1;
    int directory = openat(trustedParent, experimentName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (directory < 0) return -1;
    struct stat st;
    if (fstat(directory, &st) != 0 || !PrivateObject(st, true)) {
        close(directory); return -1;
    }
    return directory;
}

struct PosixReceiptIO {
    static ssize_t Write(int fd, const void *data, size_t size) { return write(fd, data, size); }
    static int Sync(int fd) { return fsync(fd); }
    static int Close(int fd) { return close(fd); }
};

// IO injection is a compile-time host-test policy, not runtime device config.
template<class IO = PosixReceiptIO>
inline Result CommitReceipt(int directory, const void *data, size_t size) {
    int receipt = openat(directory, "spent", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (receipt < 0) return errno == EEXIST ? Result::AlreadySpent : Result::PersistenceFailure;
    struct stat st;
    bool durable = fstat(receipt, &st) == 0 && PrivateObject(st, false) &&
        IO::Write(receipt, data, size) == static_cast<ssize_t>(size) && IO::Sync(receipt) == 0;
    if (IO::Close(receipt) != 0) durable = false;
    if (IO::Sync(directory) != 0) durable = false;
    // On ANY post-create failure, keep spent, including a partial receipt.
    return durable ? Result::Allowed : Result::PersistenceFailure;
}

template<class IO = PosixReceiptIO>
inline Result ConsumeAt(int trustedParent, const char *experimentName, const Context &context) {
    int directory = OpenExperimentAt(trustedParent, experimentName);
    if (directory < 0) return Result::UnsafeDirectory;
    struct stat st;
    int input = openat(directory, "grant", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    if (input < 0) { close(directory); return Result::InvalidGrant; }
    Grant grant{};
    bool valid = fstat(input, &st) == 0 && PrivateObject(st, false) && st.st_size == grant.size();
    ssize_t length = valid ? pread(input, grant.data(), grant.size(), 0) : -1;
    close(input);
    static const uint8_t magic[8] = {'W','F','P','E','R','M','0','1'};
    if (!valid || length != grant.size() || memcmp(grant.data(), magic, 8) != 0) {
        close(directory); return Result::InvalidGrant;
    }
    bool nonzeroToken = false;
    for (size_t i = 88; i < 104; ++i) nonzeroToken |= grant[i] != 0;
    if (!nonzeroToken || memcmp(grant.data()+8, context.processSession.data(), 16) ||
        memcmp(grant.data()+24, context.peerDigest.data(), 32) ||
        memcmp(grant.data()+56, context.artifactDigest.data(), 32)) {
        close(directory); return Result::ContextMismatch;
    }
    uint64_t deadline = 0;
    for (size_t i = 104; i < 112; ++i) deadline = (deadline << 8) | grant[i];
    if (deadline <= context.nowSeconds || deadline - context.nowSeconds > 300) {
        close(directory); return Result::Expired;
    }
    // Fixed receipt name for the WHOLE directory, not token-derived. Replacing
    // the grant or changing its token must never replenish an existing receipt.
    Result result = CommitReceipt<IO>(directory, grant.data(), grant.size());
    close(directory);
    return result;
}

inline Result RevokeAt(int trustedParent, const char *experimentName) {
    int directory = OpenExperimentAt(trustedParent, experimentName);
    if (directory < 0) return Result::UnsafeDirectory;
    static const uint8_t cancelled[8] = {'W','F','R','E','V','O','K','E'};
    // Same O_EXCL spent slot arbitrates consume vs revoke. Revoked means the
    // revoker won and synced; AlreadySpent does NOT mean a prior send was undone.
    Result result = CommitReceipt(directory, cancelled, sizeof(cancelled));
    close(directory);
    return result == Result::Allowed ? Result::Revoked : result;
}
} // namespace WFFocusPermit
#endif
