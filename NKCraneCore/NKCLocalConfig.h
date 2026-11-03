#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NKCLocalConfig : NSObject
+ (nullable NSDictionary *)currentProcessConfig;
+ (BOOL)configIsEnabled:(NSDictionary *)config;
+ (nullable NSString *)activeContainerFromConfig:(NSDictionary *)config;
+ (nullable NSString *)ownerFromConfig:(NSDictionary *)config;
@end

NS_ASSUME_NONNULL_END
