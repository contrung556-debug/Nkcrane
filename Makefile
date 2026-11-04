ARCHS = arm64
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

before-all::
	@perl -pi -e 's/NKCrane CLI v[0-9]+\.[0-9]+\.[0-9]+/NKCrane CLI v1.4.0/g' CLI/main.m
	@perl -pi -e 's/Container Manager · v[0-9]+\.[0-9]+\.[0-9]+/Container Manager · v1.4.0/g' Manager/main.m

# v1.4.0 launch-stability fix:
# - Keep the in-app physical layout resolver.
# - Create canonical physical root + legacy compatibility symlink before the
#   main Logos constructor runs.
# - Do NOT interpose broad POSIX functions (open/stat/opendir/rename/...) in
#   this build; v1.3.1 proved too invasive for Facebook startup.
# - Let the existing Foundation/preferences/keychain layer operate through the
#   compatibility symlink, then canonicalize HOME/CFFIXED_USER_HOME after ctor.
TWEAK_NAME = NKCrane
NKCrane_FILES = Tweak.xm \
	NKCraneCore/NKCStore.m \
	NKCraneCore/NKCContainer.m \
	NKCraneCore/NKCRegistryAdapter.m \
	NKCraneCore/NKCInAppLayout.m \
	NKCraneCore/NKCSafeRuntime.m \
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

nkcraneprobe_FILES = ProbeCLI/main.m NKCraneCore/NKCLaunchCapsule.c
nkcraneprobe_CFLAGS = -fobjc-arc -I$(THEOS_PROJECT_DIR)/NKCraneCore
nkcraneprobe_FRAMEWORKS = Foundation
nkcraneprobe_CODESIGN_FLAGS = -Snkcranectl.entitlements
nkcraneprobe_INSTALL_PATH = /usr/local/bin

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/tool.mk

SUBPROJECTS += Manager
include $(THEOS_MAKE_PATH)/aggregate.mk

after-install::
	install.exec "uicache -a 2>/dev/null || true; killall -9 SpringBoard || true"
