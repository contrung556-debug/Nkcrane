ARCHS = arm64
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

before-all::
	@perl -pi -e 's/NKCrane CLI v[0-9]+\.[0-9]+\.[0-9]+/NKCrane CLI v1.1.4/g' CLI/main.m
	@perl -pi -e 's/Container Manager · v[0-9]+\.[0-9]+\.[0-9]+/Container Manager · v1.1.4/g' Manager/main.m

# v1.1.4 loader-truth diagnostics:
# Keep the crash-safe single hook layer, use Any-mode Bundle/Executable filters,
# and let nkcraneprobe inspect the live Facebook process, Dopamine safe-mode,
# and Choicy settings before making further routing changes.
TWEAK_NAME = NKCrane
NKCrane_FILES = Tweak.xm NKCraneCore/NKCStore.m NKCraneCore/NKCContainer.m NKCraneCore/NKCRegistryAdapter.m NKCraneCore/NKCShimMarker.m
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
