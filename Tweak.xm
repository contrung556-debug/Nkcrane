#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <Security/Security.h>
#import <substrate.h>
#import "NKCraneCore/NKCStore.h"

// NKCrane v0.4.0
// Clean-room container engine for jailbroken iOS.
// v0.4: bundle-family coordination, App Group path virtualization,
// and broad-query isolation for password Keychain records.

static NSString *gProcessBundleID = nil;
static NSString *gBundleID = nil; // effective owner bundle ID
static NSString *gRealHome = nil;
static NSString *gMappedHome = nil;
static NSString *gContainerID = nil;
static NSString *gPreferencesDomain = nil;
static NSString *gKeychainPrefix = nil;
static BOOL gEnabled = NO;
static NSUserDefaults *gContainerDefaults = nil;

static NSString *(*orig_NSHomeDirectory)(void) = NULL;
static NSString *(*orig_NSTemporaryDirectory)(void) = NULL;
static NSArray<NSString *> *(*orig_NSSearchPathForDirectoriesInDomains)(NSSearchPathDirectory, NSSearchPathDomainMask, BOOL) = NULL;

static CFPropertyListRef (*orig_CFPreferencesCopyAppValue)(CFStringRef, CFStringRef) = NULL;
static void (*orig_CFPreferencesSetAppValue)(CFStringRef, CFPropertyListRef, CFStringRef) = NULL;
static Boolean (*orig_CFPreferencesAppSynchronize)(CFStringRef) = NULL;
static CFPropertyListRef (*orig_CFPreferencesCopyValue)(CFStringRef, CFStringRef, CFStringRef, CFStringRef) = NULL;
static void (*orig_CFPreferencesSetValue)(CFStringRef, CFPropertyListRef, CFStringRef, CFStringRef, CFStringRef) = NULL;
static Boolean (*orig_CFPreferencesSynchronize)(CFStringRef, CFStringRef, CFStringRef) = NULL;
static CFArrayRef (*orig_CFPreferencesCopyKeyList)(CFStringRef, CFStringRef, CFStringRef) = NULL;

static OSStatus (*orig_SecItemAdd)(CFDictionaryRef, CFTypeRef *) = NULL;
static OSStatus (*orig_SecItemCopyMatching)(CFDictionaryRef, CFTypeRef *) = NULL;
static OSStatus (*orig_SecItemUpdate)(CFDictionaryRef, CFDictionaryRef) = NULL;
static OSStatus (*orig_SecItemDelete)(CFDictionaryRef) = NULL;

static NSString * const NKSyntheticIdentity = @"__nkcrane_anon__";

static BOOL NKShouldRedirect(void) {
    return gEnabled && gMappedHome.length > 0 && ![gContainerID isEqualToString:NKCDefaultContainerIdentifier];
}

#pragma mark - Virtual home

static void NKEnsureVirtualRoot(void) {
    if (!NKShouldRedirect()) return;
    NSArray<NSString *> *dirs = @[
        @"Documents", @"Library", @"Library/Caches", @"Library/Preferences",
        @"Library/Application Support", @"Library/WebKit", @"Library/Cookies",
        @"Library/Saved Application State", @"tmp", @"SystemData"
    ];
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *relative in dirs) {
        [fm createDirectoryAtPath:[gMappedHome stringByAppendingPathComponent:relative]
      withIntermediateDirectories:YES attributes:nil error:nil];
    }
}

static NSString *NK_NSHomeDirectory(void) {
    if (NKShouldRedirect()) return gMappedHome;
    return orig_NSHomeDirectory ? orig_NSHomeDirectory() : gRealHome;
}

static NSString *NK_NSTemporaryDirectory(void) {
    if (NKShouldRedirect()) return [[gMappedHome stringByAppendingPathComponent:@"tmp"] stringByAppendingString:@"/"];
    return orig_NSTemporaryDirectory ? orig_NSTemporaryDirectory() : [gRealHome stringByAppendingPathComponent:@"tmp/"];
}

static NSString *NKPathForSearchDirectory(NSSearchPathDirectory directory) {
    switch (directory) {
        case NSDocumentDirectory: return [gMappedHome stringByAppendingPathComponent:@"Documents"];
        case NSLibraryDirectory: return [gMappedHome stringByAppendingPathComponent:@"Library"];
        case NSCachesDirectory: return [gMappedHome stringByAppendingPathComponent:@"Library/Caches"];
        case NSApplicationSupportDirectory: return [gMappedHome stringByAppendingPathComponent:@"Library/Application Support"];
        default: return nil;
    }
}

