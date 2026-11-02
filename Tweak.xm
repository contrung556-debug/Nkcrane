#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <Security/Security.h>
#import <substrate.h>
#import "NKCraneCore/NKCStore.h"

// NKCrane v0.3.0
// Clean-room container engine for jailbroken iOS.
// v0.3: path + preferences isolation, common Keychain namespacing, CI-ready source.

static NSString *gBundleID = nil;
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

#pragma mark - Preferences

static BOOL NKIsCurrentApplicationID(CFStringRef applicationID) {
    if (!applicationID) return NO;
    if (applicationID == kCFPreferencesCurrentApplication) return YES;
    if (gBundleID && CFEqual(applicationID, (__bridge CFStringRef)gBundleID)) return YES;
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

static NSMutableDictionary *NKMapKeychainDictionary(NSDictionary *source, id explicitClass) {
    if (!NKShouldRedirect() || ![source isKindOfClass:NSDictionary.class]) return [source mutableCopy];

    NSMutableDictionary *mapped = [source mutableCopy];
    id secClass = explicitClass ?: mapped[(__bridge id)kSecClass];
    if (!NKKeychainClassSupported(secClass)) return mapped;

    if (CFEqual((__bridge CFTypeRef)secClass, kSecClassGenericPassword)) {
        id service = mapped[(__bridge id)kSecAttrService];
        if ([service isKindOfClass:NSString.class]) mapped[(__bridge id)kSecAttrService] = NKPrefixKeychainString(service);
    } else if (CFEqual((__bridge CFTypeRef)secClass, kSecClassInternetPassword)) {
        id server = mapped[(__bridge id)kSecAttrServer];
        if ([server isKindOfClass:NSString.class]) mapped[(__bridge id)kSecAttrServer] = NKPrefixKeychainString(server);
    }

    id account = mapped[(__bridge id)kSecAttrAccount];
    if ([account isKindOfClass:NSString.class]) mapped[(__bridge id)kSecAttrAccount] = NKPrefixKeychainString(account);

    return mapped;
}

static NSDictionary *NKUnmapKeychainAttributes(NSDictionary *source) {
    if (![source isKindOfClass:NSDictionary.class]) return source;
    NSMutableDictionary *out = [source mutableCopy];

    id service = out[(__bridge id)kSecAttrService];
    if ([service isKindOfClass:NSString.class]) out[(__bridge id)kSecAttrService] = NKUnprefixKeychainString(service);

    id server = out[(__bridge id)kSecAttrServer];
    if ([server isKindOfClass:NSString.class]) out[(__bridge id)kSecAttrServer] = NKUnprefixKeychainString(server);

    id account = out[(__bridge id)kSecAttrAccount];
    if ([account isKindOfClass:NSString.class]) out[(__bridge id)kSecAttrAccount] = NKUnprefixKeychainString(account);

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

static OSStatus NK_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    NSDictionary *input = (__bridge NSDictionary *)attributes;
    id secClass = input[(__bridge id)kSecClass];
    if (!NKShouldRedirect() || !NKKeychainClassSupported(secClass)) {
        return orig_SecItemAdd(attributes, result);
    }

    NSMutableDictionary *mapped = NKMapKeychainDictionary(input, secClass);
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

    NSMutableDictionary *mapped = NKMapKeychainDictionary(input, secClass);
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

    NSMutableDictionary *mappedQuery = NKMapKeychainDictionary(inputQuery, secClass);
    NSMutableDictionary *mappedUpdate = NKMapKeychainDictionary((__bridge NSDictionary *)attributesToUpdate, secClass);
    [mappedUpdate removeObjectForKey:(__bridge id)kSecClass];
    return orig_SecItemUpdate((__bridge CFDictionaryRef)mappedQuery, (__bridge CFDictionaryRef)mappedUpdate);
}

static OSStatus NK_SecItemDelete(CFDictionaryRef query) {
    NSDictionary *input = (__bridge NSDictionary *)query;
    id secClass = input[(__bridge id)kSecClass];
    if (!NKShouldRedirect() || !NKKeychainClassSupported(secClass)) {
        return orig_SecItemDelete(query);
    }

    NSMutableDictionary *mapped = NKMapKeychainDictionary(input, secClass);
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

%end

%ctor {
    @autoreleasepool {
        gBundleID = NSBundle.mainBundle.bundleIdentifier;
        if (!gBundleID.length) return;

        // Do not containerize Apple system applications/daemons in this build.
        if ([gBundleID hasPrefix:@"com.apple."]) return;

        gRealHome = [NSHomeDirectory() copy];
        NKCStore *store = NKCStore.sharedStore;
        gEnabled = [store isEnabledForBundleIdentifier:gBundleID];
        if (!gEnabled) return;

        gContainerID = [[store activeContainerIdentifierForBundleIdentifier:gBundleID] copy];
        if (![gContainerID isEqualToString:NKCDefaultContainerIdentifier]) {
            gMappedHome = [[[[gRealHome stringByAppendingPathComponent:@".nkcrane"]
                              stringByAppendingPathComponent:gContainerID]
                              stringByAppendingPathComponent:@"Root"] copy];
            gPreferencesDomain = [[store preferencesDomainForBundleIdentifier:gBundleID containerIdentifier:gContainerID] copy];
            gKeychainPrefix = [[NSString stringWithFormat:@"nkcrane|%@|%@|", gBundleID, gContainerID] copy];
            NKEnsureVirtualRoot();

            setenv("HOME", gMappedHome.fileSystemRepresentation, 1);
            NSString *tmp = [[gMappedHome stringByAppendingPathComponent:@"tmp"] stringByAppendingString:@"/"];
            setenv("TMPDIR", tmp.fileSystemRepresentation, 1);
            setenv("NKCRANE_CONTAINER_ID", gContainerID.UTF8String, 1);
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

        NSLog(@"[NKCrane 0.3] %@ active=%@ home=%@ prefs=%@ keychain=%@",
              gBundleID,
              gContainerID,
              gMappedHome ?: @"default",
              gPreferencesDomain ?: gBundleID,
              NKShouldRedirect() ? @"namespaced" : @"default");
    }
}
