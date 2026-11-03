#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <unistd.h>
#import "../NKCraneCore/NKCAppControl.h"
#import "../NKCraneCore/NKCStore.h"
#import "../NKCraneCore/NKCPhysicalSwap.h"

// NKCrane v1.0 physical-profile mode.
// The CLI's existing `switch` command updates the logical active container and
// then calls NKCAppControl restartBundleIdentifier:. We replace that restart
// implementation inside nkcranectl so the target app is stopped, its live
// sandbox directories are swapped transactionally, and only then relaunched.
// No injected tweak/runtime marker is required.
static BOOL NKCPhysicalRestart(id self, SEL _cmd, NSString *bundleIdentifier, BOOL relaunch, NSError **error) {
    NKCStore *store = NKCStore.sharedStore;
    NSString *owner = [store ownerBundleIdentifierForProcessBundleIdentifier:bundleIdentifier];
    if (!owner.length) owner = bundleIdentifier;

    NSString *target = [store activeContainerIdentifierForBundleIdentifier:owner] ?: NKCDefaultContainerIdentifier;
    NSString *previousPhysical = [NKCPhysicalSwap physicalActiveForBundleIdentifier:owner] ?: NKCDefaultContainerIdentifier;

    NSError *terminationError = nil;
    if (![NKCAppControl terminateBundleIdentifier:owner error:&terminationError]) {
        if (error) *error = terminationError;
        return NO;
    }

    NSError *swapError = nil;
    if (![NKCPhysicalSwap switchBundleIdentifier:owner toContainerIdentifier:target error:&swapError]) {
        // NKCPhysicalSwap rolls file moves back internally. Restore the logical
        // active id as well so UI and on-disk data cannot disagree.
        [store setActiveContainerIdentifier:previousPhysical bundleIdentifier:owner error:nil];
        if (relaunch) {
            usleep(250000);
            [NKCAppControl launchBundleIdentifier:owner error:nil];
        }
        if (error) *error = swapError ?: [NSError errorWithDomain:@"NKCrane.PhysicalSwitch"
                                                               code:500
                                                           userInfo:@{NSLocalizedDescriptionKey:@"Physical profile swap failed"}];
        return NO;
    }

    if (!relaunch) return YES;
    usleep(350000);
    return [NKCAppControl launchBundleIdentifier:owner error:error];
}

__attribute__((constructor))
static void NKCInstallPhysicalSwitchBridge(void) {
    @autoreleasepool {
        Method method = class_getClassMethod(NKCAppControl.class, @selector(restartBundleIdentifier:relaunch:error:));
        if (!method) return;
        method_setImplementation(method, (IMP)NKCPhysicalRestart);
    }
}
