TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = roothide
THEOS_PACKAGE_DIR = packages
include $(THEOS)/makefiles/common.mk
TWEAK_NAME = WatchFix_FocusConfigCompatibility
WatchFix_FocusConfigCompatibility_FILES = FrozenFocus.xm FrozenConverter.xm PreflightSupport.mm
WatchFix_FocusConfigCompatibility_CFLAGS = -O2 -fobjc-arc -fobjc-arc-exceptions -DWF_FOCUS_READONLY_BUILD=0 -Wno-unused-function -I../../../../Utils
WatchFix_FocusConfigCompatibility_CCFLAGS = -std=c++17
WatchFix_FocusConfigCompatibility_FRAMEWORKS = Foundation
WatchFix_FocusConfigCompatibility_LDFLAGS = -Wl,-dead_strip -lroothide
include $(THEOS_MAKE_PATH)/tweak.mk
