#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "NKCStore.h"
#import "NKCContainer.h"

// v1.2 clean-room storage layout bridge.
// Physical container data lives inside the owning app sandbox:
//   <real home>/Library/__NKCrane_Containers/<container-id>/
// The legacy path used by the current thin shim remains as a compatibility
// symlink:
//   <real home>/.nkcrane/<container-id>/Root -> physical path
// This lets us move the data plane to the Crane-style in-sandbox layout
// without adding another filesystem hook layer.

static NKCContainer *(*orig_createContainer)(id, SEL, NSString *, NSString *) = NULL;
static BOOL (*orig_setActiveContainer)(id, SEL, NSString *, NSString *, NSError **) = NULL;
static BOOL (*orig_deleteContainer)(id, SEL, NSString *, NSString *, NSError **) = NULL;
static BOOL (*orig_wipeContainer)(id, SEL, NSString *, NSString *, NSError **) = NULL;

static NSString * const NKCContainerDirectoryName = @"__NKCrane_Containers";

static NSError *NKCLayoutError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"NKCrane.Layout" code:code userInfo:@{NSLocalizedDescriptionKey: message ?: @"NKCrane layout error"}];
}

static NSString *NKCResolvedIdentifier(NKCStore *store, NSString *value, NSString *bundle) {
    if (!value.length) return value ?: @"";
    if ([value isEqualToString:NKCDefaultContainerIdentifier]) return value;
    NKCContainer *container = [store containerForIdentifierOrName:value bundleIdentifier:bundle];
    return container.identifier.length ? container.identifier : value;
}

static NSString *NKCPhysicalContainerRoot(NKCStore *store, NSString *bundle, NSString *identifier) {
    NSString *owner = [store ownerBundleIdentifierForProcessBundleIdentifier:bundle];
    NSString *real = [store realDataContainerPathForBundleIdentifier:owner];
    if (!real.length || !identifier.length || [identifier isEqualToString:NKCDefaultContainerIdentifier]) return nil;
    return [[[[real stringByAppendingPathComponent:@"Library"]
               stringByAppendingPathComponent:NKCContainerDirectoryName]
               stringByAppendingPathComponent:identifier] copy];
}

static NSString *NKCLegacyContainerRoot(NKCStore *store, NSString *bundle, NSString *identifier) {
    NSString *owner = [store ownerBundleIdentifierForProcessBundleIdentifier:bundle];
    NSString *real = [store realDataContainerPathForBundleIdentifier:owner];
    if (!real.length || !identifier.length || [identifier isEqualToString:NKCDefaultContainerIdentifier]) return nil;
    return [[[[real stringByAppendingPathComponent:@".nkcrane"]
               stringByAppendingPathComponent:identifier]
               stringByAppendingPathComponent:@"Root"] copy];
}

