#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NKCKeychainArchive : NSObject
+ (NSDictionary *)exportForOwnerBundleIdentifier:(NSString *)ownerBundleIdentifier
                              containerIdentifier:(NSString *)containerIdentifier
                                           toPath:(NSString *)path;

+ (NSDictionary *)restoreForOwnerBundleIdentifier:(NSString *)ownerBundleIdentifier
                               containerIdentifier:(NSString *)containerIdentifier
                                         fromPath:(NSString *)path;
@end

NS_ASSUME_NONNULL_END
