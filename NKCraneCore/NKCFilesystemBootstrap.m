#import <Foundation/Foundation.h>
#import <stdlib.h>
#import "NKCStore.h"
#import "NKCFilesystemHooks.h"
#import "NKCLocalConfig.h"

// NKCrane v1.3.0
// Runtime filesystem bootstrap.
//
// v1.2.x had two possible homes for the same logical container:
//   <real-home>/.nkcrane/<id>/Root
//   <real-home>/Library/__NKCrane_Containers/<id>
// The in-app layout resolver already owns migration/compatibility symlinks.
// This bootstrap now asks that resolver for the canonical physical root and
// installs low-level filesystem hooks against the exact same root.

static NSString *NKCRecoverRealHome(NSString *home) {
    if (!home.length) return nil;

    NSArray<NSString *> *markers = @[
        @"/.nkcrane/",
        @"/Library/__NKCrane_Containers/"
    ];
    for (NSString *marker in markers) {
        NSRange range = [home rangeOfString:marker];
        if (range.location != NSNotFound) {
            return [home substringToIndex:range.location];
        }
    }
    return home;
}

static void NKCSetRuntimeEnvironment(NSString *mappedHome,
                                     NSString *ownerBundleID,
                                     NSString *processBundleID,
                                     NSString *containerID) {
    if (!mappedHome.length) return;

    setenv("HOME", mappedHome.fileSystemRepresentation, 1);
    setenv("CFFIXED_USER_HOME", mappedHome.fileSystemRepresentation, 1);

    NSString *tmp = [[mappedHome stringByAppendingPathComponent:@"tmp"] stringByAppendingString:@"/"];
    setenv("TMPDIR", tmp.fileSystemRepresentation, 1);

    if (containerID.length) setenv("NKCRANE_CONTAINER_ID", containerID.UTF8String, 1);
    if (ownerBundleID.length) setenv("NKCRANE_OWNER_BUNDLE_ID", ownerBundleID.UTF8String, 1);
    if (processBundleID.length) setenv("NKCRANE_PROCESS_BUNDLE_ID", processBundleID.UTF8String, 1);
    setenv("NKCRANE_RUNTIME_VERSION", "1.3.0", 1);
}

static void NKCWriteFilesystemRuntimeMarker(NSString *realHome,
                                            NSString *mappedHome,
                                            NSString *ownerBundleID,
                                            NSString *processBundleID,
                                            NSString *containerID) {
    if (!mappedHome.length) return;

    NSDictionary *payload = @{
        @"version": @"1.3.0",
        @"layout": @"in-app-sandbox-v3",
        @"process_bundle_id": processBundleID ?: @"",
        @"owner_bundle_id": ownerBundleID ?: @"",
        @"active_container_id": containerID ?: @"",
        @"real_home": realHome ?: @"",
        @"mapped_home": mappedHome ?: @"",
        @"home_env": NSProcessInfo.processInfo.environment[@"HOME"] ?: @"",
        @"cfixed_user_home_env": NSProcessInfo.processInfo.environment[@"CFFIXED_USER_HOME"] ?: @"",
        @"tmpdir_env": NSProcessInfo.processInfo.environment[@"TMPDIR"] ?: @"",
        @"low_level_filesystem_hooks": @YES,
        @"timestamp": @(NSDate.date.timeIntervalSince1970)
    };

    NSData *data = [NSJSONSerialization dataWithJSONObject:payload
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:nil];
    if (data) {
        [data writeToFile:[mappedHome stringByAppendingPathComponent:@".nkcrane-runtime.json"]
                  options:NSDataWritingAtomic
                    error:nil];
    }
}

__attribute__((constructor(300)))
static void NKCFilesystemBootstrap(void) {
    @autoreleasepool {
        NSString *processBundleID = NSBundle.mainBundle.bundleIdentifier;
        if (!processBundleID.length || [processBundleID hasPrefix:@"com.apple."]) return;
        if ([processBundleID isEqualToString:@"com.nktouch.nkcrane.manager"]) return;

        NKCStore *store = NKCStore.sharedStore;
        NSDictionary *local = [NKCLocalConfig currentProcessConfig];

        BOOL enabled = NO;
        NSString *ownerBundleID = nil;
        NSString *containerID = nil;

        if (local) {
            enabled = [NKCLocalConfig configIsEnabled:local];
            ownerBundleID = [NKCLocalConfig ownerFromConfig:local];
            containerID = [NKCLocalConfig activeContainerFromConfig:local];
        }

        if (!ownerBundleID.length) {
            ownerBundleID = [store ownerBundleIdentifierForProcessBundleIdentifier:processBundleID];
        }
        if (!local) {
            enabled = [store isEnabledForBundleIdentifier:ownerBundleID];
            containerID = [store activeContainerIdentifierForBundleIdentifier:ownerBundleID];
        }

        if (!enabled || !containerID.length ||
            [containerID isEqualToString:NKCDefaultContainerIdentifier]) return;

        NSString *reportedHome = NSHomeDirectory();
        NSString *realHome = NKCRecoverRealHome(reportedHome);
        if (!realHome.length) return;

        // The v1.2.2 in-app resolver is the single source of truth for the
        // physical container. It also migrates legacy .nkcrane roots and
        // leaves a compatibility symlink for older callers.
        NSString *mappedHome = [store rootPathForContainerIdentifier:containerID
                                                    bundleIdentifier:ownerBundleID
                                                              create:YES];
        if (!mappedHome.length) return;

        NSArray<NSString *> *required = @[
            @"Documents",
            @"Library",
            @"Library/Caches",
            @"Library/Preferences",
            @"Library/Application Support",
            @"Library/WebKit",
            @"Library/Cookies",
            @"tmp",
            @"SystemData"
        ];
        for (NSString *relative in required) {
            [[NSFileManager defaultManager] createDirectoryAtPath:[mappedHome stringByAppendingPathComponent:relative]
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:nil];
        }

        NKCSetRuntimeEnvironment(mappedHome, ownerBundleID, processBundleID, containerID);
        NKCInstallFilesystemHooks(realHome, mappedHome);
        NKCWriteFilesystemRuntimeMarker(realHome, mappedHome, ownerBundleID, processBundleID, containerID);

        NSLog(@"[NKCrane 1.3.0] filesystem runtime process=%@ owner=%@ active=%@ real=%@ mapped=%@",
              processBundleID,
              ownerBundleID,
              containerID,
              realHome,
              mappedHome);
    }
}
