#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <unistd.h>
#import "NKCStore.h"
#import "NKCProcessCapsule.h"

static NSString * const NKCRegistryPath = @"/var/mobile/Library/NKCrane/Public/registry.json";
static NSDictionary *sRegistry = nil;
static NKCLaunchCapsule sLaunchCapsule = {0};
static NSString *sCapsuleOwner = nil;
static BOOL sSandyAttempted = NO;
static BOOL sSandyApplied = NO;

static NSString *(*orig_owner)(id, SEL, NSString *) = NULL;
static BOOL (*orig_enabled)(id, SEL, NSString *) = NULL;
static NSString *(*orig_active)(id, SEL, NSString *) = NULL;

static NSString *NKCSafe(NSString *value) {
    if (!value.length) return @"unknown";
    NSMutableString *out = [value mutableCopy];
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"];
    for (NSInteger i=(NSInteger)out.length-1; i>=0; i--) {
        unichar c=[out characterAtIndex:(NSUInteger)i];
        if (![allowed characterIsMember:c]) [out replaceCharactersInRange:NSMakeRange((NSUInteger)i,1) withString:@"_"];
    }
    return out;
}

static NSDictionary *NKCReadRegistryFile(void) {
    NSData *data = [NSData dataWithContentsOfFile:NKCRegistryPath];
    if (!data.length) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [obj isKindOfClass:NSDictionary.class] ? obj : nil;
}

static BOOL NKCApplyRegistrySandboxProfile(void) {
    if (sSandyAttempted) return sSandyApplied;
    sSandyAttempted = YES;

    const char *candidates[] = {
        "/var/jb/usr/lib/libsandy.dylib",
        "/usr/lib/libsandy.dylib",
        "libsandy.dylib",
        NULL
    };
    void *handle = NULL;
    for (int i=0; candidates[i]; i++) {
        handle = dlopen(candidates[i], RTLD_LAZY | RTLD_LOCAL);
        if (handle) break;
    }
    if (!handle) return NO;

    int (*applyProfile)(const char *) = (int (*)(const char *))dlsym(handle, "libSandy_applyProfile");
    if (!applyProfile) return NO;

    int rc = applyProfile("NKCraneRegistry");
    sSandyApplied = (rc == 0);
    return sSandyApplied;
}

static NSDictionary *NKCLoadRegistry(void) {
    if (sRegistry) return sRegistry;

    // Fail-open: try a plain read first. Only touch libSandy if the sandbox
    // actually blocks the registry path. If libSandy fails, do not install
    // registry method hooks and let the app continue normally.
    NSDictionary *registry = NKCReadRegistryFile();
    if (!registry) {
        if (!NKCApplyRegistrySandboxProfile()) return nil;
        registry = NKCReadRegistryFile();
    }
    if ([registry isKindOfClass:NSDictionary.class]) sRegistry = registry;
    return sRegistry;
}

static NSString *NKCResolveOwner(NSString *processBundle) {
    if (!processBundle.length) return processBundle ?: @"";
    NSDictionary *registry = NKCLoadRegistry();
    NSDictionary *aliases = [registry[@"aliases"] isKindOfClass:NSDictionary.class] ? registry[@"aliases"] : @{};
    NSString *current = processBundle;
    NSMutableSet *seen = [NSMutableSet set];
    for (NSUInteger i=0; i<8; i++) {
        if (!current.length || [seen containsObject:current]) break;
        [seen addObject:current];
        NSString *next = [aliases[current] isKindOfClass:NSString.class] ? aliases[current] : nil;
        if (!next.length) break;
        current = next;
    }
    return current ?: processBundle;
}

static NSDictionary *NKCAppEntry(NSString *bundle) {
    NSDictionary *registry = NKCLoadRegistry();
    if (!registry) return nil;
    NSDictionary *apps = [registry[@"apps"] isKindOfClass:NSDictionary.class] ? registry[@"apps"] : @{};
    NSString *owner = NKCResolveOwner(bundle);
    id entry = apps[owner];
    return [entry isKindOfClass:NSDictionary.class] ? entry : nil;
}

static NSString *NKC_owner(id self, SEL _cmd, NSString *processBundle) {
    if (!sRegistry) return orig_owner ? orig_owner(self,_cmd,processBundle) : processBundle;
    return NKCResolveOwner(processBundle);
}

// A process-bound launch capsule takes precedence over mutable "next active"
// registry settings. Switching the registry cannot hot-switch this PID.
static BOOL NKCCapsuleAppliesTo(NSString *bundle) {
    return bundle.length && sCapsuleOwner.length && [bundle isEqualToString:sCapsuleOwner];
}

