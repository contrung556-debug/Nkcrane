#import "NKCStore.h"
#import "NKCContainer.h"
#import <dlfcn.h>
#import <objc/message.h>
#import <CoreFoundation/CoreFoundation.h>
#import <sys/stat.h>
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

- (BOOL)deleteContainer:(NSString *)identifier bundleIdentifier:(NSString *)bundleIdentifier error:(NSError **)error {
    NSString *owner = [self ownerBundleIdentifierForProcessBundleIdentifier:bundleIdentifier];
    if ([identifier isEqualToString:NKCDefaultContainerIdentifier]) {
        if (error) *error = [NSError errorWithDomain:@"NKCrane" code:400 userInfo:@{NSLocalizedDescriptionKey:@"Default container cannot be deleted"}];
        return NO;
    }

    __block BOOL found = NO;
    dispatch_sync(_queue, ^{
        NSMutableDictionary *s = [self loadMutableStore];
        NSMutableDictionary *entry = [self mutableAppEntry:s bundle:owner create:NO];
        NSMutableArray *containers = [entry[@"containers"] mutableCopy] ?: [NSMutableArray array];
        NSIndexSet *indexes = [containers indexesOfObjectsPassingTest:^BOOL(NSDictionary *obj, NSUInteger idx, BOOL *stop) {
            return [obj[@"id"] isEqualToString:identifier];
        }];
        found = indexes.count > 0;
        [containers removeObjectsAtIndexes:indexes];
        entry[@"containers"] = containers;
        if ([entry[@"active"] isEqualToString:identifier]) entry[@"active"] = NKCDefaultContainerIdentifier;
        [self saveStore:s];
    });

    if (!found) {
        if (error) *error = [NSError errorWithDomain:@"NKCrane" code:404 userInfo:@{NSLocalizedDescriptionKey:@"Container not found"}];
        return NO;
    }

    NSString *path = [self rootPathForContainerIdentifier:identifier bundleIdentifier:owner create:NO];
    if (path) [NSFileManager.defaultManager removeItemAtPath:[path stringByDeletingLastPathComponent] error:nil];
    return YES;
}

- (BOOL)wipeContainer:(NSString *)identifier bundleIdentifier:(NSString *)bundleIdentifier error:(NSError **)error {
    NSString *owner = [self ownerBundleIdentifierForProcessBundleIdentifier:bundleIdentifier];
    if ([identifier isEqualToString:NKCDefaultContainerIdentifier]) {
        if (error) *error = [NSError errorWithDomain:@"NKCrane" code:400 userInfo:@{NSLocalizedDescriptionKey:@"Refusing to wipe the real/default app container"}];
        return NO;
    }
    NSString *root = [self rootPathForContainerIdentifier:identifier bundleIdentifier:owner create:NO];
    if (!root) {
        if (error) *error = [NSError errorWithDomain:@"NKCrane" code:404 userInfo:@{NSLocalizedDescriptionKey:@"Container path unavailable"}];
        return NO;
    }
    NSString *containerDir = [root stringByDeletingLastPathComponent];
    [NSFileManager.defaultManager removeItemAtPath:containerDir error:nil];
    return [self rootPathForContainerIdentifier:identifier bundleIdentifier:owner create:YES] != nil;
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