static BOOL NKCEnsureVirtualHomeTree(NSString *root, NSError **error) {
    if (!root.length) {
        if (error) *error = NKCLayoutError(400, @"Physical container root is unavailable");
        return NO;
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSString *> *directories = @[
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
    for (NSString *relative in directories) {
        NSString *path = [root stringByAppendingPathComponent:relative];
        if (![fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    }
    return YES;
}

static BOOL NKCPathIsSymlink(NSString *path, NSString **destinationOut) {
    if (!path.length) return NO;
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    if (![attributes[NSFileType] isEqualToString:NSFileTypeSymbolicLink]) return NO;
    NSString *destination = [NSFileManager.defaultManager destinationOfSymbolicLinkAtPath:path error:nil];
    if (destinationOut) *destinationOut = destination;
    return YES;
}

static void NKCMoveMissingLegacyItems(NSString *legacyRoot, NSString *physicalRoot) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:legacyRoot error:nil] ?: @[];
    for (NSString *name in items) {
        NSString *source = [legacyRoot stringByAppendingPathComponent:name];
        NSString *destination = [physicalRoot stringByAppendingPathComponent:name];
        if (![fm fileExistsAtPath:destination]) {
            [fm moveItemAtPath:source toPath:destination error:nil];
        }
    }
}

static BOOL NKCEnsureContainerLayout(NKCStore *store, NSString *bundle, NSString *rawIdentifier, NSError **error) {
    NSString *owner = [store ownerBundleIdentifierForProcessBundleIdentifier:bundle];
    NSString *identifier = NKCResolvedIdentifier(store, rawIdentifier, owner);
    if (!identifier.length || [identifier isEqualToString:NKCDefaultContainerIdentifier]) return YES;

    NSString *physicalRoot = NKCPhysicalContainerRoot(store, owner, identifier);
    NSString *legacyRoot = NKCLegacyContainerRoot(store, owner, identifier);
    if (!physicalRoot.length || !legacyRoot.length) {
        if (error) *error = NKCLayoutError(404, @"Could not resolve app sandbox for container layout");
        return NO;
    }

    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *physicalBase = [physicalRoot stringByDeletingLastPathComponent];
    if (![fm createDirectoryAtPath:physicalBase withIntermediateDirectories:YES attributes:nil error:error]) return NO;

    BOOL physicalIsDir = NO;
    BOOL physicalExists = [fm fileExistsAtPath:physicalRoot isDirectory:&physicalIsDir] && physicalIsDir;

    BOOL legacyIsDir = NO;
    BOOL legacyExists = [fm fileExistsAtPath:legacyRoot isDirectory:&legacyIsDir];
    NSString *existingLinkDestination = nil;
    BOOL legacyIsSymlink = legacyExists && NKCPathIsSymlink(legacyRoot, &existingLinkDestination);

    // First upgrade from <=1.1: atomically move the old real Root directory to
    // the new in-sandbox physical location when possible.
    if (!physicalExists && legacyExists && legacyIsDir && !legacyIsSymlink) {
        NSError *moveError = nil;
        if ([fm moveItemAtPath:legacyRoot toPath:physicalRoot error:&moveError]) {
            physicalExists = YES;
            physicalIsDir = YES;
            legacyExists = NO;
        } else {
            if (error) *error = moveError ?: NKCLayoutError(500, @"Could not migrate legacy container root");
            return NO;
        }
    }

    if (!physicalExists) {
        if (![fm createDirectoryAtPath:physicalRoot withIntermediateDirectories:YES attributes:nil error:error]) return NO;
        physicalExists = YES;
    }
    if (!NKCEnsureVirtualHomeTree(physicalRoot, error)) return NO;

    // If both old and new real directories somehow exist, preserve conflicts in
    // a timestamped legacy backup while moving non-conflicting items forward.
    legacyExists = [fm fileExistsAtPath:legacyRoot isDirectory:&legacyIsDir];
    legacyIsSymlink = legacyExists && NKCPathIsSymlink(legacyRoot, &existingLinkDestination);
    if (legacyExists && legacyIsDir && !legacyIsSymlink) {
        NKCMoveMissingLegacyItems(legacyRoot, physicalRoot);
        NSString *legacyParent = [legacyRoot stringByDeletingLastPathComponent];
        NSString *backup = [legacyParent stringByAppendingPathComponent:
                            [NSString stringWithFormat:@"Root.legacy-%.0f", [NSDate.date timeIntervalSince1970]]];
        NSError *backupError = nil;
        if (![fm moveItemAtPath:legacyRoot toPath:backup error:&backupError]) {
            if (error) *error = backupError ?: NKCLayoutError(501, @"Could not preserve legacy container data");
            return NO;
        }
        legacyExists = NO;
    }

    NSString *legacyParent = [legacyRoot stringByDeletingLastPathComponent];
    if (![fm createDirectoryAtPath:legacyParent withIntermediateDirectories:YES attributes:nil error:error]) return NO;

    NSString *linkDestination = nil;
    BOOL linkExists = [fm fileExistsAtPath:legacyRoot] && NKCPathIsSymlink(legacyRoot, &linkDestination);
    if (linkExists && ![linkDestination isEqualToString:physicalRoot]) {
        if (![fm removeItemAtPath:legacyRoot error:error]) return NO;
        linkExists = NO;
    }
    if (!linkExists) {
        if ([fm fileExistsAtPath:legacyRoot] && ![fm removeItemAtPath:legacyRoot error:error]) return NO;
        if (![fm createSymbolicLinkAtPath:legacyRoot withDestinationPath:physicalRoot error:error]) return NO;
    }

    NSDictionary *marker = @{
        @"layout": @"in-sandbox-v1",
        @"version": @"1.2.0",
        @"container_id": identifier,
        @"physical_root": physicalRoot,
        @"compatibility_root": legacyRoot,
        @"timestamp": @([NSDate.date timeIntervalSince1970])
    };
    NSData *markerData = [NSJSONSerialization dataWithJSONObject:marker options:NSJSONWritingPrettyPrinted error:nil];
    if (markerData) [markerData writeToFile:[physicalRoot stringByAppendingPathComponent:@".nkcrane-layout.json"] options:NSDataWritingAtomic error:nil];
    return YES;
}

static NKCContainer *NKC_createContainer(id self, SEL _cmd, NSString *name, NSString *bundle) {
    NKCContainer *container = orig_createContainer ? orig_createContainer(self, _cmd, name, bundle) : nil;
    if (container.identifier.length) {
        NSError *layoutError = nil;
        if (!NKCEnsureContainerLayout((NKCStore *)self, bundle, container.identifier, &layoutError)) {
            NSLog(@"[NKCrane 1.2] create layout warning: %@", layoutError.localizedDescription);
        }
    }
    return container;
}

static BOOL NKC_setActiveContainer(id self, SEL _cmd, NSString *identifier, NSString *bundle, NSError **error) {
    NKCStore *store = (NKCStore *)self;
    NSString *resolved = NKCResolvedIdentifier(store, identifier, bundle);
    if (![resolved isEqualToString:NKCDefaultContainerIdentifier]) {
        NSError *layoutError = nil;
        if (!NKCEnsureContainerLayout(store, bundle, resolved, &layoutError)) {
            if (error) *error = layoutError;
            return NO;
        }
    }
    return orig_setActiveContainer ? orig_setActiveContainer(self, _cmd, identifier, bundle, error) : NO;
}

static BOOL NKC_deleteContainer(id self, SEL _cmd, NSString *identifier, NSString *bundle, NSError **error) {
    NKCStore *store = (NKCStore *)self;
    NSString *resolved = NKCResolvedIdentifier(store, identifier, bundle);
    NSString *physicalRoot = NKCPhysicalContainerRoot(store, bundle, resolved);
    BOOL ok = orig_deleteContainer ? orig_deleteContainer(self, _cmd, identifier, bundle, error) : NO;
    if (ok && physicalRoot.length) {
        [NSFileManager.defaultManager removeItemAtPath:physicalRoot error:nil];
    }
    return ok;
}

static BOOL NKC_wipeContainer(id self, SEL _cmd, NSString *identifier, NSString *bundle, NSError **error) {
    NKCStore *store = (NKCStore *)self;
    NSString *resolved = NKCResolvedIdentifier(store, identifier, bundle);
    if ([resolved isEqualToString:NKCDefaultContainerIdentifier]) {
        return orig_wipeContainer ? orig_wipeContainer(self, _cmd, identifier, bundle, error) : NO;
    }

    NSString *physicalRoot = NKCPhysicalContainerRoot(store, bundle, resolved);
    if (physicalRoot.length && [NSFileManager.defaultManager fileExistsAtPath:physicalRoot]) {
        NSError *removeError = nil;
        if (![NSFileManager.defaultManager removeItemAtPath:physicalRoot error:&removeError]) {
            if (error) *error = removeError;
            return NO;
        }
    }

    BOOL ok = orig_wipeContainer ? orig_wipeContainer(self, _cmd, identifier, bundle, error) : NO;
    if (!ok) return NO;

    NSError *layoutError = nil;
    if (!NKCEnsureContainerLayout(store, bundle, resolved, &layoutError)) {
        if (error) *error = layoutError;
        return NO;
    }
    return YES;
}

__attribute__((constructor))
static void NKCInstallContainerLayoutBridge(void) {
    @autoreleasepool {
        Class cls = NKCStore.class;
        Method m = class_getInstanceMethod(cls, @selector(createContainerNamed:bundleIdentifier:));
        if (m) { orig_createContainer = (void *)method_getImplementation(m); method_setImplementation(m, (IMP)NKC_createContainer); }
        m = class_getInstanceMethod(cls, @selector(setActiveContainerIdentifier:bundleIdentifier:error:));
        if (m) { orig_setActiveContainer = (void *)method_getImplementation(m); method_setImplementation(m, (IMP)NKC_setActiveContainer); }
        m = class_getInstanceMethod(cls, @selector(deleteContainer:bundleIdentifier:error:));
        if (m) { orig_deleteContainer = (void *)method_getImplementation(m); method_setImplementation(m, (IMP)NKC_deleteContainer); }
        m = class_getInstanceMethod(cls, @selector(wipeContainer:bundleIdentifier:error:));
        if (m) { orig_wipeContainer = (void *)method_getImplementation(m); method_setImplementation(m, (IMP)NKC_wipeContainer); }
    }
}
