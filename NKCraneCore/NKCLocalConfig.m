#import "NKCLocalConfig.h"

@implementation NKCLocalConfig

+ (nullable NSDictionary *)currentProcessConfig {
    NSString *home = NSHomeDirectory();
    if (!home.length) return nil;
    NSString *path = [[home stringByAppendingPathComponent:@".nkcrane"] stringByAppendingPathComponent:@"config.json"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data.length) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [obj isKindOfClass:NSDictionary.class] ? obj : nil;
}

+ (BOOL)configIsEnabled:(NSDictionary *)config {
    return [config[@"enabled"] boolValue];
}

+ (nullable NSString *)activeContainerFromConfig:(NSDictionary *)config {
    NSString *value = config[@"active_container_id"];
    return [value isKindOfClass:NSString.class] && value.length ? value : nil;
}

+ (nullable NSString *)ownerFromConfig:(NSDictionary *)config {
    NSString *value = config[@"owner_bundle_id"];
    return [value isKindOfClass:NSString.class] && value.length ? value : nil;
}

@end
