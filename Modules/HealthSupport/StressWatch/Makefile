TARGET := iphone:clang:16.5:15.0
ARCHS = arm64e
THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk
LIBRARY_NAME = StressWatchCompatibility
StressWatchCompatibility_FILES = StressWatchCompatibility.m
StressWatchCompatibility_CFLAGS = -fobjc-arc -Wall -Wextra -Werror
StressWatchCompatibility_FRAMEWORKS = Foundation
StressWatchCompatibility_INSTALL_PATH = /Applications/WatchFix.app/PlugIns/HealthSupport.wffix/StressWatch
include $(THEOS_MAKE_PATH)/library.mk

internal-library-stage_::
	@cp "$(CURDIR)/Filter.plist" "$(THEOS_STAGING_DIR)$(StressWatchCompatibility_INSTALL_PATH)/Filter.plist"
	@python3 "$(CURDIR)/stage_identity.py" "$(THEOS_STAGING_DIR)$(StressWatchCompatibility_INSTALL_PATH)"
