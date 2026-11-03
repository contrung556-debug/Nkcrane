#import "NKCKeychainArchive.h"
#import <Security/Security.h>
#import <sys/stat.h>

static NSString * const NKCKeychainSyntheticIdentity = @"__nkcrane_anon__";

@implementation NKCKeychainArchive

+ (NSString *)prefixForOwner:(NSString *)owner container:(NSString *)container {
    return [NSString stringWithFormat:@"nkcrane|%@|%@|", owner ?: @"", container ?: @""];
}

+ (BOOL)value:(id)value hasPrefix:(NSString *)prefix {
    return [value isKindOfClass:NSString.class] && [(NSString *)value hasPrefix:prefix];
}

+ (BOOL)item:(NSDictionary *)item classValue:(id)secClass belongsToPrefix:(NSString *)prefix {
    if ([self value:item[(__bridge id)kSecAttrAccount] hasPrefix:prefix]) return YES;
    if (CFEqual((__bridge CFTypeRef)secClass, kSecClassGenericPassword)) {
        return [self value:item[(__bridge id)kSecAttrService] hasPrefix:prefix];
    }
    return [self value:item[(__bridge id)kSecAttrServer] hasPrefix:prefix];
}

+ (NSString *)unprefix:(NSString *)value prefix:(NSString *)prefix {
    if (![value isKindOfClass:NSString.class] || ![value hasPrefix:prefix]) return value;
    return [value substringFromIndex:prefix.length];
}

+ (NSString *)prefixValue:(NSString *)value prefix:(NSString *)prefix {
    if (![value isKindOfClass:NSString.class] || [value hasPrefix:prefix]) return value;
    return [prefix stringByAppendingString:value];
}

+ (NSArray *)writableKeysForClass:(id)secClass {
    NSMutableArray *keys = [@[
        (__bridge id)kSecAttrAccount,
        (__bridge id)kSecAttrLabel,
        (__bridge id)kSecAttrDescription,
        (__bridge id)kSecAttrComment,
        (__bridge id)kSecAttrAccessible,
        (__bridge id)kSecAttrAccessGroup,
        (__bridge id)kSecAttrSynchronizable
    ] mutableCopy];
    if (CFEqual((__bridge CFTypeRef)secClass, kSecClassGenericPassword)) {
        [keys addObjectsFromArray:@[
            (__bridge id)kSecAttrService,
            (__bridge id)kSecAttrGeneric
        ]];
    } else {
        [keys addObjectsFromArray:@[
            (__bridge id)kSecAttrServer,
            (__bridge id)kSecAttrSecurityDomain,
            (__bridge id)kSecAttrPath,
            (__bridge id)kSecAttrPort,
            (__bridge id)kSecAttrProtocol,
            (__bridge id)kSecAttrAuthenticationType
        ]];
    }
    return keys;
}

+ (NSDictionary *)portableEntryFromItem:(NSDictionary *)item classValue:(id)secClass prefix:(NSString *)prefix {
    NSMutableDictionary *attributes = [NSMutableDictionary dictionary];
    for (id key in [self writableKeysForClass:secClass]) {
        id value = item[key];
        if (!value) continue;
        if (([key isEqual:(__bridge id)kSecAttrService] ||
             [key isEqual:(__bridge id)kSecAttrServer] ||
             [key isEqual:(__bridge id)kSecAttrAccount]) && [value isKindOfClass:NSString.class]) {
            NSString *plain = [self unprefix:value prefix:prefix];
            if ([plain isEqualToString:NKCKeychainSyntheticIdentity]) continue;
            attributes[key] = plain;
        } else if ([value isKindOfClass:NSString.class] ||
                   [value isKindOfClass:NSNumber.class] ||
                   [value isKindOfClass:NSData.class] ||
                   [value isKindOfClass:NSDate.class]) {
            attributes[key] = value;
        }
    }

    NSString *className = CFEqual((__bridge CFTypeRef)secClass, kSecClassGenericPassword) ? @"generic" : @"internet";
    NSMutableDictionary *entry = [@{
        @"class": className,
        @"attributes": attributes
    } mutableCopy];
    NSData *data = item[(__bridge id)kSecValueData];
    if ([data isKindOfClass:NSData.class]) entry[@"data"] = data;
    return entry;
}

