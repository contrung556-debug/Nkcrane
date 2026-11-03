#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NKCPhysicalProfileManager : NSObject
+ (BOOL)switchLiveDataToContainerIdentifier:(NSString *)containerIdentifier
                            bundleIdentifier:(NSString *)bundleIdentifier
                                      error:(NSError **)error;
+ (NSString *)physicalActiveContainerIdentifierForBundleIdentifier:(NSString *)bundleIdentifier;
+ (NSDictionary *)diagnosticsForBundleIdentifier:(NSString *)bundleIdentifier;
@end

NS_ASSUME_NONNULL_END
