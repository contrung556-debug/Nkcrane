// Experimental RunningBoard launch capsule bridge, independent implementation.
// Compiled into .deb ONLY with NKC_EXPERIMENTAL_RB=1.
// Never package or enable on normal user builds until on-device verification.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <dlfcn.h>
#import "NKCLaunchCapsule.h"

static NSString * const NKCRBRegistryPath = @"/var/mobile/Library/NKCrane/Public/registry.json";
static NSString * const NKCRBContextKey = @NKC_LAUNCH_CAPSULE_KEY;

typedef id (*RBRequestErrorIMP)(id, SEL, id, NSError **);
typedef void (*RBRequestCompletionIMP)(id, SEL, id, id);
static RBRequestErrorIMP sOrigPublicError = NULL;
static RBRequestErrorIMP sOrigPrivateError = NULL;
static RBRequestCompletionIMP sOrigCompletion = NULL;

// Experimental builds only: use the already-installed read-only libSandy
// registry profile. If sandbox read access cannot be obtained, install no hooks.
static BOOL NKCRegistryReadableForRunningBoard(void) {
    if ([NSData dataWithContentsOfFile:NKCRBRegistryPath].length > 0) return YES;
    const char *candidates[] = {
        "/var/jb/usr/lib/libsandy.dylib",
        "/usr/lib/libsandy.dylib",
        "libsandy.dylib",
        NULL
    };
    for (int i = 0; candidates[i]; i++) {
        void *library = dlopen(candidates[i], RTLD_LAZY | RTLD_LOCAL);
        if (!library) continue;
        int (*apply)(const char *) = (int (*)(const char *))dlsym(library, "libSandy_applyProfile");
        if (apply && apply("NKCraneRegistry") == 0) break;
    }
    return [NSData dataWithContentsOfFile:NKCRBRegistryPath].length > 0;
}

