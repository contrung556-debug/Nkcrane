#import "NKCAppControl.h"
#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <signal.h>
#import <sys/sysctl.h>
#import <unistd.h>

static NSString * const NKCAppControlErrorDomain = @"NKCrane.AppControl";

@interface LSApplicationProxy : NSObject
+ (instancetype)applicationProxyForIdentifier:(NSString *)identifier;
@property (nonatomic, readonly) NSString *bundleExecutable;
@end

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
