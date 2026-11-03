#import "NKCPhysicalSwap.h"
#import "NKCStore.h"
#import <sys/stat.h>

static NSString * const NKCPhysicalSwapRoot = @"/var/mobile/Library/NKCrane/PhysicalProfiles";
static NSString * const NKCPhysicalSwapErrorDomain = @"NKCrane.PhysicalSwap";

@implementation NKCPhysicalSwap

+ (NSArray<NSString *> *)managedTopLevelDirectories {
    return @[@"Documents", @"Library", @"tmp", @"SystemData"];
}

+ (NSString *)safe:(NSString *)value {
    if (!value.length) return @"unknown";
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"];
    NSMutableString *out = [NSMutableString stringWithCapacity:value.length];
    for (NSUInteger i = 0; i < value.length; i++) {
        unichar c = [value characterAtIndex:i];
        [out appendString:[allowed characterIsMember:c] ? [NSString stringWithCharacters:&c length:1] : @"_"];
    }
    return out.length ? out : @"unknown";
}

+ (NSString *)ownerRoot:(NSString *)owner {
    return [NKCPhysicalSwapRoot stringByAppendingPathComponent:[self safe:owner]];
}

+ (NSString *)profileRoot:(NSString *)owner container:(NSString *)container {
    return [[[self ownerRoot:owner] stringByAppendingPathComponent:@"containers"] stringByAppendingPathComponent:[self safe:container]];
}

+ (NSString *)statePath:(NSString *)owner {
    return [[self ownerRoot:owner] stringByAppendingPathComponent:@"state.json"];
}

+ (BOOL)ensureDirectory:(NSString *)path error:(NSError **)error {
    BOOL ok = [NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:error];
    if (ok) chmod(path.fileSystemRepresentation, 0700);
    return ok;
}

+ (NSDictionary *)readState:(NSString *)owner {
    NSData *data = [NSData dataWithContentsOfFile:[self statePath:owner]];
    if (!data.length) return @{};
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [obj isKindOfClass:NSDictionary.class] ? obj : @{};
}

+ (BOOL)writeState:(NSString *)owner active:(NSString *)active error:(NSError **)error {
    if (![self ensureDirectory:[self ownerRoot:owner] error:error]) return NO;
    NSDictionary *obj = @{
        @"format": @1,
        @"physical_active": active ?: NKCDefaultContainerIdentifier,
        @"updated_at": @([[NSDate date] timeIntervalSince1970])
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:obj options:NSJSONWritingPrettyPrinted error:error];
    return data && [data writeToFile:[self statePath:owner] options:NSDataWritingAtomic error:error];
}

+ (NSString *)physicalActiveForBundleIdentifier:(NSString *)bundleIdentifier {
    NKCStore *store = NKCStore.sharedStore;
    NSString *owner = [store ownerBundleIdentifierForProcessBundleIdentifier:bundleIdentifier];
    NSString *value = [self readState:owner][@"physical_active"];
    return [value isKindOfClass:NSString.class] && value.length ? value : NKCDefaultContainerIdentifier;
}

+ (BOOL)moveDirectoryNamed:(NSString *)name fromRoot:(NSString *)sourceRoot toRoot:(NSString *)destinationRoot error:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *src = [sourceRoot stringByAppendingPathComponent:name];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:src isDirectory:&isDir]) return YES;
    if (!isDir) return YES;

    if (![self ensureDirectory:destinationRoot error:error]) return NO;
    NSString *dst = [destinationRoot stringByAppendingPathComponent:name];
    if ([fm fileExistsAtPath:dst]) {
        if (error) *error = [NSError errorWithDomain:NKCPhysicalSwapErrorDomain code:409 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"Profile destination already contains %@", name]}];
        return NO;
    }
    return [fm moveItemAtPath:src toPath:dst error:error];
}