static id NKCInvokeGetter(id instance, NSString *selectorName) {
    if (!instance || !selectorName.length) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    if (![instance respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(instance, selector);
}

static NSString *NKCBundleForLaunchRequest(id request) {
    id context = NKCInvokeGetter(request, @"context");
    id bundleID = NKCInvokeGetter(context, @"bundleIdentifier");
    if (![bundleID isKindOfClass:NSString.class] || ![bundleID length]) {
        id identity = NKCInvokeGetter(context, @"identity");
        bundleID = NKCInvokeGetter(identity, @"embeddedApplicationIdentifier");
    }
    if (![bundleID isKindOfClass:NSString.class] || [bundleID length] > 255) return nil;
    if ([bundleID hasPrefix:@"com.apple."]) return nil;
    return bundleID;
}

static NSString *NKCOwnerForBundle(NSString *bundle, NSDictionary *aliases) {
    NSString *current = bundle;
    NSMutableSet<NSString *> *visited = [NSMutableSet set];
    for (NSUInteger n = 0; n < 8; n++) {
        if (!current.length || [visited containsObject:current]) return nil;
        [visited addObject:current];
        id next = aliases[current];
        if (![next isKindOfClass:NSString.class] || ![next length]) return current;
        if ([next hasPrefix:@"com.apple."] || [next length] > 255) return nil;
        current = next;
    }
    return nil;
}

// This is a deliberately read-only snapshot. Missing/unreadable/stale registry
// means NO change to Apple's original launch context (never force Default).
static NSString *NKCSelectedCapsuleForBundle(NSString *bundleID) {
    NSData *bytes = [NSData dataWithContentsOfFile:NKCRBRegistryPath];
    if (!bytes.length || bytes.length > 2 * 1024 * 1024) return nil;
    NSDictionary *registry = [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil];
    if (![registry isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *apps = [registry[@"apps"] isKindOfClass:NSDictionary.class] ? registry[@"apps"] : nil;
    NSDictionary *aliases = [registry[@"aliases"] isKindOfClass:NSDictionary.class] ? registry[@"aliases"] : @{};
    NSString *owner = NKCOwnerForBundle(bundleID, aliases);
    if (!owner || [owner hasPrefix:@"com.apple."]) return nil;
    NSDictionary *entry = [apps[owner] isKindOfClass:NSDictionary.class] ? apps[owner] : nil;
    if (![entry[@"enabled"] isKindOfClass:NSNumber.class] || ![entry[@"enabled"] boolValue]) return nil;
    NSString *active = [entry[@"active"] isKindOfClass:NSString.class] ? entry[@"active"] : nil;
    if (!active.length) return nil;

    NSString *value = [active isEqualToString:@"default"] ? @"DEFAULT" : active;
    NSString *candidate = [NSString stringWithFormat:@"%@=%@", NKCRBContextKey, value];
    const char *strings[] = {candidate.UTF8String};
    NKCLaunchCapsule capsule = NKCParseEnvStrings(strings, 1);
    if (capsule.status != NKC_CAPSULE_DEFAULT && capsule.status != NKC_CAPSULE_NAMED) return nil;
    return value;
}

static void NKCApplyLaunchCapsule(id request) {
    @try {
        id context = NKCInvokeGetter(request, @"context");
        if (!context ||
            ![context respondsToSelector:NSSelectorFromString(@"_additionalEnvironment")] ||
            ![context respondsToSelector:NSSelectorFromString(@"_setAdditionalEnvironment:")]) return;
        NSString *bundleID = NKCBundleForLaunchRequest(request);
        if (!bundleID) return;

        NSString *value = NKCSelectedCapsuleForBundle(bundleID);
        if (!value) return;
        id current = NKCInvokeGetter(context, @"_additionalEnvironment");
        if (current && ![current isKindOfClass:NSDictionary.class]) return;
        if ([current objectForKey:NKCRBContextKey]) return;  // never overwrite Apple/previous launch context

        NSMutableDictionary *updated = [current mutableCopy] ?: [NSMutableDictionary dictionary];
        updated[NKCRBContextKey] = value;
        ((void (*)(id, SEL, id))objc_msgSend)(context,
            NSSelectorFromString(@"_setAdditionalEnvironment:"), updated);
        NSLog(@"[NKCraneRB experimental] launch %@ capsule=%@", bundleID, value);
    } @catch (NSException *exception) {
        NSLog(@"[NKCraneRB experimental] skipped request after %@ exception", exception.name);
    }
}

static id NKCPublicWithError(id self, SEL cmd, id request, NSError **error) {
    NKCApplyLaunchCapsule(request);
    return sOrigPublicError ? sOrigPublicError(self, cmd, request, error) : nil;
}

static id NKCPrivateWithError(id self, SEL cmd, id request, NSError **error) {
    NKCApplyLaunchCapsule(request);
    return sOrigPrivateError ? sOrigPrivateError(self, cmd, request, error) : nil;
}

static void NKCWithCompletion(id self, SEL cmd, id request, id completion) {
    NKCApplyLaunchCapsule(request);
    if (sOrigCompletion) sOrigCompletion(self, cmd, request, completion);
}

static void NKCTryInstall(Class cls, const char *methodName, IMP replacement, IMP *original, char expectedReturn) {
    SEL selector = sel_registerName(methodName);
    Method method = class_getInstanceMethod(cls, selector);
    if (!method || method_getNumberOfArguments(method) != 4) return;
    char returnType[8] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    if (returnType[0] != expectedReturn) {
        NSLog(@"[NKCraneRB experimental] skip %s: return type %s not expected %c",
              methodName, returnType, expectedReturn);
        return;
    }
    MSHookMessageEx(cls, selector, replacement, original);
    NSLog(@"[NKCraneRB experimental] hooked %s", methodName);
}

__attribute__((constructor))
static void NKCInstallRunningBoardLaunchBridge(void) {
    @autoreleasepool {
        NSString *executable = [NSProcessInfo.processInfo.arguments.firstObject lastPathComponent];
        if (![executable isEqualToString:@"runningboardd"]) return;
        if (!NKCRegistryReadableForRunningBoard()) {
            NSLog(@"[NKCraneRB experimental] registry unavailable; no launch hooks installed");
            return;
        }
        Class cls = objc_getClass("RBProcessManager");
        if (!cls) {
            NSLog(@"[NKCraneRB experimental] RBProcessManager unavailable; disabled");
            return;
        }
        // A missing/private signature means no hook; never force it.
        NKCTryInstall(cls, "executeLaunchRequest:withError:",
                      (IMP)NKCPublicWithError, (IMP *)&sOrigPublicError, '@');
        NKCTryInstall(cls, "_executeLaunchRequest:withError:",
                      (IMP)NKCPrivateWithError, (IMP *)&sOrigPrivateError, '@');
        NKCTryInstall(cls, "executeLaunchRequest:withCompletion:",
                      (IMP)NKCWithCompletion, (IMP *)&sOrigCompletion, 'v');
    }
}
