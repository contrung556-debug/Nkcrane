#import "NKCAppControl.h"
#import "NKCStore.h"
#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <signal.h>
#import <sys/sysctl.h>
#import <sys/stat.h>
#import <unistd.h>

static NSString * const NKCAppControlErrorDomain = @"NKCrane.AppControl";

@interface LSApplicationProxy : NSObject
+ (instancetype)applicationProxyForIdentifier:(NSString *)identifier;
@property (nonatomic, readonly) NSString *bundleExecutable;
@end

static BOOL NKCWriteVerifiedLocalConfig(NSString *bundleIdentifier, NSError **error) {
    NKCStore *store = NKCStore.sharedStore;
    NSString *owner = [store ownerBundleIdentifierForProcessBundleIdentifier:bundleIdentifier];
    if (!owner.length) owner = bundleIdentifier;

    NSString *home = [store realDataContainerPathForBundleIdentifier:owner];
    if (!home.length) {
        if (error) *error = [NSError errorWithDomain:NKCAppControlErrorDomain
                                                 code:410
                                             userInfo:@{NSLocalizedDescriptionKey:
                                                            [NSString stringWithFormat:@"Could not resolve real data container for %@", owner ?: @"unknown app"]}];
        return NO;
    }

    NSString *dir = [home stringByAppendingPathComponent:@".nkcrane"];
    NSError *dirError = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:dir
                                 withIntermediateDirectories:YES
                                                  attributes:@{NSFilePosixPermissions:@0700}
                                                       error:&dirError]) {
        if (error) *error = [NSError errorWithDomain:NKCAppControlErrorDomain
                                                 code:411
                                             userInfo:@{NSLocalizedDescriptionKey:
                                                            [NSString stringWithFormat:@"Could not create %@: %@", dir, dirError.localizedDescription ?: @"unknown error"]}];
        return NO;
    }

    NSString *active = [store activeContainerIdentifierForBundleIdentifier:owner] ?: NKCDefaultContainerIdentifier;
    BOOL enabled = [store isEnabledForBundleIdentifier:owner];
    NSDictionary *payload = @{
        @"version": @"0.9.4",
        @"bundle_id": bundleIdentifier ?: @"",
        @"owner_bundle_id": owner ?: @"",
        @"enabled": @(enabled),
        @"active_container_id": active,
        @"updated_at": @([[NSDate date] timeIntervalSince1970])
    };

    NSError *jsonError = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:NSJSONWritingPrettyPrinted error:&jsonError];
    if (!data.length) {
        if (error) *error = [NSError errorWithDomain:NKCAppControlErrorDomain
                                                 code:412
                                             userInfo:@{NSLocalizedDescriptionKey:
                                                            [NSString stringWithFormat:@"Could not encode local config: %@", jsonError.localizedDescription ?: @"unknown error"]}];
        return NO;
    }

    NSString *path = [dir stringByAppendingPathComponent:@"config.json"];
    NSError *writeError = nil;
    if (![data writeToFile:path options:0 error:&writeError]) {
        if (error) *error = [NSError errorWithDomain:NKCAppControlErrorDomain
                                                 code:413
                                             userInfo:@{NSLocalizedDescriptionKey:
                                                            [NSString stringWithFormat:@"Could not write %@: %@", path, writeError.localizedDescription ?: @"unknown error"]}];
        return NO;
    }
    chmod(path.fileSystemRepresentation, 0600);

    NSError *readError = nil;
    NSData *verifyData = [NSData dataWithContentsOfFile:path options:0 error:&readError];
    if (!verifyData.length) {
        if (error) *error = [NSError errorWithDomain:NKCAppControlErrorDomain
                                                 code:414
                                             userInfo:@{NSLocalizedDescriptionKey:
                                                            [NSString stringWithFormat:@"Could not read back %@: %@", path, readError.localizedDescription ?: @"unknown error"]}];
        return NO;
    }

    NSError *parseError = nil;
    id object = [NSJSONSerialization JSONObjectWithData:verifyData options:0 error:&parseError];
    if (![object isKindOfClass:NSDictionary.class]) {
        if (error) *error = [NSError errorWithDomain:NKCAppControlErrorDomain
                                                 code:415
                                             userInfo:@{NSLocalizedDescriptionKey:
                                                            [NSString stringWithFormat:@"Local config verification failed: %@", parseError.localizedDescription ?: @"invalid JSON"]}];
        return NO;
    }

    NSDictionary *verified = (NSDictionary *)object;
    BOOL matches = [verified[@"owner_bundle_id"] isEqualToString:owner] &&
                   [verified[@"active_container_id"] isEqualToString:active] &&
                   [verified[@"enabled"] boolValue] == enabled;
    if (!matches) {
        if (error) *error = [NSError errorWithDomain:NKCAppControlErrorDomain
                                                 code:416
                                             userInfo:@{NSLocalizedDescriptionKey:@"Local config was written but verification did not match active NKCrane state"}];
        return NO;
    }

    return YES;
}

