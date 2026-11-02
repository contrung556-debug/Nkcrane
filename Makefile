ARCHS = arm64
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = NKCrane
NKCrane_FILES = Tweak.xm NKCraneCore/NKCStore.m NKCraneCore/NKCContainer.m
NKCrane_CFLAGS = -fobjc-arc -I$(THEOS_PROJECT_DIR)/NKCraneCore
NKCrane_FRAMEWORKS = Foundation UIKit Security

TOOL_NAME = nkcranectl
nkcranectl_FILES = CLI/main.m NKCraneCore/NKCStore.m NKCraneCore/NKCContainer.m NKCraneCore/NKCAppControl.m
nkcranectl_CFLAGS = -fobjc-arc -I$(THEOS_PROJECT_DIR)/NKCraneCore
nkcranectl_FRAMEWORKS = Foundation Security
nkcranectl_INSTALL_PATH = /usr/local/bin

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/tool.mk

after-install::
	install.exec "killall -9 SpringBoard || true"
