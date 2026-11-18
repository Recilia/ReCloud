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
ReinMusic_FILES = main.m \
	LTAppDelegate.m \
	LTModel.m \
	LTAuth.m \
	LTYouTubeClient.m \
	LTSignInViewController.m \
	LTTabBarController.m \
	LTSplitContainerViewController.m \
	LTHomeViewController.m \
	LTSettingsViewController.m \
	LTGraphics.m \
	LTHaptics.m \
	LTAppIcon.m \
	LTLucideIcons.m \
	LTSearchViewController.m \
	LTTrackListViewController.m \
	LTArtistViewController.m \
	LTPlayerViewController.m \
	LTPlayerController.m \
	LTQueueViewController.m \
	LTPlaylistStore.m \
	LTDownloadQueueViewController.m \
	LTPlaylistPicker.m \
	LTSongMenu.m \
	LTSyncServer.m \
	LTP2PSync.m \
	LTLocalPlaylistDetailViewController.m \
	LTMediaCell.m \
	LTShelfCell.m \
	LTPersonalShelves.m \
	LTToast.m \
	LTTableSongMenu.m \
	LTTextUtils.m \
	LTTheme.m \
	LTSafeArea.m \
	LTSimpleCell.m \
	LTHeaderView.m \
	LTCustomActionSheet.m \
	LTTransitionSettings.m \
	LTTransitionSpeedViewController.m \
	LTRecentsTileSizeViewController.m \
	LTOneHandedMode.m \
	LTOneHandedModeViewController.m \
	LTAppTabBar.m \
	LTWebExporter.m \
	LTPlaylistSelectViewController.m \
	LTLibraryViewController.m \
	LTLibrarySongsViewController.m \
	LTSpinnerView.m \
	LTStatsViewController.m \
	LTStatsDetailViewController.m \
	LTDebugMenuViewController.m \
	LTDebugSettings.m \
	LTUpdater.m \
	LTiPodViewController.m
ReinMusic_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore MediaPlayer
ReinMusic_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-objc-interface-ivars
ReinMusic_LDFLAGS = -Wl,-U,_memcpy -Wl,-U,_memset -Wl,-U,__Unwind_Resume

include $(THEOS_MAKE_PATH)/application.mk
