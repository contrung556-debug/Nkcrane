#import <Foundation/Foundation.h>
#import <substrate.h>
#import <objc/runtime.h>
#import <unistd.h>
#import "NKCStore.h"
#import "NKCLocalConfig.h"

static NSString *sOwner = nil;
static NSString *sProcess = nil;
static NSString *sContainer = nil;
static NSString *sSuitePrefix = nil;
static BOOL sEnabled = NO;
static BOOL sUsedLocalConfig = NO;
static NSUserDefaults *sStandardDefaults = nil;

static id (*orig_NSUserDefaults_initWithSuiteName)(id, SEL, NSString *) = NULL;
static id (*orig_NSUserDefaults_standardUserDefaults)(id, SEL) = NULL;

static NSString *NKCSafeComponent(NSString *value) {
    if (!value.length) return @"unknown";
    NSMutableString *out = [value mutableCopy];
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"];
    for (NSInteger i = (NSInteger)out.length - 1; i >= 0; i--) {
        unichar c = [out characterAtIndex:(NSUInteger)i];
        if (![allowed characterIsMember:c]) [out replaceCharactersInRange:NSMakeRange((NSUInteger)i, 1) withString:@"_"];
    }
    return out;
}

static NSString *NKCMapSuiteName(NSString *suiteName) {
    if (!sEnabled || !suiteName.length) return suiteName;
    if ([suiteName hasPrefix:sSuitePrefix]) return suiteName;
    if ([suiteName hasPrefix:@"com.apple."]) return suiteName;
    return [NSString stringWithFormat:@"%@.%@", sSuitePrefix, NKCSafeComponent(suiteName)];
}

static id NKC_NSUserDefaults_initWithSuiteName(id self, SEL _cmd, NSString *suiteName) {
    NSString *mapped = NKCMapSuiteName(suiteName);
    return orig_NSUserDefaults_initWithSuiteName ? orig_NSUserDefaults_initWithSuiteName(self, _cmd, mapped) : nil;
}

static id NKC_NSUserDefaults_standardUserDefaults(id cls, SEL _cmd) {
    if (!sEnabled || !orig_NSUserDefaults_initWithSuiteName) {
        return orig_NSUserDefaults_standardUserDefaults ? orig_NSUserDefaults_standardUserDefaults(cls, _cmd) : nil;
    }
    @synchronized(NSUserDefaults.class) {
        if (!sStandardDefaults) {
            NSString *domain = [NSString stringWithFormat:@"%@.standard.%@", sSuitePrefix, NKCSafeComponent(sProcess)];
            id obj = [NSUserDefaults alloc];
            sStandardDefaults = orig_NSUserDefaults_initWithSuiteName(obj, @selector(initWithSuiteName:), domain);
        }
        return sStandardDefaults;
    }
}

static void NKCWriteRuntimeMarker(NSString *realHome, NSString *mappedHome) {
    if (!realHome.length || !sProcess.length) return;
    NSString *dir = [realHome stringByAppendingPathComponent:@".nkcrane"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *name = [NSString stringWithFormat:@"runtime-%@.json", NKCSafeComponent(sProcess)];
    NSString *path = [dir stringByAppendingPathComponent:name];
    NSDictionary *payload = @{
        @"version": @"0.9.2",
        @"pid": @(getpid()),
        @"process_bundle_id": sProcess ?: @"",
        @"owner_bundle_id": sOwner ?: @"",
        @"active_container_id": sContainer ?: @"default",
        @"real_home": realHome ?: @"",
        @"mapped_home": mappedHome ?: @"",
        @"standard_defaults_isolated": @YES,
        @"suite_defaults_isolated": @YES,
        @"local_config_used": @(sUsedLocalConfig),
        @"timestamp": @([[NSDate date] timeIntervalSince1970])
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:NSJSONWritingPrettyPrinted error:nil];
    if (data) [data writeToFile:path options:NSDataWritingAtomic error:nil];
}

__attribute__((constructor))
static void NKCRuntimeIsolationBootstrap(void) {
    @autoreleasepool {
        sProcess = [NSBundle.mainBundle.bundleIdentifier copy];
        if (!sProcess.length || [sProcess hasPrefix:@"com.apple."]) return;

        NSDictionary *local = [NKCLocalConfig currentProcessConfig];
        if (local) {
            sUsedLocalConfig = YES;
            sOwner = [[NKCLocalConfig ownerFromConfig:local] copy] ?: [sProcess copy];
            if (![NKCLocalConfig configIsEnabled:local]) return;
            sContainer = [[NKCLocalConfig activeContainerFromConfig:local] copy];
        } else {
            NKCStore *store = NKCStore.sharedStore;
            sOwner = [[store ownerBundleIdentifierForProcessBundleIdentifier:sProcess] copy];
            if (![store isEnabledForBundleIdentifier:sOwner]) return;
            sContainer = [[store activeContainerIdentifierForBundleIdentifier:sOwner] copy];
        }
        if (!sContainer.length || [sContainer isEqualToString:NKCDefaultContainerIdentifier]) return;

        NSString *home = NSHomeDirectory();
        if (!home.length) return;
        NSRange marker = [home rangeOfString:@"/.nkcrane/"];
        NSString *realHome = marker.location == NSNotFound ? home : [home substringToIndex:marker.location];
        NSString *mappedHome = [[[realHome stringByAppendingPathComponent:@".nkcrane"] stringByAppendingPathComponent:sContainer] stringByAppendingPathComponent:@"Root"];

        sSuitePrefix = [[NSString stringWithFormat:@"com.nktouch.nkcrane.suite.%@.%@", NKCSafeComponent(sOwner), NKCSafeComponent(sContainer)] copy];
        sEnabled = YES;

        Method initSuite = class_getInstanceMethod(NSUserDefaults.class, @selector(initWithSuiteName:));
        if (initSuite) MSHookMessageEx(NSUserDefaults.class, @selector(initWithSuiteName:), (IMP)NKC_NSUserDefaults_initWithSuiteName, (IMP *)&orig_NSUserDefaults_initWithSuiteName);

        Class meta = object_getClass(NSUserDefaults.class);
        Method standard = class_getClassMethod(NSUserDefaults.class, @selector(standardUserDefaults));
        if (meta && standard) MSHookMessageEx(meta, @selector(standardUserDefaults), (IMP)NKC_NSUserDefaults_standardUserDefaults, (IMP *)&orig_NSUserDefaults_standardUserDefaults);

        NKCWriteRuntimeMarker(realHome, mappedHome);
    }
}
