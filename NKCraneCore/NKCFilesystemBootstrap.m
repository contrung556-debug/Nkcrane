#import <Foundation/Foundation.h>
#import "NKCStore.h"
#import "NKCFilesystemHooks.h"

__attribute__((constructor))
static void NKCFilesystemBootstrap(void) {
    @autoreleasepool {
        NSString *processBundleID = NSBundle.mainBundle.bundleIdentifier;
        if (!processBundleID.length || [processBundleID hasPrefix:@"com.apple."]) return;

        NKCStore *store = NKCStore.sharedStore;
        NSString *owner = [store ownerBundleIdentifierForProcessBundleIdentifier:processBundleID];
        if (![store isEnabledForBundleIdentifier:owner]) return;

        NSString *containerID = [store activeContainerIdentifierForBundleIdentifier:owner];
        if (!containerID.length || [containerID isEqualToString:NKCDefaultContainerIdentifier]) return;

        NSString *home = NSHomeDirectory();
        if (!home.length) return;

        // This constructor may run before or after Tweak.xm's NSHomeDirectory hook.
        // If the old hook already returned the virtual home, recover the real app home.
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
