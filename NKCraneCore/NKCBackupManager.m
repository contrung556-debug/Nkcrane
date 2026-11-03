#import "NKCBackupManager.h"
#import "NKCStore.h"
#import "NKCContainer.h"
#import "NKCKeychainArchive.h"
#import <CoreFoundation/CoreFoundation.h>
#import <sys/stat.h>

static NSString * const NKCBackupErrorDomain = @"NKCrane.Backup";
static NSString * const NKCSharedAppGroupRoot = @"/var/mobile/Containers/Shared/AppGroup";

@implementation NKCBackupManager

+ (NSString *)defaultBackupRoot {
    return @"/var/mobile/Library/NKCrane/Backups";
}

+ (NSString *)safePathComponent:(NSString *)value {
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"];
    NSMutableString *out = [NSMutableString stringWithCapacity:value.length];
    for (NSUInteger i = 0; i < value.length; i++) {
        unichar c = [value characterAtIndex:i];
        NSString *s = [NSString stringWithCharacters:&c length:1];
        [out appendString:[s rangeOfCharacterFromSet:allowed].location != NSNotFound ? s : @"_"];
    }
    return out.length ? out : @"unknown";
}

+ (BOOL)ensureDirectory:(NSString *)path error:(NSError **)error {
    BOOL ok = [NSFileManager.defaultManager createDirectoryAtPath:path
                                      withIntermediateDirectories:YES
                                                       attributes:@{NSFilePosixPermissions:@0700}
                                                            error:error];
    if (ok) chmod(path.fileSystemRepresentation, 0700);
    return ok;
}

+ (NSString *)defaultBackupDirectoryForBundleIdentifier:(NSString *)bundleIdentifier {
    NSString *owner = [NKCStore.sharedStore ownerBundleIdentifierForProcessBundleIdentifier:bundleIdentifier];
    return [[self defaultBackupRoot] stringByAppendingPathComponent:[self safePathComponent:owner]];
}

+ (BOOL)copyContentsFromDirectory:(NSString *)source
                      toDirectory:(NSString *)destination
                        excluding:(NSSet<NSString *> *)excluded
                            error:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![self ensureDirectory:destination error:error]) return NO;

    NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:source error:error];
    if (!items) return NO;

    for (NSString *name in items) {
        if ([excluded containsObject:name]) continue;
        NSString *src = [source stringByAppendingPathComponent:name];
        NSString *dst = [destination stringByAppendingPathComponent:name];
        [fm removeItemAtPath:dst error:nil];
        if (![fm copyItemAtPath:src toPath:dst error:error]) return NO;
    }
    return YES;
}

+ (NSArray<NSDictionary *> *)virtualAppGroupsForOwner:(NSString *)owner container:(NSString *)container {
    if (!owner.length || !container.length || [container isEqualToString:NKCDefaultContainerIdentifier]) return @[];

    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:NKCSharedAppGroupRoot isDirectory:&isDir] || !isDir) return @[];

    NSString *safeOwner = [self safePathComponent:owner];
    NSString *safeContainer = [self safePathComponent:container];
    NSArray<NSString *> *groupContainers = [fm contentsOfDirectoryAtPath:NKCSharedAppGroupRoot error:nil] ?: @[];
    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];

    for (NSString *uuid in groupContainers) {
        NSString *realParent = [NKCSharedAppGroupRoot stringByAppendingPathComponent:uuid];
        NSString *containerBase = [[[[realParent stringByAppendingPathComponent:@".nkcrane"]
                                      stringByAppendingPathComponent:safeOwner]
                                      stringByAppendingPathComponent:safeContainer] copy];
        BOOL baseIsDir = NO;
        if (![fm fileExistsAtPath:containerBase isDirectory:&baseIsDir] || !baseIsDir) continue;

        NSArray<NSString *> *groups = [fm contentsOfDirectoryAtPath:containerBase error:nil] ?: @[];
        for (NSString *groupKey in groups) {
            NSString *root = [[containerBase stringByAppendingPathComponent:groupKey] stringByAppendingPathComponent:@"Root"];
            BOOL rootIsDir = NO;
            if (![fm fileExistsAtPath:root isDirectory:&rootIsDir] || !rootIsDir) continue;
            [result addObject:@{
                @"group_key": groupKey,
                @"real_parent": realParent,
                @"root": root
            }];
        }
    }
    return result;
}

