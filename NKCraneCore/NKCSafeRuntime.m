#import <Foundation/Foundation.h>
#import <stdlib.h>
#import "NKCStore.h"

// NKCrane v1.3.2
// Safe runtime bridge.
//
// v1.3.1 linked broad POSIX hooks (open/stat/opendir/rename/...) into the app.
// That made complex apps such as Facebook fail very early during launch when a
// named container was active.  The backing store also lives inside the app
// sandbox, so blanket remapping of every path under the sandbox is too risky.
//
// v1.3.2 keeps the in-app physical layout resolver, creates its compatibility
// symlink before the main Logos constructor runs, and lets the existing
// Foundation/preferences/keychain layer operate through that symlink.  No
// low-level POSIX functions are interposed in this build.

static void NKCWriteSafeRuntimeMarker(NSString *realHome,
                                      NSString *physicalRoot,
                                      NSString *ownerBundleID,
                                      NSString *processBundleID,
                                      NSString *containerID) {
    if (!physicalRoot.length) return;

    NSDictionary *payload = @{
        @"version": @"1.3.2",
        @"mode": @"safe-canonical-runtime-v1",
        @"process_bundle_id": processBundleID ?: @"",
        @"owner_bundle_id": ownerBundleID ?: @"",
        @"active_container_id": containerID ?: @"",
        @"real_home": realHome ?: @"",
        @"mapped_home": physicalRoot,
        @"home_env": NSProcessInfo.processInfo.environment[@"HOME"] ?: @"",
        @"cfixed_user_home_env": NSProcessInfo.processInfo.environment[@"CFFIXED_USER_HOME"] ?: @"",
        @"tmpdir_env": NSProcessInfo.processInfo.environment[@"TMPDIR"] ?: @"",
        @"low_level_filesystem_hooks": @NO,
        @"compatibility_symlink_runtime": @YES,
        @"timestamp": @(NSDate.date.timeIntervalSince1970)
    };

    NSData *data = [NSJSONSerialization dataWithJSONObject:payload
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:nil];
    if (data) {
        [data writeToFile:[physicalRoot stringByAppendingPathComponent:@".nkcrane-runtime.json"]
                  options:NSDataWritingAtomic
                    error:nil];
    }
}

__attribute__((constructor(300)))
static void NKCInstallSafeRuntime(void) {
    @autoreleasepool {
        NSString *processBundleID = NSBundle.mainBundle.bundleIdentifier;
        if (!processBundleID.length || [processBundleID hasPrefix:@"com.apple."]) return;
        if ([processBundleID isEqualToString:@"com.nktouch.nkcrane.manager"]) return;

        NSString *realHome = [NSHomeDirectory() copy];
        if (!realHome.length) return;

        NKCStore *store = NKCStore.sharedStore;
        NSString *ownerBundleID = [store ownerBundleIdentifierForProcessBundleIdentifier:processBundleID];
        if (![store isEnabledForBundleIdentifier:ownerBundleID]) return;

        NSString *containerID = [store activeContainerIdentifierForBundleIdentifier:ownerBundleID];
        if (!containerID.length || [containerID isEqualToString:NKCDefaultContainerIdentifier]) return;

        // NKCInAppLayout is installed at constructor priority 120, so this call
        // returns the canonical physical root and also creates the legacy
        // .nkcrane/<id>/Root compatibility symlink before Tweak.xm runs.
        NSString *physicalRoot = [store rootPathForContainerIdentifier:containerID
                                                      bundleIdentifier:ownerBundleID
                                                                create:YES];
        if (!physicalRoot.length) {
            NSLog(@"[NKCrane 1.3.2] could not resolve physical root process=%@ owner=%@ active=%@",
                  processBundleID, ownerBundleID, containerID);
            return;
        }

        // Identity variables are safe to publish before the main tweak starts.
        setenv("NKCRANE_CONTAINER_ID", containerID.UTF8String, 1);
        setenv("NKCRANE_OWNER_BUNDLE_ID", ownerBundleID.UTF8String, 1);
        setenv("NKCRANE_PROCESS_BUNDLE_ID", processBundleID.UTF8String, 1);
        setenv("NKCRANE_RUNTIME_VERSION", "1.3.2", 1);

        // Do not rewrite HOME before the Logos %ctor captures the real sandbox.
        // Once constructors have returned, canonicalize environment consumers to
        // the physical root. Foundation APIs continue to use the compatibility
        // symlink maintained by Tweak.xm, which resolves to the same data.
        dispatch_async(dispatch_get_main_queue(), ^{
            setenv("HOME", physicalRoot.fileSystemRepresentation, 1);
            setenv("CFFIXED_USER_HOME", physicalRoot.fileSystemRepresentation, 1);
            NSString *tmp = [[physicalRoot stringByAppendingPathComponent:@"tmp"] stringByAppendingString:@"/"];
            setenv("TMPDIR", tmp.fileSystemRepresentation, 1);

            NKCWriteSafeRuntimeMarker(realHome, physicalRoot, ownerBundleID, processBundleID, containerID);
            NSLog(@"[NKCrane 1.3.2] safe runtime process=%@ owner=%@ active=%@ real=%@ physical=%@",
                  processBundleID, ownerBundleID, containerID, realHome, physicalRoot);
        });
    }
}