+ (NSDictionary *)exportForOwnerBundleIdentifier:(NSString *)ownerBundleIdentifier
                              containerIdentifier:(NSString *)containerIdentifier
                                           toPath:(NSString *)path {
    NSString *prefix = [self prefixForOwner:ownerBundleIdentifier container:containerIdentifier];
    NSMutableArray *archiveItems = [NSMutableArray array];
    NSMutableArray *warnings = [NSMutableArray array];
    __block OSStatus firstFailure = errSecSuccess;

    NSArray *classes = @[(__bridge id)kSecClassGenericPassword, (__bridge id)kSecClassInternetPassword];
    for (id secClass in classes) {
        NSDictionary *query = @{
            (__bridge id)kSecClass: secClass,
            (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll,
            (__bridge id)kSecReturnAttributes: @YES,
            (__bridge id)kSecReturnData: @YES
        };
        CFTypeRef raw = NULL;
        OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &raw);
        if (status == errSecItemNotFound) continue;
        if (status != errSecSuccess) {
            if (firstFailure == errSecSuccess) firstFailure = status;
            [warnings addObject:[NSString stringWithFormat:@"SecItemCopyMatching failed for %@: %d", secClass, (int)status]];
            continue;
        }

        id object = raw ? CFBridgingRelease(raw) : nil;
        NSArray *items = [object isKindOfClass:NSArray.class] ? object : ([object isKindOfClass:NSDictionary.class] ? @[object] : @[]);
        for (NSDictionary *item in items) {
            if (![item isKindOfClass:NSDictionary.class]) continue;
            if (![self item:item classValue:secClass belongsToPrefix:prefix]) continue;
            [archiveItems addObject:[self portableEntryFromItem:item classValue:secClass prefix:prefix]];
        }
    }

    NSDictionary *archive = @{
        @"format": @"nkcrane-keychain",
        @"format_version": @1,
        @"owner_bundle_id": ownerBundleIdentifier ?: @"",
        @"source_container_id": containerIdentifier ?: @"",
        @"created_at": @([NSDate.date timeIntervalSince1970]),
        @"items": archiveItems
    };

    NSError *serializationError = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:archive
                                                               format:NSPropertyListBinaryFormat_v1_0
                                                              options:0
                                                                error:&serializationError];
    BOOL wrote = data && [data writeToFile:path options:NSDataWritingAtomic error:&serializationError];
    if (wrote) chmod(path.fileSystemRepresentation, 0600);

    BOOL readable = firstFailure == errSecSuccess;
    return @{
        @"ok": @(wrote && readable),
        @"written": @(wrote),
        @"accessible": @(readable),
        @"items": @(archiveItems.count),
        @"status": readable ? @"ok" : @"unavailable",
        @"osstatus": @(firstFailure),
        @"warnings": warnings,
        @"error": serializationError.localizedDescription ?: @""
    };
}

+ (id)classValueForName:(NSString *)name {
    if ([name isEqualToString:@"generic"]) return (__bridge id)kSecClassGenericPassword;
    if ([name isEqualToString:@"internet"]) return (__bridge id)kSecClassInternetPassword;
    return nil;
}

+ (NSArray<NSDictionary *> *)itemsForClass:(id)secClass prefix:(NSString *)prefix status:(OSStatus *)statusOut {
    NSDictionary *query = @{
        (__bridge id)kSecClass: secClass,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll,
        (__bridge id)kSecReturnAttributes: @YES,
        (__bridge id)kSecReturnPersistentRef: @YES
    };
    CFTypeRef raw = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &raw);
    if (statusOut) *statusOut = status;
    if (status != errSecSuccess || !raw) return @[];
    id object = CFBridgingRelease(raw);
    NSArray *items = [object isKindOfClass:NSArray.class] ? object : ([object isKindOfClass:NSDictionary.class] ? @[object] : @[]);
    NSMutableArray *filtered = [NSMutableArray array];
    for (NSDictionary *item in items) {
        if ([item isKindOfClass:NSDictionary.class] && [self item:item classValue:secClass belongsToPrefix:prefix]) [filtered addObject:item];
    }
    return filtered;
}

+ (BOOL)purgePrefix:(NSString *)prefix warnings:(NSMutableArray *)warnings {
    BOOL ok = YES;
    for (id secClass in @[(__bridge id)kSecClassGenericPassword, (__bridge id)kSecClassInternetPassword]) {
        OSStatus status = errSecSuccess;
        NSArray<NSDictionary *> *items = [self itemsForClass:secClass prefix:prefix status:&status];
        if (status != errSecSuccess && status != errSecItemNotFound) {
            ok = NO;
            [warnings addObject:[NSString stringWithFormat:@"Could not enumerate target keychain class %@: %d", secClass, (int)status]];
            continue;
        }
        for (NSDictionary *item in items) {
            NSData *persistentRef = item[(__bridge id)kSecValuePersistentRef];
            if (![persistentRef isKindOfClass:NSData.class]) continue;
            NSDictionary *query = @{(__bridge id)kSecValuePersistentRef:persistentRef};
            OSStatus current = SecItemDelete((__bridge CFDictionaryRef)query);
            if (current != errSecSuccess && current != errSecItemNotFound) {
                ok = NO;
                [warnings addObject:[NSString stringWithFormat:@"SecItemDelete failed: %d", (int)current]];
            }
        }
    }
    return ok;
}

