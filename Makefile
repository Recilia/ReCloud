# No explicit SDK/deployment in TARGET so the per-arch values below apply.
# arm64 stays on the iOS 11.2 SDK: newer SDKs auto-link AVFAudio (iOS 14+) and
# other new symbols, which makes the app fail to launch on iOS 11-13.
# The notched/letterbox fix (bumping the Mach-O SDK field to 18.0 + adding a
# launch storyboard) is applied to the .ipa by make_modern_ipa.py instead.
# armv7 stays on the iOS 9.3 SDK for iOS 6-10.
TARGET = iphone:clang
ARCHS = armv7 arm64
SDKVERSION_arm64 = 11.2
SDKVERSION_armv7 = 9.3
TARGET_OS_DEPLOYMENT_VERSION_arm64 = 11.0
TARGET_OS_DEPLOYMENT_VERSION_armv7 = 6.0

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = ReinMusic

# Sources live under src/<area>/. Find them automatically so adding a file
# only means dropping it in the right folder.
SRC_DIRS := $(shell find src -type d)
ReinMusic_FILES = $(shell find src -name '*.m' | sort)

ReinMusic_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore MediaPlayer
# Every source folder is on the include path, so a file can import a header
# from another area by name (e.g. #import "LTAuth.h") regardless of location.
ReinMusic_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-objc-interface-ivars \
	$(addprefix -I,$(SRC_DIRS))
ReinMusic_LDFLAGS = -Wl,-U,_memcpy -Wl,-U,_memset -Wl,-U,__Unwind_Resume

include $(THEOS_MAKE_PATH)/application.mk
