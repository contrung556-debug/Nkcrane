#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <unistd.h>
#import "NKCStore.h"

static NSString * const NKCRegistryPath = @"/var/mobile/Library/NKCrane/Public/registry.json";
static NSDictionary *sRegistry = nil;
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

static BOOL NKCApplyRegistrySandboxProfile(void) {
    if (sSandyAttempted) return sSandyApplied;
    sSandyAttempted = YES;

    const char *candidates[] = {
        "/var/jb/usr/lib/libSandy.dylib",
        "/usr/lib/libSandy.dylib",
        "libSandy.dylib",
        NULL
    };
    void *handle = NULL;
    for (int i=0; candidates[i]; i++) {
        handle = dlopen(candidates[i], RTLD_LAZY | RTLD_GLOBAL);
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
    NKCApplyRegistrySandboxProfile();
    NSData *data = [NSData dataWithContentsOfFile:NKCRegistryPath];
    id obj = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if ([obj isKindOfClass:NSDictionary.class]) sRegistry = obj;
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
    NSDictionary *apps = [registry[@"apps"] isKindOfClass:NSDictionary.class] ? registry[@"apps"] : @{};
    NSString *owner = NKCResolveOwner(bundle);
    id entry = apps[owner];
    return [entry isKindOfClass:NSDictionary.class] ? entry : nil;
}

static NSString *NKC_owner(id self, SEL _cmd, NSString *processBundle) {
    NSDictionary *registry = NKCLoadRegistry();
    if (registry) return NKCResolveOwner(processBundle);
    return orig_owner ? orig_owner(self,_cmd,processBundle) : processBundle;
}

static BOOL NKC_enabled(id self, SEL _cmd, NSString *bundle) {
    NSDictionary *entry = NKCAppEntry(bundle);
    if (entry) return [entry[@"enabled"] boolValue];
    return orig_enabled ? orig_enabled(self,_cmd,bundle) : NO;
}

static NSString *NKC_active(id self, SEL _cmd, NSString *bundle) {
    NSDictionary *entry = NKCAppEntry(bundle);
    NSString *active = [entry[@"active"] isKindOfClass:NSString.class] ? entry[@"active"] : nil;
    if (active.length) return active;
    return orig_active ? orig_active(self,_cmd,bundle) : NKCDefaultContainerIdentifier;
}

static void NKCWriteRegistryRuntimeMarker(void) {
    NSString *process = NSBundle.mainBundle.bundleIdentifier;
    if (!process.length || [process hasPrefix:@"com.apple."]) return;
    NSDictionary *registry = NKCLoadRegistry();
    if (!registry) return;
    NSString *owner = NKCResolveOwner(process);
    NSDictionary *entry = NKCAppEntry(owner);
    NSString *home = NSHomeDirectory();
    if (!home.length) return;
    NSString *dir = [home stringByAppendingPathComponent:@".nkcrane"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"runtime-registry-%@.json", NKCSafe(process)]];
    NSDictionary *payload = @{
        @"version": @"1.1.0",
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
        NKCLoadRegistry();

        Method m = class_getInstanceMethod(NKCStore.class, @selector(ownerBundleIdentifierForProcessBundleIdentifier:));
        if (m) { orig_owner = (void *)method_getImplementation(m); method_setImplementation(m, (IMP)NKC_owner); }
        m = class_getInstanceMethod(NKCStore.class, @selector(isEnabledForBundleIdentifier:));
        if (m) { orig_enabled = (void *)method_getImplementation(m); method_setImplementation(m, (IMP)NKC_enabled); }
        m = class_getInstanceMethod(NKCStore.class, @selector(activeContainerIdentifierForBundleIdentifier:));
        if (m) { orig_active = (void *)method_getImplementation(m); method_setImplementation(m, (IMP)NKC_active); }

        NKCWriteRegistryRuntimeMarker();
    }
}
