#import "LTUpdater.h"
#import "LTLog.h"
#import <UIKit/UIKit.h>
#import <sys/utsname.h>

static NSString *const LTUpdaterLatestReleaseURL =
    @"https://api.github.com/repos/Recilia/ReinMusic/releases/latest";

// GitHub's REST API rejects requests without a User-Agent.
static NSString *const LTUpdaterUserAgent = @"ReinMusic-Updater";

@implementation LTUpdater

#pragma mark - Versioning

+ (NSString *)currentVersion {
    NSString *version = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"];
    if (!version.length) {
        version = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    }
    return version ?: @"0";
}

+ (NSString *)versionForRelease:(NSDictionary *)release {
    id tag = [release objectForKey:@"tag_name"];
    if (![tag isKindOfClass:[NSString class]]) return nil;
    NSString *version = tag;
    if ([version hasPrefix:@"v"] || [version hasPrefix:@"V"]) {
        version = [version substringFromIndex:1];
    }
    return version.length ? version : nil;
}

// Dotted numeric comparison: "3.10" > "3.9", missing components count as 0.
static NSInteger LTCompareVersions(NSString *a, NSString *b) {
    NSArray *pa = [a componentsSeparatedByString:@"."];
    NSArray *pb = [b componentsSeparatedByString:@"."];
    NSUInteger count = MAX(pa.count, pb.count);
    for (NSUInteger i = 0; i < count; i++) {
        NSInteger va = i < pa.count ? [[pa objectAtIndex:i] integerValue] : 0;
        NSInteger vb = i < pb.count ? [[pb objectAtIndex:i] integerValue] : 0;
        if (va != vb) return va < vb ? -1 : 1;
    }
    return 0;
}

+ (BOOL)isReleaseNewer:(NSDictionary *)release {
    NSString *latest = [self versionForRelease:release];
    if (!latest.length) return NO;
    return LTCompareVersions(latest, [self currentVersion]) > 0;
}

#pragma mark - Device / install type

+ (BOOL)isJailbroken {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *paths = @[@"/Applications/Cydia.app",
                       @"/Applications/Sileo.app",
                       @"/var/lib/dpkg/status",
                       @"/bin/bash",
                       @"/usr/sbin/sshd"];
    for (NSString *path in paths) {
        if ([fm fileExistsAtPath:path]) return YES;
    }
    return NO;
}

// 64-bit slice => modern device; the 32-bit slice covers the legacy phones.
+ (BOOL)isModernDevice {
    return sizeof(void *) == 8;
}

// Asset name suffixes in preference order for this install.
+ (NSArray *)preferredAssetSuffixes {
    if ([self isJailbroken]) return @[@"-rootful.deb", @".deb"];
    if ([self isModernDevice]) return @[@".ipa"];
    return @[@"-legacy.ipa", @".ipa"];
}

+ (NSDictionary *)assetForRelease:(NSDictionary *)release {
    id assets = [release objectForKey:@"assets"];
    if (![assets isKindOfClass:[NSArray class]]) return nil;
    NSArray *suffixes = [self preferredAssetSuffixes];
    for (NSString *suffix in suffixes) {
        for (id a in assets) {
            if (![a isKindOfClass:[NSDictionary class]]) continue;
            NSString *name = [a objectForKey:@"name"];
            if (![name isKindOfClass:[NSString class]]) continue;
            NSString *lower = [name lowercaseString];
            if (![lower hasSuffix:[suffix lowercaseString]]) continue;
            // On modern devices skip the legacy build when the plain .ipa exists.
            if ([self isModernDevice] && ![self isJailbroken] &&
                [lower hasSuffix:@"-legacy.ipa"] && ![suffix isEqualToString:@"-legacy.ipa"]) {
                continue;
            }
            if ([a objectForKey:@"browser_download_url"]) return a;
        }
    }
    return nil;
}

#pragma mark - Checking