+ (NSDictionary *)backupAppGroupsForOwner:(NSString *)owner
                                 container:(NSString *)container
                               packagePath:(NSString *)packagePath
                                     error:(NSError **)error {
    NSArray<NSDictionary *> *groups = [self virtualAppGroupsForOwner:owner container:container];
    if (groups.count == 0) return @{@"ok":@YES,@"count":@0,@"entries":@[]};

    NSString *appGroupsRoot = [packagePath stringByAppendingPathComponent:@"AppGroups"];
    if (![self ensureDirectory:appGroupsRoot error:error]) return nil;
    NSMutableArray *entries = [NSMutableArray array];

    NSUInteger index = 0;
    for (NSDictionary *group in groups) {
        NSString *groupKey = group[@"group_key"];
        NSString *sourceRoot = group[@"root"];
        NSString *leaf = [NSString stringWithFormat:@"%03lu-%@", (unsigned long)index++, [self safePathComponent:groupKey]];
        NSString *destinationRoot = [[appGroupsRoot stringByAppendingPathComponent:leaf] stringByAppendingPathComponent:@"Root"];
        if (![self copyContentsFromDirectory:sourceRoot toDirectory:destinationRoot excluding:[NSSet set] error:error]) return nil;
        [entries addObject:@{
            @"group_key": groupKey ?: @"group",
            @"real_parent": group[@"real_parent"] ?: @"",
            @"archive_leaf": leaf
        }];
    }
    return @{@"ok":@YES,@"count":@(entries.count),@"entries":entries};
}

+ (NSString *)resolveRealAppGroupParentForEntry:(NSDictionary *)entry owner:(NSString *)owner {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *stored = entry[@"real_parent"];
    BOOL isDir = NO;
    if ([stored isKindOfClass:NSString.class] && stored.length && [fm fileExistsAtPath:stored isDirectory:&isDir] && isDir) return stored;

    NSString *groupKey = entry[@"group_key"];
    NSString *safeOwner = [self safePathComponent:owner];
    NSArray<NSString *> *containers = [fm contentsOfDirectoryAtPath:NKCSharedAppGroupRoot error:nil] ?: @[];
    for (NSString *uuid in containers) {
        NSString *candidate = [NKCSharedAppGroupRoot stringByAppendingPathComponent:uuid];
        NSString *ownerRoot = [[candidate stringByAppendingPathComponent:@".nkcrane"] stringByAppendingPathComponent:safeOwner];
        BOOL ownerDir = NO;
        if (![fm fileExistsAtPath:ownerRoot isDirectory:&ownerDir] || !ownerDir) continue;
        NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:ownerRoot];
        NSString *relative = nil;
        while ((relative = [enumerator nextObject])) {
            if ([[relative lastPathComponent] isEqualToString:groupKey]) return candidate;
        }
    }
    return nil;
}

+ (BOOL)restoreAppGroupsFromManifest:(NSDictionary *)manifest
                          backupPath:(NSString *)backupPath
                               owner:(NSString *)owner
                           container:(NSString *)container
                               error:(NSError **)error {
    NSArray *entries = [manifest[@"app_groups"] isKindOfClass:NSArray.class] ? manifest[@"app_groups"] : @[];
    if (entries.count == 0) return YES;

    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *safeOwner = [self safePathComponent:owner];
    NSString *safeContainer = [self safePathComponent:container];

    for (NSDictionary *entry in entries) {
        NSString *realParent = [self resolveRealAppGroupParentForEntry:entry owner:owner];
        if (!realParent.length) {
            if (error) *error = [NSError errorWithDomain:NKCBackupErrorDomain code:424 userInfo:@{NSLocalizedDescriptionKey:@"Could not resolve an App Group container while restoring"}];
            return NO;
        }
        NSString *groupKey = entry[@"group_key"] ?: @"group";
        NSString *destinationRoot = [[[[[[realParent stringByAppendingPathComponent:@".nkcrane"]
                                          stringByAppendingPathComponent:safeOwner]
                                          stringByAppendingPathComponent:safeContainer]
                                          stringByAppendingPathComponent:groupKey]
                                          stringByAppendingPathComponent:@"Root"] copy];
        NSString *archiveLeaf = entry[@"archive_leaf"];
        NSString *sourceRoot = [[[backupPath stringByAppendingPathComponent:@"AppGroups"] stringByAppendingPathComponent:archiveLeaf ?: @""] stringByAppendingPathComponent:@"Root"];

        BOOL sourceIsDir = NO;
        if (![fm fileExistsAtPath:sourceRoot isDirectory:&sourceIsDir] || !sourceIsDir) continue;
        [fm removeItemAtPath:destinationRoot error:nil];
        if (![self copyContentsFromDirectory:sourceRoot toDirectory:destinationRoot excluding:[NSSet set] error:error]) return NO;
    }
    return YES;
}

