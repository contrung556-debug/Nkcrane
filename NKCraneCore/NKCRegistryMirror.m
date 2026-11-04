#import "NKCRegistryMirror.h"
#import <CoreFoundation/CoreFoundation.h>
#import <sys/stat.h>
#import <stdlib.h>
#import <stdio.h>
#import <errno.h>

NSString * const NKCRegistryPublicDirectory = @"/var/mobile/Library/NKCrane/Public";
NSString * const NKCRegistryPath = @"/var/mobile/Library/NKCrane/Public/registry.json";

static CFStringRef const NKCPreferencesDomain = CFSTR("com.nktouch.nkcrane");
static CFStringRef const NKCStoreKey = CFSTR("store");

static NSDictionary *NKCSanitizedRegistryFromStore(NSDictionary *store) {
    NSDictionary *rawApps = [store[@"apps"] isKindOfClass:NSDictionary.class] ? store[@"apps"] : @{};
    NSDictionary *rawAliases = [store[@"aliases"] isKindOfClass:NSDictionary.class] ? store[@"aliases"] : @{};

    NSMutableDictionary *apps = [NSMutableDictionary dictionary];
    [rawApps enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        if (![key isKindOfClass:NSString.class] || ![obj isKindOfClass:NSDictionary.class]) return;
        NSDictionary *entry = (NSDictionary *)obj;
        NSString *active = [entry[@"active"] isKindOfClass:NSString.class] && [entry[@"active"] length] ? entry[@"active"] : @"default";
        apps[key] = @{
            @"enabled": @([entry[@"enabled"] boolValue]),
            @"active": active
        };
    }];

    NSMutableDictionary *aliases = [NSMutableDictionary dictionary];
    [rawAliases enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        if ([key isKindOfClass:NSString.class] && [obj isKindOfClass:NSString.class] && [key length] && [obj length]) aliases[key] = obj;
    }];

    return @{
        @"version": @1,
        @"updated_at": @([[NSDate date] timeIntervalSince1970]),
        @"apps": apps,
        @"aliases": aliases
    };
}

BOOL NKCRegistryMirrorSyncNow(NSError **error) {
    CFPropertyListRef raw = CFPreferencesCopyAppValue(NKCStoreKey, NKCPreferencesDomain);
    NSDictionary *store = CFBridgingRelease(raw);
    if (![store isKindOfClass:NSDictionary.class]) store = @{@"apps":@{}, @"aliases":@{}};

    NSDictionary *registry = NKCSanitizedRegistryFromStore(store);
    NSError *jsonError = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:registry options:NSJSONWritingPrettyPrinted error:&jsonError];
    if (!data.length) {
        if (error) *error = jsonError ?: [NSError errorWithDomain:@"NKCrane.Registry" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Could not encode registry"}];
        return NO;
    }

    NSFileManager *fm = NSFileManager.defaultManager;
    NSError *dirError = nil;
    if (![fm createDirectoryAtPath:NKCRegistryPublicDirectory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0755} error:&dirError]) {
        if (error) *error = dirError;
        return NO;
    }
    chmod(NKCRegistryPublicDirectory.fileSystemRepresentation, 0755);

    // Unique temporary file + same-filesystem POSIX rename makes the new
    // registry appear atomically. Do NOT remove the previous JSON first:
    // RunningBoard may be reading it for an app spawn at exactly that time.
    NSString *tmp = [NSString stringWithFormat:@"%@.%d.%@.tmp",
                     NKCRegistryPath, getpid(), NSUUID.UUID.UUIDString];
    NSError *writeError = nil;
    if (![data writeToFile:tmp options:0 error:&writeError]) {
        if (error) *error = writeError;
        return NO;
    }
    chmod(tmp.fileSystemRepresentation, 0644);
    if (rename(tmp.fileSystemRepresentation, NKCRegistryPath.fileSystemRepresentation) != 0) {
        int reason = errno;
        [fm removeItemAtPath:tmp error:nil];
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                             code:reason
                                         userInfo:@{NSLocalizedDescriptionKey:@"Could not atomically publish NKCrane registry"}];
        return NO;
    }
    chmod(NKCRegistryPath.fileSystemRepresentation, 0644);

    NSData *verify = [NSData dataWithContentsOfFile:NKCRegistryPath options:0 error:nil];
    id obj = verify.length ? [NSJSONSerialization JSONObjectWithData:verify options:0 error:nil] : nil;
    if (![obj isKindOfClass:NSDictionary.class]) {
        if (error) *error = [NSError errorWithDomain:@"NKCrane.Registry" code:2 userInfo:@{NSLocalizedDescriptionKey:@"Registry read-back verification failed"}];
        return NO;
    }
    return YES;
}

static void NKCRegistryMirrorAtExit(void) {
    @autoreleasepool { NKCRegistryMirrorSyncNow(nil); }
}

__attribute__((constructor))
static void NKCRegistryMirrorBootstrap(void) {
    @autoreleasepool {
        NKCRegistryMirrorSyncNow(nil);
        atexit(NKCRegistryMirrorAtExit);
    }
}
