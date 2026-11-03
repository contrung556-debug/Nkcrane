#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NKCPhysicalSwap : NSObject
+ (BOOL)switchBundleIdentifier:(NSString *)bundleIdentifier
          toContainerIdentifier:(NSString *)containerIdentifier
                          error:(NSError **)error;
+ (NSString *)physicalActiveForBundleIdentifier:(NSString *)bundleIdentifier;
+ (NSDictionary *)diagnosticsForBundleIdentifier:(NSString *)bundleIdentifier;
@end

NS_ASSUME_NONNULL_END
