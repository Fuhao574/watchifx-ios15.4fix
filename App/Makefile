include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = WatchFix
WATCHFIX_PLUGIN_CONFIGURATION_FILES = \
	$(foreach source,$(wildcard $(CURDIR)/../Plugins/*/*PluginConfiguration.xm),$(realpath $(source))) \
	$(foreach source,$(wildcard $(CURDIR)/../Plugins/*/*PluginConfiguration.m),$(realpath $(source)))

$(APPLICATION_NAME)_FILES = \
    $(wildcard ./App/*.swift) \
    $(wildcard ./Views/*.swift) \
    $(wildcard ./Store/*.swift) \
    $(wildcard ./Models/*.swift) \
    $(wildcard ./Bridge/*/*.xm) \
    $(wildcard ./Bridge/*/*.m) \
    $(WATCHFIX_PLUGIN_CONFIGURATION_FILES) \
    $(WATCHFIX_UTILS_FILES)
$(APPLICATION_NAME)_SWIFT_BRIDGING_HEADER = App-Bridging-Header.h
$(APPLICATION_NAME)_FRAMEWORKS = UIKit AVFoundation Combine
$(APPLICATION_NAME)_PRIVATE_FRAMEWORKS = NanoRegistry NanoSystemSettings SoftwareUpdateBridge VisualPairing PBBridgeSupport AppSupport RunningBoardServices Symbolication BridgePreferences
$(APPLICATION_NAME)_CFLAGS = -fobjc-arc -I$(CURDIR)/../Utils -I$(CURDIR)/Bridge -I$(CURDIR)/Bridge/Internal -I$(CURDIR)/Bridge/Plugin -I$(CURDIR)/Bridge/Scanner -I$(CURDIR)/Bridge/Watch
# $(APPLICATION_NAME)_LDFLAGS = -lroothide
$(APPLICATION_NAME)_RESOURCE_DIRS = Resources
# Keep ldid's entitlement syntax for the normal jailbreak toolchain, but allow
# local ad-hoc codesign builds to supply Apple's equivalent flags explicitly.
WATCHFIX_APPLICATION_CODESIGN_FLAGS ?= -S$(CURDIR)/Entitlements.xml
$(APPLICATION_NAME)_CODESIGN_FLAGS = $(WATCHFIX_APPLICATION_CODESIGN_FLAGS)

# Explicit LOCAL diagnostics App variant only; never enabled by aggregate build.
# Private fixed PID/path header must be generated/audited separately. No helper
# executable, extra entitlement, compatibility runtime or SleepSync change.
ifeq ($(WATCHFIX_HEALTH_DIAGNOSTICS),1)
ifeq ($(strip $(WATCHFIX_HEALTH_DIAGNOSTICS_INCLUDE)),)
$(error "Diagnostics opt-in requires private fixed configuration include directory")
endif
$(APPLICATION_NAME)_FILES += $(CURDIR)/../Modules/HealthSupport/AppDiagnostics/FixedMappingDiagnostic.m
$(APPLICATION_NAME)_CFLAGS += -DWATCHFIX_HEALTH_DIAGNOSTICS=1 -fobjc-arc-exceptions -I$(WATCHFIX_HEALTH_DIAGNOSTICS_INCLUDE)
$(APPLICATION_NAME)_SWIFTFLAGS += -D WATCHFIX_HEALTH_DIAGNOSTICS
endif

include $(THEOS_MAKE_PATH)/application.mk
