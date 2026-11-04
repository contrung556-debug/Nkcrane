// NKCrane v1.4 — independent, fail-closed launch capsule parser.
// These functions do not hook system processes or read the mutable app registry.
// "ABSENT" is not proof of "DEFAULT". Only an explicit DEFAULT token is.
#ifndef NKC_LAUNCH_CAPSULE_H
#define NKC_LAUNCH_CAPSULE_H
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif

#define NKC_LAUNCH_CAPSULE_KEY "NKCRANE_LAUNCH_CONTAINER_ID"
#define NKC_LAUNCH_UUID_LENGTH 36

typedef enum {
    NKC_CAPSULE_ABSENT = 0,
    NKC_CAPSULE_NAMED = 1,
    NKC_CAPSULE_DEFAULT = 2,
    NKC_CAPSULE_INVALID = 3,
    NKC_CAPSULE_UNKNOWN = 4
} NKCCapsuleStatus;

typedef struct {
    NKCCapsuleStatus status;
    char uuid[NKC_LAUNCH_UUID_LENGTH + 1];
} NKCLaunchCapsule;

// An array of NUL-terminated KEY=VALUE strings. Duplicate marker => INVALID.
NKCLaunchCapsule NKCParseEnvStrings(const char * const *strings, size_t count);

// Parse the bounded Darwin KERN_PROCARGS2 buffer. Invalid or truncated
// procargs => UNKNOWN, not DEFAULT. No sysctl/task_for_pid performed here.
NKCLaunchCapsule NKCParseProcArgs2(const void *buffer, size_t length);

const char *NKCCapsuleStatusName(NKCCapsuleStatus status);

#ifdef __cplusplus
}
#endif
#endif