+ (NSDictionary *)restoreForOwnerBundleIdentifier:(NSString *)ownerBundleIdentifier
                               containerIdentifier:(NSString *)containerIdentifier
                                         fromPath:(NSString *)path {
    NSMutableArray *warnings = [NSMutableArray array];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return @{@"ok":@NO,@"status":@"missing",@"items":@0,@"restored":@0,@"failed":@0,@"warnings":@[@"Keychain archive is missing"]};

    NSError *error = nil;
    id object = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:nil error:&error];
    if (![object isKindOfClass:NSDictionary.class]) {
        return @{@"ok":@NO,@"status":@"invalid",@"items":@0,@"restored":@0,@"failed":@0,@"warnings":@[error.localizedDescription ?: @"Invalid keychain archive"]};
    }
    NSDictionary *archive = object;
    if (![archive[@"format"] isEqual:@"nkcrane-keychain"] || [archive[@"format_version"] integerValue] != 1) {
        return @{@"ok":@NO,@"status":@"unsupported",@"items":@0,@"restored":@0,@"failed":@0,@"warnings":@[@"Unsupported keychain archive format"]};
    }

    NSArray *items = [archive[@"items"] isKindOfClass:NSArray.class] ? archive[@"items"] : @[];
    NSString *prefix = [self prefixForOwner:ownerBundleIdentifier container:containerIdentifier];
    BOOL purgeOK = [self purgePrefix:prefix warnings:warnings];
    NSUInteger restored = 0;
    NSUInteger failed = 0;

    for (NSDictionary *entry in items) {
        if (![entry isKindOfClass:NSDictionary.class]) { failed++; continue; }
        id secClass = [self classValueForName:entry[@"class"]];
        NSDictionary *attrs = [entry[@"attributes"] isKindOfClass:NSDictionary.class] ? entry[@"attributes"] : @{};
        if (!secClass) { failed++; continue; }

        NSMutableDictionary *add = [NSMutableDictionary dictionary];
        add[(__bridge id)kSecClass] = secClass;
        for (id key in [self writableKeysForClass:secClass]) {
            id value = attrs[key];
            if (!value) continue;
            if (([key isEqual:(__bridge id)kSecAttrService] ||
                 [key isEqual:(__bridge id)kSecAttrServer] ||
                 [key isEqual:(__bridge id)kSecAttrAccount]) && [value isKindOfClass:NSString.class]) {
                add[key] = [self prefixValue:value prefix:prefix];
            } else {
                add[key] = value;
            }
        }

        BOOL hasIdentity = [add[(__bridge id)kSecAttrAccount] isKindOfClass:NSString.class];
        if (CFEqual((__bridge CFTypeRef)secClass, kSecClassGenericPassword)) hasIdentity = hasIdentity || [add[(__bridge id)kSecAttrService] isKindOfClass:NSString.class];
        else hasIdentity = hasIdentity || [add[(__bridge id)kSecAttrServer] isKindOfClass:NSString.class];
        if (!hasIdentity) {
            NSString *synthetic = [prefix stringByAppendingString:NKCKeychainSyntheticIdentity];
            if (CFEqual((__bridge CFTypeRef)secClass, kSecClassGenericPassword)) add[(__bridge id)kSecAttrService] = synthetic;
            else add[(__bridge id)kSecAttrAccount] = synthetic;
        }

        NSData *valueData = entry[@"data"];
        if ([valueData isKindOfClass:NSData.class]) add[(__bridge id)kSecValueData] = valueData;

        OSStatus status = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
        if (status == errSecSuccess) restored++;
        else {
            failed++;
            [warnings addObject:[NSString stringWithFormat:@"SecItemAdd failed for %@ item: %d", entry[@"class"] ?: @"unknown", (int)status]];
        }
    }

    BOOL ok = purgeOK && failed == 0;
    return @{
        @"ok": @(ok),
        @"status": ok ? @"ok" : @"partial",
        @"items": @(items.count),
        @"restored": @(restored),
        @"failed": @(failed),
        @"warnings": warnings
    };
}

@end