static NSArray<NSString *> *NK_NSSearchPathForDirectoriesInDomains(NSSearchPathDirectory directory, NSSearchPathDomainMask domainMask, BOOL expandTilde) {
    if (!NKShouldRedirect() || !(domainMask & NSUserDomainMask)) {
        return orig_NSSearchPathForDirectoriesInDomains(directory, domainMask, expandTilde);
    }

    NSString *path = NKPathForSearchDirectory(directory);
    if (!path) return orig_NSSearchPathForDirectoriesInDomains(directory, domainMask, expandTilde);
    [NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    return @[path];
}

static NSString *NKSafePathComponent(NSString *value) {
    if (!value.length) return @"unknown";
    NSMutableString *out = [value mutableCopy];
    [out replaceOccurrencesOfString:@"/" withString:@"_" options:0 range:NSMakeRange(0, out.length)];
    [out replaceOccurrencesOfString:@":" withString:@"_" options:0 range:NSMakeRange(0, out.length)];
    return out;
}

static NSURL *NKVirtualAppGroupURL(NSURL *realURL, NSString *groupIdentifier) {
    if (!NKShouldRedirect() || !realURL.isFileURL) return realURL;
    NSString *root = realURL.path;
    root = [root stringByAppendingPathComponent:@".nkcrane"];
    root = [root stringByAppendingPathComponent:NKSafePathComponent(gBundleID)];
    root = [root stringByAppendingPathComponent:NKSafePathComponent(gContainerID)];
    root = [root stringByAppendingPathComponent:NKSafePathComponent(groupIdentifier ?: @"group")];
    root = [root stringByAppendingPathComponent:@"Root"];
    [NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
    return [NSURL fileURLWithPath:root isDirectory:YES];
}

#pragma mark - Preferences

static BOOL NKIsCurrentApplicationID(CFStringRef applicationID) {
    if (!applicationID) return NO;
    if (applicationID == kCFPreferencesCurrentApplication) return YES;
    if (gProcessBundleID && CFEqual(applicationID, (__bridge CFStringRef)gProcessBundleID)) return YES;
    return NO;
}

static CFStringRef NKMapPreferencesApplicationID(CFStringRef applicationID) {
    if (!NKShouldRedirect() || !gPreferencesDomain.length) return applicationID;
    if (NKIsCurrentApplicationID(applicationID)) return (__bridge CFStringRef)gPreferencesDomain;
    return applicationID;
}

static CFPropertyListRef NK_CFPreferencesCopyAppValue(CFStringRef key, CFStringRef applicationID) {
    return orig_CFPreferencesCopyAppValue(key, NKMapPreferencesApplicationID(applicationID));
}

static void NK_CFPreferencesSetAppValue(CFStringRef key, CFPropertyListRef value, CFStringRef applicationID) {
    orig_CFPreferencesSetAppValue(key, value, NKMapPreferencesApplicationID(applicationID));
}

static Boolean NK_CFPreferencesAppSynchronize(CFStringRef applicationID) {
    return orig_CFPreferencesAppSynchronize(NKMapPreferencesApplicationID(applicationID));
}

static CFPropertyListRef NK_CFPreferencesCopyValue(CFStringRef key, CFStringRef applicationID, CFStringRef userName, CFStringRef hostName) {
    return orig_CFPreferencesCopyValue(key, NKMapPreferencesApplicationID(applicationID), userName, hostName);
}

static void NK_CFPreferencesSetValue(CFStringRef key, CFPropertyListRef value, CFStringRef applicationID, CFStringRef userName, CFStringRef hostName) {
    orig_CFPreferencesSetValue(key, value, NKMapPreferencesApplicationID(applicationID), userName, hostName);
}

static Boolean NK_CFPreferencesSynchronize(CFStringRef applicationID, CFStringRef userName, CFStringRef hostName) {
    return orig_CFPreferencesSynchronize(NKMapPreferencesApplicationID(applicationID), userName, hostName);
}

static CFArrayRef NK_CFPreferencesCopyKeyList(CFStringRef applicationID, CFStringRef userName, CFStringRef hostName) {
    return orig_CFPreferencesCopyKeyList(NKMapPreferencesApplicationID(applicationID), userName, hostName);
}

static NSUserDefaults *NKContainerStandardDefaults(void) {
    if (!NKShouldRedirect()) return nil;
    @synchronized(NSUserDefaults.class) {
        if (!gContainerDefaults) gContainerDefaults = [[NSUserDefaults alloc] initWithSuiteName:gPreferencesDomain];
        return gContainerDefaults;
    }
}

#pragma mark - Keychain

static BOOL NKKeychainClassSupported(id secClass) {
    if (!secClass) return NO;
    return CFEqual((__bridge CFTypeRef)secClass, kSecClassGenericPassword) ||
           CFEqual((__bridge CFTypeRef)secClass, kSecClassInternetPassword);
}

static NSString *NKPrefixKeychainString(NSString *value) {
    if (!NKShouldRedirect() || !gKeychainPrefix.length || ![value isKindOfClass:NSString.class]) return value;
    if ([value hasPrefix:gKeychainPrefix]) return value;
    return [gKeychainPrefix stringByAppendingString:value];
}

static NSString *NKUnprefixKeychainString(NSString *value) {
    if (!gKeychainPrefix.length || ![value isKindOfClass:NSString.class]) return value;
    if (![value hasPrefix:gKeychainPrefix]) return value;
    return [value substringFromIndex:gKeychainPrefix.length];
}

static BOOL NKStringHasCurrentPrefix(id value) {
    return [value isKindOfClass:NSString.class] && gKeychainPrefix.length && [(NSString *)value hasPrefix:gKeychainPrefix];
}

static BOOL NKKeychainQueryIsBroad(NSDictionary *source, id secClass) {
    if (!NKKeychainClassSupported(secClass)) return NO;
    id account = source[(__bridge id)kSecAttrAccount];
    if ([account isKindOfClass:NSString.class]) return NO;
    if (CFEqual((__bridge CFTypeRef)secClass, kSecClassGenericPassword)) {
        return ![source[(__bridge id)kSecAttrService] isKindOfClass:NSString.class];
    }
    return ![source[(__bridge id)kSecAttrServer] isKindOfClass:NSString.class];
}

static NSMutableDictionary *NKMapKeychainDictionary(NSDictionary *source, id explicitClass, BOOL ensureIdentity) {
    if (!NKShouldRedirect() || ![source isKindOfClass:NSDictionary.class]) return [source mutableCopy];

    NSMutableDictionary *mapped = [source mutableCopy];
    id secClass = explicitClass ?: mapped[(__bridge id)kSecClass];
    if (!NKKeychainClassSupported(secClass)) return mapped;

    BOOL hasPrimary = NO;
    if (CFEqual((__bridge CFTypeRef)secClass, kSecClassGenericPassword)) {
        id service = mapped[(__bridge id)kSecAttrService];
        if ([service isKindOfClass:NSString.class]) {
            mapped[(__bridge id)kSecAttrService] = NKPrefixKeychainString(service);
            hasPrimary = YES;
        }
    } else {
        id server = mapped[(__bridge id)kSecAttrServer];
        if ([server isKindOfClass:NSString.class]) {
            mapped[(__bridge id)kSecAttrServer] = NKPrefixKeychainString(server);
            hasPrimary = YES;
        }
    }

    id account = mapped[(__bridge id)kSecAttrAccount];
    BOOL hasAccount = [account isKindOfClass:NSString.class];
    if (hasAccount) mapped[(__bridge id)kSecAttrAccount] = NKPrefixKeychainString(account);

    if (ensureIdentity && !hasPrimary && !hasAccount) {
        NSString *synthetic = NKPrefixKeychainString(NKSyntheticIdentity);
        if (CFEqual((__bridge CFTypeRef)secClass, kSecClassGenericPassword)) {
            mapped[(__bridge id)kSecAttrService] = synthetic;
        } else {
            mapped[(__bridge id)kSecAttrAccount] = synthetic;
        }
    }

    return mapped;
}

static NSDictionary *NKUnmapKeychainAttributes(NSDictionary *source) {
    if (![source isKindOfClass:NSDictionary.class]) return source;
    NSMutableDictionary *out = [source mutableCopy];

    NSArray *keys = @[
        (__bridge id)kSecAttrService,
        (__bridge id)kSecAttrServer,
        (__bridge id)kSecAttrAccount
    ];
    for (id key in keys) {
        id value = out[key];
        if (![value isKindOfClass:NSString.class]) continue;
        NSString *plain = NKUnprefixKeychainString(value);
        if ([plain isEqualToString:NKSyntheticIdentity]) [out removeObjectForKey:key];
        else out[key] = plain;
    }
    return out;
}

static id NKUnmapKeychainResult(id result) {
    if ([result isKindOfClass:NSDictionary.class]) return NKUnmapKeychainAttributes(result);
    if ([result isKindOfClass:NSArray.class]) {
        NSMutableArray *items = [NSMutableArray arrayWithCapacity:[result count]];
        for (id item in (NSArray *)result) {
            [items addObject:[item isKindOfClass:NSDictionary.class] ? NKUnmapKeychainAttributes(item) : item];
        }
        return items;
    }
    return result;
}

static BOOL NKKeychainMappedAttributesBelongToContainer(NSDictionary *attrs, id secClass) {
    if (![attrs isKindOfClass:NSDictionary.class]) return NO;
    if (NKStringHasCurrentPrefix(attrs[(__bridge id)kSecAttrAccount])) return YES;
    if (CFEqual((__bridge CFTypeRef)secClass, kSecClassGenericPassword)) {
        return NKStringHasCurrentPrefix(attrs[(__bridge id)kSecAttrService]);
    }
    return NKStringHasCurrentPrefix(attrs[(__bridge id)kSecAttrServer]);
}

static NSArray<NSDictionary *> *NKEnumerateContainerKeychainItems(NSDictionary *originalQuery, id secClass, BOOL needData, BOOL needRef, OSStatus *statusOut) {
    NSMutableDictionary *query = [originalQuery mutableCopy];
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitAll;
    query[(__bridge id)kSecReturnAttributes] = @YES;
    query[(__bridge id)kSecReturnPersistentRef] = @YES;
    if (needData) query[(__bridge id)kSecReturnData] = @YES;
    if (needRef) query[(__bridge id)kSecReturnRef] = @YES;

    CFTypeRef raw = NULL;
    OSStatus status = orig_SecItemCopyMatching((__bridge CFDictionaryRef)query, &raw);
    if (statusOut) *statusOut = status;
    if (status != errSecSuccess || !raw) return @[];

    id object = CFBridgingRelease(raw);
    NSArray *items = [object isKindOfClass:NSArray.class] ? object : ([object isKindOfClass:NSDictionary.class] ? @[object] : @[]);
    NSMutableArray<NSDictionary *> *filtered = [NSMutableArray array];
    for (id item in items) {
        if ([item isKindOfClass:NSDictionary.class] && NKKeychainMappedAttributesBelongToContainer(item, secClass)) {
            [filtered addObject:item];
        }
    }
    return filtered;
}

static id NKShapeKeychainItemForOriginalQuery(NSDictionary *mappedItem, NSDictionary *originalQuery) {
    BOOL wantAttributes = [originalQuery[(__bridge id)kSecReturnAttributes] boolValue];
    BOOL wantData = [originalQuery[(__bridge id)kSecReturnData] boolValue];
    BOOL wantPersistent = [originalQuery[(__bridge id)kSecReturnPersistentRef] boolValue];
    BOOL wantRef = [originalQuery[(__bridge id)kSecReturnRef] boolValue];
    NSUInteger count = (wantAttributes ? 1 : 0) + (wantData ? 1 : 0) + (wantPersistent ? 1 : 0) + (wantRef ? 1 : 0);

    if (count == 0 || (count == 1 && wantAttributes)) {
        NSMutableDictionary *attrs = [NKUnmapKeychainAttributes(mappedItem) mutableCopy];
        [attrs removeObjectForKey:(__bridge id)kSecValueData];
        [attrs removeObjectForKey:(__bridge id)kSecValuePersistentRef];
        [attrs removeObjectForKey:(__bridge id)kSecValueRef];
        return attrs;
    }
    if (count == 1 && wantData) return mappedItem[(__bridge id)kSecValueData];
    if (count == 1 && wantPersistent) return mappedItem[(__bridge id)kSecValuePersistentRef];
    if (count == 1 && wantRef) return mappedItem[(__bridge id)kSecValueRef];

    NSMutableDictionary *out = wantAttributes ? [NKUnmapKeychainAttributes(mappedItem) mutableCopy] : [NSMutableDictionary dictionary];
    if (!wantData) [out removeObjectForKey:(__bridge id)kSecValueData];
    else if (mappedItem[(__bridge id)kSecValueData]) out[(__bridge id)kSecValueData] = mappedItem[(__bridge id)kSecValueData];
    if (!wantPersistent) [out removeObjectForKey:(__bridge id)kSecValuePersistentRef];
    else if (mappedItem[(__bridge id)kSecValuePersistentRef]) out[(__bridge id)kSecValuePersistentRef] = mappedItem[(__bridge id)kSecValuePersistentRef];
    if (!wantRef) [out removeObjectForKey:(__bridge id)kSecValueRef];
    else if (mappedItem[(__bridge id)kSecValueRef]) out[(__bridge id)kSecValueRef] = mappedItem[(__bridge id)kSecValueRef];
    return out;
}

static OSStatus NKCopyBroadKeychainQuery(NSDictionary *input, id secClass, CFTypeRef *result) {
    BOOL needData = [input[(__bridge id)kSecReturnData] boolValue];
    BOOL needRef = [input[(__bridge id)kSecReturnRef] boolValue];
    OSStatus status = errSecSuccess;
    NSArray<NSDictionary *> *items = NKEnumerateContainerKeychainItems(input, secClass, needData, needRef, &status);
    if (status != errSecSuccess && status != errSecItemNotFound) return status;
    if (items.count == 0) {
        if (result) *result = NULL;
        return errSecItemNotFound;
    }
    if (!result) return errSecSuccess;

    BOOL all = CFEqual((__bridge CFTypeRef)(input[(__bridge id)kSecMatchLimit] ?: (__bridge id)kSecMatchLimitOne), kSecMatchLimitAll);
    if (all) {
        NSMutableArray *shaped = [NSMutableArray arrayWithCapacity:items.count];
        for (NSDictionary *item in items) {
            id value = NKShapeKeychainItemForOriginalQuery(item, input);
            if (value) [shaped addObject:value];
        }
        *result = CFBridgingRetain(shaped);
    } else {
        id value = NKShapeKeychainItemForOriginalQuery(items.firstObject, input);
        *result = value ? CFBridgingRetain(value) : NULL;
    }
    return errSecSuccess;
}

static OSStatus NKModifyBroadKeychainQuery(NSDictionary *input, id secClass, NSDictionary *update, BOOL deleting) {
    OSStatus status = errSecSuccess;
    NSArray<NSDictionary *> *items = NKEnumerateContainerKeychainItems(input, secClass, NO, NO, &status);
    if (status != errSecSuccess && status != errSecItemNotFound) return status;
    if (items.count == 0) return errSecItemNotFound;

    NSMutableDictionary *mappedUpdate = update ? NKMapKeychainDictionary(update, secClass, NO) : nil;
    [mappedUpdate removeObjectForKey:(__bridge id)kSecClass];

    OSStatus firstError = errSecSuccess;
    NSUInteger changed = 0;
    for (NSDictionary *item in items) {
        NSData *persistentRef = item[(__bridge id)kSecValuePersistentRef];
        if (![persistentRef isKindOfClass:NSData.class]) continue;
        NSDictionary *refQuery = @{ (__bridge id)kSecValuePersistentRef: persistentRef };
        OSStatus current = deleting
            ? orig_SecItemDelete((__bridge CFDictionaryRef)refQuery)
            : orig_SecItemUpdate((__bridge CFDictionaryRef)refQuery, (__bridge CFDictionaryRef)mappedUpdate);
        if (current == errSecSuccess) changed++;
        else if (firstError == errSecSuccess) firstError = current;
    }
    if (changed > 0) return firstError == errSecSuccess ? errSecSuccess : firstError;
    return firstError == errSecSuccess ? errSecItemNotFound : firstError;
}

static OSStatus NK_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    NSDictionary *input = (__bridge NSDictionary *)attributes;
    id secClass = input[(__bridge id)kSecClass];
    if (!NKShouldRedirect() || !NKKeychainClassSupported(secClass)) {
        return orig_SecItemAdd(attributes, result);
    }

    NSMutableDictionary *mapped = NKMapKeychainDictionary(input, secClass, YES);
    if (!result) return orig_SecItemAdd((__bridge CFDictionaryRef)mapped, NULL);

    CFTypeRef raw = NULL;
    OSStatus status = orig_SecItemAdd((__bridge CFDictionaryRef)mapped, &raw);
    if (status == errSecSuccess && raw) {
        id obj = CFBridgingRelease(raw);
        *result = CFBridgingRetain(NKUnmapKeychainResult(obj));
    } else {
        *result = raw;
    }
    return status;
}

static OSStatus NK_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    NSDictionary *input = (__bridge NSDictionary *)query;
    id secClass = input[(__bridge id)kSecClass];
    if (!NKShouldRedirect() || !NKKeychainClassSupported(secClass)) {
        return orig_SecItemCopyMatching(query, result);
    }

    if (NKKeychainQueryIsBroad(input, secClass)) {
        return NKCopyBroadKeychainQuery(input, secClass, result);
    }

    NSMutableDictionary *mapped = NKMapKeychainDictionary(input, secClass, NO);
    if (!result) return orig_SecItemCopyMatching((__bridge CFDictionaryRef)mapped, NULL);

    CFTypeRef raw = NULL;
    OSStatus status = orig_SecItemCopyMatching((__bridge CFDictionaryRef)mapped, &raw);
    if (status == errSecSuccess && raw) {
        id obj = CFBridgingRelease(raw);
        *result = CFBridgingRetain(NKUnmapKeychainResult(obj));
    } else {
        *result = raw;
    }
    return status;
}

