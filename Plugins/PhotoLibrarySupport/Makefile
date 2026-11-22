PLUGIN_NAME = PhotoLibrarySupport
WATCHFIX_PLUGIN_SHORT_VERSION = 1.0.2
WATCHFIX_PLUGIN_VERSION = 1.0.2~ios154context4
WATCHFIX_PLUGIN_RESOURCE_DIRS = Resources
WATCHFIX_PLUGIN_FRAMEWORKS = Photos
WATCHFIX_PLUGIN_PRIVATE_FRAMEWORKS = IDS NanoRegistry ProtocolBuffer AppSupport
WATCHFIX_PHOTO_DIAGNOSTICS ?= 0
# Keep test logging objects separate: Theos can reuse the final dylib when only
# CFLAGS change, even though device test logging must stay out of default builds.
override THEOS_OBJ_DIR_NAME := obj/photo-context$(WATCHFIX_PHOTO_DIAGNOSTICS)
WATCHFIX_PLUGIN_CFLAGS = -fobjc-arc $(WATCHFIX_UTILS_CFLAGS) -DWF_PHOTO_CONTEXT_DIAGNOSTICS=$(WATCHFIX_PHOTO_DIAGNOSTICS)
PhotoLibrarySupport_CCFLAGS = -std=c++17
PhotoLibrarySupport_LDFLAGS = -lroothide

include ../plugin.mk