+ (BOOL)rollbackMovedNames:(NSArray<NSString *> *)names fromRoot:(NSString *)sourceRoot toRoot:(NSString *)destinationRoot {
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *name in [names reverseObjectEnumerator]) {
        NSString *src = [sourceRoot stringByAppendingPathComponent:name];
        NSString *dst = [destinationRoot stringByAppendingPathComponent:name];
        if (![fm fileExistsAtPath:src] || [fm fileExistsAtPath:dst]) continue;
        [self ensureDirectory:destinationRoot error:nil];
        [fm moveItemAtPath:src toPath:dst error:nil];
    }
    return YES;
}

+ (BOOL)switchBundleIdentifier:(NSString *)bundleIdentifier toContainerIdentifier:(NSString *)containerIdentifier error:(NSError **)error {
    NKCStore *store = NKCStore.sharedStore;
    NSString *owner = [store ownerBundleIdentifierForProcessBundleIdentifier:bundleIdentifier];
    NSString *liveRoot = [store realDataContainerPathForBundleIdentifier:owner];
    if (!owner.length || !liveRoot.length) {
        if (error) *error = [NSError errorWithDomain:NKCPhysicalSwapErrorDomain code:404 userInfo:@{NSLocalizedDescriptionKey:@"Real app data container unavailable"}];
        return NO;
    }

    NSString *target = containerIdentifier.length ? containerIdentifier : NKCDefaultContainerIdentifier;
    NSDictionary *state = [self readState:owner];
    NSString *current = [state[@"physical_active"] isKindOfClass:NSString.class] ? state[@"physical_active"] : NKCDefaultContainerIdentifier;
    if ([current isEqualToString:target]) return YES;

    NSString *currentRoot = [self profileRoot:owner container:current];
    NSString *targetRoot = [self profileRoot:owner container:target];
    if (![self ensureDirectory:currentRoot error:error] || ![self ensureDirectory:targetRoot error:error]) return NO;

    NSMutableArray<NSString *> *movedOut = [NSMutableArray array];
    for (NSString *name in [self managedTopLevelDirectories]) {
        BOOL existed = [NSFileManager.defaultManager fileExistsAtPath:[liveRoot stringByAppendingPathComponent:name]];
        if (![self moveDirectoryNamed:name fromRoot:liveRoot toRoot:currentRoot error:error]) {
            [self rollbackMovedNames:movedOut fromRoot:currentRoot toRoot:liveRoot];
            return NO;
        }
        if (existed) [movedOut addObject:name];
    }

    NSMutableArray<NSString *> *movedIn = [NSMutableArray array];
    for (NSString *name in [self managedTopLevelDirectories]) {
        BOOL existed = [NSFileManager.defaultManager fileExistsAtPath:[targetRoot stringByAppendingPathComponent:name]];
        if (![self moveDirectoryNamed:name fromRoot:targetRoot toRoot:liveRoot error:error]) {
            [self rollbackMovedNames:movedIn fromRoot:liveRoot toRoot:targetRoot];
            [self rollbackMovedNames:movedOut fromRoot:currentRoot toRoot:liveRoot];
            return NO;
        }
        if (existed) [movedIn addObject:name];
    }

    if (![self writeState:owner active:target error:error]) {
        [self rollbackMovedNames:movedIn fromRoot:liveRoot toRoot:targetRoot];
        [self rollbackMovedNames:movedOut fromRoot:currentRoot toRoot:liveRoot];
        return NO;
    }
    return YES;
}

+ (NSDictionary *)diagnosticsForBundleIdentifier:(NSString *)bundleIdentifier {
    NKCStore *store = NKCStore.sharedStore;
    NSString *owner = [store ownerBundleIdentifierForProcessBundleIdentifier:bundleIdentifier];
    NSString *physical = [self physicalActiveForBundleIdentifier:owner];
    NSString *logical = [store activeContainerIdentifierForBundleIdentifier:owner] ?: NKCDefaultContainerIdentifier;
    NSString *liveRoot = [store realDataContainerPathForBundleIdentifier:owner] ?: @"";
    return @{
        @"owner": owner ?: @"",
        @"logical_active": logical,
        @"physical_active": physical,
        @"live_root": liveRoot,
        @"profile_root": [self profileRoot:owner container:physical]
    };
}

@end
