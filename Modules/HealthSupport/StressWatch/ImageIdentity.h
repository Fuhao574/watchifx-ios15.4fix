#ifndef WFHS_STRESS_IMAGE_IDENTITY_H
#define WFHS_STRESS_IMAGE_IDENTITY_H
#include <mach-o/loader.h>
#include <mach/machine.h>
#include <stdbool.h>
#include <string.h>

// Loader-provided mapped headers only, not arbitrary pointer scanning.
static inline bool WFHeaderMatches(const struct mach_header_64 *h,
                                  const uint8_t uuid[16]) {
    if (!h || h->magic != MH_MAGIC_64 || h->cputype != CPU_TYPE_ARM64 ||
        h->filetype != MH_EXECUTE || h->sizeofcmds > 1024 * 1024 ||
        h->ncmds > h->sizeofcmds / sizeof(struct load_command)) return false;
    const uint8_t *p = (const uint8_t *)(h + 1);
    size_t remaining = h->sizeofcmds;
    unsigned uuidCount = 0, textCount = 0;
    bool uuidOK = false, textOK = false;
    for (uint32_t i = 0; i < h->ncmds; ++i) {
        if (remaining < sizeof(struct load_command)) return false;
        const struct load_command *lc = (const struct load_command *)p;
        if (lc->cmdsize < sizeof(*lc) || lc->cmdsize > remaining || lc->cmdsize % 8) return false;
        if (lc->cmd == LC_UUID) {
            if (lc->cmdsize != sizeof(struct uuid_command)) return false;
            ++uuidCount;
            uuidOK = memcmp(((const struct uuid_command *)p)->uuid, uuid, 16) == 0;
        }
        if (lc->cmd == LC_SEGMENT_64) {
            if (lc->cmdsize < sizeof(struct segment_command_64)) return false;
            const struct segment_command_64 *s = (const struct segment_command_64 *)p;
            if (strncmp(s->segname, "__TEXT", 16) == 0) {
                ++textCount;
                textOK = s->vmaddr == 0x100000000ULL && s->fileoff == 0 &&
                    s->vmsize == 24477696 && s->filesize == 24477696 &&
                    (s->initprot & 5) == 5;
            }
        }
        p += lc->cmdsize;
        remaining -= lc->cmdsize;
    }
    return remaining == 0 && uuidCount == 1 && textCount == 1 && uuidOK && textOK;
}
#endif
