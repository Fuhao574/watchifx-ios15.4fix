#ifndef WF_HELLO_NEUTRAL_COPY_H
#define WF_HELLO_NEUTRAL_COPY_H

struct WFField {
    const char *name;
    const char *ivar;
    const char *type;
    const char *setter;
    uintptr_t getterOffset;
    uintptr_t setterOffset;
    SEL get;
    SEL set;
    IMP getter;
    IMP setterIMP;
};

#define WF_FIELD(n, t, s, i) {#n, "_" #n, t, s, 0x179524 + (i) * 0x64, 0x17954C + (i) * 0x64, NULL, NULL, NULL, NULL}
static WFField WFFields[12] = {
    WF_FIELD(controlChannelVersion, "@\"NSString\"", "setControlChannelVersion:", 0),
    WF_FIELD(productName, "@\"NSString\"", "setProductName:", 1),
    WF_FIELD(productVersion, "@\"NSString\"", "setProductVersion:", 2),
    WF_FIELD(productBuildVersion, "@\"NSString\"", "setProductBuildVersion:", 3),
    WF_FIELD(model, "@\"NSString\"", "setModel:", 4),
    WF_FIELD(pairingProtocolVersion, "@\"NSNumber\"", "setPairingProtocolVersion:", 5),
    WF_FIELD(minCompatibilityVersion, "@\"NSNumber\"", "setMinCompatibilityVersion:", 6),
    WF_FIELD(maxCompatibilityVersion, "@\"NSNumber\"", "setMaxCompatibilityVersion:", 7),
    WF_FIELD(capabilityFlags, "@\"NSNumber\"", "setCapabilityFlags:", 8),
    WF_FIELD(serviceMinCompatibilityVersion, "@\"NSNumber\"", "setServiceMinCompatibilityVersion:", 9),
    WF_FIELD(instanceID, "@\"NSUUID\"", "setInstanceID:", 10),
    WF_FIELD(deviceUniqueID, "@\"NSUUID\"", "setDeviceUniqueID:", 11)
};
#undef WF_FIELD
static IMP WFHelloInit;
struct WFBinding {
    IMP init;
    IMP getters[12];
    IMP setters[12];
    unsigned int compatibilitySetters;
};
#ifndef WF_OBSERVER_HOST_TEST
static const struct mach_header_64 *WFNativeHeader;
static const char *WFNativePath;
#else
// Test only: allowlists simulate native or exact known compatibility code.
// Never used by the compiled device target.
static bool (*WFTestAllowed)(Method, unsigned int, unsigned int);
#endif

static bool WFNeutralLayout() {
    if (!WFHelloClass || class_getSuperclass(WFHelloClass) != [NSObject class] ||
        class_getInstanceSize(WFHelloClass) != 104) return false;
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList(WFHelloClass, &count);
    bool valid = ivars && count == 12;
    for (unsigned int i = 0; valid && i < 12; i++) {
        valid = strcmp(ivar_getName(ivars[i]), WFFields[i].ivar) == 0 &&
                strcmp(ivar_getTypeEncoding(ivars[i]), WFFields[i].type) == 0 &&
                ivar_getOffset(ivars[i]) == (ptrdiff_t)(8 + i * 8);
    }
    free(ivars);
    return valid;
}

#ifndef WF_OBSERVER_HOST_TEST
// Compatibility exception ONLY for the existing, previously inspected clean1
// PairingCompatibility service-min setter. Never bypass this active hook chain.
static bool WFKnownPairingSetter(IMP imp) {
    Dl_info symbol = {};
    const void *address = ptrauth_strip((void *)imp, ptrauth_key_function_pointer);
    if (!dladdr(address, &symbol) || !symbol.dli_fname || !symbol.dli_fbase ||
        !WFBaseNameMatches(symbol.dli_fname, "WatchFix_PairingCompatibility.dylib")) return false;
    auto *h = (const struct mach_header_64 *)symbol.dli_fbase;
    if (h->magic != MH_MAGIC_64 || h->filetype != MH_DYLIB || h->sizeofcmds > 1024 * 1024 || h->ncmds > 4096)
        return false;
    const uint8_t expected[16] = {0x82,0x1E,0xD9,0xBB,0x1B,0x7F,0x34,0x10,0xBD,0x94,0x99,0xD8,0x6D,0xDA,0x6A,0xBA};
    const uint8_t *cursor = (const uint8_t *)(h + 1);
    size_t remaining = h->sizeofcmds;
    bool match = false;
    unsigned int uuids = 0;
    for (uint32_t i = 0; i < h->ncmds; i++) {
        if (remaining < sizeof(struct load_command)) return false;
        auto *cmd = (const struct load_command *)cursor;
        if (cmd->cmdsize < sizeof(*cmd) || cmd->cmdsize > remaining) return false;
        if (cmd->cmd == LC_UUID) {
            if (cmd->cmdsize != sizeof(struct uuid_command) || ++uuids != 1) return false;
            match = memcmp(((const struct uuid_command *)cmd)->uuid, expected, 16) == 0;
        }
        cursor += cmd->cmdsize;
        remaining -= cmd->cmdsize;
    }
    return remaining == 0 && match;
}

