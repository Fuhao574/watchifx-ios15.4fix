TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = roothide
include $(THEOS)/makefiles/common.mk
SUBPROJECTS =
include $(THEOS_MAKE_PATH)/aggregate.mk

# Runtime is bundled privately with the App, NOT installed as permanent hooks.
# The coordinator alone installs/restores it during an explicit user session.
before-stage::
	@$(MAKE) -C "$(CURDIR)/Runtime/Focus" all
	@$(MAKE) -C "$(CURDIR)/Runtime/Identity" all

after-stage::
	@python3 "$(CURDIR)/stage_runtime.py" "$(THEOS_STAGING_DIR)/Applications/WatchFix.app/SleepSyncRuntime"