static BOOL NKC_enabled(id self, SEL _cmd, NSString *bundle) {
    if (NKCCapsuleAppliesTo(bundle) && sLaunchCapsule.status == NKC_CAPSULE_NAMED)
        return YES;
    if (NKCCapsuleAppliesTo(bundle) && sLaunchCapsule.status == NKC_CAPSULE_DEFAULT)
        return YES;
    if (!sRegistry) return orig_enabled ? orig_enabled(self, _cmd, bundle) : NO;
    NSDictionary *entry = NKCAppEntry(bundle);
    if (entry) return [entry[@"enabled"] boolValue];
    return NO;
}

static NSString *NKC_active(id self, SEL _cmd, NSString *bundle) {
    if (NKCCapsuleAppliesTo(bundle)) {
        if (sLaunchCapsule.status == NKC_CAPSULE_NAMED)
            return [NSString stringWithUTF8String:sLaunchCapsule.uuid];
        if (sLaunchCapsule.status == NKC_CAPSULE_DEFAULT)
            return NKCDefaultContainerIdentifier;
    }
    if (!sRegistry) return orig_active ? orig_active(self, _cmd, bundle) : NKCDefaultContainerIdentifier;
    NSDictionary *entry = NKCAppEntry(bundle);
    NSString *active = [entry[@"active"] isKindOfClass:NSString.class] ? entry[@"active"] : nil;
    return active.length ? active : NKCDefaultContainerIdentifier;
}

static void NKCWriteRegistryRuntimeMarker(void) {
    NSString *process = NSBundle.mainBundle.bundleIdentifier;
    if (!process.length || [process hasPrefix:@"com.apple."] || !sRegistry) return;
    NSString *owner = NKCResolveOwner(process);
    NSDictionary *entry = NKCAppEntry(owner);
    NSString *home = NSHomeDirectory();
    if (!home.length) return;
    NSString *dir = [home stringByAppendingPathComponent:@".nkcrane"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"runtime-registry-%@.json", NKCSafe(process)]];
    NSDictionary *payload = @{
        @"version": @"1.1.1",
        @"mode": @"registry-shim-v1",
        @"pid": @(getpid()),
        @"process_bundle_id": process,
        @"owner_bundle_id": owner ?: process,
        @"registry_seen": @YES,
        @"libsandy_applied": @(sSandyApplied),
        @"enabled": @([entry[@"enabled"] boolValue]),
        @"active_container_id": ([entry[@"active"] isKindOfClass:NSString.class] ? entry[@"active"] : @"default"),
        @"timestamp": @([[NSDate date] timeIntervalSince1970])
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:NSJSONWritingPrettyPrinted error:nil];
    if (data) [data writeToFile:path options:NSDataWritingAtomic error:nil];
}

__attribute__((constructor(101)))
static void NKCInstallRegistryAdapter(void) {
    @autoreleasepool {
        NSString *process = NSBundle.mainBundle.bundleIdentifier;
        if (!process.length || [process hasPrefix:@"com.apple."]) return;

        // Snapshot launch context once, BEFORE any registry swizzling.
        sLaunchCapsule = NKCProcessLaunchCapsule();
        BOOL explicitCapsule = (sLaunchCapsule.status == NKC_CAPSULE_NAMED ||
                                sLaunchCapsule.status == NKC_CAPSULE_DEFAULT);
        NSDictionary *registry = NKCLoadRegistry();
        if (!registry && !explicitCapsule) return;

        // If registry cannot be read, the app's own process bundle is used as
        // the owner. This does NOT enable App Group/extension isolation.
        sCapsuleOwner = [NKCResolveOwner(process) copy];
        if (sLaunchCapsule.status == NKC_CAPSULE_INVALID ||
            sLaunchCapsule.status == NKC_CAPSULE_UNKNOWN) {
            setenv("NKCRANE_CONTEXT_ERROR", NKCCapsuleStatusName(sLaunchCapsule.status), 1);
            NSLog(@"[NKCrane] malformed/unverifiable launch capsule: %@",
                  [NSString stringWithUTF8String:NKCCapsuleStatusName(sLaunchCapsule.status)]);
            return; // never interpret malformed capsule as named or Default
        }

        Method m = class_getInstanceMethod(NKCStore.class, @selector(ownerBundleIdentifierForProcessBundleIdentifier:));
        if (m) { orig_owner = (void *)method_getImplementation(m); method_setImplementation(m, (IMP)NKC_owner); }
        m = class_getInstanceMethod(NKCStore.class, @selector(isEnabledForBundleIdentifier:));
        if (m) { orig_enabled = (void *)method_getImplementation(m); method_setImplementation(m, (IMP)NKC_enabled); }
        m = class_getInstanceMethod(NKCStore.class, @selector(activeContainerIdentifierForBundleIdentifier:));
        if (m) { orig_active = (void *)method_getImplementation(m); method_setImplementation(m, (IMP)NKC_active); }

        NKCWriteRegistryRuntimeMarker();
    }
}
