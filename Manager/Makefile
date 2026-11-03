ARCHS = arm64
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = NKCraneManager
NKCraneManager_FILES = main.m NKCDiagnostics.m
NKCraneManager_FRAMEWORKS = Foundation UIKit
NKCraneManager_CFLAGS = -fobjc-arc
NKCraneManager_INSTALL_PATH = /Applications

include $(THEOS_MAKE_PATH)/application.mk