static OSStatus NK_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
    NSDictionary *inputQuery = (__bridge NSDictionary *)query;
    id secClass = inputQuery[(__bridge id)kSecClass];
    if (!NKShouldRedirect() || !NKKeychainClassSupported(secClass)) {
        return orig_SecItemUpdate(query, attributesToUpdate);
    }

    NSDictionary *update = (__bridge NSDictionary *)attributesToUpdate;
    if (NKKeychainQueryIsBroad(inputQuery, secClass)) {
        return NKModifyBroadKeychainQuery(inputQuery, secClass, update, NO);
    }

    NSMutableDictionary *mappedQuery = NKMapKeychainDictionary(inputQuery, secClass, NO);
    NSMutableDictionary *mappedUpdate = NKMapKeychainDictionary(update, secClass, NO);
    [mappedUpdate removeObjectForKey:(__bridge id)kSecClass];
    return orig_SecItemUpdate((__bridge CFDictionaryRef)mappedQuery, (__bridge CFDictionaryRef)mappedUpdate);
}

static OSStatus NK_SecItemDelete(CFDictionaryRef query) {
    NSDictionary *input = (__bridge NSDictionary *)query;
    id secClass = input[(__bridge id)kSecClass];
    if (!NKShouldRedirect() || !NKKeychainClassSupported(secClass)) {
        return orig_SecItemDelete(query);
    }

    if (NKKeychainQueryIsBroad(input, secClass)) {
        return NKModifyBroadKeychainQuery(input, secClass, nil, YES);
    }

    NSMutableDictionary *mapped = NKMapKeychainDictionary(input, secClass, NO);
    return orig_SecItemDelete((__bridge CFDictionaryRef)mapped);
}

