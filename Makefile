ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BaojunBleVerify
BaojunBleVerify_FILES = Tweak.x
BaojunBleVerify_CFLAGS = -fobjc-arc
BaojunBleVerify_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
