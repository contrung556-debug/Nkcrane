#import "NKCBackupManager.h"
#import "NKCStore.h"
#import "NKCContainer.h"

static NSString * const NKCBackupErrorDomain = @"NKCrane.Backup";

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
    return [NSFileManager.defaultManager createDirectoryAtPath:path
                                  withIntermediateDirectories:YES
                                                   attributes:@{NSFilePosixPermissions:@0755}
                                                        error:error];
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

+ (NSDictionary *)manifestForContainer:(NKCContainer *)container owner:(NSString *)owner {
    return @{
        @"format": @"nkcrane-backup",
        @"format_version": @1,
        @"engine_version": @"0.5.0",
        @"owner_bundle_id": owner ?: @"",
        @"source_container_id": container.identifier ?: @"",
        @"source_container_name": container.name ?: @"",
        @"created_at": @([[NSDate date] timeIntervalSince1970]),
        @"includes_filesystem": @YES,
        @"includes_keychain": @NO,
        @"includes_app_groups": @NO
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
        NSString *leaf = [NSString stringWithFormat:@"%@-%@-%@.nkcb", stamp, [self safePathComponent:container.name], [container.identifier substringToIndex:MIN((NSUInteger)8, container.identifier.length)]];
        packagePath = [root stringByAppendingPathComponent:leaf];
    }

    NSFileManager *fm = NSFileManager.defaultManager;
    if ([fm fileExistsAtPath:packagePath]) {
        if (error) *error = [NSError errorWithDomain:NKCBackupErrorDomain code:409 userInfo:@{NSLocalizedDescriptionKey:@"Backup destination already exists"}];
        return nil;
    }

    NSString *rootPath = [packagePath stringByAppendingPathComponent:@"Root"];
    if (![self ensureDirectory:rootPath error:error]) return nil;

    NSSet *excluded = [container.identifier isEqualToString:NKCDefaultContainerIdentifier] ? [NSSet setWithObject:@".nkcrane"] : [NSSet set];
    if (![self copyContentsFromDirectory:source toDirectory:rootPath excluding:excluded error:error]) {
        [fm removeItemAtPath:packagePath error:nil];
        return nil;
    }

    NSDictionary *manifest = [self manifestForContainer:container owner:owner];
    NSData *json = [NSJSONSerialization dataWithJSONObject:manifest options:NSJSONWritingPrettyPrinted error:error];
    if (!json || ![json writeToFile:[packagePath stringByAppendingPathComponent:@"manifest.json"] options:NSDataWritingAtomic error:error]) {
        [fm removeItemAtPath:packagePath error:nil];
        return nil;
    }

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
    if (![manifest[@"format"] isEqual:@"nkcrane-backup"] || [manifest[@"format_version"] integerValue] != 1) {
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

    return [self copyContentsFromDirectory:backupRoot toDirectory:targetRoot excluding:[NSSet set] error:error];
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
    return created;
}

@end