@implementation NKCAppControl

+ (id)applicationProxyForBundleIdentifier:(NSString *)bundleIdentifier {
    dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY);
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    SEL selector = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (!proxyClass || ![proxyClass respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(proxyClass, selector, bundleIdentifier);
}

+ (NSString *)executableNameForBundleIdentifier:(NSString *)bundleIdentifier {
    id proxy = [self applicationProxyForBundleIdentifier:bundleIdentifier];
    SEL selector = NSSelectorFromString(@"bundleExecutable");
    if (proxy && [proxy respondsToSelector:selector]) {
        id value = ((id (*)(id, SEL))objc_msgSend)(proxy, selector);
        if ([value isKindOfClass:NSString.class] && [value length] > 0) return value;
    }
    return nil;
}

+ (NSArray<NSNumber *> *)pidsForExecutableName:(NSString *)executableName {
    if (!executableName.length) return @[];

    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t size = 0;
    if (sysctl(mib, 4, NULL, &size, NULL, 0) != 0 || size == 0) return @[];

    struct kinfo_proc *procs = calloc(1, size);
    if (!procs) return @[];

    if (sysctl(mib, 4, procs, &size, NULL, 0) != 0) {
        free(procs);
        return @[];
    }

    NSUInteger count = size / sizeof(struct kinfo_proc);
    NSMutableArray<NSNumber *> *matches = [NSMutableArray array];
    for (NSUInteger i = 0; i < count; i++) {
        pid_t pid = procs[i].kp_proc.p_pid;
        if (pid <= 1 || pid == getpid()) continue;
        NSString *comm = [NSString stringWithUTF8String:procs[i].kp_proc.p_comm ?: ""];
        if ([comm isEqualToString:executableName]) [matches addObject:@(pid)];
    }
    free(procs);
    return matches;
}

+ (BOOL)terminateBundleIdentifier:(NSString *)bundleIdentifier error:(NSError **)error {
    NSString *executable = [self executableNameForBundleIdentifier:bundleIdentifier];
    if (!executable.length) {
        if (error) *error = [NSError errorWithDomain:NKCAppControlErrorDomain code:404 userInfo:@{NSLocalizedDescriptionKey: @"Could not resolve app executable"}];
        return NO;
    }

    NSArray<NSNumber *> *pids = [self pidsForExecutableName:executable];
    if (pids.count == 0) return YES;

    BOOL ok = YES;
    int lastErrno = 0;
    for (NSNumber *value in pids) {
        if (kill((pid_t)value.intValue, SIGKILL) != 0) {
            ok = NO;
            lastErrno = errno;
        }
    }

    if (!ok && error) {
        *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:lastErrno userInfo:@{NSLocalizedDescriptionKey: @"Failed to terminate one or more app processes"}];
    }
    return ok;
}

+ (BOOL)launchBundleIdentifier:(NSString *)bundleIdentifier error:(NSError **)error {
    dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY);
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    SEL defaultSelector = NSSelectorFromString(@"defaultWorkspace");
    SEL openSelector = NSSelectorFromString(@"openApplicationWithBundleID:");
    if (!workspaceClass || ![workspaceClass respondsToSelector:defaultSelector]) {
        if (error) *error = [NSError errorWithDomain:NKCAppControlErrorDomain code:501 userInfo:@{NSLocalizedDescriptionKey: @"LSApplicationWorkspace unavailable"}];
        return NO;
    }

    id workspace = ((id (*)(id, SEL))objc_msgSend)(workspaceClass, defaultSelector);
    if (!workspace || ![workspace respondsToSelector:openSelector]) {
        if (error) *error = [NSError errorWithDomain:NKCAppControlErrorDomain code:501 userInfo:@{NSLocalizedDescriptionKey: @"App launch API unavailable"}];
        return NO;
    }

    BOOL result = ((BOOL (*)(id, SEL, id))objc_msgSend)(workspace, openSelector, bundleIdentifier);
    if (!result && error) {
        *error = [NSError errorWithDomain:NKCAppControlErrorDomain code:500 userInfo:@{NSLocalizedDescriptionKey: @"App launch request failed"}];
    }
    return result;
}

+ (BOOL)restartBundleIdentifier:(NSString *)bundleIdentifier relaunch:(BOOL)relaunch error:(NSError **)error {
    NSError *configError = nil;
    if (!NKCWriteVerifiedLocalConfig(bundleIdentifier, &configError)) {
        if (error) *error = configError;
        return NO;
    }

    NSError *terminationError = nil;
    if (![self terminateBundleIdentifier:bundleIdentifier error:&terminationError]) {
        if (error) *error = terminationError;
        return NO;
    }

    if (!relaunch) return YES;
    usleep(350000);
    return [self launchBundleIdentifier:bundleIdentifier error:error];
}

@end
