TARGET := iphone:clang:16.5:15.0
WATCHFIX_PLUGIN_MINIMUM_OS_VERSION = 15.0
PLUGIN_NAME = HealthSupport
WATCHFIX_PLUGIN_SHORT_VERSION = 1.0.0
WATCHFIX_PLUGIN_VERSION = 1.0.0~healthsupport1
WATCHFIX_PLUGIN_RESOURCE_DIRS = Resources
WATCHFIX_PLUGIN_FRAMEWORKS = Foundation

# healthd only, and arm64e only. A fat (arm64 + arm64e) build of this dylib,
# loaded into healthd on 15.4, gets the daemon killed with
# OS_REASON_CODESIGNING every now and then; the arm64e slice alone loaded
# cleanly each time it was tried.
ARCHS = arm64e

HEALTHSUPPORT = ../../Modules/HealthSupport
WATCHFIX_PLUGIN_FILES = \
	$(HEALTHSUPPORT)/Runtime/HealthSupportRuntime.mm \
	$(HEALTHSUPPORT)/Runtime/EnableMarker.mm \
	$(HEALTHSUPPORT)/Runtime/RuntimeSignal.mm \
	$(HEALTHSUPPORT)/Bootstrap/Exact154Targets.mm \
	$(HEALTHSUPPORT)/Adapters/DayProjectionAdapter.mm \
	$(HEALTHSUPPORT)/Adapters/DayProjectionInstall.mm \
	$(HEALTHSUPPORT)/Adapters/HealthSupportBootstrap.mm \
	$(HEALTHSUPPORT)/Adapters/SleepAcceptDomain.mm \
	$(HEALTHSUPPORT)/Adapters/LegacyPeriodAdapter.mm \
	$(HEALTHSUPPORT)/Adapters/SleepSampleAdapter.mm \
	$(HEALTHSUPPORT)/Adapters/MethodExchangeInstaller.m \
	$(HEALTHSUPPORT)/Adapters/DayBuilderSnapshot.m \
	$(HEALTHSUPPORT)/Adapters/LoadedMethodIdentity.m \
	$(HEALTHSUPPORT)/Adapters/IOS154BoundaryIdentity.m
WATCHFIX_PLUGIN_CFLAGS = -fobjc-arc -Wall -Wextra \
	-I$(HEALTHSUPPORT)/Runtime \
	-I$(HEALTHSUPPORT)/Adapters \
	-I$(HEALTHSUPPORT)/Core \
	-I$(HEALTHSUPPORT)/Bootstrap
# CCFLAGS reaches C++/Objective-C++ rules only, so .m files stay Objective-C.
HealthSupport_CCFLAGS = -std=gnu++17

include ../plugin.mk
