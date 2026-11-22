#ifndef WF_HELLO_EXECUTABLE_GATE_H
#define WF_HELLO_EXECUTABLE_GATE_H
#include <mach-o/loader.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

static const uint8_t WFExpectedUUID[16] = {
    0x1A,0x72,0x00,0x5E,0x04,0xC1,0x31,0x99,
    0x8C,0x01,0x6A,0x54,0x45,0x4F,0x54,0xF8
};

// Return reason codes rather than a single undifferentiated host failure.
// 0=valid; 1=header/arch/type; 2=bounds/commands; 3=UUID absent;
// 4=UUID mismatch; 5=duplicate UUID command.
static unsigned int WFValidateExecutable(const void *bytes, size_t available) {
    if (!bytes || available < sizeof(struct mach_header_64)) return 1;
    const struct mach_header_64 *h = (const struct mach_header_64 *)bytes;
    if (h->magic != MH_MAGIC_64 || h->filetype != MH_EXECUTE ||
        h->cputype != 0x0100000C || ((uint32_t)h->cpusubtype & 0x00FFFFFF) != 2) return 1;
    if (h->sizeofcmds > 1024 * 1024 || h->ncmds > 4096 ||
        h->sizeofcmds > available - sizeof(*h)) return 2;
    const uint8_t *cursor = (const uint8_t *)(h + 1);
    size_t remaining = h->sizeofcmds;
    unsigned int uuids = 0;
    bool matched = false;
    for (uint32_t i = 0; i < h->ncmds; i++) {
        if (remaining < sizeof(struct load_command)) return 2;
        const struct load_command *cmd = (const struct load_command *)cursor;
        if (cmd->cmdsize < sizeof(*cmd) || cmd->cmdsize > remaining || cmd->cmdsize % 4) return 2;
        if (cmd->cmd == LC_UUID) {
            if (cmd->cmdsize != sizeof(struct uuid_command)) return 2;
            if (++uuids > 1) return 5;
            matched = memcmp(((const struct uuid_command *)cmd)->uuid, WFExpectedUUID, 16) == 0;
        }
        cursor += cmd->cmdsize;
        remaining -= cmd->cmdsize;
    }
    if (remaining != 0) return 2;
    if (!uuids) return 3;
    return matched ? 0 : 4;
}

static bool WFBaseNameMatches(const char *path, const char *expected) {
    if (!path || !expected) return false;
    const char *slash = strrchr(path, '/');
    return strcmp(slash ? slash + 1 : path, expected) == 0;
}
#endif