static IMP WFHelloDecodeIMP;

static bool WFDecodeABI(Method method) {
    if (!method || method_getNumberOfArguments(method) != 5) return false;
    char *type = method_copyReturnType(method);
    bool valid = type && strcmp(type, "@") == 0;
    free(type);
    const char *expected[] = {"@", ":", "r^v", "Q", "@"};
    for (unsigned int i = 0; valid && i < 5; i++) {
        type = method_copyArgumentType(method, i);
        valid = type && strcmp(type, expected[i]) == 0;
        free(type);
    }
    return valid;
}

static bool WFPrepareNeutralContract(const struct mach_header_64 *header, const char *path) {
    if (!WFNeutralLayout()) return false;
    Method decode = class_getInstanceMethod(WFHelloClass, sel_registerName("initWithBytes:length:loggingPrefixString:"));
    if (!WFDecodeABI(decode) || !WFOwned(WFHelloClass, decode, header, path, 0x176CF4)) return false;
    WFHelloDecodeIMP = method_getImplementation(decode);
    Method init = class_getInstanceMethod(WFHelloClass, sel_registerName("init"));
    if (!WFABI(init, "@", 2) || !WFOwned(WFHelloClass, init, header, path, 0x17607C)) return false;
    WFHelloInit = method_getImplementation(init);
    WFNativeHeader = header;
    WFNativePath = path;
    for (unsigned int i = 0; i < 12; i++) {
        auto &f = WFFields[i];
        f.get = sel_registerName(f.name);
        f.set = sel_registerName(f.setter);
        Method get = class_getInstanceMethod(WFHelloClass, f.get);
        Method set = class_getInstanceMethod(WFHelloClass, f.set);
        if (!WFABI(get, "@", 2) || !WFABI(set, "v", 3) ||
            !WFOwned(WFHelloClass, get, header, path, f.getterOffset)) return false;
        if (!WFOwned(WFHelloClass, set, header, path, f.setterOffset) &&
            !(i == 9 && WFKnownPairingSetter(method_getImplementation(set)))) return false;
        f.getter = method_getImplementation(get);
        f.setterIMP = method_getImplementation(set);
    }
    return true;
}
#endif

// kind: 0 init, 1 getter, 2 setter. Always validate fresh ABI and code owner;
// accepting a known late service-min hook is NOT accepting arbitrary changes.
static bool WFAllowed(Method method, unsigned int kind, unsigned int index) {
#ifdef WF_OBSERVER_HOST_TEST
    return WFTestAllowed && WFTestAllowed(method, kind, index);
#else
    if (!WFNativeHeader || !WFNativePath || !method) return false;
    uintptr_t offset = kind == 0 ? 0x17607C :
                       (kind == 1 ? WFFields[index].getterOffset : WFFields[index].setterOffset);
    if (WFOwned(WFHelloClass, method, WFNativeHeader, WFNativePath, offset)) return true;
    return kind == 2 && index == 9 && WFKnownPairingSetter(method_getImplementation(method));
#endif
}

// Full candidate assembled locally; no output assignment until every check
// passes. Do not refresh global IMPs piecemeal during a live callback.
static unsigned int WFBindCurrent(WFBinding *output) {
    if (!WFNeutralLayout()) return 100;
    Method init = class_getInstanceMethod(WFHelloClass, sel_registerName("init"));
    if (!WFABI(init, "@", 2)) return 110;
    if (!WFAllowed(init, 0, 0)) return 111;
    WFBinding candidate = {};
    candidate.init = method_getImplementation(init);
    for (unsigned int i = 0; i < 12; i++) {
        auto &f = WFFields[i];
        Method get = class_getInstanceMethod(WFHelloClass, f.get);
        Method set = class_getInstanceMethod(WFHelloClass, f.set);
        if (!WFABI(get, "@", 2)) return 200 + i;
        if (!WFAllowed(get, 1, i)) return 220 + i;
        if (!WFABI(set, "v", 3)) return 240 + i;
        if (!WFAllowed(set, 2, i)) return 260 + i;
        candidate.getters[i] = method_getImplementation(get);
        candidate.setters[i] = method_getImplementation(set);
        if (i == 9 && candidate.setters[i] != WFFields[i].setterIMP)
            candidate.compatibilitySetters = 1;
    }
    *output = candidate;
    return 0;
}

