#ifndef NKC_PROCESS_CAPSULE_H
#define NKC_PROCESS_CAPSULE_H
#include "NKCLaunchCapsule.h"
#ifdef __cplusplus
extern "C" {
#endif

// Immutable per-process snapshot of the *pre-spawn* environment capsule.
// This is an identity hint for app runtime, NOT cryptographic attestation.
// ABSENT preserves compatibility with v1.3.2 until RB bridge is tested.
NKCLaunchCapsule NKCProcessLaunchCapsule(void);
#ifdef __cplusplus
}
#endif
#endif
