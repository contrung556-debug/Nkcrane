ARCHS = arm64
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = NKCranePrefs
NKCranePrefs_FILES = NKCPreferences.m
NKCranePrefs_FRAMEWORKS = Foundation UIKit
NKCranePrefs_PRIVATE_FRAMEWORKS = Preferences
NKCranePrefs_CFLAGS = -fobjc-arc
NKCranePrefs_INSTALL_PATH = /Library/PreferenceBundles

include $(THEOS_MAKE_PATH)/bundle.mk