+ (void)checkForUpdateWithCompletion:(void (^)(NSDictionary *release,
                                               NSString *latestVersion,
                                               NSError *error))completion {
    void (^finish)(NSDictionary *, NSString *, NSError *) = ^(NSDictionary *release,
                                                              NSString *version,
                                                              NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(release, version, error);
        });
    };

    NSURL *url = [NSURL URLWithString:LTUpdaterLatestReleaseURL];
    NSMutableURLRequest *request =
        [NSMutableURLRequest requestWithURL:url
                                cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                            timeoutInterval:20.0];
    [request setValue:LTUpdaterUserAgent forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"application/vnd.github.v3+json" forHTTPHeaderField:@"Accept"];

    [NSURLConnection sendAsynchronousRequest:request
                                       queue:[NSOperationQueue mainQueue]
                           completionHandler:^(NSURLResponse *response, NSData *data, NSError *connectionError) {
        if (connectionError) {
            LTLog(@"UPDATER check error %@", connectionError);
            finish(nil, nil, connectionError);
            return;
        }
        NSInteger status = 0;
        if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
            status = [(NSHTTPURLResponse *)response statusCode];
        }
        if (status != 200) {
            LTLog(@"UPDATER check http %d", (int)status);
            NSError *error = [NSError errorWithDomain:@"LTUpdater"
                                                 code:status
                                             userInfo:@{NSLocalizedDescriptionKey:
                                                            @"GitHub returned an error. Try again in a minute."}];
            finish(nil, nil, error);
            return;
        }
        NSError *parseError = nil;
        id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseError] : nil;
        if (![json isKindOfClass:[NSDictionary class]]) {
            LTLog(@"UPDATER parse error %@", parseError);
            finish(nil, nil, parseError ?: [NSError errorWithDomain:@"LTUpdater"
                                                              code:-1
                                                          userInfo:@{NSLocalizedDescriptionKey:
                                                                         @"Couldn't read the release information."}]);
            return;
        }
        finish(json, [self versionForRelease:json], nil);
    }];
}

#pragma mark - Downloading

+ (NSString *)downloadsDirectory {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docs = paths.count ? [paths objectAtIndex:0] : NSTemporaryDirectory();
    NSString *dir = [docs stringByAppendingPathComponent:@"Updates"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    return dir;
}

+ (void)downloadAsset:(NSDictionary *)asset
           completion:(void (^)(NSString *path, NSError *error))completion {
    NSString *urlString = [asset objectForKey:@"browser_download_url"];
    NSString *name = [asset objectForKey:@"name"];
    if (!urlString.length || !name.length) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(nil, [NSError errorWithDomain:@"LTUpdater"
                                                                code:-2
                                                            userInfo:@{NSLocalizedDescriptionKey:
                                                                           @"This release has no downloadable file."}]);
        });
        return;
    }

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSURL *url = [NSURL URLWithString:urlString];
        NSError *error = nil;
        NSData *data = url ? [NSData dataWithContentsOfURL:url options:0 error:&error] : nil;
        if (!data.length) {
            LTLog(@"UPDATER download failed %@", error);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(nil, error ?: [NSError errorWithDomain:@"LTUpdater"
                                                                            code:-3
                                                                        userInfo:@{NSLocalizedDescriptionKey:
                                                                                       @"Download failed. Check your connection."}]);
            });
            return;
        }
        NSString *dir = [self downloadsDirectory];
        NSString *path = [dir stringByAppendingPathComponent:name];
        [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
        BOOL ok = [data writeToFile:path atomically:YES];
        LTLog(@"UPDATER saved %@ (%lu bytes) ok=%d", path, (unsigned long)data.length, ok ? 1 : 0);
        // On jailbroken devices also stage a copy where it is easy to find
        // with shell/SSH (best effort — the sandbox usually denies this).
        if ([self isJailbroken] && [name hasSuffix:@".deb"]) {
            NSString *publicPath = [@"/var/mobile/Documents" stringByAppendingPathComponent:name];
            [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/mobile/Documents"
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:NULL];
            [[NSFileManager defaultManager] copyItemAtPath:path toPath:publicPath error:NULL];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ok) {
                if (completion) completion(nil, [NSError errorWithDomain:@"LTUpdater"
                                                                    code:-4
                                                                userInfo:@{NSLocalizedDescriptionKey:
                                                                               @"Couldn't save the download."}]);
                return;
            }
            if (completion) completion(path, nil);
        });
    });
}

#pragma mark - Install handoff

+ (BOOL)openDownloadedFileInFilza:(NSString *)path {
    if (!path.length) return NO;
    NSString *encoded = [path stringByReplacingOccurrencesOfString:@" "
                                                       withString:@"%20"];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"filza://view%@", encoded]];
    if (url && [[UIApplication sharedApplication] canOpenURL:url]) {
        [[UIApplication sharedApplication] openURL:url];
        return YES;
    }
    // Older Filza builds answer the "open" route instead.
    NSURL *alt = [NSURL URLWithString:[NSString stringWithFormat:@"filza://%@", encoded]];
    if (alt && [[UIApplication sharedApplication] canOpenURL:alt]) {
        [[UIApplication sharedApplication] openURL:alt];
        return YES;
    }
    return NO;
}

@end
