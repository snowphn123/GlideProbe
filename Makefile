TARGET = iphone:clang:latest:14.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = WeChat

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = GlideProbe

GlideProbe_FILES = GlideProbe.m
GlideProbe_FRAMEWORKS = Foundation UIKit
GlideProbe_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-function
GlideProbe_LDFLAGS = -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/library.mk
