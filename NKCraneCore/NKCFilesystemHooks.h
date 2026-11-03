#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Installs low-level filesystem path virtualization for the current process.
/// Only install this for an enabled, non-default NKCrane container.
void NKCInstallFilesystemHooks(NSString *realHome, NSString *mappedHome);

NS_ASSUME_NONNULL_END
