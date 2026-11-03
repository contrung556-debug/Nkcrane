#import <Foundation/Foundation.h>
#import "../NKCraneCore/NKCStore.h"

static NSString *sBundleIdentifier = nil;
static NSString *sCommand = nil;

static BOOL NKCShouldSyncCommand(NSString *command) {
    static NSSet<NSString *> *commands;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        commands = [NSSet setWithArray:@[@"enable", @"disable", @"create", @"switch", @"rename", @"wipe", @"delete", @"restore", @"clone"]];
    });
    return [commands containsObject:command ?: @""];
}

static void NKCSyncLocalConfigAtExit(void) {
    @autoreleasepool {
        if (!sBundleIdentifier.length || !NKCShouldSyncCommand(sCommand)) return;

        NKCStore *store = NKCStore.sharedStore;
        NSString *owner = [store ownerBundleIdentifierForProcessBundleIdentifier:sBundleIdentifier];
        if (!owner.length) owner = sBundleIdentifier;

        NSString *home = [store realDataContainerPathForBundleIdentifier:owner];
        if (!home.length) return;

        NSString *dir = [home stringByAppendingPathComponent:@".nkcrane"];
        NSError *dirError = nil;
        if (![[NSFileManager defaultManager] createDirectoryAtPath:dir
                                       withIntermediateDirectories:YES
                                                        attributes:@{NSFilePosixPermissions:@0700}
                                                             error:&dirError]) {
            return;
        }

        NSString *active = [store activeContainerIdentifierForBundleIdentifier:owner] ?: NKCDefaultContainerIdentifier;
        BOOL enabled = [store isEnabledForBundleIdentifier:owner];
        NSDictionary *payload = @{
            @"version": @"0.9.3",
            @"bundle_id": sBundleIdentifier ?: @"",
            @"owner_bundle_id": owner ?: @"",
            @"enabled": @(enabled),
            @"active_container_id": active,
            @"updated_at": @([[NSDate date] timeIntervalSince1970])
        };

        NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:NSJSONWritingPrettyPrinted error:nil];
        if (!data.length) return;

        NSString *path = [dir stringByAppendingPathComponent:@"config.json"];
        [data writeToFile:path options:NSDataWritingAtomic error:nil];
    }
}

__attribute__((constructor))
static void NKCRegisterLocalConfigSync(void) {
    @autoreleasepool {
        NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
        if (arguments.count < 3) return;
        NSString *command = arguments[1];
        NSString *bundle = arguments[2];
        if (!NKCShouldSyncCommand(command) || !bundle.length) return;
        sCommand = [command copy];
        sBundleIdentifier = [bundle copy];
        atexit(NKCSyncLocalConfigAtExit);
    }
}