+ (NSDictionary *)manifestForContainer:(NKCContainer *)container
                                  owner:(NSString *)owner
                         appGroupResult:(NSDictionary *)appGroupResult
                        keychainResult:(NSDictionary *)keychainResult {
    BOOL keychainWritten = [keychainResult[@"written"] boolValue];
    BOOL keychainAccessible = [keychainResult[@"accessible"] boolValue];
    NSArray *warnings = [keychainResult[@"warnings"] isKindOfClass:NSArray.class] ? keychainResult[@"warnings"] : @[];
    return @{
        @"format": @"nkcrane-backup",
        @"format_version": @2,
        @"engine_version": @"0.6.0",
        @"owner_bundle_id": owner ?: @"",
        @"source_container_id": container.identifier ?: @"",
        @"source_container_name": container.name ?: @"",
        @"created_at": @([[NSDate date] timeIntervalSince1970]),
        @"includes_filesystem": @YES,
        @"includes_app_groups": @([appGroupResult[@"count"] unsignedIntegerValue] > 0),
        @"app_group_count": appGroupResult[@"count"] ?: @0,
        @"app_groups": appGroupResult[@"entries"] ?: @[],
        @"includes_keychain": @(keychainWritten && keychainAccessible),
        @"keychain_status": keychainResult[@"status"] ?: @"unknown",
        @"keychain_item_count": keychainResult[@"items"] ?: @0,
        @"warnings": warnings
    };
}

+ (NSString *)backupContainerIdentifier:(NSString *)containerIdentifier
                        bundleIdentifier:(NSString *)bundleIdentifier
                             destination:(NSString *)destination
                                   error:(NSError **)error {
    NKCStore *store = NKCStore.sharedStore;
    NSString *owner = [store ownerBundleIdentifierForProcessBundleIdentifier:bundleIdentifier];
    NKCContainer *container = [store containerForIdentifierOrName:containerIdentifier bundleIdentifier:owner];
    if (!container) {
        if (error) *error = [NSError errorWithDomain:NKCBackupErrorDomain code:404 userInfo:@{NSLocalizedDescriptionKey:@"Container not found"}];
        return nil;
    }

    NSString *source = [store rootPathForContainerIdentifier:container.identifier bundleIdentifier:owner create:NO];
    if (!source.length || ![NSFileManager.defaultManager fileExistsAtPath:source]) {
        if (error) *error = [NSError errorWithDomain:NKCBackupErrorDomain code:404 userInfo:@{NSLocalizedDescriptionKey:@"Container data path is unavailable"}];
        return nil;
    }

    NSString *packagePath = destination;
    if (!packagePath.length) {
        NSString *root = [self defaultBackupDirectoryForBundleIdentifier:owner];
        if (![self ensureDirectory:root error:error]) return nil;
        NSDateFormatter *formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"yyyyMMdd-HHmmss";
        NSString *stamp = [formatter stringFromDate:[NSDate date]];
        NSString *shortID = [container.identifier substringToIndex:MIN((NSUInteger)8, container.identifier.length)];
        NSString *leaf = [NSString stringWithFormat:@"%@-%@-%@.nkcb", stamp, [self safePathComponent:container.name], shortID];
        packagePath = [root stringByAppendingPathComponent:leaf];
    }

    NSFileManager *fm = NSFileManager.defaultManager;
    if ([fm fileExistsAtPath:packagePath]) {
        if (error) *error = [NSError errorWithDomain:NKCBackupErrorDomain code:409 userInfo:@{NSLocalizedDescriptionKey:@"Backup destination already exists"}];
        return nil;
    }
    if (![self ensureDirectory:packagePath error:error]) return nil;

    NSString *rootPath = [packagePath stringByAppendingPathComponent:@"Root"];
    if (![self ensureDirectory:rootPath error:error]) return nil;
    NSSet *excluded = [container.identifier isEqualToString:NKCDefaultContainerIdentifier] ? [NSSet setWithObject:@".nkcrane"] : [NSSet set];
    if (![self copyContentsFromDirectory:source toDirectory:rootPath excluding:excluded error:error]) {
        [fm removeItemAtPath:packagePath error:nil];
        return nil;
    }

    NSDictionary *appGroupResult = [self backupAppGroupsForOwner:owner container:container.identifier packagePath:packagePath error:error];
    if (!appGroupResult) {
        [fm removeItemAtPath:packagePath error:nil];
        return nil;
    }

    NSString *keychainPath = [packagePath stringByAppendingPathComponent:@"Keychain.plist"];
    NSDictionary *keychainResult = [NKCKeychainArchive exportForOwnerBundleIdentifier:owner containerIdentifier:container.identifier toPath:keychainPath];
    if (![keychainResult[@"written"] boolValue]) [fm removeItemAtPath:keychainPath error:nil];

    NSDictionary *manifest = [self manifestForContainer:container owner:owner appGroupResult:appGroupResult keychainResult:keychainResult];
    NSData *json = [NSJSONSerialization dataWithJSONObject:manifest options:NSJSONWritingPrettyPrinted error:error];
    NSString *manifestPath = [packagePath stringByAppendingPathComponent:@"manifest.json"];
    if (!json || ![json writeToFile:manifestPath options:NSDataWritingAtomic error:error]) {
        [fm removeItemAtPath:packagePath error:nil];
        return nil;
    }
    chmod(manifestPath.fileSystemRepresentation, 0600);
    chmod(packagePath.fileSystemRepresentation, 0700);
    return packagePath;
}

