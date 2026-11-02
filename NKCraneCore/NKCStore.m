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
    NSDictionary *initial = @{ @"version": @3, @"apps": @{} };
    CFPreferencesSetAppValue(NKCStoreKey, (__bridge CFPropertyListRef)initial, NKCPreferencesDomain);
    CFPreferencesAppSynchronize(NKCPreferencesDomain);
}

- (NSMutableDictionary *)loadMutableStore {
    CFPropertyListRef raw = CFPreferencesCopyAppValue(NKCStoreKey, NKCPreferencesDomain);
    NSDictionary *d = CFBridgingRelease(raw);
    NSMutableDictionary *m = [d isKindOfClass:NSDictionary.class] ? [d mutableCopy] : [NSMutableDictionary dictionary];
    if (![m[@"apps"] isKindOfClass:NSDictionary.class]) m[@"apps"] = @{};
    m[@"version"] = @3;
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

- (BOOL)isEnabledForBundleIdentifier:(NSString *)bundleIdentifier {
    __block BOOL enabled = NO;
    dispatch_sync(_queue, ^{
        NSDictionary *s = [self loadMutableStore];
        NSDictionary *entry = s[@"apps"][bundleIdentifier];
        enabled = [entry[@"enabled"] boolValue];
    });
    return enabled;
}

- (void)setEnabled:(BOOL)enabled forBundleIdentifier:(NSString *)bundleIdentifier {
    dispatch_sync(_queue, ^{
        NSMutableDictionary *s = [self loadMutableStore];
        NSMutableDictionary *entry = [self mutableAppEntry:s bundle:bundleIdentifier create:YES];
        entry[@"enabled"] = @(enabled);
        [self saveStore:s];
    });
}

- (NSArray<NKCContainer *> *)containersForBundleIdentifier:(NSString *)bundleIdentifier {
    __block NSArray *result = @[];
    dispatch_sync(_queue, ^{
        NSDictionary *s = [self loadMutableStore];
        NSArray *raw = s[@"apps"][bundleIdentifier][@"containers"];
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
    __block NKCContainer *created;
    dispatch_sync(_queue, ^{
        NSMutableDictionary *s = [self loadMutableStore];
        NSMutableDictionary *entry = [self mutableAppEntry:s bundle:bundleIdentifier create:YES];
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
    [self rootPathForContainerIdentifier:created.identifier bundleIdentifier:bundleIdentifier create:YES];
    return created;
}

- (NSString *)activeContainerIdentifierForBundleIdentifier:(NSString *)bundleIdentifier {
    __block NSString *active = NKCDefaultContainerIdentifier;
    dispatch_sync(_queue, ^{
        NSDictionary *s = [self loadMutableStore];
        NSString *v = s[@"apps"][bundleIdentifier][@"active"];
        if ([v isKindOfClass:NSString.class] && v.length) active = v;
    });
    return active;
}

- (BOOL)setActiveContainerIdentifier:(NSString *)identifier bundleIdentifier:(NSString *)bundleIdentifier error:(NSError **)error {
    if (![identifier isEqualToString:NKCDefaultContainerIdentifier] && ![self containerForIdentifierOrName:identifier bundleIdentifier:bundleIdentifier]) {
        if (error) *error = [NSError errorWithDomain:@"NKCrane" code:404 userInfo:@{NSLocalizedDescriptionKey:@"Container not found"}];
        return NO;
    }
    dispatch_sync(_queue, ^{
        NSMutableDictionary *s = [self loadMutableStore];
        NSMutableDictionary *entry = [self mutableAppEntry:s bundle:bundleIdentifier create:YES];
        entry[@"active"] = identifier;
        entry[@"enabled"] = @YES;
        entry[@"last_switch_at"] = @([NSDate.date timeIntervalSince1970]);
        [self saveStore:s];
    });
    return YES;
}

- (BOOL)renameContainer:(NSString *)identifier toName:(NSString *)newName bundleIdentifier:(NSString *)bundleIdentifier error:(NSError **)error {
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
        NSMutableDictionary *entry = [self mutableAppEntry:s bundle:bundleIdentifier create:NO];
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
    if ([identifier isEqualToString:NKCDefaultContainerIdentifier]) {
        if (error) *error = [NSError errorWithDomain:@"NKCrane" code:400 userInfo:@{NSLocalizedDescriptionKey:@"Default container cannot be deleted"}];
        return NO;
    }

    __block BOOL found = NO;
    dispatch_sync(_queue, ^{
        NSMutableDictionary *s = [self loadMutableStore];
        NSMutableDictionary *entry = [self mutableAppEntry:s bundle:bundleIdentifier create:NO];
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

    NSString *path = [self rootPathForContainerIdentifier:identifier bundleIdentifier:bundleIdentifier create:NO];
    if (path) [NSFileManager.defaultManager removeItemAtPath:[path stringByDeletingLastPathComponent] error:nil];
    return YES;
}

- (BOOL)wipeContainer:(NSString *)identifier bundleIdentifier:(NSString *)bundleIdentifier error:(NSError **)error {
    if ([identifier isEqualToString:NKCDefaultContainerIdentifier]) {
        if (error) *error = [NSError errorWithDomain:@"NKCrane" code:400 userInfo:@{NSLocalizedDescriptionKey:@"Refusing to wipe the real/default app container"}];
        return NO;
    }
    NSString *root = [self rootPathForContainerIdentifier:identifier bundleIdentifier:bundleIdentifier create:NO];
    if (!root) {
        if (error) *error = [NSError errorWithDomain:@"NKCrane" code:404 userInfo:@{NSLocalizedDescriptionKey:@"Container path unavailable"}];
        return NO;
    }
    NSString *containerDir = [root stringByDeletingLastPathComponent];
    [NSFileManager.defaultManager removeItemAtPath:containerDir error:nil];
    return [self rootPathForContainerIdentifier:identifier bundleIdentifier:bundleIdentifier create:YES] != nil;
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
    if ([identifier isEqualToString:NKCDefaultContainerIdentifier]) return [self realDataContainerPathForBundleIdentifier:bundleIdentifier];
    NSString *real = [self realDataContainerPathForBundleIdentifier:bundleIdentifier];
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
