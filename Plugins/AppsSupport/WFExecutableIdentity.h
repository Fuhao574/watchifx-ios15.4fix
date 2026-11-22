#ifndef WF_EXECUTABLE_IDENTITY_H
#define WF_EXECUTABLE_IDENTITY_H
#include <mach-o/loader.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

static const uint8_t WFAnalyzedAppConduitUUID[16] = {
    0x4a,0xc0,0xfd,0x74,0xf9,0xc8,0x32,0x04,
    0x95,0xe9,0x03,0x49,0x62,0x58,0x0d,0x34
};

// Works on either a mapped image header or a bounded offline image buffer.
// Return the observed UUID separately so a mismatch is diagnosable.
static int WFReadExecutableUUID(const void *bytes, size_t available, uint8_t uuid[16]) {
    if (!bytes || available < sizeof(struct mach_header_64)) return 0;
    const struct mach_header_64 *header = (const struct mach_header_64 *)bytes;
    if (header->magic != MH_MAGIC_64 || header->filetype != MH_EXECUTE ||
        header->sizeofcmds > available - sizeof(*header)) return 0;
    const uint8_t *p = (const uint8_t *)(header + 1);
    size_t remaining = header->sizeofcmds;
    for (uint32_t i = 0; i < header->ncmds; i++) {
        if (remaining < sizeof(struct load_command)) return 0;
        const struct load_command *cmd = (const struct load_command *)p;
        if (cmd->cmdsize < sizeof(*cmd) || cmd->cmdsize > remaining) return 0;
        if (cmd->cmd == LC_UUID) {
            if (cmd->cmdsize < sizeof(struct uuid_command)) return 0;
            memcpy(uuid, ((const struct uuid_command *)cmd)->uuid, 16);
            return 1;
        }
        p += cmd->cmdsize;
        remaining -= cmd->cmdsize;
    }
    return 0;
}
#endif
