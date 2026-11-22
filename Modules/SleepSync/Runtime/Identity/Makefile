TARGET := iphone:clang:16.5:15.0
ARCHS = arm64e
THEOS_PACKAGE_SCHEME = roothide
THEOS_PACKAGE_DIR = packages

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WatchFix_HelloReadOnlyObserver
WatchFix_HelloReadOnlyObserver_FILES = Observer.mm
WatchFix_HelloReadOnlyObserver_CFLAGS = -fobjc-arc -fobjc-arc-exceptions -Wall -Wextra
WatchFix_HelloReadOnlyObserver_CCFLAGS = -std=c++17
WatchFix_HelloReadOnlyObserver_LDFLAGS = -lroothide
WatchFix_HelloReadOnlyObserver_FRAMEWORKS = Foundation

include $(THEOS_MAKE_PATH)/tweak.mk

# Regenerate staged Debian metadata when only source control/version changes.
.PHONY: $(THEOS_STAGING_DIR)/DEBIAN/control
$(THEOS_STAGING_DIR)/DEBIAN/control: $(CURDIR)/control
