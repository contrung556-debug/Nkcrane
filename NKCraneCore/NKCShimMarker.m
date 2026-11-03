#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <unistd.h>

static NSString *NKCSafeMarkerComponent(NSString *value) {
    if (!value.length) return @"unknown";
    NSMutableString *out = [value mutableCopy];
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"];
    for (NSInteger i = (NSInteger)out.length - 1; i >= 0; i--) {
        unichar c = [out characterAtIndex:(NSUInteger)i];
        if (![allowed characterIsMember:c]) {
            [out replaceCharactersInRange:NSMakeRange((NSUInteger)i, 1) withString:@"_"];
        }
    }
    return out;
}

static NSString *NKCRealHomeFromObservedHome(NSString *home) {
    if (!home.length) return nil;
    NSRange marker = [home rangeOfString:@"/.nkcrane/"];
    if (marker.location != NSNotFound) {
        return [home substringToIndex:marker.location];
    }
    return home;
}

static NSString *NKCStringFromEnv(const char *name) {
    const char *value = getenv(name);
    if (!value || !value[0]) return nil;
    return [NSString stringWithUTF8String:value];
}

static void NKCWriteShimMarker(void) {
    NSString *process = NSBundle.mainBundle.bundleIdentifier;
    if (!process.length || [process hasPrefix:@"com.apple."]) return;

    NSString *observedHome = NSHomeDirectory();
    NSString *realHome = NKCRealHomeFromObservedHome(observedHome);
    if (!realHome.length) return;

    NSString *container = NKCStringFromEnv("NKCRANE_CONTAINER_ID");
    NSString *owner = NKCStringFromEnv("NKCRANE_OWNER_BUNDLE_ID");
    NSString *processEnv = NKCStringFromEnv("NKCRANE_PROCESS_BUNDLE_ID");

    NSString *dir = [realHome stringByAppendingPathComponent:@".nkcrane"];
    NSError *dirError = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:&dirError]) {
        return;
    }

    NSString *path = [dir stringByAppendingPathComponent:
        [NSString stringWithFormat:@"runtime-registry-%@.json", NKCSafeMarkerComponent(process)]];

    NSMutableDictionary *payload = [@{
        @"version": @"1.2.1",
        @"mode": @"registry-shim-v1",
        @"pid": @(getpid()),
        @"process_bundle_id": process,
        @"injected": @YES,
        @"routing_active": @(container.length > 0),
        @"active_container_id": container ?: @"default",
        @"observed_home": observedHome ?: @"",
        @"real_home": realHome,
        @"timestamp": @([[NSDate date] timeIntervalSince1970])
    } mutableCopy];
    if (owner.length) payload[@"owner_bundle_id"] = owner;
    if (processEnv.length) payload[@"process_env_bundle_id"] = processEnv;

    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:NSJSONWritingPrettyPrinted error:nil];
    if (data) [data writeToFile:path options:NSDataWritingAtomic error:nil];
}

__attribute__((constructor(250)))
static void NKCInstallShimMarker(void) {
    @autoreleasepool {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            NKCWriteShimMarker();
        });
    }
}
