#import <Foundation/Foundation.h>
#import "NKCStore.h"
#import "NKCFilesystemHooks.h"
#import "NKCLocalConfig.h"

__attribute__((constructor))
static void NKCFilesystemBootstrap(void) {
    @autoreleasepool {
        NSString *processBundleID = NSBundle.mainBundle.bundleIdentifier;
        if (!processBundleID.length || [processBundleID hasPrefix:@"com.apple."]) return;

        BOOL enabled = NO;
        NSString *containerID = nil;
        NSDictionary *local = [NKCLocalConfig currentProcessConfig];
        if (local) {
            enabled = [NKCLocalConfig configIsEnabled:local];
            containerID = [NKCLocalConfig activeContainerFromConfig:local];
        } else {
            NKCStore *store = NKCStore.sharedStore;
            NSString *owner = [store ownerBundleIdentifierForProcessBundleIdentifier:processBundleID];
            enabled = [store isEnabledForBundleIdentifier:owner];
            containerID = [store activeContainerIdentifierForBundleIdentifier:owner];
        }
        if (!enabled || !containerID.length || [containerID isEqualToString:NKCDefaultContainerIdentifier]) return;

        NSString *home = NSHomeDirectory();
        if (!home.length) return;

        NSRange marker = [home rangeOfString:@"/.nkcrane/"];
        NSString *realHome = marker.location == NSNotFound ? home : [home substringToIndex:marker.location];
        if (!realHome.length) return;

        NSString *mappedHome = [[[realHome stringByAppendingPathComponent:@".nkcrane"]
                                 stringByAppendingPathComponent:containerID]
                                 stringByAppendingPathComponent:@"Root"];

        [[NSFileManager defaultManager] createDirectoryAtPath:mappedHome
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        NKCInstallFilesystemHooks(realHome, mappedHome);
    }
}
