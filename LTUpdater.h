#import <Foundation/Foundation.h>

// GitHub Releases updater. Manual only: nothing runs at launch or on a timer
// — the user taps "Check for Updates" in Settings, and only then does the app
// contact GitHub.
//
// Flow: GET /repos/Recilia/ReinMusic/releases/latest -> compare tag_name with
// the running CFBundleVersion -> if newer, pick the asset that matches this
// install (rootful .deb on jailbroken devices, otherwise the .ipa that fits
// the CPU) and download it into the app's Documents folder. Installing is
// handed to the device (Filza can install a .deb), since an app cannot run
// dpkg itself.
@interface LTUpdater : NSObject

// Running version, e.g. "3.4" (CFBundleVersion).
+ (NSString *)currentVersion;

// YES when the release is newer than the running build.
+ (BOOL)isReleaseNewer:(NSDictionary *)release;

// Human-readable release version ("3.4") from a release dictionary.
+ (NSString *)versionForRelease:(NSDictionary *)release;

// The asset to download for this device, or nil if the release has none.
+ (NSDictionary *)assetForRelease:(NSDictionary *)release;

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

// Opens a downloaded file in Filza (installs .deb packages there) when Filza
// is installed. Returns NO if it could not be handed off.
+ (BOOL)openDownloadedFileInFilza:(NSString *)path;

@end