+ (NSDictionary *)manifestAtBackupPath:(NSString *)backupPath error:(NSError **)error {
    NSString *manifestPath = [backupPath stringByAppendingPathComponent:@"manifest.json"];
    NSData *data = [NSData dataWithContentsOfFile:manifestPath options:0 error:error];
    if (!data) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (![obj isKindOfClass:NSDictionary.class]) {
        if (error) *error = [NSError errorWithDomain:NKCBackupErrorDomain code:422 userInfo:@{NSLocalizedDescriptionKey:@"Invalid backup manifest"}];
        return nil;
    }
    NSDictionary *manifest = obj;
    NSInteger version = [manifest[@"format_version"] integerValue];
    if (![manifest[@"format"] isEqual:@"nkcrane-backup"] || (version != 1 && version != 2)) {
        if (error) *error = [NSError errorWithDomain:NKCBackupErrorDomain code:422 userInfo:@{NSLocalizedDescriptionKey:@"Unsupported backup format"}];
        return nil;
    }
    return manifest;
}

+ (BOOL)restoreBackupAtPath:(NSString *)backupPath
      toContainerIdentifier:(NSString *)containerIdentifier
           bundleIdentifier:(NSString *)bundleIdentifier
                      error:(NSError **)error {
    NKCStore *store = NKCStore.sharedStore;
    NSString *owner = [store ownerBundleIdentifierForProcessBundleIdentifier:bundleIdentifier];
    NKCContainer *target = [store containerForIdentifierOrName:containerIdentifier bundleIdentifier:owner];
    if (!target) {
        if (error) *error = [NSError errorWithDomain:NKCBackupErrorDomain code:404 userInfo:@{NSLocalizedDescriptionKey:@"Target container not found"}];
        return NO;
    }
    if ([target.identifier isEqualToString:NKCDefaultContainerIdentifier]) {
        if (error) *error = [NSError errorWithDomain:NKCBackupErrorDomain code:403 userInfo:@{NSLocalizedDescriptionKey:@"Restoring directly over the Default app container is intentionally disabled"}];
        return NO;
    }

    NSDictionary *manifest = [self manifestAtBackupPath:backupPath error:error];
    if (!manifest) return NO;
    NSString *backupOwner = manifest[@"owner_bundle_id"];
    if ([backupOwner isKindOfClass:NSString.class] && backupOwner.length && ![backupOwner isEqualToString:owner]) {
        if (error) *error = [NSError errorWithDomain:NKCBackupErrorDomain code:409 userInfo:@{NSLocalizedDescriptionKey:@"Backup belongs to a different app family"}];
        return NO;
    }

    NSString *backupRoot = [backupPath stringByAppendingPathComponent:@"Root"];
    BOOL isDir = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:backupRoot isDirectory:&isDir] || !isDir) {
        if (error) *error = [NSError errorWithDomain:NKCBackupErrorDomain code:422 userInfo:@{NSLocalizedDescriptionKey:@"Backup Root directory is missing"}];
        return NO;
    }

    NSString *targetRoot = [store rootPathForContainerIdentifier:target.identifier bundleIdentifier:owner create:YES];
    if (!targetRoot.length) {
        if (error) *error = [NSError errorWithDomain:NKCBackupErrorDomain code:500 userInfo:@{NSLocalizedDescriptionKey:@"Could not resolve target container path"}];
        return NO;
    }

    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSString *> *existing = [fm contentsOfDirectoryAtPath:targetRoot error:error];
    if (!existing) return NO;
    for (NSString *name in existing) {
        if (![fm removeItemAtPath:[targetRoot stringByAppendingPathComponent:name] error:error]) return NO;
    }
    if (![self copyContentsFromDirectory:backupRoot toDirectory:targetRoot excluding:[NSSet set] error:error]) return NO;

    if ([manifest[@"format_version"] integerValue] >= 2 && [manifest[@"includes_app_groups"] boolValue]) {
        if (![self restoreAppGroupsFromManifest:manifest backupPath:backupPath owner:owner container:target.identifier error:error]) return NO;
    }

    if ([manifest[@"format_version"] integerValue] >= 2 && [manifest[@"includes_keychain"] boolValue]) {
        NSString *keychainPath = [backupPath stringByAppendingPathComponent:@"Keychain.plist"];
        NSDictionary *result = [NKCKeychainArchive restoreForOwnerBundleIdentifier:owner containerIdentifier:target.identifier fromPath:keychainPath];
        if (![result[@"ok"] boolValue]) {
            NSArray *warningItems = [result[@"warnings"] isKindOfClass:NSArray.class] ? result[@"warnings"] : @[];
            NSString *warning = [warningItems componentsJoinedByString:@"; "];
            if (error) *error = [NSError errorWithDomain:NKCBackupErrorDomain code:425 userInfo:@{NSLocalizedDescriptionKey: warning.length ? warning : @"Keychain restore was incomplete"}];
            return NO;
        }
    }
    return YES;
}