// Same runtime API and callable IMP type for both sides; no stripped-pointer
// calls or PAC workaround. Any change AFTER binding is rejected, not refreshed.
static unsigned int WFBindingStable(const WFBinding &binding) {
    if (!WFNeutralLayout()) return 300;
    Method init = class_getInstanceMethod(WFHelloClass, sel_registerName("init"));
    if (!init || method_getImplementation(init) != binding.init) return 310;
    for (unsigned int i = 0; i < 12; i++) {
        Method get = class_getInstanceMethod(WFHelloClass, WFFields[i].get);
        Method set = class_getInstanceMethod(WFHelloClass, WFFields[i].set);
        if (!get || method_getImplementation(get) != binding.getters[i]) return 320 + i;
        if (!set || method_getImplementation(set) != binding.setters[i]) return 340 + i;
    }
    return 0;
}

static NSArray *WFNeutralSnapshot(id source, const WFBinding &binding) {
    NSMutableArray *values = [NSMutableArray arrayWithCapacity:12];
    for (unsigned int i = 0; i < 12; i++) {
        auto &f = WFFields[i];
        id value = ((id (*)(id, SEL))binding.getters[i])(source, f.get);
        Class type = i < 5 ? [NSString class] : (i < 10 ? [NSNumber class] : [NSUUID class]);
        if (value && ![value isKindOfClass:type]) return nil;
        [values addObject:value ?: [NSNull null]];
    }
    return values;
}

static bool WFLogContractFailure(unsigned int reason, WFFrame *frame) {
    if (!reason) return false;
    WFLog("neutral-contract-failed", frame->sequence, frame->depth, 1, frame->route, reason, false);
    return true;
}

static void WFCompareNeutral(id source, id originalResult, WFFrame *frame) {
    // Catch INSIDE the pool so ARC temporaries drain even on probe exceptions.
    // Never emit contents/length/hash of either payload or any field.
    @autoreleasepool {
        unsigned int stage = 1;
        @try {
            WFBinding binding = {};
            if (WFLogContractFailure(WFBindCurrent(&binding), frame)) return;
            WFLog("neutral-bound", frame->sequence, frame->depth, 1, frame->route,
                  binding.compatibilitySetters, true);
            stage = 2;
            NSArray *before = WFNeutralSnapshot(source, binding);
            if (!before) {
                WFLog("neutral-failed", frame->sequence, frame->depth, 1, frame->route, stage, false);
                return;
            }
            stage = 3;
            if (WFLogContractFailure(WFBindingStable(binding), frame)) return;
            // ARC recognizes real alloc/init method families. Do not call init
            // via a falsely non-retained id-returning function pointer.
            id copy = [[WFHelloClass alloc] init];
            if (!copy || object_getClass(copy) != WFHelloClass) {
                WFLog("neutral-failed", frame->sequence, frame->depth, 1, frame->route, stage, false);
                return;
            }
            stage = 4;
            for (unsigned int i = 0; i < 12; i++) {
                auto &f = WFFields[i];
                id value = before[i] == [NSNull null] ? nil : before[i];
                // The SAME active setter chain is used, including clean1's
                // existing service-min compatibility hook. No bypass or override.
                if (WFLogContractFailure(WFBindingStable(binding), frame)) return;
                ((void (*)(id, SEL, id))binding.setters[i])(copy, f.set, value);
            }
            stage = 5;
            if (WFLogContractFailure(WFBindingStable(binding), frame)) return;
            NSArray *copied = WFNeutralSnapshot(copy, binding);
            if (!copied || ![before isEqualToArray:copied]) {
                WFLog("neutral-fields-differ", frame->sequence, frame->depth, 1, frame->route, stage, false);
                return;
            }
            stage = 6;
            if (WFLogContractFailure(WFBindingStable(binding), frame)) return;
            // The ONLY extra native encoding call, on a neutral temporary copy.
            id copyResult = ((id (*)(id, SEL))WFOriginalData)(copy, sel_registerName("data"));
            stage = 7;
            if (WFLogContractFailure(WFBindingStable(binding), frame)) return;
            NSArray *after = WFNeutralSnapshot(source, binding);
            bool stable = after && [before isEqualToArray:after];
            bool data = WFClassifyResult(copyResult) == WFResultData;
            bool equal = stable && data && [(NSData *)originalResult isEqualToData:(NSData *)copyResult];
            unsigned int flags = (stable ? 1u : 0u) | (data ? 2u : 0u) | (equal ? 4u : 0u);
            WFLog("neutral-result", frame->sequence, frame->depth, 1, frame->route, flags, true);
        } @catch (NSException *exception) {
            (void)exception;
            WFLog("neutral-failed", frame->sequence, frame->depth, 1, frame->route, stage, false);
        }
    }
}

