#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const NKCRegistryPublicDirectory;
FOUNDATION_EXPORT NSString * const NKCRegistryPath;

/// Mirrors only non-sensitive NKCrane routing state to the public registry.
/// The registry is designed to be readable from sandboxed target apps after
/// applying the NKCraneRegistry libSandy profile.
BOOL NKCRegistryMirrorSyncNow(NSError **error);

NS_ASSUME_NONNULL_END
