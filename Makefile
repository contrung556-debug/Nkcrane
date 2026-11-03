ARCHS = arm64
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

before-all::
	@perl -pi -e 's/NKCrane CLI v[0-9]+\.[0-9]+\.[0-9]+/NKCrane CLI v1.3.1/g' CLI/main.m
	@perl -pi -e 's/Container Manager · v[0-9]+\.[0-9]+\.[0-9]+/Container Manager · v1.3.1/g' Manager/main.m

# v1.3.1 runtime-unification fix:
# - Keep v1.2.2's in-app physical layout resolver.
# - Compile the low-level filesystem interception layer that previously existed
#   in the source tree but was not linked into NKCrane.dylib.
# - Resolve the canonical container through NKCStore so Foundation hooks,
#   POSIX file I/O and the compatibility .nkcrane symlink all reach the same data.
# - Delay HOME/CFFIXED_USER_HOME canonicalization until after the main Logos
#   constructor captures the real application sandbox, preventing recursive
#   container path construction.
TWEAK_NAME = NKCrane
NKCrane_FILES = Tweak.xm \
	NKCraneCore/NKCStore.m \
	NKCraneCore/NKCContainer.m \
	NKCraneCore/NKCRegistryAdapter.m \
	NKCraneCore/NKCInAppLayout.m \
	NKCraneCore/NKCFilesystemHooks.m \
	NKCraneCore/NKCFilesystemBootstrap.m \
	NKCraneCore/NKCLocalConfig.m \
	NKCraneCore/NKCShimMarker.m
NKCrane_CFLAGS = -fobjc-arc -I$(THEOS_PROJECT_DIR)/NKCraneCore
NKCrane_FRAMEWORKS = Foundation UIKit Security

TOOL_NAME = nkcranectl nkcranemeta nkcraneprobe

nkcranectl_FILES = CLI/main.m NKCraneCore/NKCRegistryMirror.m NKCraneCore/NKCStore.m NKCraneCore/NKCContainer.m NKCraneCore/NKCAppControl.m NKCraneCore/NKCBackupManager.m NKCraneCore/NKCKeychainArchive.m
nkcranectl_CFLAGS = -fobjc-arc -I$(THEOS_PROJECT_DIR)/NKCraneCore
nkcranectl_FRAMEWORKS = Foundation Security
nkcranectl_CODESIGN_FLAGS = -Snkcranectl.entitlements
nkcranectl_INSTALL_PATH = /usr/local/bin

nkcranemeta_FILES = MetadataCLI/main.m NKCraneCore/NKCStore.m NKCraneCore/NKCContainer.m
nkcranemeta_CFLAGS = -fobjc-arc -I$(THEOS_PROJECT_DIR)/NKCraneCore
nkcranemeta_FRAMEWORKS = Foundation
nkcranemeta_INSTALL_PATH = /usr/local/bin

nkcraneprobe_FILES = ProbeCLI/main.m
nkcraneprobe_CFLAGS = -fobjc-arc
nkcraneprobe_FRAMEWORKS = Foundation
nkcraneprobe_CODESIGN_FLAGS = -Snkcranectl.entitlements
nkcraneprobe_INSTALL_PATH = /usr/local/bin

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/tool.mk

SUBPROJECTS += Manager
include $(THEOS_MAKE_PATH)/aggregate.mk

after-install::
	install.exec "uicache -a 2>/dev/null || true; killall -9 SpringBoard || true"
