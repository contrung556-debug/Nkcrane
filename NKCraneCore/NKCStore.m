#import "NKCStore.h"
#import "NKCContainer.h"
#import <dlfcn.h>
#import <objc/message.h>
#import <CoreFoundation/CoreFoundation.h>
#import <sys/stat.h>
#import <errno.h>
#import <unistd.h>

NSString * const NKCDefaultContainerIdentifier = @"default";
NSString * const NKCPreferencesPath = @"/var/mobile/Library/Preferences/com.nktouch.nkcrane.plist";
static CFStringRef const NKCPreferencesDomain = CFSTR("com.nktouch.nkcrane");
static CFStringRef const NKCStoreKey = CFSTR("store");

@interface LSApplicationProxy : NSObject
+ (instancetype)applicationProxyForIdentifier:(NSString *)identifier;
@property (nonatomic, readonly) NSURL *containerURL;
@end

@implementation NKCStore {
    dispatch_queue_t _queue;
}

+ (instancetype)sharedStore {
    static NKCStore *store;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ store = [NKCStore new]; });
    return store;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.nktouch.nkcrane.store", DISPATCH_QUEUE_SERIAL);
        [self ensureStoreExists];
    }
    return self;
}

- (void)ensureStoreExists {
    CFPropertyListRef existing = CFPreferencesCopyAppValue(NKCStoreKey, NKCPreferencesDomain);
    if (existing) {
        CFRelease(existing);
        return;
    }
    NSDictionary *initial = @{ @"version": @4, @"apps": @{}, @"aliases": @{} };
    CFPreferencesSetAppValue(NKCStoreKey, (__bridge CFPropertyListRef)initial, NKCPreferencesDomain);
    CFPreferencesAppSynchronize(NKCPreferencesDomain);
}

- (NSMutableDictionary *)loadMutableStore {
    CFPropertyListRef raw = CFPreferencesCopyAppValue(NKCStoreKey, NKCPreferencesDomain);
    NSDictionary *d = CFBridgingRelease(raw);
    NSMutableDictionary *m = [d isKindOfClass:NSDictionary.class] ? [d mutableCopy] : [NSMutableDictionary dictionary];
    if (![m[@"apps"] isKindOfClass:NSDictionary.class]) m[@"apps"] = @{};
    if (![m[@"aliases"] isKindOfClass:NSDictionary.class]) m[@"aliases"] = @{};
    m[@"version"] = @4;
    return m;
}

- (void)saveStore:(NSDictionary *)store {
    CFPreferencesSetAppValue(NKCStoreKey, (__bridge CFPropertyListRef)store, NKCPreferencesDomain);
    CFPreferencesAppSynchronize(NKCPreferencesDomain);
}

- (NSMutableDictionary *)mutableAppEntry:(NSMutableDictionary *)store bundle:(NSString *)bundle create:(BOOL)create {
    NSMutableDictionary *apps = [store[@"apps"] mutableCopy] ?: [NSMutableDictionary dictionary];
    NSMutableDictionary *entry = [apps[bundle] mutableCopy];
    if (!entry && create) {
        entry = [@{
            @"enabled": @YES,
            @"active": NKCDefaultContainerIdentifier,
            @"containers": @[]
        } mutableCopy];
    }
    if (entry) {
        apps[bundle] = entry;
        store[@"apps"] = apps;
    }
    return entry;
}

- (NSString *)ownerBundleIdentifierForProcessBundleIdentifier:(NSString *)processBundleIdentifier {
    if (!processBundleIdentifier.length) return processBundleIdentifier ?: @"";
    __block NSString *resolved = [processBundleIdentifier copy];
    dispatch_sync(_queue, ^{
        NSDictionary *s = [self loadMutableStore];
        NSDictionary *aliases = s[@"aliases"];
        NSMutableSet<NSString *> *seen = [NSMutableSet set];
        NSString *current = processBundleIdentifier;
        for (NSUInteger i = 0; i < 8; i++) {
            if (!current.length || [seen containsObject:current]) break;
            [seen addObject:current];
            NSString *next = aliases[current];
            if (![next isKindOfClass:NSString.class] || !next.length) break;
            current = next;
        }
        resolved = current ?: processBundleIdentifier;
    });
    return resolved;
}

