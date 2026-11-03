#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "NKCStore.h"

static BOOL NKCWriteConfigForProcess(NKCStore *store, NSString *owner, NSString *processBundle, NSError **error) {
    NSString *home=[store realDataContainerPathForBundleIdentifier:processBundle];
    if(!home.length) return YES;
    NSString *dir=[home stringByAppendingPathComponent:@".nkcrane"];
    if(![NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:error]) return NO;
    NSDictionary *payload=@{
        @"version":@"0.9.2",
        @"process_bundle_id":processBundle?:@"",
        @"owner_bundle_id":owner?:@"",
        @"enabled":@([store isEnabledForBundleIdentifier:owner]),
        @"active_container_id":[store activeContainerIdentifierForBundleIdentifier:owner]?:NKCDefaultContainerIdentifier,
        @"updated_at":@([[NSDate date] timeIntervalSince1970])
    };
    NSData *data=[NSJSONSerialization dataWithJSONObject:payload options:NSJSONWritingPrettyPrinted error:error];
    return data && [data writeToFile:[dir stringByAppendingPathComponent:@"config.json"] options:NSDataWritingAtomic error:error];
}

static void NKCSyncRuntimeConfig(NKCStore *store, NSString *bundle) {
    NSString *owner=[store ownerBundleIdentifierForProcessBundleIdentifier:bundle];
    if(!owner.length) return;
    NKCWriteConfigForProcess(store,owner,owner,nil);
    for(NSString *child in [store linkedBundleIdentifiersForOwnerBundleIdentifier:owner]) NKCWriteConfigForProcess(store,owner,child,nil);
}

@implementation NKCStore (NKCRuntimeConfigSync)

- (void)nkc_setEnabled:(BOOL)enabled forBundleIdentifier:(NSString *)bundleIdentifier {
    [self nkc_setEnabled:enabled forBundleIdentifier:bundleIdentifier];
    NKCSyncRuntimeConfig(self,bundleIdentifier);
}

- (BOOL)nkc_setActiveContainerIdentifier:(NSString *)identifier bundleIdentifier:(NSString *)bundleIdentifier error:(NSError **)error {
    BOOL ok=[self nkc_setActiveContainerIdentifier:identifier bundleIdentifier:bundleIdentifier error:error];
    if(ok) NKCSyncRuntimeConfig(self,bundleIdentifier);
    return ok;
}

@end

__attribute__((constructor))
static void NKCInstallRuntimeConfigSync(void) {
    Method a=class_getInstanceMethod(NKCStore.class,@selector(setEnabled:forBundleIdentifier:));
    Method b=class_getInstanceMethod(NKCStore.class,@selector(nkc_setEnabled:forBundleIdentifier:));
    if(a&&b) method_exchangeImplementations(a,b);
    Method c=class_getInstanceMethod(NKCStore.class,@selector(setActiveContainerIdentifier:bundleIdentifier:error:));
    Method d=class_getInstanceMethod(NKCStore.class,@selector(nkc_setActiveContainerIdentifier:bundleIdentifier:error:));
    if(c&&d) method_exchangeImplementations(c,d);
}
