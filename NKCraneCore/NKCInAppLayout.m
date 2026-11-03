#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "NKCStore.h"

// v1.2.2: resolve non-default app-data roots from inside the target app.
// The target process already owns its sandbox, so it can safely create:
//   <real home>/Library/__NKCrane_Containers/<container-id>/
// without granting nkcranectl cross-sandbox write access.

static NSString *(*orig_rootPath)(id, SEL, NSString *, NSString *, BOOL) = NULL;
static NSString * const NKCInAppContainerDirectory = @"__NKCrane_Containers";

static NSString *NKCRealHomeFromPath(NSString *path) {
    if (!path.length) return nil;
    NSArray<NSString *> *markers = @[@"/.nkcrane/", @"/Library/__NKCrane_Containers/"];
    for (NSString *marker in markers) {
        NSRange r = [path rangeOfString:marker];
        if (r.location != NSNotFound) return [path substringToIndex:r.location];
    }
    return path;
}

static BOOL NKCIsSymlink(NSString *path) {
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    return [attrs[NSFileType] isEqualToString:NSFileTypeSymbolicLink];
}

static BOOL NKCEnsureTree(NSString *root) {
    if (!root.length) return NO;
    NSArray<NSString *> *dirs = @[
        @"Documents",
        @"Library",
        @"Library/Caches",
        @"Library/Preferences",
        @"Library/Application Support",
        @"Library/WebKit",
        @"Library/Cookies",
        @"Library/Saved Application State",
        @"tmp",
        @"SystemData"
    ];
    for (NSString *relative in dirs) {
        NSString *path = [root stringByAppendingPathComponent:relative];
        if (![NSFileManager.defaultManager createDirectoryAtPath:path
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:nil]) return NO;
    }
    return YES;
}

static void NKCMigrateLegacyRoot(NSString *legacyRoot, NSString *physicalRoot) {
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL legacyIsDir = NO;
    BOOL physicalIsDir = NO;
    BOOL legacyExists = [fm fileExistsAtPath:legacyRoot isDirectory:&legacyIsDir];
    BOOL physicalExists = [fm fileExistsAtPath:physicalRoot isDirectory:&physicalIsDir];

    if (!physicalExists && legacyExists && legacyIsDir && !NKCIsSymlink(legacyRoot)) {
        NSString *parent = [physicalRoot stringByDeletingLastPathComponent];
        [fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:nil];
        if ([fm moveItemAtPath:legacyRoot toPath:physicalRoot error:nil]) return;
    }

    if (!physicalExists) {
        [fm createDirectoryAtPath:physicalRoot withIntermediateDirectories:YES attributes:nil error:nil];
    }
}

static void NKCEnsureCompatibilitySymlink(NSString *realHome, NSString *identifier, NSString *physicalRoot) {
    if (!realHome.length || !identifier.length || !physicalRoot.length) return;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *legacyParent = [[realHome stringByAppendingPathComponent:@".nkcrane"] stringByAppendingPathComponent:identifier];
    NSString *legacyRoot = [legacyParent stringByAppendingPathComponent:@"Root"];
    [fm createDirectoryAtPath:legacyParent withIntermediateDirectories:YES attributes:nil error:nil];

    BOOL isDir = NO;
    if ([fm fileExistsAtPath:legacyRoot isDirectory:&isDir]) {
        if (NKCIsSymlink(legacyRoot)) {
            NSString *dest = [fm destinationOfSymbolicLinkAtPath:legacyRoot error:nil];
            if ([dest isEqualToString:physicalRoot]) return;
            [fm removeItemAtPath:legacyRoot error:nil];
        } else {
            // Preserve any leftover legacy directory instead of deleting it.
            NSString *backup = [legacyParent stringByAppendingPathComponent:
                                [NSString stringWithFormat:@"Root.legacy-%.0f", NSDate.date.timeIntervalSince1970]];
            [fm moveItemAtPath:legacyRoot toPath:backup error:nil];
        }
    }
    [fm createSymbolicLinkAtPath:legacyRoot withDestinationPath:physicalRoot error:nil];
}

static NSString *NKC_rootPath(id self, SEL _cmd, NSString *identifier, NSString *bundleIdentifier, BOOL create) {
    if (!identifier.length || [identifier isEqualToString:NKCDefaultContainerIdentifier]) {
        return orig_rootPath ? orig_rootPath(self, _cmd, identifier, bundleIdentifier, create) : nil;
    }

    // Ask the original resolver for the legacy location only to recover the real sandbox root.
    NSString *legacyRoot = orig_rootPath ? orig_rootPath(self, _cmd, identifier, bundleIdentifier, NO) : nil;
    NSString *realHome = NKCRealHomeFromPath(legacyRoot);
    if (!realHome.length) {
        realHome = NKCRealHomeFromPath(NSHomeDirectory());
    }
    if (!realHome.length) return nil;

    NSString *physicalRoot = [[[[realHome stringByAppendingPathComponent:@"Library"]
                                stringByAppendingPathComponent:NKCInAppContainerDirectory]
                                stringByAppendingPathComponent:identifier] copy];

    if (create) {
        NSString *derivedLegacyRoot = [[[realHome stringByAppendingPathComponent:@".nkcrane"]
                                        stringByAppendingPathComponent:identifier]
                                        stringByAppendingPathComponent:@"Root"];
        NKCMigrateLegacyRoot(derivedLegacyRoot, physicalRoot);
        if (!NKCEnsureTree(physicalRoot)) return nil;
        NKCEnsureCompatibilitySymlink(realHome, identifier, physicalRoot);

        NSDictionary *marker = @{
            @"layout": @"in-app-sandbox-v2",
            @"version": @"1.2.2",
            @"container_id": identifier,
            @"physical_root": physicalRoot,
            @"timestamp": @(NSDate.date.timeIntervalSince1970)
        };
        NSData *data = [NSJSONSerialization dataWithJSONObject:marker options:NSJSONWritingPrettyPrinted error:nil];
        if (data) [data writeToFile:[physicalRoot stringByAppendingPathComponent:@".nkcrane-layout.json"]
                            options:NSDataWritingAtomic error:nil];
    }

    BOOL isDir = NO;
    return [NSFileManager.defaultManager fileExistsAtPath:physicalRoot isDirectory:&isDir] && isDir ? physicalRoot : nil;
}

__attribute__((constructor(120)))
static void NKCInstallInAppLayoutResolver(void) {
    @autoreleasepool {
        NSString *bundle = NSBundle.mainBundle.bundleIdentifier;
        if (!bundle.length || [bundle hasPrefix:@"com.apple."] || [bundle isEqualToString:@"com.nktouch.nkcrane.manager"]) return;

        Class cls = NKCStore.class;
        SEL sel = @selector(rootPathForContainerIdentifier:bundleIdentifier:create:);
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) return;
        orig_rootPath = (void *)method_getImplementation(m);
        method_setImplementation(m, (IMP)NKC_rootPath);
    }
}