static id WFIdentityFailure(unsigned int stage, WFFrame *frame) {
    WFLog("identity-failed", frame->sequence, frame->depth, 1, frame->route, stage, false);
    return nil;
}

static bool WFIdentityFieldsMatch(NSArray *values, NSArray *before) {
    if (!values || values.count != 12 || before.count != 12) return false;
    for (unsigned int i = 0; i < 12; i++) {
        id expected = i == 2 ? @"15.5" : (i == 3 ? @"19F77" : before[i]);
        id actual = values[i];
        if (actual != expected && ![actual isEqual:expected]) return false;
    }
    return true;
}

static id WFIdentityCandidate(id source, id originalResult, WFFrame *frame) {
    @autoreleasepool {
        unsigned int stage = 1;
        @try {
            if (WFClassifyResult(originalResult) != WFResultData) return WFIdentityFailure(stage, frame);
            WFBinding binding = {};
            unsigned int reason = WFBindCurrent(&binding);
            if (reason) return WFIdentityFailure(reason, frame);
            stage = 2;
            NSArray *before = WFNeutralSnapshot(source, binding);
            if (!before) return WFIdentityFailure(stage, frame);
            stage = 3;
            if (![before[2] isEqualToString:@"15.4"] || ![before[3] isEqualToString:@"19E241"])
                return WFIdentityFailure(stage, frame);
            if (WFBindingStable(binding)) return WFIdentityFailure(300, frame);
            stage = 4;
            id copy = [[WFHelloClass alloc] init];
            if (!copy || object_getClass(copy) != WFHelloClass) return WFIdentityFailure(stage, frame);
            for (unsigned int i = 0; i < 12; i++) {
                auto &f = WFFields[i];
                id value = before[i] == [NSNull null] ? nil : before[i];
                if (WFBindingStable(binding)) return WFIdentityFailure(400 + i, frame);
                ((void (*)(id, SEL, id))binding.setters[i])(copy, f.set, value);
            }
            stage = 5;
            if (WFBindingStable(binding)) return WFIdentityFailure(500, frame);
            ((void (*)(id, SEL, id))binding.setters[2])(copy, WFFields[2].set, @"15.5");
            ((void (*)(id, SEL, id))binding.setters[3])(copy, WFFields[3].set, @"19F77");
            stage = 6;
            NSArray *copied = WFNeutralSnapshot(copy, binding);
            if (!WFIdentityFieldsMatch(copied, before)) return WFIdentityFailure(stage, frame);
            if (WFBindingStable(binding)) return WFIdentityFailure(600, frame);
            stage = 7;
            id candidate = ((id (*)(id, SEL))WFOriginalData)(copy, sel_registerName("data"));
            if (WFClassifyResult(candidate) != WFResultData) return WFIdentityFailure(stage, frame);
            stage = 8;
#ifdef WF_OBSERVER_HOST_TEST
            extern id (*WFTestIdentityDecode)(id, NSArray *);
            id decoded = WFTestIdentityDecode ? WFTestIdentityDecode(candidate, before) : nil;
#else
            SEL decodeSelector = sel_registerName("initWithBytes:length:loggingPrefixString:");
            Method decodeMethod = class_getInstanceMethod(WFHelloClass, decodeSelector);
            if (!WFDecodeABI(decodeMethod) ||
                !WFOwned(WFHelloClass, decodeMethod, WFNativeHeader, WFNativePath, 0x176CF4) ||
                method_getImplementation(decodeMethod) != WFHelloDecodeIMP)
                return WFIdentityFailure(stage, frame);
            id decoded = [[WFHelloClass alloc] initWithBytes:[(NSData *)candidate bytes]
                                                      length:[(NSData *)candidate length]
                                        loggingPrefixString:@"WFIdentityShadow"];
#endif
            stage = 9;
            if (!decoded || object_getClass(decoded) != WFHelloClass) return WFIdentityFailure(stage, frame);
            NSArray *decodedFields = WFNeutralSnapshot(decoded, binding);
            if (!WFIdentityFieldsMatch(decodedFields, before)) return WFIdentityFailure(stage, frame);
            stage = 10;
            if (WFBindingStable(binding)) return WFIdentityFailure(1000, frame);
            NSArray *after = WFNeutralSnapshot(source, binding);
            if (!after || ![before isEqualToArray:after]) return WFIdentityFailure(stage, frame);
            WFLog("identity-result", frame->sequence, frame->depth, 1, frame->route, 15, true);
            return candidate;
        } @catch (NSException *exception) {
            (void)exception;
            return WFIdentityFailure(stage, frame);
        }
    }
}
#endif
