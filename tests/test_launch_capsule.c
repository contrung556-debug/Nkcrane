#include "../NKCraneCore/NKCLaunchCapsule.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>

#define ID "f15da6b2-b39c-4270-8f50-1d0067179c83"
static void expect(NKCCapsuleStatus have, NKCCapsuleStatus wanted) {
    if (have != wanted) { fprintf(stderr, "got %s, wanted %s\n", NKCCapsuleStatusName(have), NKCCapsuleStatusName(wanted)); assert(have == wanted); }
}

static void test_env(void) {
    const char *none[] = {"HOME=/var/mobile", "NKCRANE_LAUNCH_CONTAINER_ID_EXTRA=bad"};
    expect(NKCParseEnvStrings(none, 2).status, NKC_CAPSULE_ABSENT);
    const char *named[] = {"HOME=/var/mobile", NKC_LAUNCH_CAPSULE_KEY "=" ID};
    NKCLaunchCapsule result = NKCParseEnvStrings(named, 2);
    expect(result.status, NKC_CAPSULE_NAMED);
    assert(strcmp(result.uuid, ID) == 0);
    const char *def[] = {NKC_LAUNCH_CAPSULE_KEY "=DEFAULT"};
    expect(NKCParseEnvStrings(def, 1).status, NKC_CAPSULE_DEFAULT);
    const char *wrong[] = {NKC_LAUNCH_CAPSULE_KEY "=../../Library"};
    expect(NKCParseEnvStrings(wrong, 1).status, NKC_CAPSULE_INVALID);
    const char *missingEqual[] = {NKC_LAUNCH_CAPSULE_KEY};
    expect(NKCParseEnvStrings(missingEqual, 1).status, NKC_CAPSULE_INVALID);
    const char *dupe[] = {NKC_LAUNCH_CAPSULE_KEY "=" ID, NKC_LAUNCH_CAPSULE_KEY "=DEFAULT"};
    expect(NKCParseEnvStrings(dupe, 2).status, NKC_CAPSULE_INVALID);
    expect(NKCParseEnvStrings(NULL, 1).status, NKC_CAPSULE_UNKNOWN);
}

static void test_procargs(void) {
    unsigned char buffer[512] = {0};
    int argc = 2;
    memcpy(buffer, &argc, sizeof(argc));
    size_t at = sizeof(argc);
    const char *parts[] = {"/Applications/Facebook", "Facebook", "-flag", "HOME=/var/mobile", NKC_LAUNCH_CAPSULE_KEY "=" ID};
    for (size_t i = 0; i < 5; i++) {
        size_t n = strlen(parts[i]) + 1;
        memcpy(buffer + at, parts[i], n);
        at += n;
        if (i == 0) buffer[at++] = 0;  // padding after executable
    }
    NKCLaunchCapsule good = NKCParseProcArgs2(buffer, at + 1);
    expect(good.status, NKC_CAPSULE_NAMED);
    assert(strcmp(good.uuid, ID) == 0);
    expect(NKCParseProcArgs2(buffer, 5).status, NKC_CAPSULE_UNKNOWN);
    unsigned char badArgc[32] = {0};
    expect(NKCParseProcArgs2(badArgc, sizeof(badArgc)).status, NKC_CAPSULE_UNKNOWN);

    unsigned char spoof[512] = {0}; at = sizeof(argc);
    const char *spoofParts[] = {"/Applications/Facebook", "Facebook", NKC_LAUNCH_CAPSULE_KEY "=" ID, "HOME=/var/mobile"};
    memcpy(spoof, &argc, sizeof(argc));
    // The marker in argv[1] must not be mistaken for an environment value.
    for (size_t i = 0; i < 4; i++) {
        size_t n = strlen(spoofParts[i]) + 1;
        memcpy(spoof + at, spoofParts[i], n); at += n;
        if (i == 0) spoof[at++] = 0;
    }
    expect(NKCParseProcArgs2(spoof, at + 1).status, NKC_CAPSULE_ABSENT);
}

int main(void) {
    test_env();
    test_procargs();
    puts("NKCrane launch capsule parser: PASS");
    return 0;
}
