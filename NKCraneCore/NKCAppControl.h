#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NKCAppControl : NSObject
+ (nullable NSString *)executableNameForBundleIdentifier:(NSString *)bundleIdentifier;
+ (BOOL)terminateBundleIdentifier:(NSString *)bundleIdentifier error:(NSError **)error;
+ (BOOL)launchBundleIdentifier:(NSString *)bundleIdentifier error:(NSError **)error;
+ (BOOL)restartBundleIdentifier:(NSString *)bundleIdentifier relaunch:(BOOL)relaunch error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