- (NSArray<NSString *> *)linkedBundleIdentifiersForOwnerBundleIdentifier:(NSString *)ownerBundleIdentifier {
    if (!ownerBundleIdentifier.length) return @[];
    __block NSArray<NSString *> *result = @[];
    dispatch_sync(_queue, ^{
        NSDictionary *s = [self loadMutableStore];
        NSDictionary *aliases = s[@"aliases"];
        NSMutableArray<NSString *> *children = [NSMutableArray array];
        [aliases enumerateKeysAndObjectsUsingBlock:^(NSString *child, NSString *owner, BOOL *stop) {
            if ([owner isEqualToString:ownerBundleIdentifier]) [children addObject:child];
        }];
        [children sortUsingSelector:@selector(compare:)];
        result = [children copy];
    });
    return result;
}

- (BOOL)linkBundleIdentifier:(NSString *)childBundleIdentifier toOwnerBundleIdentifier:(NSString *)ownerBundleIdentifier error:(NSError **)error {
    NSString *child = [childBundleIdentifier stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *owner = [ownerBundleIdentifier stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!child.length || !owner.length || [child isEqualToString:owner]) {
        if (error) *error = [NSError errorWithDomain:@"NKCrane" code:400 userInfo:@{NSLocalizedDescriptionKey:@"Owner and child bundle IDs must be non-empty and different"}];
        return NO;
    }

    __block BOOL cycle = NO;
    dispatch_sync(_queue, ^{
        NSMutableDictionary *s = [self loadMutableStore];
        NSMutableDictionary *aliases = [s[@"aliases"] mutableCopy] ?: [NSMutableDictionary dictionary];
        NSString *current = owner;
        NSMutableSet<NSString *> *seen = [NSMutableSet setWithObject:child];
        for (NSUInteger i = 0; i < 8; i++) {
            if ([seen containsObject:current]) { cycle = YES; break; }
            [seen addObject:current];
            NSString *next = aliases[current];
            if (![next isKindOfClass:NSString.class] || !next.length) break;
            current = next;
        }
        if (!cycle) {
            aliases[child] = owner;
            s[@"aliases"] = aliases;
            [self saveStore:s];
        }
    });

    if (cycle && error) *error = [NSError errorWithDomain:@"NKCrane" code:409 userInfo:@{NSLocalizedDescriptionKey:@"Bundle-family link would create a cycle"}];
    return !cycle;
}

- (BOOL)unlinkBundleIdentifier:(NSString *)childBundleIdentifier error:(NSError **)error {
    if (!childBundleIdentifier.length) {
        if (error) *error = [NSError errorWithDomain:@"NKCrane" code:400 userInfo:@{NSLocalizedDescriptionKey:@"Child bundle ID is required"}];
        return NO;
    }
    __block BOOL found = NO;
    dispatch_sync(_queue, ^{
        NSMutableDictionary *s = [self loadMutableStore];
        NSMutableDictionary *aliases = [s[@"aliases"] mutableCopy] ?: [NSMutableDictionary dictionary];
        found = aliases[childBundleIdentifier] != nil;
        if (found) {
            [aliases removeObjectForKey:childBundleIdentifier];
            s[@"aliases"] = aliases;
            [self saveStore:s];
        }
    });
    if (!found && error) *error = [NSError errorWithDomain:@"NKCrane" code:404 userInfo:@{NSLocalizedDescriptionKey:@"Bundle-family link not found"}];
    return found;
}

- (BOOL)isEnabledForBundleIdentifier:(NSString *)bundleIdentifier {
    NSString *owner = [self ownerBundleIdentifierForProcessBundleIdentifier:bundleIdentifier];
    __block BOOL enabled = NO;
    dispatch_sync(_queue, ^{
        NSDictionary *s = [self loadMutableStore];
        NSDictionary *entry = s[@"apps"][owner];
        enabled = [entry[@"enabled"] boolValue];
    });
    return enabled;
}

- (void)setEnabled:(BOOL)enabled forBundleIdentifier:(NSString *)bundleIdentifier {
    NSString *owner = [self ownerBundleIdentifierForProcessBundleIdentifier:bundleIdentifier];
    dispatch_sync(_queue, ^{
        NSMutableDictionary *s = [self loadMutableStore];
        NSMutableDictionary *entry = [self mutableAppEntry:s bundle:owner create:YES];
        entry[@"enabled"] = @(enabled);
        [self saveStore:s];
    });
}

- (NSArray<NKCContainer *> *)containersForBundleIdentifier:(NSString *)bundleIdentifier {
    NSString *owner = [self ownerBundleIdentifierForProcessBundleIdentifier:bundleIdentifier];
    __block NSArray *result = @[];
    dispatch_sync(_queue, ^{
        NSDictionary *s = [self loadMutableStore];
        NSArray *raw = s[@"apps"][owner][@"containers"];
        NSMutableArray *out = [NSMutableArray array];
        for (id obj in raw) {
            if ([obj isKindOfClass:NSDictionary.class]) [out addObject:[NKCContainer containerWithDictionary:obj]];
        }
        result = [out copy];
    });
    return result;
}

- (NKCContainer *)containerForIdentifierOrName:(NSString *)value bundleIdentifier:(NSString *)bundleIdentifier {
    if ([value isEqualToString:NKCDefaultContainerIdentifier] || [value caseInsensitiveCompare:@"Default"] == NSOrderedSame) {
        NKCContainer *c = [NKCContainer new];
        c.identifier = NKCDefaultContainerIdentifier;
        c.name = @"Default";
        c.createdAt = [NSDate distantPast];
        return c;
    }
    for (NKCContainer *c in [self containersForBundleIdentifier:bundleIdentifier]) {
        if ([c.identifier isEqualToString:value] || [c.name caseInsensitiveCompare:value] == NSOrderedSame) return c;
    }
    return nil;
}

- (NKCContainer *)createContainerNamed:(NSString *)name bundleIdentifier:(NSString *)bundleIdentifier {
    NSString *owner = [self ownerBundleIdentifierForProcessBundleIdentifier:bundleIdentifier];
    __block NKCContainer *created;
    dispatch_sync(_queue, ^{
        NSMutableDictionary *s = [self loadMutableStore];
        NSMutableDictionary *entry = [self mutableAppEntry:s bundle:owner create:YES];
        NSMutableArray *containers = [entry[@"containers"] mutableCopy] ?: [NSMutableArray array];

        created = [NKCContainer new];
        created.identifier = NSUUID.UUID.UUIDString.lowercaseString;
        created.name = name.length ? name : [NSString stringWithFormat:@"Container %lu", (unsigned long)containers.count + 1];
        created.createdAt = [NSDate date];
        [containers addObject:created.dictionaryRepresentation];
        entry[@"containers"] = containers;
        entry[@"enabled"] = @YES;
        [self saveStore:s];
    });
    [self rootPathForContainerIdentifier:created.identifier bundleIdentifier:owner create:YES];
    return created;
}

- (NSString *)activeContainerIdentifierForBundleIdentifier:(NSString *)bundleIdentifier {
    NSString *owner = [self ownerBundleIdentifierForProcessBundleIdentifier:bundleIdentifier];
    __block NSString *active = NKCDefaultContainerIdentifier;
    dispatch_sync(_queue, ^{
        NSDictionary *s = [self loadMutableStore];
        NSString *v = s[@"apps"][owner][@"active"];
        if ([v isKindOfClass:NSString.class] && v.length) active = v;
    });
    return active;
}

- (BOOL)setActiveContainerIdentifier:(NSString *)identifier bundleIdentifier:(NSString *)bundleIdentifier error:(NSError **)error {
    NSString *owner = [self ownerBundleIdentifierForProcessBundleIdentifier:bundleIdentifier];
    if (![identifier isEqualToString:NKCDefaultContainerIdentifier] && ![self containerForIdentifierOrName:identifier bundleIdentifier:owner]) {
        if (error) *error = [NSError errorWithDomain:@"NKCrane" code:404 userInfo:@{NSLocalizedDescriptionKey:@"Container not found"}];
        return NO;
    }
    dispatch_sync(_queue, ^{
        NSMutableDictionary *s = [self loadMutableStore];
        NSMutableDictionary *entry = [self mutableAppEntry:s bundle:owner create:YES];
        entry[@"active"] = identifier;
        entry[@"enabled"] = @YES;
        entry[@"last_switch_at"] = @([NSDate.date timeIntervalSince1970]);
        [self saveStore:s];
    });
    return YES;
}

- (BOOL)renameContainer:(NSString *)identifier toName:(NSString *)newName bundleIdentifier:(NSString *)bundleIdentifier error:(NSError **)error {
    NSString *owner = [self ownerBundleIdentifierForProcessBundleIdentifier:bundleIdentifier];
    NSString *trimmed = [newName stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([identifier isEqualToString:NKCDefaultContainerIdentifier]) {
        if (error) *error = [NSError errorWithDomain:@"NKCrane" code:400 userInfo:@{NSLocalizedDescriptionKey:@"Default container cannot be renamed"}];
        return NO;
    }
    if (trimmed.length == 0) {
        if (error) *error = [NSError errorWithDomain:@"NKCrane" code:400 userInfo:@{NSLocalizedDescriptionKey:@"Container name cannot be empty"}];
        return NO;
    }

    __block BOOL found = NO;
    dispatch_sync(_queue, ^{
        NSMutableDictionary *s = [self loadMutableStore];
        NSMutableDictionary *entry = [self mutableAppEntry:s bundle:owner create:NO];
        NSMutableArray *containers = [entry[@"containers"] mutableCopy] ?: [NSMutableArray array];
        for (NSUInteger i = 0; i < containers.count; i++) {
            NSMutableDictionary *obj = [containers[i] mutableCopy];
            if ([obj[@"id"] isEqualToString:identifier]) {
                obj[@"name"] = trimmed;
                containers[i] = obj;
                found = YES;
                break;
            }
        }
        if (found) {
            entry[@"containers"] = containers;
            [self saveStore:s];
        }
    });

    if (!found && error) *error = [NSError errorWithDomain:@"NKCrane" code:404 userInfo:@{NSLocalizedDescriptionKey:@"Container not found"}];
    return found;
}

// v1.4 safety: never infer a destructive target by deleting the parent of a
// potentially swizzled rootPath.  In-app NKCInAppLayout returns a canonical
// <real sandbox>/Library/__NKCrane_Containers/<UUID> root, while older builds
// returned <real sandbox>/.nkcrane/<UUID>/Root. Both must be handled explicitly.
static BOOL NKCValidNamedContainerID(NSString *identifier) {
    if (![identifier isKindOfClass:NSString.class] || identifier.length != 36) return NO;
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:identifier];
    return uuid && [identifier isEqualToString:uuid.UUIDString.lowercaseString];
}

static NSError *NKCDestructiveError(NSInteger code, NSString *reason) {
    return [NSError errorWithDomain:@"NKCrane" code:code
                           userInfo:@{NSLocalizedDescriptionKey:reason}];
}

static BOOL NKCVerifyNoSymlink(NSString *path, NSError **error) {
    struct stat sb = {0};
    if (lstat(path.fileSystemRepresentation, &sb) != 0) {
        if (errno == ENOENT) return YES;
        if (error) *error = NKCDestructiveError(503, [NSString stringWithFormat:@"Cannot inspect path: %@", path]);
        return NO;
    }
    if (S_ISLNK(sb.st_mode)) {
        if (error) *error = NKCDestructiveError(409, [NSString stringWithFormat:@"Refusing symlink in managed data path: %@", path]);
        return NO;
    }
    if (!S_ISDIR(sb.st_mode)) {
        if (error) *error = NKCDestructiveError(409, [NSString stringWithFormat:@"Managed path is not a directory: %@", path]);
        return NO;
    }
    return YES;
}

- (nullable NSString *)nkc_verifiedPhysicalRootForIdentifier:(NSString *)identifier
                                                       owner:(NSString *)owner
                                                  legacyRoot:(NSString * _Nullable * _Nullable)legacyRoot
                                                       error:(NSError **)error {
    if (!NKCValidNamedContainerID(identifier)) {
        if (error) *error = NKCDestructiveError(400, @"Invalid named container UUID; refusing destructive operation");
        return nil;
    }
    NSString *real = [self realDataContainerPathForBundleIdentifier:owner];
    if (!real.length || !real.isAbsolutePath) {
        if (error) *error = NKCDestructiveError(503, @"Real Apple data container unavailable; no files were removed");
        return nil;
    }

    NSString *library = [real stringByAppendingPathComponent:@"Library"];
    NSString *parent = [library stringByAppendingPathComponent:@"__NKCrane_Containers"];
    NSString *physical = [parent stringByAppendingPathComponent:identifier];
    NSString *legacyParent = [[real stringByAppendingPathComponent:@".nkcrane"] stringByAppendingPathComponent:identifier];
    NSString *legacy = [legacyParent stringByAppendingPathComponent:@"Root"];

    // Never follow a malicious symlink out of the app sandbox.
    for (NSString *path in @[real, library, parent, physical, legacyParent]) {
        if (!NKCVerifyNoSymlink(path, error)) return nil;
    }
    NSString *expected = [[parent stringByStandardizingPath] stringByAppendingPathComponent:identifier];
    if (![physical isEqualToString:expected]) {
        if (error) *error = NKCDestructiveError(409, @"Unsafe canonical path");
        return nil;
    }

    struct stat sb = {0};
    if (lstat(legacy.fileSystemRepresentation, &sb) == 0) {
        if (S_ISLNK(sb.st_mode)) {
            NSString *destination = [NSFileManager.defaultManager destinationOfSymbolicLinkAtPath:legacy error:error];
            if (!destination || ![[destination stringByStandardizingPath] isEqualToString:physical]) {
                if (error && !*error) *error = NKCDestructiveError(409, @"Legacy symlink points outside the expected container");
                return nil;
            }
        } else {
            // Legacy-only data must be migrated by the app before deleting.
            if (error) *error = NKCDestructiveError(409, @"Legacy Root contains data; open this named container to migrate it before deleting/wiping");
            return nil;
        }
    } else if (errno != ENOENT) {
        if (error) *error = NKCDestructiveError(503, @"Cannot inspect legacy container path");
        return nil;
    }

    if (legacyRoot) *legacyRoot = legacy;
    return physical;
}

- (BOOL)nkc_preflightDestructiveIdentifier:(NSString *)identifier
                                     owner:(NSString *)owner
                                     error:(NSError **)error {
    if (!NKCValidNamedContainerID(identifier)) {
        if (error) *error = NKCDestructiveError(400, @"Invalid or default container ID");
        return NO;
    }
    __block BOOL exists = NO;
    __block BOOL active = NO;
    dispatch_sync(_queue, ^{
        NSDictionary *entry = [self loadMutableStore][@"apps"][owner];
        for (NSDictionary *item in entry[@"containers"]) {
            if ([item[@"id"] isEqualToString:identifier]) { exists = YES; break; }
        }
        active = [entry[@"active"] isEqualToString:identifier];
    });
    if (!exists && error) *error = NKCDestructiveError(404, @"Named container not found");
    if (active && error) *error = NKCDestructiveError(409, @"Switch away from this container and stop the app before deleting/wiping it");
    return exists && !active;
}

- (BOOL)deleteContainer:(NSString *)identifier bundleIdentifier:(NSString *)bundleIdentifier error:(NSError **)error {
    NSString *owner = [self ownerBundleIdentifierForProcessBundleIdentifier:bundleIdentifier];
    if (![self nkc_preflightDestructiveIdentifier:identifier owner:owner error:error]) return NO;
    NSString *legacy = nil;
    NSString *physical = [self nkc_verifiedPhysicalRootForIdentifier:identifier owner:owner legacyRoot:&legacy error:error];
    if (!physical) return NO;

    NSFileManager *fm = NSFileManager.defaultManager;
    if ([fm fileExistsAtPath:physical] && ![fm removeItemAtPath:physical error:error]) return NO;
    // Only remove a known compatibility symlink, never the legacy parent.
    struct stat sb = {0};
    if (lstat(legacy.fileSystemRepresentation, &sb) == 0 && S_ISLNK(sb.st_mode)) {
        if (![fm removeItemAtPath:legacy error:error]) return NO;
    }

    dispatch_sync(_queue, ^{
        NSMutableDictionary *store = [self loadMutableStore];
        NSMutableDictionary *entry = [self mutableAppEntry:store bundle:owner create:NO];
        NSMutableArray *containers = [entry[@"containers"] mutableCopy] ?: [NSMutableArray array];
        NSIndexSet *matches = [containers indexesOfObjectsPassingTest:^BOOL(NSDictionary *item, NSUInteger idx, BOOL *stop) {
            return [item[@"id"] isEqualToString:identifier];
        }];
        [containers removeObjectsAtIndexes:matches];
        entry[@"containers"] = containers;
        [self saveStore:store];
    });
    return YES;
}

- (BOOL)wipeContainer:(NSString *)identifier bundleIdentifier:(NSString *)bundleIdentifier error:(NSError **)error {
    NSString *owner = [self ownerBundleIdentifierForProcessBundleIdentifier:bundleIdentifier];
    if (![self nkc_preflightDestructiveIdentifier:identifier owner:owner error:error]) return NO;
    NSString *physical = [self nkc_verifiedPhysicalRootForIdentifier:identifier owner:owner legacyRoot:NULL error:error];
    if (!physical) return NO;

    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDirectory = NO;
    if (![fm fileExistsAtPath:physical isDirectory:&isDirectory] || !isDirectory) {
        if (error) *error = NKCDestructiveError(404, @"Canonical container data missing; no files were removed");
        return NO;
    }
    NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:physical error:error];
    if (!items) return NO;
    for (NSString *item in items) {
        if (![fm removeItemAtPath:[physical stringByAppendingPathComponent:item] error:error]) return NO;
    }
    for (NSString *name in @[@"Documents", @"Library", @"Library/Caches", @"Library/Preferences",
                             @"Library/Application Support", @"Library/WebKit", @"Library/Cookies",
                             @"Library/Saved Application State", @"tmp", @"SystemData"]) {
        if (![fm createDirectoryAtPath:[physical stringByAppendingPathComponent:name]
           withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    }
    return YES;
}

- (NSString *)preferencesDomainForBundleIdentifier:(NSString *)bundleIdentifier containerIdentifier:(NSString *)identifier {
    if ([identifier isEqualToString:NKCDefaultContainerIdentifier]) return bundleIdentifier;
    return [NSString stringWithFormat:@"%@.nkcrane.%@", bundleIdentifier, identifier];
}

- (NSString *)realDataContainerPathForBundleIdentifier:(NSString *)bundleIdentifier {
    dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY);
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    if (proxyClass && [proxyClass respondsToSelector:@selector(applicationProxyForIdentifier:)]) {
        id proxy = ((id (*)(id, SEL, id))objc_msgSend)(proxyClass, @selector(applicationProxyForIdentifier:), bundleIdentifier);
        if (proxy && [proxy respondsToSelector:@selector(containerURL)]) {
            NSURL *url = ((id (*)(id, SEL))objc_msgSend)(proxy, @selector(containerURL));
            if ([url isKindOfClass:NSURL.class]) return url.path;
        }
    }

    dlopen("/System/Library/PrivateFrameworks/MobileContainerManager.framework/MobileContainerManager", RTLD_LAZY);
    Class mcm = NSClassFromString(@"MCMAppDataContainer");
    SEL sel = NSSelectorFromString(@"containerWithIdentifier:createIfNecessary:existed:error:");
    if (mcm && [mcm respondsToSelector:sel]) {
        id (*send)(id, SEL, id, BOOL, BOOL *, NSError **) = (void *)objc_msgSend;
        NSError *err = nil;
        id c = send(mcm, sel, bundleIdentifier, NO, NULL, &err);
        SEL urlSel = NSSelectorFromString(@"url");
        if (c && [c respondsToSelector:urlSel]) {
            NSURL *url = ((id (*)(id, SEL))objc_msgSend)(c, urlSel);
            if ([url isKindOfClass:NSURL.class]) return url.path;
        }
    }
    return nil;
}

- (NSString *)rootPathForContainerIdentifier:(NSString *)identifier bundleIdentifier:(NSString *)bundleIdentifier create:(BOOL)create {
    NSString *owner = [self ownerBundleIdentifierForProcessBundleIdentifier:bundleIdentifier];
    if ([identifier isEqualToString:NKCDefaultContainerIdentifier]) return [self realDataContainerPathForBundleIdentifier:owner];
    NSString *real = [self realDataContainerPathForBundleIdentifier:owner];
    if (!real.length) return nil;

    NSString *base = [real stringByAppendingPathComponent:@".nkcrane"];
    NSString *dir = [base stringByAppendingPathComponent:identifier];
    NSString *root = [dir stringByAppendingPathComponent:@"Root"];
    if (create) {
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
            [fm createDirectoryAtPath:[root stringByAppendingPathComponent:relative] withIntermediateDirectories:YES attributes:nil error:nil];
        }
    }
    return [NSFileManager.defaultManager fileExistsAtPath:root] ? root : nil;
}

@end
