#import <Foundation/Foundation.h>
@class NKCContainer;

NS_ASSUME_NONNULL_BEGIN

@interface NKCBackupManager : NSObject
+ (NSString *)defaultBackupRoot;
+ (NSString *)defaultBackupDirectoryForBundleIdentifier:(NSString *)bundleIdentifier;

+ (nullable NSString *)backupContainerIdentifier:(NSString *)containerIdentifier
                                bundleIdentifier:(NSString *)bundleIdentifier
                                     destination:(nullable NSString *)destination
                                           error:(NSError **)error;

+ (BOOL)restoreBackupAtPath:(NSString *)backupPath
      toContainerIdentifier:(NSString *)containerIdentifier
           bundleIdentifier:(NSString *)bundleIdentifier
                      error:(NSError **)error;

+ (nullable NKCContainer *)cloneContainerIdentifier:(NSString *)containerIdentifier
                                   bundleIdentifier:(NSString *)bundleIdentifier
                                            newName:(NSString *)newName
                                              error:(NSError **)error;

+ (nullable NSDictionary *)manifestAtBackupPath:(NSString *)backupPath error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
