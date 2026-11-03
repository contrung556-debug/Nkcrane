#import <Foundation/Foundation.h>
@class NKCContainer;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const NKCDefaultContainerIdentifier;
FOUNDATION_EXPORT NSString * const NKCPreferencesPath;

@interface NKCStore : NSObject
+ (instancetype)sharedStore;

- (BOOL)isEnabledForBundleIdentifier:(NSString *)bundleIdentifier;
- (void)setEnabled:(BOOL)enabled forBundleIdentifier:(NSString *)bundleIdentifier;

- (NSArray<NKCContainer *> *)containersForBundleIdentifier:(NSString *)bundleIdentifier;
- (nullable NKCContainer *)containerForIdentifierOrName:(NSString *)value bundleIdentifier:(NSString *)bundleIdentifier;
- (NKCContainer *)createContainerNamed:(NSString *)name bundleIdentifier:(NSString *)bundleIdentifier;
- (BOOL)renameContainer:(NSString *)identifier toName:(NSString *)newName bundleIdentifier:(NSString *)bundleIdentifier error:(NSError **)error;
- (BOOL)deleteContainer:(NSString *)identifier bundleIdentifier:(NSString *)bundleIdentifier error:(NSError **)error;
- (BOOL)wipeContainer:(NSString *)identifier bundleIdentifier:(NSString *)bundleIdentifier error:(NSError **)error;

- (NSString *)activeContainerIdentifierForBundleIdentifier:(NSString *)bundleIdentifier;
- (BOOL)setActiveContainerIdentifier:(NSString *)identifier bundleIdentifier:(NSString *)bundleIdentifier error:(NSError **)error;

// v0.4 bundle-family coordination. A child/extension resolves to an owner app.
- (NSString *)ownerBundleIdentifierForProcessBundleIdentifier:(NSString *)processBundleIdentifier;
- (NSArray<NSString *> *)linkedBundleIdentifiersForOwnerBundleIdentifier:(NSString *)ownerBundleIdentifier;
- (BOOL)linkBundleIdentifier:(NSString *)childBundleIdentifier toOwnerBundleIdentifier:(NSString *)ownerBundleIdentifier error:(NSError **)error;
- (BOOL)unlinkBundleIdentifier:(NSString *)childBundleIdentifier error:(NSError **)error;

- (NSString *)preferencesDomainForBundleIdentifier:(NSString *)bundleIdentifier containerIdentifier:(NSString *)identifier;
- (nullable NSString *)realDataContainerPathForBundleIdentifier:(NSString *)bundleIdentifier;
- (nullable NSString *)rootPathForContainerIdentifier:(NSString *)identifier bundleIdentifier:(NSString *)bundleIdentifier create:(BOOL)create;
@end

NS_ASSUME_NONNULL_END
