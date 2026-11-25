#import <Foundation/Foundation.h>

// GitHub Releases updater. Manual only: nothing runs at launch or on a timer
// — the user taps "Check for Updates" in Settings, and only then does the app
// contact GitHub.
//
// Flow: GET /repos/Recilia/ReCloud/releases/latest -> compare tag_name with
// the running CFBundleVersion -> if newer, pick the IPA built for this device
// (ReCloud-<ver>-legacy.ipa on 32-bit armv7 devices, ReCloud-<ver>.ipa on
// 64-bit devices) and download it into the app's Documents folder. Installing
// is handed to the device (Filza with AppSync, AltStore or any sideloader),
// since an app cannot install another app itself.
@interface LTUpdater : NSObject

// Running version, e.g. "3.4" (CFBundleVersion).
+ (NSString *)currentVersion;

// YES when the release is newer than the running build.
+ (BOOL)isReleaseNewer:(NSDictionary *)release;

// Human-readable release version ("3.4") from a release dictionary.
+ (NSString *)versionForRelease:(NSDictionary *)release;

// The IPA to download for this device: the -legacy build on 32-bit (armv7)
// devices, the regular arm64 build otherwise. Nil if the release has neither.
+ (NSDictionary *)assetForRelease:(NSDictionary *)release;

// YES when the running binary is the 32-bit (armv7) build, i.e. the legacy IPA.
+ (BOOL)isLegacyDevice;

// Asynchronous check against the GitHub API. Completion always runs on the
// main queue. On success `release` is the parsed JSON and `latestVersion` the
// tag without the leading "v"; on failure `error` is set.
+ (void)checkForUpdateWithCompletion:(void (^)(NSDictionary *release,
                                               NSString *latestVersion,
                                               NSError *error))completion;

// Downloads the given asset (from a release dictionary) into Documents.
// Completion runs on the main queue with the local path.
+ (void)downloadAsset:(NSDictionary *)asset
           completion:(void (^)(NSString *path, NSError *error))completion;

// Opens the downloaded IPA in Filza (which installs it when AppSync Unified
// is present) or any other app that handles IPAs. Returns NO if it could not
// be handed off.
+ (BOOL)openDownloadedFileInFilza:(NSString *)path;

@end