+ (NKCContainer *)cloneContainerIdentifier:(NSString *)containerIdentifier
                           bundleIdentifier:(NSString *)bundleIdentifier
                                    newName:(NSString *)newName
                                      error:(NSError **)error {
    NKCStore *store = NKCStore.sharedStore;
    NSString *owner = [store ownerBundleIdentifierForProcessBundleIdentifier:bundleIdentifier];
    NKCContainer *sourceContainer = [store containerForIdentifierOrName:containerIdentifier bundleIdentifier:owner];
    if (!sourceContainer) {
        if (error) *error = [NSError errorWithDomain:NKCBackupErrorDomain code:404 userInfo:@{NSLocalizedDescriptionKey:@"Source container not found"}];
        return nil;
    }

    NSString *source = [store rootPathForContainerIdentifier:sourceContainer.identifier bundleIdentifier:owner create:NO];
    if (!source.length) {
        if (error) *error = [NSError errorWithDomain:NKCBackupErrorDomain code:404 userInfo:@{NSLocalizedDescriptionKey:@"Source container data is unavailable"}];
        return nil;
    }

    NKCContainer *created = [store createContainerNamed:newName bundleIdentifier:owner];
    if (!created) {
        if (error) *error = [NSError errorWithDomain:NKCBackupErrorDomain code:500 userInfo:@{NSLocalizedDescriptionKey:@"Could not create destination container"}];
        return nil;
    }

    NSString *destination = [store rootPathForContainerIdentifier:created.identifier bundleIdentifier:owner create:YES];
    NSSet *excluded = [sourceContainer.identifier isEqualToString:NKCDefaultContainerIdentifier] ? [NSSet setWithObject:@".nkcrane"] : [NSSet set];
    if (![self copyContentsFromDirectory:source toDirectory:destination excluding:excluded error:error]) {
        [store deleteContainer:created.identifier bundleIdentifier:owner error:nil];
        return nil;
    }

    NSString *temporary = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"nkcrane-clone-%@.nkcb", NSUUID.UUID.UUIDString.lowercaseString]];
    NSString *backup = [self backupContainerIdentifier:sourceContainer.identifier bundleIdentifier:owner destination:temporary error:nil];
    if (backup) {
        NSDictionary *manifest = [self manifestAtBackupPath:backup error:nil];
        if ([manifest[@"includes_app_groups"] boolValue]) [self restoreAppGroupsFromManifest:manifest backupPath:backup owner:owner container:created.identifier error:nil];
        if ([manifest[@"includes_keychain"] boolValue]) {
            [NKCKeychainArchive restoreForOwnerBundleIdentifier:owner containerIdentifier:created.identifier fromPath:[backup stringByAppendingPathComponent:@"Keychain.plist"]];
        }
        [NSFileManager.defaultManager removeItemAtPath:backup error:nil];
    }
    return created;
}

@end