%hook NSUserDefaults

+ (NSUserDefaults *)standardUserDefaults {
    NSUserDefaults *defaults = NKContainerStandardDefaults();
    return defaults ?: %orig;
}

+ (void)resetStandardUserDefaults {
    if (NKShouldRedirect()) {
        @synchronized(NSUserDefaults.class) { gContainerDefaults = nil; }
    }
    %orig;
}

%end

%hook NSFileManager

- (NSArray<NSURL *> *)URLsForDirectory:(NSSearchPathDirectory)directory inDomains:(NSSearchPathDomainMask)domainMask {
    if (NKShouldRedirect() && (domainMask & NSUserDomainMask)) {
        NSString *path = NKPathForSearchDirectory(directory);
        if (path.length) {
            [self createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
            return @[[NSURL fileURLWithPath:path isDirectory:YES]];
        }
    }
    return %orig;
}

- (NSURL *)containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier {
    NSURL *realURL = %orig(groupIdentifier);
    if (!NKShouldRedirect() || !realURL) return realURL;
    return NKVirtualAppGroupURL(realURL, groupIdentifier);
}

%end

%ctor {
    @autoreleasepool {
        gProcessBundleID = NSBundle.mainBundle.bundleIdentifier;
        if (!gProcessBundleID.length) return;

        // Do not containerize Apple system applications/daemons in this build.
        if ([gProcessBundleID hasPrefix:@"com.apple."]) return;

        gRealHome = [NSHomeDirectory() copy];
        NKCStore *store = NKCStore.sharedStore;
        gBundleID = [[store ownerBundleIdentifierForProcessBundleIdentifier:gProcessBundleID] copy];
        gEnabled = [store isEnabledForBundleIdentifier:gBundleID];
        if (!gEnabled) return;

        gContainerID = [[store activeContainerIdentifierForBundleIdentifier:gBundleID] copy];
        if (![gContainerID isEqualToString:NKCDefaultContainerIdentifier]) {
            gMappedHome = [[[[gRealHome stringByAppendingPathComponent:@".nkcrane"]
                              stringByAppendingPathComponent:gContainerID]
                              stringByAppendingPathComponent:@"Root"] copy];
            // Keep process-local normal preferences separate while sharing owner container selection.
            gPreferencesDomain = [[store preferencesDomainForBundleIdentifier:gProcessBundleID containerIdentifier:gContainerID] copy];
            // Keychain is namespaced by owner so linked extensions can share credentials within one container.
            gKeychainPrefix = [[NSString stringWithFormat:@"nkcrane|%@|%@|", gBundleID, gContainerID] copy];
            NKEnsureVirtualRoot();

            setenv("HOME", gMappedHome.fileSystemRepresentation, 1);
            NSString *tmp = [[gMappedHome stringByAppendingPathComponent:@"tmp"] stringByAppendingString:@"/"];
            setenv("TMPDIR", tmp.fileSystemRepresentation, 1);
            setenv("NKCRANE_CONTAINER_ID", gContainerID.UTF8String, 1);
            setenv("NKCRANE_OWNER_BUNDLE_ID", gBundleID.UTF8String, 1);
            setenv("NKCRANE_PROCESS_BUNDLE_ID", gProcessBundleID.UTF8String, 1);
        }

        MSHookFunction((void *)NSHomeDirectory, (void *)NK_NSHomeDirectory, (void **)&orig_NSHomeDirectory);
        MSHookFunction((void *)NSTemporaryDirectory, (void *)NK_NSTemporaryDirectory, (void **)&orig_NSTemporaryDirectory);
        MSHookFunction((void *)NSSearchPathForDirectoriesInDomains, (void *)NK_NSSearchPathForDirectoriesInDomains, (void **)&orig_NSSearchPathForDirectoriesInDomains);

        if (NKShouldRedirect()) {
            MSHookFunction((void *)CFPreferencesCopyAppValue, (void *)NK_CFPreferencesCopyAppValue, (void **)&orig_CFPreferencesCopyAppValue);
            MSHookFunction((void *)CFPreferencesSetAppValue, (void *)NK_CFPreferencesSetAppValue, (void **)&orig_CFPreferencesSetAppValue);
            MSHookFunction((void *)CFPreferencesAppSynchronize, (void *)NK_CFPreferencesAppSynchronize, (void **)&orig_CFPreferencesAppSynchronize);
            MSHookFunction((void *)CFPreferencesCopyValue, (void *)NK_CFPreferencesCopyValue, (void **)&orig_CFPreferencesCopyValue);
            MSHookFunction((void *)CFPreferencesSetValue, (void *)NK_CFPreferencesSetValue, (void **)&orig_CFPreferencesSetValue);
            MSHookFunction((void *)CFPreferencesSynchronize, (void *)NK_CFPreferencesSynchronize, (void **)&orig_CFPreferencesSynchronize);
            MSHookFunction((void *)CFPreferencesCopyKeyList, (void *)NK_CFPreferencesCopyKeyList, (void **)&orig_CFPreferencesCopyKeyList);

            MSHookFunction((void *)SecItemAdd, (void *)NK_SecItemAdd, (void **)&orig_SecItemAdd);
            MSHookFunction((void *)SecItemCopyMatching, (void *)NK_SecItemCopyMatching, (void **)&orig_SecItemCopyMatching);
            MSHookFunction((void *)SecItemUpdate, (void *)NK_SecItemUpdate, (void **)&orig_SecItemUpdate);
            MSHookFunction((void *)SecItemDelete, (void *)NK_SecItemDelete, (void **)&orig_SecItemDelete);
        }

        NSLog(@"[NKCrane 0.4] process=%@ owner=%@ active=%@ home=%@ prefs=%@ keychain=%@",
              gProcessBundleID,
              gBundleID,
              gContainerID,
              gMappedHome ?: @"default",
              gPreferencesDomain ?: gProcessBundleID,
              NKShouldRedirect() ? @"namespaced" : @"default");
    }
}
