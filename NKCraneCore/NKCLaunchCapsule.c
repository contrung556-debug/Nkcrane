#include "NKCLaunchCapsule.h"
#include <stdint.h>
#include <string.h>

static NKCLaunchCapsule NKCResult(NKCCapsuleStatus status) {
    NKCLaunchCapsule value = {0};
    value.status = status;
    return value;
}

static int NKCIsHex(char ch) {
    return (ch >= '0' && ch <= '9') ||
           (ch >= 'a' && ch <= 'f') || (ch >= 'A' && ch <= 'F');
}

static int NKCValidUUID(const char *value, size_t length) {
    if (!value || length != NKC_LAUNCH_UUID_LENGTH) return 0;
    for (size_t i = 0; i < NKC_LAUNCH_UUID_LENGTH; i++) {
        if (i == 8 || i == 13 || i == 18 || i == 23) {
            if (value[i] != '-') return 0;
        } else if (!NKCIsHex(value[i])) return 0;
    }
    return 1;
}

static NKCLaunchCapsule NKCParseValues(const char *const *strings, size_t count) {
    const char key[] = NKC_LAUNCH_CAPSULE_KEY;
    const size_t keyLength = sizeof(key) - 1;
    NKCLaunchCapsule out = NKCResult(NKC_CAPSULE_ABSENT);
    int seen = 0;
    for (size_t i = 0; i < count; i++) {
        const char *item = strings[i];
        if (!item) return NKCResult(NKC_CAPSULE_UNKNOWN);
        const size_t itemLength = strlen(item);
        if (itemLength < keyLength || memcmp(item, key, keyLength) != 0) continue;
        // A longer identifier such as NKCRANE_LAUNCH_CONTAINER_ID_EXTRA is
        // unrelated, but the exact key without an '=' is malformed.
        if (itemLength > keyLength && item[keyLength] != '=') continue;
        if (++seen != 1 || itemLength == keyLength) return NKCResult(NKC_CAPSULE_INVALID);
        const char *value = item + keyLength + 1;
        size_t valueLength = itemLength - keyLength - 1;
        if (valueLength == 7 && memcmp(value, "DEFAULT", 7) == 0) {
            out.status = NKC_CAPSULE_DEFAULT;
        } else if (NKCValidUUID(value, valueLength)) {
            out.status = NKC_CAPSULE_NAMED;
            memcpy(out.uuid, value, NKC_LAUNCH_UUID_LENGTH);
            out.uuid[NKC_LAUNCH_UUID_LENGTH] = '\0';
        } else {
            return NKCResult(NKC_CAPSULE_INVALID);
        }
    }
    return out;
}

NKCLaunchCapsule NKCParseEnvStrings(const char *const *strings, size_t count) {
    if (count && !strings) return NKCResult(NKC_CAPSULE_UNKNOWN);
    if (count > 4096) return NKCResult(NKC_CAPSULE_UNKNOWN);
    return NKCParseValues(strings, count);
}

static const unsigned char *NKCFindTerminator(const unsigned char *p, const unsigned char *end) {
    if (p >= end) return NULL;
    return (const unsigned char *)memchr(p, 0, (size_t)(end - p));
}

NKCLaunchCapsule NKCParseProcArgs2(const void *buffer, size_t length) {
    if (!buffer || length < sizeof(int) + 4 || length > 4u * 1024u * 1024u)
        return NKCResult(NKC_CAPSULE_UNKNOWN);
    const unsigned char *begin = (const unsigned char *)buffer;
    const unsigned char *end = begin + length;
    int argc = 0;
    memcpy(&argc, begin, sizeof(argc));
    if (argc <= 0 || argc > 4096) return NKCResult(NKC_CAPSULE_UNKNOWN);

    const unsigned char *p = begin + sizeof(argc);
    const unsigned char *nul = NKCFindTerminator(p, end);  // executable path
    if (!nul) return NKCResult(NKC_CAPSULE_UNKNOWN);
    p = nul + 1;
    // Darwin procargs2 pads after the executable path, before argv[0].
    while (p < end && *p == 0) p++;
    for (int i = 0; i < argc; ++i) {
        nul = NKCFindTerminator(p, end);
        if (!nul || nul == p) return NKCResult(NKC_CAPSULE_UNKNOWN);
        p = nul + 1;
    }

    // After argv[argc - 1], envp strings follow. Do not scan arbitrary
    // executable/argv strings, and stop at the first empty env entry.
    const char *env[4096];
    size_t count = 0;
    while (p < end && *p != 0 && count < 4096) {
        nul = NKCFindTerminator(p, end);
        if (!nul) return NKCResult(NKC_CAPSULE_UNKNOWN);
        env[count++] = (const char *)p;
        p = nul + 1;
    }
    if (count == 4096 && p < end && *p != 0)
        return NKCResult(NKC_CAPSULE_UNKNOWN);
    return NKCParseValues(env, count);
}

const char *NKCCapsuleStatusName(NKCCapsuleStatus status) {
    switch (status) {
        case NKC_CAPSULE_ABSENT: return "ABSENT";
        case NKC_CAPSULE_NAMED: return "NAMED";
        case NKC_CAPSULE_DEFAULT: return "DEFAULT";
        case NKC_CAPSULE_INVALID: return "INVALID";
        case NKC_CAPSULE_UNKNOWN: return "UNKNOWN";
        default: return "UNKNOWN";
    }
}
