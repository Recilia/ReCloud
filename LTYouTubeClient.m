#import "LTYouTubeClient.h"
#import "LTPlaylistStore.h"
#import "LTAuth.h"
#import "LTLog.h"
#import <CommonCrypto/CommonDigest.h>

NSString *const LTAPIKey = @"AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8";
NSString *const LTBrowserUserAgent = @"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36";

NSString *const LTYouTubeDomain = @"LTYouTube";

static id LTPath(id root, id key, ...) {
    if (!root) return nil;
    id current = root;
    va_list args;
    va_start(args, key);
    for (id k = key; k != nil; k = va_arg(args, id)) {
        if ([current isKindOfClass:[NSDictionary class]]) {
            current = [current objectForKey:k];
        } else if ([current isKindOfClass:[NSArray class]]) {
            NSInteger idx = [k respondsToSelector:@selector(intValue)] ? [k intValue] : -1;
            if (idx < 0 || idx >= (NSInteger)[(NSArray *)current count]) { current = nil; break; }
            current = [current objectAtIndex:(NSUInteger)idx];
        } else {
            current = nil;
            break;
        }
    }
    va_end(args);
    return current;
}

@interface LTYouTubeClient ()
@property (nonatomic, strong) NSCache *imageCache;
@property (nonatomic, strong) NSMutableDictionary *channelAvatarCache;
@property (nonatomic, strong) NSMutableDictionary *pendingChannelAvatars;
@property (nonatomic, strong) NSMutableDictionary *pendingNameAvatars;
@end

#pragma mark - Disk artwork cache limits

// Every thumbnail the app displays (home shelves, search results, related
// tracks, artist pages, ...) used to be written to disk forever, so simply
// browsing could fill a 16 GB phone. The disk cache is now bounded: only the
// MD5-named JPEGs created by -diskCachePathForURL: are managed here, and the
// least recently used ones are dropped first. Playlist covers (cover-*.jpg)
// live in the same directory but are owned by LTPlaylistStore and never
// touched by this code.
static const unsigned long long LTArtDiskCacheLimitBytes = 32ULL * 1024ULL * 1024ULL; // 32 MB
static const NSUInteger LTArtDiskCacheLimitFiles = 400;
static const NSUInteger LTArtDiskCacheWritesPerScan = 8;

// Serial queue for JPEG encoding, writes and pruning. Keeping this work off
// the main thread avoids scroll hitches when covers arrive in bursts.
static dispatch_queue_t LTArtDiskCacheQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.legacymusic.artcache", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

// YES for cache entries only: 32 lowercase hex characters plus ".jpg".
static BOOL LTIsManagedArtFileName(NSString *name) {
    if (![name hasSuffix:@".jpg"]) return NO;
    if ([name hasPrefix:@"cover-"]) return NO;
    NSString *stem = [name stringByDeletingPathExtension];
    if (stem.length != 32) return NO;
    NSCharacterSet *nonHex =
        [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet];
    return [stem rangeOfCharacterFromSet:nonHex].location == NSNotFound;
}

@implementation LTYouTubeClient

+ (instancetype)sharedClient {
    static LTYouTubeClient *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[LTYouTubeClient alloc] init];
    });
    return shared;
}

- (id)init {
    self = [super init];
    if (self) {
        _imageCache = [[NSCache alloc] init];
        // 512MB-device budget: cap the in-memory image cache by both count and
        // decoded size. Images are also written to the disk cache, so dropping
        // them from RAM only costs a file read on the next view.
        _imageCache.countLimit = 160;
        _imageCache.totalCostLimit = 24 * 1024 * 1024;  // ~24 MB of decoded pixels
        _channelAvatarCache = [NSMutableDictionary dictionary];
        _pendingChannelAvatars = [NSMutableDictionary dictionary];
        _pendingNameAvatars = [NSMutableDictionary dictionary];
        // Older builds wrote every cover to disk with no limit. Trim that
        // backlog once on startup so existing installs get their space back.
        dispatch_async(LTArtDiskCacheQueue(), ^{
            [self pruneDiskArtworkCache];
        });
    }
    return self;
}

#pragma mark - Networking

static NSString * const kLTVisitorDataKey = @"LTVisitorData";

static NSString *LTCachedVisitorData(void) {
    return [[NSUserDefaults standardUserDefaults] stringForKey:kLTVisitorDataKey];
}

static void LTStoreVisitorData(NSString *value) {
    if (!value.length) return;
    if ([LTCachedVisitorData() isEqualToString:value]) return;
    [[NSUserDefaults standardUserDefaults] setObject:value forKey:kLTVisitorDataKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

// ytmusicapi and yt-dlp send the page's VISITOR_DATA with every InnerTube call.
// Fetch it once from music.youtube.com's ytcfg and cache it; failure is
// non-fatal (guest requests already work without it).
- (void)ensureVisitorDataWithCompletion:(void (^)(void))completion {
    if (LTCachedVisitorData().length) {
        if (completion) completion();
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:@"https://music.youtube.com/"]
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
        timeoutInterval:12.0];
    [request setValue:LTBrowserUserAgent forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"en-US,en;q=0.9" forHTTPHeaderField:@"Accept-Language"];
    [NSURLConnection sendAsynchronousRequest:request queue:[NSOperationQueue mainQueue]
                           completionHandler:^(NSURLResponse *response, NSData *data, NSError *error) {
        NSString *html = data.length ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        if (html.length) {
            NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:
                @"\"VISITOR_DATA\"\\s*:\\s*\"([^\"]+)\"" options:0 error:nil];
            NSTextCheckingResult *match = [regex firstMatchInString:html options:0
                range:NSMakeRange(0, html.length)];
            if (match.numberOfRanges > 1) {
                LTStoreVisitorData([html substringWithRange:[match rangeAtIndex:1]]);
            }
        }
        if (completion) completion();
    }];
}

- (void)postToHost:(NSString *)host path:(NSString *)path body:(NSDictionary *)body
        completion:(void (^)(id json, NSError *error))completion {
    NSString *urlString = [NSString stringWithFormat:@"https://%@/youtubei/v1/%@?key=%@&prettyPrint=false",
                           host, path, LTAPIKey];
    NSURL *url = [NSURL URLWithString:urlString];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:30.0];
    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:LTBrowserUserAgent forHTTPHeaderField:@"User-Agent"];
    NSString *origin = [NSString stringWithFormat:@"https://%@", host];
    [request setValue:[NSString stringWithFormat:@"%@/", origin] forHTTPHeaderField:@"Referer"];
    // The SAPISIDHASH is validated against the Origin header, not X-Origin;
    // the web client sends both and Google rejects the hash without Origin.
    [request setValue:origin forHTTPHeaderField:@"Origin"];
    [request setValue:origin forHTTPHeaderField:@"X-Origin"];
    // WEB_REMIX is client 67. The web client always identifies itself with
    // these headers; some responses use them to choose the signed-in layout.
    [request setValue:@"67" forHTTPHeaderField:@"X-YouTube-Client-Name"];
    [request setValue:@"1.20250721.00.00" forHTTPHeaderField:@"X-YouTube-Client-Version"];
    NSString *visitorData = LTCachedVisitorData();
    if (visitorData.length) [request setValue:visitorData forHTTPHeaderField:@"X-Goog-Visitor-Id"];

    if ([[LTAuth sharedAuth] signedIn]) {
        // Cookie-based InnerTube auth (SAPISIDHASH), same scheme the
        // YouTube Music web client uses for signed-in users.
        NSString *auth = [[LTAuth sharedAuth] authorizationHeaderForOrigin:origin];
        if (auth.length) [request setValue:auth forHTTPHeaderField:@"Authorization"];
        NSString *cookie = [[LTAuth sharedAuth] cookieHeader];
        if (cookie.length) [request setValue:cookie forHTTPHeaderField:@"Cookie"];
        // Don't let the URL loading system merge/replace the explicit Cookie
        // header with whatever happens to be in the shared store.
        [request setHTTPShouldHandleCookies:NO];
        [request setValue:@"0" forHTTPHeaderField:@"X-Goog-AuthUser"];
        // The web client marks signed-in API calls so YouTube does not fall
        // back to the guest layout.
        [request setValue:@"true" forHTTPHeaderField:@"X-Youtube-Bootstrap-Logged-In"];
    }

    NSError *serializeError = nil;
    NSData *payload = [NSJSONSerialization dataWithJSONObject:body options:0 error:&serializeError];
    if (!payload) {
        if (completion) completion(nil, serializeError);
        return;
    }
    [request setHTTPBody:payload];

    [NSURLConnection sendAsynchronousRequest:request queue:[NSOperationQueue mainQueue]
                           completionHandler:^(NSURLResponse *response, NSData *data, NSError *connectionError) {
        if (connectionError) {
            if (completion) completion(nil, connectionError);
            return;
        }
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]]
            ? [(NSHTTPURLResponse *)response statusCode] : 0;
        if (status >= 400) {
            LTLog(@"HTTP %d from %@/%@ (signed in: %d)", (int)status, host, path,
                  (int)[[LTAuth sharedAuth] signedIn]);
            NSString *message = (status == 401 || status == 403)
                ? @"YouTube rejected the account cookie (HTTP 401). Paste a fresh cookie in Settings \u2192 Account."
                : [NSString stringWithFormat:@"YouTube returned HTTP %d.", (int)status];
            if (completion) completion(nil, [self errorWithCode:status message:message]);
            return;
        }
        NSError *parseError = nil;
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseError];
        if (!obj) {
            if (completion) completion(nil, parseError);
            return;
        }
        // Any response carries the visitor id; keep it for later requests.
        if ([obj isKindOfClass:[NSDictionary class]]) {
            id responseContext = [(NSDictionary *)obj objectForKey:@"responseContext"];
            if ([responseContext isKindOfClass:[NSDictionary class]]) {
                id visitor = [(NSDictionary *)responseContext objectForKey:@"visitorData"];
                if ([visitor isKindOfClass:[NSString class]]) LTStoreVisitorData(visitor);
            }
        }
        if (completion) completion(obj, nil);
    }];
}

#pragma mark - Contexts

- (NSDictionary *)webRemixContext {
    return @{
        @"client": @{
            @"clientName": @"WEB_REMIX",
            @"clientVersion": @"1.20250721.00.00",
            @"hl": @"en",
        },
        @"user": @{},
    };
}

- (NSDictionary *)androidVRContext {
    NSMutableDictionary *client = [NSMutableDictionary dictionaryWithDictionary:@{
        @"clientName": @"ANDROID_VR",
        @"clientVersion": @"1.65.10",
        @"hl": @"en",
        @"deviceMake": @"Oculus",
        @"deviceModel": @"Quest 3",
        @"androidSdkVersion": @32,
        @"osName": @"Android",
        @"osVersion": @"12L",
        @"userAgent": @"com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
    }];
    return @{@"client": client};
}

- (NSDictionary *)iosContext {
    NSMutableDictionary *client = [NSMutableDictionary dictionaryWithDictionary:@{
        @"clientName": @"IOS",
        @"clientVersion": @"21.26.4",
        @"hl": @"en",
        @"deviceMake": @"Apple",
        @"deviceModel": @"iPhone16,2",
        @"osName": @"iPhone",
        @"osVersion": @"18.3.2.22D82",
        @"userAgent": @"com.google.ios.youtube/21.26.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
    }];
    return @{@"client": client};
}

- (NSDictionary *)androidContext {
    NSMutableDictionary *client = [NSMutableDictionary dictionaryWithDictionary:@{
        @"clientName": @"ANDROID",
        @"clientVersion": @"21.26.364",
        @"hl": @"en",
        @"androidSdkVersion": @30,
        @"osName": @"Android",
        @"osVersion": @"11",
        @"userAgent": @"com.google.android.youtube/21.26.364 (Linux; U; Android 11) gzip",
    }];
    return @{@"client": client};
}

// The mobile music client is required for timed (synced) lyric responses.
- (NSDictionary *)androidMusicContext {
    NSMutableDictionary *client = [NSMutableDictionary dictionaryWithDictionary:@{
        @"clientName": @"ANDROID_MUSIC",
        @"clientVersion": @"7.21.50",
        @"hl": @"en",
        @"androidSdkVersion": @30,
        @"osName": @"Android",
        @"osVersion": @"11",
        @"userAgent": @"com.google.android.apps.youtube.music/7.21.50 (Linux; U; Android 11) gzip",
    }];
    return @{@"client": client};
}

#pragma mark - Search

+ (NSString *)searchParamsForType:(NSString *)type {
    static NSDictionary *params = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        params = @{
            @"songs": @"EgWKAQIIAWoMEA4QChADEAQQCRAF",
            @"videos": @"EgWKAQIQAWoMEA4QChADEAQQCRAF",
            @"albums": @"EgWKAQIYAWoMEA4QChADEAQQCRAF",
            @"artists": @"EgWKAQIgAWoMEA4QChADEAQQCRAF",
            @"playlists": @"Eg-KAQwIABAAGAAgACgBMABqChAEEAMQCRAFEAo=",
        };
    });
    return [params objectForKey:type];
}

- (void)searchWithQuery:(NSString *)query type:(NSString *)type
             completion:(void (^)(NSArray *items, NSError *error))completion {
    if (!query.length) {
        if (completion) completion(nil, [self errorWithCode:1 message:@"Empty search"]);
        return;
    }
    NSMutableDictionary *body = [NSMutableDictionary dictionaryWithDictionary:@{
        @"context": [self webRemixContext],
        @"query": query,
    }];
    NSString *p = [[self class] searchParamsForType:type];
    if (p.length) [body setObject:p forKey:@"params"];

    [self postToHost:@"music.youtube.com" path:@"search" body:body completion:^(id json, NSError *error) {
        if (error || !json) {
            if (completion) completion(nil, error);
            return;
        }
        NSArray *items = [self parseSearchResults:json];
        if (completion) completion(items, nil);
    }];
}

- (void)searchVideosWithQuery:(NSString *)query
                   completion:(void (^)(NSArray *tracks, NSError *error))completion {
    if (!query.length) {
        if (completion) completion(nil, [self errorWithCode:1 message:@"Empty search"]);
        return;
    }
    NSMutableDictionary *body = [NSMutableDictionary dictionaryWithDictionary:@{
        @"context": [self webContext],
        @"query": query,
    }];
    NSString *p = [[self class] searchParamsForType:@"videos"];
    if (p.length) [body setObject:p forKey:@"params"];

    [self postToHost:@"www.youtube.com" path:@"search" body:body completion:^(id json, NSError *error) {
        if (error || !json) {
            if (completion) completion(nil, error);
            return;
        }
        NSMutableArray *tracks = [NSMutableArray array];
        [self enumerateRenderersIn:json key:@"videoRenderer" block:^(NSDictionary *renderer) {
            LTTrack *track = [self trackFromVideoRenderer:renderer];
            if (track) [tracks addObject:track];
        }];
        if (tracks.count) {
            if (completion) completion(tracks, nil);
            return;
        }
        NSMutableDictionary *fallbackBody = [NSMutableDictionary dictionaryWithDictionary:@{
            @"context": [self androidContext],
            @"query": query,
        }];
        if (p.length) [fallbackBody setObject:p forKey:@"params"];
        [self postToHost:@"www.youtube.com" path:@"search" body:fallbackBody completion:^(id fallbackJson, NSError *fallbackError) {
            if (fallbackError || !fallbackJson) {
                if (completion) completion(tracks, nil);
                return;
            }
            [self enumerateRenderersIn:fallbackJson key:@"compactVideoRenderer" block:^(NSDictionary *renderer) {
                LTTrack *track = [self trackFromCompactVideoRenderer:renderer];
                if (track) [tracks addObject:track];
            }];
            if (completion) completion(tracks, nil);
        }];
    }];
}

- (NSDictionary *)webContext {
    return @{
        @"client": @{
            @"clientName": @"WEB",
            @"clientVersion": @"2.20241112.00.00",
            @"hl": @"en",
        }
    };
}

- (LTTrack *)trackFromVideoRenderer:(NSDictionary *)renderer {
    NSString *videoId = [renderer objectForKey:@"videoId"];
    if (![videoId isKindOfClass:[NSString class]] || !videoId.length) return nil;
    id titleObj = [renderer objectForKey:@"title"];
    NSString *title = [self textFromRuns:titleObj[@"runs"]];
    if (!title.length) title = titleObj[@"simpleText"];
    if (!title.length) return nil;

    LTTrack *track = [[LTTrack alloc] init];
    track.title = title;
    track.videoId = videoId;
    track.thumbnailURL = [self compatThumbnailURL:[self videoThumbnailURL:renderer] videoId:videoId];
    NSString *lengthText = LTPath(renderer, @"lengthText", @"simpleText", nil);
    if (![lengthText isKindOfClass:[NSString class]]) lengthText = LTPath(renderer, @"lengthText", @"runs", @0, @"text", nil);
    if (lengthText.length) track.duration = [[self class] timeFromString:lengthText];
    NSArray *ownerRuns = LTPath(renderer, @"ownerText", @"runs", nil);
    NSArray *parts = [self filteredRuns:ownerRuns];
    if (parts.count) track.artist = [parts objectAtIndex:0];
    return track;
}

- (LTTrack *)trackFromCompactVideoRenderer:(NSDictionary *)renderer {
    NSString *videoId = [renderer objectForKey:@"videoId"];
    if (![videoId isKindOfClass:[NSString class]] || !videoId.length) return nil;
    id titleObj = [renderer objectForKey:@"title"];
    NSString *title = [self textFromRuns:titleObj[@"runs"]];
    if (!title.length) title = titleObj[@"simpleText"];
    if (!title.length) return nil;

    LTTrack *track = [[LTTrack alloc] init];
    track.title = title;
    track.videoId = videoId;
    track.thumbnailURL = [self compatThumbnailURL:[self videoThumbnailURL:renderer] videoId:videoId];
    NSString *lengthText = LTPath(renderer, @"lengthText", @"simpleText", nil);
    if (![lengthText isKindOfClass:[NSString class]]) lengthText = LTPath(renderer, @"lengthText", @"runs", @0, @"text", nil);
    if (lengthText.length) track.duration = [[self class] timeFromString:lengthText];
    NSArray *bylineRuns = LTPath(renderer, @"longBylineText", @"runs", nil);
    NSArray *parts = [self filteredRuns:bylineRuns];
    if (!parts.count) parts = [self filteredRuns:LTPath(renderer, @"shortBylineText", @"runs", nil)];
    if (parts.count) track.artist = [parts objectAtIndex:0];
    return track;
}

- (NSString *)videoThumbnailURL:(NSDictionary *)renderer {
    NSArray *thumbs = LTPath(renderer, @"thumbnail", @"thumbnails", nil);
    return [self largestThumbnailURLFromArray:thumbs];
}

- (NSArray *)parseSearchResults:(NSDictionary *)json {
    NSArray *sections = LTPath(json, @"contents", @"tabbedSearchResultsRenderer", @"tabs", @0,
                               @"tabRenderer", @"content", @"sectionListRenderer", @"contents", nil);
    NSMutableArray *items = [NSMutableArray array];
    for (id section in sections) {
        if (![section isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *shelf = [section objectForKey:@"musicShelfRenderer"];
        if (!shelf) continue;
        id contents = [shelf objectForKey:@"contents"];
        if (![contents isKindOfClass:[NSArray class]]) continue;
        for (id row in contents) {
            if (![row isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *item = [row objectForKey:@"musicResponsiveListItemRenderer"];
            if (!item) continue;
            id parsed = [self parseSearchItem:item];
            if (parsed) [items addObject:parsed];
        }
    }
    return items;
}

- (id)parseSearchItem:(NSDictionary *)item {
    NSArray *flex = [item objectForKey:@"flexColumns"];
    if (![flex isKindOfClass:[NSArray class]] || flex.count == 0) return nil;

    NSArray *runs = [self runsFromFlexColumn:[flex objectAtIndex:0]];
    NSString *title = [self textFromRuns:runs];
    if (!title.length) return nil;

    NSDictionary *nav = nil;
    if (runs.count) {
        id firstRun = [runs objectAtIndex:0];
        if ([firstRun isKindOfClass:[NSDictionary class]]) {
            nav = [firstRun objectForKey:@"navigationEndpoint"];
        }
    }
    if (!nav) nav = [item objectForKey:@"navigationEndpoint"];

    NSDictionary *watch = [nav objectForKey:@"watchEndpoint"];
    if (watch) {
        NSString *videoId = [watch objectForKey:@"videoId"];
        if (!videoId.length) {
            videoId = LTPath(item, @"overlay", @"content", @"musicPlayButtonRenderer",
                             @"playNavigationEndpoint", @"watchEndpoint", @"videoId", nil);
        }
        if (!videoId.length) return nil;
        LTTrack *track = [[LTTrack alloc] init];
        track.title = title;
        track.videoId = videoId;
        track.thumbnailURL = [self compatThumbnailURL:[self thumbnailFromItem:item] videoId:videoId];
        NSArray *subRuns = flex.count > 1 ? [self runsFromFlexColumn:[flex objectAtIndex:1]] : nil;
        [self applySubtitleRuns:subRuns toTrack:track];
        return track;
    }

    NSDictionary *browse = [nav objectForKey:@"browseEndpoint"];
    if (browse) {
        NSString *browseId = [browse objectForKey:@"browseId"];
        if (!browseId.length) return nil;
        LTBrowseItem *bi = [[LTBrowseItem alloc] init];
        bi.browseId = browseId;
        bi.title = title;
        bi.kind = [self kindForBrowseId:browseId];
        bi.thumbnailURL = [self thumbnailFromItem:item];
        if (bi.kind == LTBrowseKindArtist) {
            bi.thumbnailURL = [self squareAvatarURL:bi.thumbnailURL size:160];
        }
        NSArray *subRuns = flex.count > 1 ? [self runsFromFlexColumn:[flex objectAtIndex:1]] : nil;
        bi.subtitle = [self textFromRuns:subRuns];
        return bi;
    }
    return nil;
}

#pragma mark - Browse

- (void)browseAlbum:(NSString *)browseId
         completion:(void (^)(NSDictionary *info, NSArray *tracks, NSError *error))completion {
    NSDictionary *body = @{@"context": [self webRemixContext], @"browseId": browseId};
    [self postToHost:@"music.youtube.com" path:@"browse" body:body completion:^(id json, NSError *error) {
        if (error || !json) {
            if (completion) completion(nil, nil, error);
            return;
        }
        NSDictionary *info = [self headerInfo:json squareThumbnail:NO];
        NSArray *tracks = [self tracksFromShelf:json];
        if (completion) completion(info, tracks, nil);
    }];
}

- (void)browsePlaylist:(NSString *)browseId
            completion:(void (^)(NSDictionary *info, NSArray *tracks, NSError *error))completion {
    NSDictionary *body = @{@"context": [self webRemixContext], @"browseId": browseId};
    [self postToHost:@"music.youtube.com" path:@"browse" body:body completion:^(id json, NSError *error) {
        if (error || !json) {
            if (completion) completion(nil, nil, error);
            return;
        }
        NSDictionary *info = [self headerInfo:json squareThumbnail:NO];
        NSArray *tracks = [self tracksFromPlaylistShelf:json];
        if (completion) completion(info, tracks, nil);
    }];
}

- (void)browseArtist:(NSString *)browseId
          completion:(void (^)(NSDictionary *info, NSArray *topSongs, NSArray *albums, NSError *error))completion
          avatarURL:(void (^)(NSString *avatarURL))avatarBlock {
    NSDictionary *body = @{@"context": [self webRemixContext], @"browseId": browseId};
    [self postToHost:@"music.youtube.com" path:@"browse" body:body completion:^(id json, NSError *error) {
        if (error || !json) {
            if (completion) completion(nil, nil, nil, error);
            return;
        }
        NSDictionary *info = [self headerInfo:json squareThumbnail:YES];
        NSArray *topSongs = [self artistTopSongs:json];
        NSArray *albums = [self artistAlbums:json];
        if (completion) completion(info, topSongs, albums, nil);
    }];
    if (avatarBlock) {
        [self channelAvatarURLForBrowseId:browseId completion:avatarBlock];
    }
}

- (void)channelAvatarURLForBrowseId:(NSString *)browseId
                         completion:(void (^)(NSString *avatarURL))completion {
    if (!completion) return;
    if (![browseId isKindOfClass:[NSString class]] || ![browseId hasPrefix:@"UC"]) {
        completion(nil);
        return;
    }
    NSString *cached = [self.channelAvatarCache objectForKey:browseId];
    if (cached.length) {
        completion(cached);
        return;
    }
    NSMutableArray *pending = [self.pendingChannelAvatars objectForKey:browseId];
    if (!pending) {
        pending = [NSMutableArray array];
        [self.pendingChannelAvatars setObject:pending forKey:browseId];
    }
    [pending addObject:completion];
    if (pending.count > 1) return;

    NSDictionary *body = @{@"context": [self webContext], @"browseId": browseId};
    [self postToHost:@"www.youtube.com" path:@"browse" body:body completion:^(id json, NSError *error) {
        NSString *avatarURL = nil;
        if (!error && [json isKindOfClass:[NSDictionary class]]) {
            NSArray *thumbs = LTPath(json, @"metadata", @"channelMetadataRenderer", @"avatar", @"thumbnails", nil);
            avatarURL = [self largestThumbnailURLFromArray:thumbs];
            if (!avatarURL.length) {
                thumbs = LTPath(json, @"microformat", @"microformatDataRenderer", @"thumbnail", @"thumbnails", nil);
                avatarURL = [self largestThumbnailURLFromArray:thumbs];
            }
        }
        if (avatarURL.length) {
            [self.channelAvatarCache setObject:avatarURL forKey:browseId];
        }
        NSArray *waiters = [self.pendingChannelAvatars objectForKey:browseId] ?: @[];
        [self.pendingChannelAvatars removeObjectForKey:browseId];
        dispatch_async(dispatch_get_main_queue(), ^{
            for (void (^waiter)(NSString *) in waiters) {
                waiter(avatarURL);
            }
        });
    }];
}

- (void)resolveArtistAvatarForName:(NSString *)name
                        completion:(void (^)(NSString *avatarURL))completion {
    if (!completion) return;
    NSString *trimmed = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!trimmed.length) {
        completion(nil);
        return;
    }
    NSString *key = [trimmed lowercaseString];
    NSString *cached = [[LTPlaylistStore sharedStore] artistAvatarURLForName:trimmed];
    if (cached.length) {
        completion(cached);
        return;
    }
    NSMutableArray *pending = [self.pendingNameAvatars objectForKey:key];
    if (!pending) {
        pending = [NSMutableArray array];
        [self.pendingNameAvatars setObject:pending forKey:key];
    }
    [pending addObject:completion];
    if (pending.count > 1) return;

    __weak LTYouTubeClient *weakSelf = self;
    [self searchWithQuery:trimmed type:@"artists" completion:^(NSArray *items, NSError *error) {
        LTYouTubeClient *strongSelf = weakSelf;
        if (!strongSelf) return;
        NSString *browseId = nil;
        NSString *partialId = nil;
        for (id item in items) {
            if (![item isKindOfClass:[LTBrowseItem class]]) continue;
            LTBrowseItem *bi = item;
            if (bi.kind != LTBrowseKindArtist || !bi.browseId.length) continue;
            if ([[bi.title lowercaseString] isEqualToString:key]) { browseId = bi.browseId; break; }
            if (!partialId && [bi.title rangeOfString:trimmed options:NSCaseInsensitiveSearch].location != NSNotFound) {
                partialId = bi.browseId;
            }
        }
        if (!browseId.length) browseId = partialId;

        void (^finish)(NSString *) = ^(NSString *avatarURL) {
            NSString *final = avatarURL;
            if (final.length) {
                final = [strongSelf channelAvatarURL:final size:160];
                [[LTPlaylistStore sharedStore] setArtistAvatarURL:final forName:trimmed];
            }
            NSArray *waiters = [strongSelf.pendingNameAvatars objectForKey:key] ?: @[];
            [strongSelf.pendingNameAvatars removeObjectForKey:key];
            dispatch_async(dispatch_get_main_queue(), ^{
                for (void (^waiter)(NSString *) in waiters) {
                    waiter(final);
                }
            });
        };
        if (!browseId.length) {
            finish(nil);
            return;
        }
        [strongSelf channelAvatarURLForBrowseId:browseId completion:finish];
    }];
}

- (NSString *)channelAvatarURL:(NSString *)urlString size:(NSInteger)size {
    if (![urlString isKindOfClass:[NSString class]] || !urlString.length) return urlString;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"=s\\d+[a-z0-9_-]*(?=\\?|$)"
                                                                           options:0 error:nil];
    if ([regex rangeOfFirstMatchInString:urlString options:0 range:NSMakeRange(0, urlString.length)].location != NSNotFound) {
        NSMutableString *result = [urlString mutableCopy];
        [regex replaceMatchesInString:result options:0 range:NSMakeRange(0, result.length)
                         withTemplate:[NSString stringWithFormat:@"=s%ld", (long)size]];
        return result;
    }
    return urlString;
}

// The user's YouTube Music library playlists. YouTube Music serves this page
// in whichever layout the account has been migrated to (a grid of
// musicTwoRowItemRenderer tiles, a shelf of musicResponsiveListItemRenderer
// rows, single- or two-column), returns only the first ~25 entries, and can
// answer with a sign-in message when the stored cookie is stale. Items are
// therefore collected recursively from both renderer types and the grid/shelf
// continuations are followed until the whole library has been read.
- (void)fetchLibraryPlaylistsWithCompletion:(void (^)(NSArray *items, NSError *error))completion {
    if (![[LTAuth sharedAuth] signedIn]) {
        if (completion) completion(nil, [self errorWithCode:5 message:@"Not signed in"]);
        return;
    }
    NSDictionary *body = @{@"context": [self webRemixContext], @"browseId": @"FEmusic_liked_playlists"};
    NSMutableArray *items = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    NSMutableSet *visited = [NSMutableSet set];
    [self ensureVisitorDataWithCompletion:^{
        [self fetchLibraryPlaylistsPageWithBody:body
                                          items:items
                                           seen:seen
                                        visited:visited
                                          pages:0
                                     completion:completion];
    }];
}

- (void)fetchLibraryPlaylistsPageWithBody:(NSDictionary *)body
                                    items:(NSMutableArray *)items
                                     seen:(NSMutableSet *)seen
                                  visited:(NSMutableSet *)visited
                                    pages:(NSUInteger)pages
                               completion:(void (^)(NSArray *items, NSError *error))completion {
    // Guard against a malformed token chain looping forever. 40 pages is far
    // beyond a realistic library (the page returns ~25 entries each).
    if (pages >= 40) {
        if (completion) completion(items, nil);
        return;
    }
    __weak LTYouTubeClient *weakSelf = self;
    [self postToHost:@"music.youtube.com" path:@"browse" body:body completion:^(id json, NSError *error) {
        LTYouTubeClient *strongSelf = weakSelf;
        if (!strongSelf) {
            if (completion) completion(items, error);
            return;
        }
        if (![json isKindOfClass:[NSDictionary class]]) {
            // Keep whatever earlier pages produced; only fail when empty.
            if (items.count) {
                if (completion) completion(items, nil);
                return;
            }
            if (!error) error = [strongSelf errorWithCode:2 message:@"Couldn't read the library response."];
            if (completion) completion(nil, error);
            return;
        }
        NSUInteger before = items.count;
        [strongSelf collectLibraryPlaylistsFromResponse:json into:items seen:seen];
        NSString *loggedIn = [strongSelf loggedInFlagForResponse:json];
        LTLog(@"LIB playlists page=%d new=%d total=%d logged_in=%@",
              (int)pages, (int)(items.count - before), (int)items.count, loggedIn ?: @"?");
        BOOL authenticated = [loggedIn isEqualToString:@"1"] || items.count > 0;
        if (!authenticated && [strongSelf responseHasSignInPrompt:json]) {
            LTLog(@"LIB playlists response requires sign-in");
            if (completion) completion(nil, [strongSelf errorWithCode:401
                message:@"YouTube Music asked for a sign-in. Paste a fresh cookie in Settings \u2192 Account."]);
            return;
        }
        NSString *token = [strongSelf libraryContinuationTokenInResponse:json visited:visited];
        if (!token.length) token = [strongSelf continuationTokenInObject:json visited:visited];
        BOOL madeProgress = items.count > before;
        if (!token.length || (pages > 0 && !madeProgress)) {
            if (completion) completion(items, nil);
            return;
        }
        [visited addObject:token];
        NSDictionary *next = @{@"context": [strongSelf webRemixContext], @"continuation": token};
        [strongSelf fetchLibraryPlaylistsPageWithBody:next
                                                items:items
                                                 seen:seen
                                              visited:visited
                                                pages:pages + 1
                                           completion:completion];
    }];
}

// browse expects playlists as "VL"+id; library endpoints hand back either
// form. Radio mixes (RD...) and album/artist ids are deliberately rejected.
- (NSString *)normalizedLibraryPlaylistId:(NSString *)rawId {
    if (![rawId isKindOfClass:[NSString class]] || rawId.length < 3) return nil;
    if ([rawId hasPrefix:@"VL"]) {
        NSString *bare = [rawId substringFromIndex:2];
        if ([bare hasPrefix:@"PL"]) return rawId;
        return nil;
    }
    if ([rawId hasPrefix:@"PL"]) {
        return [@"VL" stringByAppendingString:rawId];
    }
    return nil;
}

// The playlist id sits in a different place in every layout (title run, tile
// endpoint, watch-playlist endpoint, edit menu), so accept the first
// browse/playlist id inside the tile that looks like a real playlist. Artist,
// album and mix ids simply do not match.
- (NSString *)libraryPlaylistIdInObject:(id)obj {
    if ([obj isKindOfClass:[NSDictionary class]]) {
        for (NSString *key in @[@"browseId", @"playlistId"]) {
            NSString *normalized = [self normalizedLibraryPlaylistId:[(NSDictionary *)obj objectForKey:key]];
            if (normalized.length) return normalized;
        }
        for (id value in [(NSDictionary *)obj allValues]) {
            NSString *found = [self libraryPlaylistIdInObject:value];
            if (found.length) return found;
        }
    } else if ([obj isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)obj) {
            NSString *found = [self libraryPlaylistIdInObject:value];
            if (found.length) return found;
        }
    }
    return nil;
}

- (NSString *)textFromTextObject:(NSDictionary *)textObject {
    if (![textObject isKindOfClass:[NSDictionary class]]) return @"";
    NSString *text = [self textFromRuns:[textObject objectForKey:@"runs"]];
    if (!text.length) {
        id simple = [textObject objectForKey:@"simpleText"];
        if ([simple isKindOfClass:[NSString class]]) text = simple;
    }
    return text ?: @"";
}

- (void)collectLibraryPlaylistsFromResponse:(NSDictionary *)json
                                       into:(NSMutableArray *)items
                                       seen:(NSMutableSet *)seen {
    // Grid layout: playlist tiles.
    [self enumerateRenderersIn:json key:@"musicTwoRowItemRenderer" block:^(NSDictionary *it) {
        NSString *title = [self textFromTextObject:[it objectForKey:@"title"]];
        if (!title.length) return;
        NSString *browseId = [self libraryPlaylistIdInObject:it];
        if (!browseId.length) return;
        NSString *dedupeKey = [browseId hasPrefix:@"VL"] ? [browseId substringFromIndex:2] : browseId;
        if (!dedupeKey.length || [seen containsObject:dedupeKey]) return;
        NSArray *thumbs = LTPath(it, @"thumbnailRenderer", @"musicThumbnailRenderer", @"thumbnail", @"thumbnails", nil);
        if (![thumbs isKindOfClass:[NSArray class]] || !thumbs.count) {
            thumbs = LTPath(it, @"thumbnail", @"musicThumbnailRenderer", @"thumbnail", @"thumbnails", nil);
        }
        LTBrowseItem *bi = [[LTBrowseItem alloc] init];
        bi.kind = LTBrowseKindPlaylist;
        bi.browseId = browseId;
        bi.title = title;
        bi.subtitle = [self textFromTextObject:[it objectForKey:@"subtitle"]];
        bi.thumbnailURL = [self largestThumbnailURLFromArray:thumbs];
        [seen addObject:dedupeKey];
        [items addObject:bi];
    }];

    // Shelf layout: responsive list rows.
    [self enumerateRenderersIn:json key:@"musicResponsiveListItemRenderer" block:^(NSDictionary *it) {
        NSArray *flexColumns = [it objectForKey:@"flexColumns"];
        if (![flexColumns isKindOfClass:[NSArray class]] || !flexColumns.count) return;
        NSString *title = [self textFromRuns:[self runsFromFlexColumn:[flexColumns objectAtIndex:0]]];
        if (!title.length) return;
        NSString *browseId = [self libraryPlaylistIdInObject:it];
        if (!browseId.length) return;
        NSString *dedupeKey = [browseId hasPrefix:@"VL"] ? [browseId substringFromIndex:2] : browseId;
        if (!dedupeKey.length || [seen containsObject:dedupeKey]) return;
        LTBrowseItem *bi = [[LTBrowseItem alloc] init];
        bi.kind = LTBrowseKindPlaylist;
        bi.browseId = browseId;
        bi.title = title;
        if (flexColumns.count > 1) {
            bi.subtitle = [self textFromRuns:[self runsFromFlexColumn:[flexColumns objectAtIndex:1]]];
        }
        NSArray *thumbs = LTPath(it, @"thumbnail", @"musicThumbnailRenderer", @"thumbnail", @"thumbnails", nil);
        bi.thumbnailURL = [self largestThumbnailURLFromArray:thumbs];
        [seen addObject:dedupeKey];
        [items addObject:bi];
    }];
}

// Prefer a token that belongs to the grid/shelf holding the playlists; the
// page can also contain other shelves with their own continuation.
- (NSString *)libraryContinuationTokenInResponse:(id)obj visited:(NSMutableSet *)visited {
    if ([obj isKindOfClass:[NSDictionary class]]) {
        for (NSString *key in @[@"gridRenderer", @"musicShelfRenderer"]) {
            id container = [(NSDictionary *)obj objectForKey:key];
            if (![container isKindOfClass:[NSDictionary class]]) continue;
            NSString *token = [self continuationTokenInObject:container visited:visited];
            if (token.length) return token;
        }
        for (id value in [(NSDictionary *)obj allValues]) {
            NSString *found = [self libraryContinuationTokenInResponse:value visited:visited];
            if (found.length) return found;
        }
    } else if ([obj isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)obj) {
            NSString *found = [self libraryContinuationTokenInResponse:value visited:visited];
            if (found.length) return found;
        }
    }
    return nil;
}

// Finds the next page token anywhere in a browse response. Handles both the
// old `continuations[].next*ContinuationData` shape and the 2025
// `continuationItemRenderer.continuationEndpoint.continuationCommand.token`.
- (NSString *)continuationTokenInObject:(id)obj visited:(NSMutableSet *)visited {
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = obj;
        id command = [dict objectForKey:@"continuationCommand"];
        if ([command isKindOfClass:[NSDictionary class]]) {
            id token = [command objectForKey:@"token"];
            if ([token isKindOfClass:[NSString class]] && [token length] && ![visited containsObject:token]) {
                return token;
            }
        }
        for (NSString *key in @[@"nextContinuationData", @"nextGridContinuationData",
                                @"nextMusicShelfContinuationData"]) {
            id data = [dict objectForKey:key];
            if (![data isKindOfClass:[NSDictionary class]]) continue;
            id token = [data objectForKey:@"continuation"];
            if ([token isKindOfClass:[NSString class]] && [token length] && ![visited containsObject:token]) {
                return token;
            }
        }
        for (id value in [dict allValues]) {
            NSString *found = [self continuationTokenInObject:value visited:visited];
            if (found.length) return found;
        }
    } else if ([obj isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)obj) {
            NSString *found = [self continuationTokenInObject:value visited:visited];
            if (found.length) return found;
        }
    }
    return nil;
}

// A stale cookie makes YouTube Music answer with a "Sign in" card instead of
// an error, which used to look like an account with zero playlists. Only a
// messageRenderer carrying signInEndpoint is that card: signed-in pages can
// contain signInEndpoint elsewhere (menus/guide entries) and must not be
// mistaken for a signed-out session.
- (BOOL)responseHasSignInPrompt:(id)obj {
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = obj;
        id message = [dict objectForKey:@"messageRenderer"];
        if ([message isKindOfClass:[NSDictionary class]] &&
            [self responseRequiresSignIn:message]) {
            return YES;
        }
        for (id value in [dict allValues]) {
            if ([self responseHasSignInPrompt:value]) return YES;
        }
    } else if ([obj isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)obj) {
            if ([self responseHasSignInPrompt:value]) return YES;
        }
    }
    return NO;
}

// A stale cookie makes YouTube Music answer with a "Sign in" button instead
// of an error, which used to look like an account with zero playlists.
- (BOOL)responseRequiresSignIn:(id)obj {
    if ([obj isKindOfClass:[NSDictionary class]]) {
        if ([(NSDictionary *)obj objectForKey:@"signInEndpoint"]) return YES;
        for (id value in [(NSDictionary *)obj allValues]) {
            if ([self responseRequiresSignIn:value]) return YES;
        }
    } else if ([obj isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)obj) {
            if ([self responseRequiresSignIn:value]) return YES;
        }
    }
    return NO;
}

// Account listening history (reverse chronological).
- (void)fetchAccountHistoryWithCompletion:(void (^)(NSArray *tracks, NSError *error))completion {
    if (![[LTAuth sharedAuth] signedIn]) {
        if (completion) completion(nil, [self errorWithCode:5 message:@"Not signed in"]);
        return;
    }
    NSDictionary *body = @{@"context": [self webRemixContext], @"browseId": @"FEmusic_history"};
    [self postToHost:@"music.youtube.com" path:@"browse" body:body completion:^(id json, NSError *error) {
        if (error || !json) {
            if (completion) completion(nil, error);
            return;
        }
        NSArray *tracks = [self tracksFromShelf:json];
        if (tracks.count > 50) {
            NSMutableArray *limited = [NSMutableArray array];
            for (NSUInteger i = 0; i < 50; i++) [limited addObject:[tracks objectAtIndex:i]];
            tracks = limited;
        }
        if (completion) completion(tracks, nil);
    }];
}

// Depth-first lookup of the first value stored under `key`. The account menu
// response has moved between popup headers and plain account headers over
// time, so the name is located by key instead of by a fixed path.
- (id)firstValueForKey:(NSString *)key inObject:(id)obj {
    if ([obj isKindOfClass:[NSDictionary class]]) {
        id direct = [(NSDictionary *)obj objectForKey:key];
        if (direct && ![direct isKindOfClass:[NSNull class]]) return direct;
        for (id value in [(NSDictionary *)obj allValues]) {
            id found = [self firstValueForKey:key inObject:value];
            if (found && ![found isKindOfClass:[NSNull class]]) return found;
        }
    } else if ([obj isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)obj) {
            id found = [self firstValueForKey:key inObject:value];
            if (found && ![found isKindOfClass:[NSNull class]]) return found;
        }
    }
    return nil;
}

// Reads the "logged_in" flag YouTube puts in responseContext.serviceTrackingParams.
// It is the ground truth for whether the server authenticated the request;
// keep it for logs because a signed-in account can still get logged_in=0 in
// some account_menu responses while the library endpoints work.
- (NSString *)loggedInFlagForResponse:(id)json {
    id params = [self firstValueForKey:@"serviceTrackingParams" inObject:json];
    if (![params isKindOfClass:[NSArray class]]) return nil;
    for (id service in (NSArray *)params) {
        if (![service isKindOfClass:[NSDictionary class]]) continue;
        id values = [service objectForKey:@"params"];
        if (![values isKindOfClass:[NSArray class]]) continue;
        for (id entry in (NSArray *)values) {
            if (![entry isKindOfClass:[NSDictionary class]]) continue;
            id key = [entry objectForKey:@"key"];
            if ([key isKindOfClass:[NSString class]] && [key isEqualToString:@"logged_in"]) {
                id value = [entry objectForKey:@"value"];
                return [value isKindOfClass:[NSString class]] ? value : nil;
            }
        }
    }
    return nil;
}

// Display name of the signed-in Google account. The name is best-effort:
// YouTube can omit it (or report logged_in=0 in the account menu) while the
// account is still authenticated, so a missing name is not treated as an
// error. checkLibraryAuthWithCompletion: is the actual sign-in test.
- (void)fetchAccountNameWithCompletion:(void (^)(NSString *name, NSError *error))completion {
    NSDictionary *body = @{@"context": [self webRemixContext]};
    [self postToHost:@"music.youtube.com" path:@"account/account_menu" body:body completion:^(id json, NSError *error) {
        if (error) {
            if (completion) completion(nil, error);
            return;
        }
        if (![json isKindOfClass:[NSDictionary class]]) {
            if (completion) completion(nil, nil);
            return;
        }

        id header = [self firstValueForKey:@"activeAccountHeaderRenderer" inObject:json];
        NSString *name = nil;
        if ([header isKindOfClass:[NSDictionary class]]) {
            name = [self textFromTextObject:[(NSDictionary *)header objectForKey:@"accountName"]];
            if (!name.length) name = [self textFromTextObject:[(NSDictionary *)header objectForKey:@"email"]];
        }
        if (!name.length) {
            id accountName = [self firstValueForKey:@"accountName" inObject:json];
            if ([accountName isKindOfClass:[NSDictionary class]]) {
                name = [self textFromTextObject:accountName];
            }
        }

        LTLog(@"AUTH account_menu logged_in=%@ name=%@",
              [self loggedInFlagForResponse:json] ?: @"?", name.length ? @"yes" : @"no");

        if (name.length) {
            if (completion) completion(name, nil);
            return;
        }
        if ([self responseRequiresSignIn:json]) {
            if (completion) completion(nil, [self errorWithCode:401
                message:@"YouTube Music did not accept the cookie. Copy it again from a browser tab that is open on music.youtube.com while signed in."]);
            return;
        }
        if (completion) completion(nil, nil);
    }];
}

// One browse request is enough to tell whether the stored cookie authenticates:
// a guest gets a "Sign in" card, a signed-in account gets the library grid
// (which may legitimately be empty). This is much more reliable than the
// account menu, which can report logged_in=0 even for working sessions.
- (void)checkLibraryAuthWithCompletion:(void (^)(BOOL signedIn, NSError *error))completion {
    if (![[LTAuth sharedAuth] signedIn]) {
        if (completion) completion(NO, [self errorWithCode:5 message:@"Not signed in"]);
        return;
    }
    NSDictionary *body = @{@"context": [self webRemixContext], @"browseId": @"FEmusic_liked_playlists"};
    [self ensureVisitorDataWithCompletion:^{
        [self postToHost:@"music.youtube.com" path:@"browse" body:body completion:^(id json, NSError *error) {
        if (error) {
            if (completion) completion(NO, error);
            return;
        }
        if (![json isKindOfClass:[NSDictionary class]]) {
            if (completion) completion(NO, [self errorWithCode:2 message:@"Couldn't read YouTube's response."]);
            return;
        }
        NSMutableArray *items = [NSMutableArray array];
        NSMutableSet *seen = [NSMutableSet set];
        [self collectLibraryPlaylistsFromResponse:json into:items seen:seen];
        NSString *loggedIn = [self loggedInFlagForResponse:json];
        BOOL requiresSignIn = [self responseHasSignInPrompt:json];
        LTLog(@"AUTH library probe logged_in=%@ items=%d signInPrompt=%d",
              loggedIn ?: @"?", (int)items.count, (int)requiresSignIn);
        BOOL authenticated = [loggedIn isEqualToString:@"1"] || items.count > 0;
        if (!authenticated && requiresSignIn) {
            NSString *reason = [[LTAuth sharedAuth] hasLoginInfo]
                ? @"YouTube Music still treats this session as signed out. The cookie may be expired, copied from the wrong site, or tied to another network."
                : @"The pasted cookie only contains SAPISID/APISID. YouTube now requires the full Cookie header, including LOGIN_INFO, SID, HSID and SSID.";
            if (completion) completion(NO, [self errorWithCode:401 message:reason]);
            return;
        }
        if (completion) completion(YES, nil);
        }];
    }];
}

// Mixes/rotations ("RD..." playlist ids) come through the next endpoint.
- (void)fetchRadioTracksForPlaylistId:(NSString *)playlistId
                           completion:(void (^)(NSArray *tracks, NSError *error))completion {
    if (!playlistId.length) {
        if (completion) completion(nil, [self errorWithCode:1 message:@"No playlist id"]);
        return;
    }
    NSDictionary *body = @{@"context": [self webRemixContext], @"playlistId": playlistId};
    __weak LTYouTubeClient *weakSelf = self;
    [self postToHost:@"music.youtube.com" path:@"next" body:body completion:^(id json, NSError *error) {
        LTYouTubeClient *strongSelf = weakSelf;
        if (!strongSelf) {
            if (completion) completion(nil, error);
            return;
        }
        if (error || !json) {
            if (completion) completion(nil, error);
            return;
        }
        NSMutableArray *tracks = [NSMutableArray array];
        [strongSelf enumerateRenderersIn:json key:@"playlistPanelVideoRenderer" block:^(NSDictionary *renderer) {
            LTTrack *track = [strongSelf trackFromPanelVideoRenderer:renderer];
            if (track) [tracks addObject:track];
        }];
        if (completion) completion(tracks, nil);
    }];
}

- (LTTrack *)trackFromPanelVideoRenderer:(NSDictionary *)renderer {
    NSString *videoId = [renderer objectForKey:@"videoId"];
    if (![videoId isKindOfClass:[NSString class]] || !videoId.length) return nil;
    NSString *title = [self textFromRuns:LTPath(renderer, @"title", @"runs", nil)];
    if (!title.length) return nil;

    LTTrack *track = [[LTTrack alloc] init];
    track.title = title;
    track.videoId = videoId;
    NSArray *thumbs = LTPath(renderer, @"thumbnail", @"thumbnails", nil);
    track.thumbnailURL = [self compatThumbnailURL:[self largestThumbnailURLFromArray:thumbs] videoId:videoId];
    NSArray *byline = [self filteredRuns:LTPath(renderer, @"longBylineText", @"runs", nil)];
    if (!byline.count) byline = [self filteredRuns:LTPath(renderer, @"shortBylineText", @"runs", nil)];
    if (byline.count) track.artist = [byline objectAtIndex:0];
    NSString *lengthText = LTPath(renderer, @"lengthText", @"runs", @0, @"text", nil);
    if ([lengthText isKindOfClass:[NSString class]]) {
        track.duration = [[self class] timeFromString:lengthText];
    }
    return track;
}


- (NSDictionary *)headerInfo:(NSDictionary *)json squareThumbnail:(BOOL)square {
    NSString *title = nil, *subtitle = nil, *thumb = nil;

    id immersive = LTPath(json, @"header", @"musicImmersiveHeaderRenderer", nil);
    if ([immersive isKindOfClass:[NSDictionary class]]) {
        title = [self textFromRuns:[immersive objectForKey:@"title"][@"runs"]];
        thumb = [self thumbnailFromHeader:immersive];
    }

    if (!title) {
        NSArray *sections = LTPath(json, @"contents", @"singleColumnBrowseResultsRenderer", @"tabs", @0,
                                   @"tabRenderer", @"content", @"sectionListRenderer", @"contents", nil);
        for (id section in sections) {
            if (![section isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *header = [section objectForKey:@"musicResponsiveHeaderRenderer"];
            if (!header) continue;
            title = [self textFromRuns:[header objectForKey:@"title"][@"runs"]];
            subtitle = [self textFromRuns:[header objectForKey:@"subtitle"][@"runs"]];
            thumb = [self thumbnailFromHeader:header];
            break;
        }
    }

    if (!title) {
        id detail = LTPath(json, @"contents", @"twoColumnBrowseResultsRenderer", @"tabs", @0,
                           @"tabRenderer", @"content", @"sectionListRenderer", @"contents", @0,
                           @"musicDetailHeaderRenderer", nil);
        if (![detail isKindOfClass:[NSDictionary class]]) {
            detail = LTPath(json, @"contents", @"singleColumnBrowseResultsRenderer", @"tabs", @0,
                            @"tabRenderer", @"content", @"musicDetailHeaderRenderer", nil);
        }
        if ([detail isKindOfClass:[NSDictionary class]]) {
            title = [self textFromRuns:[detail objectForKey:@"title"][@"runs"]];
            subtitle = [self subtitleForDetailHeader:detail];
            thumb = [self thumbnailFromHeader:detail];
        }
    }

    if (square && thumb.length) thumb = [self squareAvatarURL:thumb size:720];

    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    if (title.length) [info setObject:title forKey:@"title"];
    if (subtitle.length) [info setObject:subtitle forKey:@"subtitle"];
    if (thumb.length) [info setObject:thumb forKey:@"thumbnail"];
    return info;
}

- (NSString *)subtitleForDetailHeader:(NSDictionary *)detail {
    NSMutableArray *parts = [NSMutableArray array];
    NSArray *s1 = [detail objectForKey:@"subtitle"][@"runs"];
    for (id run in s1) {
        if ([run isKindOfClass:[NSDictionary class]]) {
            NSString *text = [run objectForKey:@"text"];
            if (text.length) [parts addObject:text];
        }
    }
    id affects = [detail objectForKey:@"subtitle"][@"content"];
    if ([affects isKindOfClass:[NSString class]] && ((NSString *)affects).length) {
        [parts addObject:affects];
    }
    return [parts componentsJoinedByString:@" · "];
}

- (NSString *)thumbnailFromHeader:(NSDictionary *)header {
    NSArray *thumbs = LTPath(header, @"thumbnail", @"musicThumbnailRenderer", @"thumbnail", @"thumbnails", nil);
    return [self largestThumbnailURLFromArray:thumbs];
}

#pragma mark - Track parsing

- (NSArray *)tracksFromShelf:(NSDictionary *)json {
    NSMutableArray *tracks = [NSMutableArray array];
    [self enumerateRenderersIn:json key:@"musicShelfRenderer" block:^(NSDictionary *shelf) {
        id contents = [shelf objectForKey:@"contents"];
        if (![contents isKindOfClass:[NSArray class]]) return;
        for (id row in contents) {
            if (![row isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *item = [row objectForKey:@"musicResponsiveListItemRenderer"];
            if (!item) continue;
            LTTrack *track = [self trackFromItem:item];
            if (track) [tracks addObject:track];
        }
    }];
    return tracks;
}

- (NSArray *)tracksFromPlaylistShelf:(NSDictionary *)json {
    NSMutableArray *tracks = [NSMutableArray array];
    [self enumerateRenderersIn:json key:@"musicPlaylistShelfRenderer" block:^(NSDictionary *shelf) {
        id contents = [shelf objectForKey:@"contents"];
        if (![contents isKindOfClass:[NSArray class]]) return;
        for (id row in contents) {
            if (![row isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *item = [row objectForKey:@"musicResponsiveListItemRenderer"];
            if (!item) continue;
            LTTrack *track = [self trackFromItem:item];
            if (track) [tracks addObject:track];
        }
    }];
    return tracks;
}

- (LTTrack *)trackFromItem:(NSDictionary *)item {
    NSArray *flex = [item objectForKey:@"flexColumns"];
    if (![flex isKindOfClass:[NSArray class]] || flex.count == 0) return nil;
    NSArray *runs = [self runsFromFlexColumn:[flex objectAtIndex:0]];
    NSString *title = [self textFromRuns:runs];
    if (!title.length) return nil;

    NSString *videoId = LTPath(item, @"playlistItemData", @"videoId", nil);
    if (![videoId isKindOfClass:[NSString class]] || !videoId.length) {
        videoId = nil;
    }
    if (!videoId) {
        id firstRun = runs.count ? [runs objectAtIndex:0] : nil;
        NSDictionary *nav = [firstRun objectForKey:@"navigationEndpoint"];
        videoId = LTPath(nav, @"watchEndpoint", @"videoId", nil);
    }
    if (!videoId) {
        videoId = LTPath(item, @"overlay", @"content", @"musicPlayButtonRenderer",
                         @"playNavigationEndpoint", @"watchEndpoint", @"videoId", nil);
    }
    if (!videoId.length) return nil;

    LTTrack *track = [[LTTrack alloc] init];
    track.title = title;
    track.videoId = videoId;
    track.thumbnailURL = [self compatThumbnailURL:[self thumbnailFromItem:item] videoId:videoId];

    NSArray *col1 = flex.count > 1 ? [self runsFromFlexColumn:[flex objectAtIndex:1]] : nil;
    NSArray *col2 = flex.count > 2 ? [self runsFromFlexColumn:[flex objectAtIndex:2]] : nil;

    NSArray *parts1 = [self filteredRuns:col1];
    if (parts1.count) track.artist = [parts1 objectAtIndex:0];
    NSArray *parts2 = [self filteredRuns:col2];
    if (parts2.count) track.album = [parts2 objectAtIndex:0];

    NSArray *fixed = [item objectForKey:@"fixedColumns"];
    if ([fixed isKindOfClass:[NSArray class]] && fixed.count) {
        NSDictionary *fc = [fixed objectAtIndex:0][@"musicResponsiveListItemFixedColumnRenderer"];
        NSArray *druns = [fc objectForKey:@"text"][@"runs"];
        NSString *durText = [self textFromRuns:druns];
        track.duration = [[self class] timeFromString:durText];
    } else {
        NSArray *parts = [self filteredRuns:col1];
        if (parts.count >= 3) {
            track.duration = [[self class] timeFromString:[parts objectAtIndex:2]];
        }
    }
    return track;
}

- (NSArray *)artistTopSongs:(NSDictionary *)json {
    NSMutableArray *tracks = [NSMutableArray array];
    [self enumerateRenderersIn:json key:@"musicShelfRenderer" block:^(NSDictionary *shelf) {
        NSString *shelfTitle = [self textFromRuns:[shelf objectForKey:@"title"][@"runs"]];
        if (![shelfTitle isEqualToString:@"Top songs"]) return;
        id contents = [shelf objectForKey:@"contents"];
        if (![contents isKindOfClass:[NSArray class]]) return;
        for (id row in contents) {
            if (![row isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *item = [row objectForKey:@"musicResponsiveListItemRenderer"];
            if (!item) continue;
            LTTrack *track = [self trackFromItem:item];
            if (track) [tracks addObject:track];
        }
    }];
    return tracks;
}

- (NSArray *)artistAlbums:(NSDictionary *)json {
    NSMutableArray *albums = [NSMutableArray array];
    __block BOOL found = NO;
    [self enumerateRenderersIn:json key:@"musicCarouselShelfRenderer" block:^(NSDictionary *car) {
        if (found) return;
        NSString *carTitle = [self textFromRuns:LTPath(car, @"header", @"musicCarouselShelfBasicHeaderRenderer", @"title", @"runs", nil)];
        if (![carTitle isEqualToString:@"Albums"]) return;
        found = YES;
        id contents = [car objectForKey:@"contents"];
        if (![contents isKindOfClass:[NSArray class]]) return;
        for (id row in contents) {
            if (![row isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *it = [row objectForKey:@"musicTwoRowItemRenderer"];
            if (!it) continue;
            NSString *browseId = LTPath(it, @"navigationEndpoint", @"browseEndpoint", @"browseId", nil);
            if (![browseId isKindOfClass:[NSString class]] || !browseId.length) continue;
            LTBrowseItem *bi = [[LTBrowseItem alloc] init];
            bi.kind = LTBrowseKindAlbum;
            bi.browseId = browseId;
            bi.title = [self textFromRuns:[it objectForKey:@"title"][@"runs"]];
            bi.subtitle = [self textFromRuns:[it objectForKey:@"subtitle"][@"runs"]];
            NSArray *thumbs = LTPath(it, @"thumbnailRenderer", @"musicThumbnailRenderer", @"thumbnail", @"thumbnails", nil);
            bi.thumbnailURL = [self largestThumbnailURLFromArray:thumbs];
            [albums addObject:bi];
        }
    }];
    return albums;
}

#pragma mark - Player

- (void)streamURLForVideo:(NSString *)videoId
               completion:(void (^)(NSString *streamURL, BOOL muxedStream, NSInteger audioBitrateKbps, NSError *error))completion {
    if (!videoId.length) {
        if (completion) completion(nil, NO, 0, [self errorWithCode:1 message:@"Missing video id"]);
        return;
    }
    __weak LTYouTubeClient *weakSelf = self;
    // ANDROID first: it is the only client whose stream URLs googlevideo
    // still accepts (ANDROID_VR URLs now 403 from PO-token enforcement, and
    // IOS only returns URL-less SABR formats). VR stays as a later fallback.
    [self fetchStreamURLWithContext:[self androidContext]
                         clientName:@"ANDROID"
                            videoId:videoId
                         completion:^(NSString *streamURL, BOOL muxed, NSInteger kbps, NSError *androidError) {
        if (streamURL.length) {
            if (completion) completion(streamURL, muxed, kbps, nil);
            return;
        }
        LTLog(@"STREAM falling back to ANDROID_VR client for %@", videoId);
        [weakSelf fetchStreamURLWithContext:[weakSelf androidVRContext]
                                 clientName:@"ANDROID_VR"
                                    videoId:videoId
                                 completion:^(NSString *vrURL, BOOL vrMuxed, NSInteger vrKbps, NSError *vrError) {
            if (vrURL.length) {
                if (completion) completion(vrURL, vrMuxed, vrKbps, nil);
                return;
            }
            LTLog(@"STREAM falling back to IOS client for %@", videoId);
            [weakSelf fetchStreamURLWithContext:[weakSelf iosContext]
                                     clientName:@"IOS"
                                        videoId:videoId
                                     completion:^(NSString *iosURL, BOOL iosMuxed, NSInteger iosKbps, NSError *iosError) {
                if (iosURL.length) {
                    if (completion) completion(iosURL, iosMuxed, iosKbps, nil);
                    return;
                }
                NSError *last = iosError ?: vrError ?: androidError;
                NSString *msg = [NSString stringWithFormat:@"All playback sources failed.\nLast error: %@",
                                 last.localizedDescription ?: @"unknown"];
                if (completion) completion(nil, NO, 0, [weakSelf errorWithCode:2 message:msg]);
            }];
        }];
    }];
}

- (void)fetchStreamURLWithContext:(NSDictionary *)context
                         clientName:(NSString *)clientName
                            videoId:(NSString *)videoId
                         completion:(void (^)(NSString *streamURL, BOOL muxedStream, NSInteger audioBitrateKbps, NSError *error))completion {
    if (!videoId.length) {
        if (completion) completion(nil, NO, 0, [self errorWithCode:1 message:@"Missing video id"]);
        return;
    }
    NSDictionary *body = @{
        @"context": context,
        @"videoId": videoId,
        @"racyCheckOk": @YES,
        @"contentCheckOk": @YES,
    };
    [self postToHost:@"www.youtube.com" path:@"player" body:body completion:^(id json, NSError *error) {
        if (error || !json) {
            if (completion) completion(nil, NO, 0, error);
            return;
        }
        NSDictionary *playability = [json objectForKey:@"playabilityStatus"];
        NSString *status = [playability objectForKey:@"status"];
        if (![status isEqualToString:@"OK"]) {
            NSString *reason = [playability objectForKey:@"reason"];
            if (!reason.length) reason = @"Playback unavailable";
            NSLog(@"LTYouTubeClient: player status=%@ reason=%@ for videoId=%@ client=%@", status, reason, videoId, clientName);
            LTLog(@"PLAYER status=%@ reason=%@ videoId=%@ client=%@", status, reason, videoId, clientName);
            if (completion) completion(nil, NO, 0, [self errorWithCode:2 message:reason]);
            return;
        }
        NSDictionary *sd = [json objectForKey:@"streamingData"];
        NSDictionary *best = nil;
        NSArray *orders = @[
            @[@141, @140, @139],
            @[@140, @141, @139],
            @[@139, @140, @141],
        ];
        NSInteger quality = 0;
        NSArray *adaptive = [sd objectForKey:@"adaptiveFormats"];
        if ([adaptive isKindOfClass:[NSArray class]]) {
            NSArray *order = [orders objectAtIndex:(NSUInteger)quality];
            for (NSNumber *itagNum in order) {
                for (NSDictionary *f in adaptive) {
                    if ([[f objectForKey:@"itag"] intValue] == [itagNum intValue] && [[f objectForKey:@"url"] length]) {
                        best = f;
                        break;
                    }
                }
                if (best) break;
            }
        }
        if (!best) {
            NSArray *progressive = [sd objectForKey:@"formats"];
            if ([progressive isKindOfClass:[NSArray class]]) {
                for (NSDictionary *f in progressive) {
                    if ([[f objectForKey:@"itag"] intValue] == 18 && [[f objectForKey:@"url"] length]) {
                        best = f;
                        break;
                    }
                }
            }
        }
        NSString *url = [best objectForKey:@"url"];
        if (best && url.length) {
            NSInteger kbps = [self audioBitrateKbpsForItag:[[best objectForKey:@"itag"] intValue]];
            NSString *mime = [best objectForKey:@"mimeType"] ?: @"";
            BOOL muxed = ([mime rangeOfString:@"video/"].location != NSNotFound);
            BOOL hasN = ([url rangeOfString:@"&n="].location != NSNotFound || [url rangeOfString:@"?n="].location != NSNotFound);
            self.lastFormatInfo = @{
                @"videoId": videoId,
                @"clientName": clientName,
                @"itag": [best objectForKey:@"itag"] ?: @(0),
                @"mimeType": mime,
                @"bitrate": [best objectForKey:@"bitrate"] ?: @(0),
                @"audioSampleRate": [best objectForKey:@"audioSampleRate"] ?: @"",
                @"muxed": @(muxed),
            };
            LTLog(@"STREAM client=%@ itag=%d kbps=%d muxed=%d videoId=%@ hasN=%d fullurl=%@", clientName, [[best objectForKey:@"itag"] intValue], (int)kbps, muxed, videoId, hasN, url);
            if (completion) completion(url, muxed, kbps, nil);
        } else {
            NSLog(@"LTYouTubeClient: no playable stream found for videoId=%@", videoId);
            if (completion) completion(nil, NO, 0, [self errorWithCode:3 message:@"No playable stream found"]);
        }
    }];
}

- (NSInteger)audioBitrateKbpsForItag:(NSInteger)itag {
    switch (itag) {
        case 141: return 256;
        case 140: return 128;
        case 139: return 48;
        case 18: return 128;
        default: return 128;
    }
}

#pragma mark - Lyrics (YouTube captions)

- (void)fetchLyricsForVideo:(NSString *)videoId
                 completion:(void (^)(NSString *lyricsText, NSError *error))completion {
    if (!videoId.length) {
        if (completion) completion(nil, [self errorWithCode:1 message:@"Missing video id"]);
        return;
    }
    [self loadCaptionTracksForVideo:videoId completion:^(NSString *captionURL, NSError *error) {
        if (error || !captionURL.length) {
            if (completion) completion(nil, error ?: [self errorWithCode:4 message:@"No lyrics available"]);
            return;
        }
        [self fetchCaptionTextAtURL:captionURL completion:completion];
    }];
}

// Ask the player endpoint for the video's caption track list and hand back the
// baseUrl of the best (non-auto-generated preferred) caption track.
- (void)loadCaptionTracksForVideo:(NSString *)videoId
                       completion:(void (^)(NSString *captionURL, NSError *error))completion {
    if (!videoId.length) {
        if (completion) completion(nil, [self errorWithCode:1 message:@"Missing video id"]);
        return;
    }
    [self loadCaptionTracksForVideo:videoId
                            context:[self webContext]
                      clientStrings:@"WEB"
                         completion:completion];
}

- (void)loadCaptionTracksForVideo:(NSString *)videoId
                          context:(NSDictionary *)context
                    clientStrings:(NSString *)clientStrings
                       completion:(void (^)(NSString *captionURL, NSError *error))completion {
    NSDictionary *body = @{
        @"context": context,
        @"videoId": videoId,
        @"racyCheckOk": @YES,
        @"contentCheckOk": @YES,
    };
    [self postToHost:@"www.youtube.com" path:@"player" body:body completion:^(id json, NSError *error) {
        if (error || !json) {
            LTLog(@"LYRICS player error for videoId=%@ client=%@ error=%@", videoId, clientStrings, error ?: @"nil-json");
            [self loadCaptionTracksWithFallback:videoId
                          firstClientString:clientStrings
                                  completion:completion];
            return;
        }
        NSDictionary *captions = [json objectForKey:@"captions"];
        NSDictionary *tracklist = [captions objectForKey:@"playerCaptionsTracklistRenderer"];
        NSArray *tracks = [tracklist objectForKey:@"captionTracks"];
        NSString *status = [[json objectForKey:@"playabilityStatus"] objectForKey:@"status"];
        LTLog(@"LYRICS player captions client=%@ tracks=%d status=%@ videoId=%@", clientStrings, (int)[tracks count], status ?: @"?", videoId);
        if (![tracks isKindOfClass:[NSArray class]] || tracks.count == 0) {
            [self loadCaptionTracksWithFallback:videoId
                          firstClientString:clientStrings
                                  completion:completion];
            return;
        }
        NSDictionary *choice = nil;
        for (NSDictionary *candidate in tracks) {
            if (![candidate isKindOfClass:[NSDictionary class]]) continue;
            NSString *kind = [candidate objectForKey:@"kind"];
            if (kind.length && ![kind isEqualToString:@"asr"]) {
                if ([[candidate objectForKey:@"baseUrl"] length]) { choice = candidate; break; }
            }
        }
        if (!choice) {
            for (NSDictionary *candidate in tracks) {
                if (![candidate isKindOfClass:[NSDictionary class]]) continue;
                if ([[candidate objectForKey:@"baseUrl"] length]) { choice = candidate; break; }
            }
        }
        NSString *baseUrl = [choice objectForKey:@"baseUrl"];
        if (!baseUrl.length) {
            [self loadCaptionTracksWithFallback:videoId
                          firstClientString:clientStrings
                                  completion:completion];
            return;
        }
        if (completion) completion(baseUrl, nil);
    }];
}

- (void)loadCaptionTracksWithFallback:(NSString *)videoId
                  firstClientString:(NSString *)firstClientString
                          completion:(void (^)(NSString *captionURL, NSError *error))completion {
    if ([firstClientString isEqualToString:@"WEB"]) {
        [self loadCaptionTracksForVideo:videoId
                                context:[self iosContext]
                          clientStrings:@"IOS"
                             completion:completion];
        return;
    }
    if ([firstClientString isEqualToString:@"IOS"]) {
        [self loadCaptionTracksForVideo:videoId
                                context:[self androidContext]
                          clientStrings:@"ANDROID"
                             completion:completion];
        return;
    }
    LTLog(@"LYRICS trying watch page fallback for videoId=%@", videoId);
    [self loadCaptionTracksFromWatchPage:videoId completion:completion];
}

- (void)loadCaptionTracksFromWatchPage:(NSString *)videoId
                             completion:(void (^)(NSString *captionURL, NSError *error))completion {
    NSString *urlString = [NSString stringWithFormat:@"https://www.youtube.com/watch?v=%@", videoId];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:30.0];
    [request setValue:LTBrowserUserAgent forHTTPHeaderField:@"User-Agent"];
    [NSURLConnection sendAsynchronousRequest:request queue:[NSOperationQueue mainQueue]
                           completionHandler:^(NSURLResponse *response, NSData *data, NSError *connectionError) {
        if (connectionError || !data.length) {
            LTLog(@"LYRICS watch page fetch error videoId=%@ err=%@", videoId, connectionError ?: @"no-data");
            if (completion) completion(nil, connectionError ?: [self errorWithCode:6 message:@"Watch page fetch failed"]);
            return;
        }
        NSString *html = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!html.length) {
            if (completion) completion(nil, [self errorWithCode:6 message:@"Empty watch page"]);
            return;
        }
        LTLog(@"LYRICS watch page html len=%d hasYT=%d consent=%d videoId=%@",
              (int)html.length,
              (int)[self occurrencesOf:@"ytInitialPlayerResponse" in:html],
              [html rangeOfString:@"consent.youtube.com"].location != NSNotFound,
              videoId);
        NSString *playerJSON = [self extractYTInitialPlayerResponse:html];
        LTLog(@"LYRICS watch page playerJSON len=%d hasCaptions=%d videoId=%@",
              (int)playerJSON.length,
              [playerJSON rangeOfString:@"\"captions\""].location != NSNotFound,
              videoId);
        if (!playerJSON.length) {
            LTLog(@"LYRICS no ytInitialPlayerResponse in watch page for videoId=%@", videoId);
            if (completion) completion(nil, [self errorWithCode:6 message:@"No player data in watch page"]);
            return;
        }
        NSError *jsonErr = nil;
        id obj = [NSJSONSerialization JSONObjectWithData:[playerJSON dataUsingEncoding:NSUTF8StringEncoding]
                                                options:0 error:&jsonErr];
        if (jsonErr || ![obj isKindOfClass:[NSDictionary class]]) {
            LTLog(@"LYRICS watch page JSON parse failed for videoId=%@", videoId);
            if (completion) completion(nil, jsonErr ?: [self errorWithCode:6 message:@"JSON parse failed"]);
            return;
        }
        NSDictionary *captions = [obj objectForKey:@"captions"];
        NSDictionary *tracklist = [captions objectForKey:@"playerCaptionsTracklistRenderer"];
        NSArray *tracks = [tracklist objectForKey:@"captionTracks"];
        LTLog(@"LYRICS watch page captions tracks=%d videoId=%@", (int)[tracks count], videoId);
        if (![tracks isKindOfClass:[NSArray class]] || tracks.count == 0) {
            if (completion) completion(nil, [self errorWithCode:4 message:@"No lyrics available"]);
            return;
        }
        NSDictionary *choice = nil;
        for (NSDictionary *candidate in tracks) {
            if (![candidate isKindOfClass:[NSDictionary class]]) continue;
            NSString *kind = [candidate objectForKey:@"kind"];
            if (kind.length && ![kind isEqualToString:@"asr"]) {
                if ([[candidate objectForKey:@"baseUrl"] length]) { choice = candidate; break; }
            }
        }
        if (!choice) {
            for (NSDictionary *candidate in tracks) {
                if (![candidate isKindOfClass:[NSDictionary class]]) continue;
                if ([[candidate objectForKey:@"baseUrl"] length]) { choice = candidate; break; }
            }
        }
        NSString *baseUrl = [choice objectForKey:@"baseUrl"];
        if (!baseUrl.length) {
            if (completion) completion(nil, [self errorWithCode:4 message:@"No lyrics available"]);
            return;
        }
        if (completion) completion(baseUrl, nil);
    }];
}

- (NSInteger)occurrencesOf:(NSString *)needle in:(NSString *)haystack {
    if (!needle.length || !haystack.length) return 0;
    NSInteger count = 0;
    NSUInteger searchFrom = 0;
    while (YES) {
        NSRange r = [haystack rangeOfString:needle options:NSLiteralSearch range:NSMakeRange(searchFrom, haystack.length - searchFrom)];
        if (r.location == NSNotFound) break;
        count++;
        searchFrom = r.location + r.length;
        if (searchFrom >= haystack.length) break;
    }
    return count;
}

- (NSString *)extractYTInitialPlayerResponse:(NSString *)html {
    NSString *key = @"var ytInitialPlayerResponse = ";
    NSRange start = [html rangeOfString:key];
    if (start.location == NSNotFound) {
        key = @"window[\"ytInitialPlayerResponse\"] = ";
        start = [html rangeOfString:key];
    }
    if (start.location == NSNotFound) return nil;
    NSUInteger offset = start.location + start.length;
    if (offset >= html.length) return nil;
    NSUInteger braceCount = 0;
    BOOL inString = NO;
    BOOL escaped = NO;
    for (NSUInteger i = offset; i < html.length; i++) {
        unichar c = [html characterAtIndex:i];
        if (escaped) { escaped = NO; continue; }
        if (c == '\\') { escaped = YES; continue; }
        if (c == '"') { inString = !inString; continue; }
        if (inString) continue;
        if (c == '{') braceCount++;
        else if (c == '}') {
            if (braceCount == 0) break;
            braceCount--;
            if (braceCount == 0) {
                return [html substringWithRange:NSMakeRange(offset, i + 1 - offset)];
            }
        }
    }
    return nil;
}

- (void)fetchCaptionTextAtURL:(NSString *)urlString
                   completion:(void (^)(NSString *text, NSError *error))completion {
    NSString *requestURL = urlString;
    NSRange amp = [urlString rangeOfString:@"?"];
    NSString *connector = (amp.location == NSNotFound) ? @"?" : @"&";
    if ([urlString rangeOfString:@"fmt="].location == NSNotFound) {
        requestURL = [urlString stringByAppendingString:[NSString stringWithFormat:@"%@fmt=1", connector]];
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:requestURL]
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:30.0];
    [request setValue:LTBrowserUserAgent forHTTPHeaderField:@"User-Agent"];
    [NSURLConnection sendAsynchronousRequest:request queue:[NSOperationQueue mainQueue]
                           completionHandler:^(NSURLResponse *response, NSData *data, NSError *connectionError) {
        if (connectionError) {
            if (completion) completion(nil, connectionError);
            return;
        }
        NSString *raw = nil;
        if (data.length) raw = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!raw.length) {
            if (completion) completion(nil, [self errorWithCode:5 message:@"No caption data"]);
            return;
        }
        NSArray *lines = nil;
        if ([raw rangeOfString:@"<text"].location != NSNotFound) {
            lines = [self parseCaptionLinesFromXML:raw];
        }
        if (!lines.count && [raw rangeOfString:@"}}" options:NSLiteralSearch].location != NSNotFound) {
            lines = [self parseCaptionLinesFromJSON:raw];
        }
        if (!lines.count) {
            lines = [self parseCaptionLinesFromVTT:raw];
        }
        if (!lines.count) {
            if (completion) completion(nil, [self errorWithCode:5 message:@"No caption data"]);
            return;
        }
        if (completion) completion([lines componentsJoinedByString:@"\n"], nil);
    }];
}

- (NSArray *)parseCaptionLinesFromXML:(NSString *)raw {
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"<text[^>]*>(.*?)</text>"
                                                                           options:NSRegularExpressionDotMatchesLineSeparators
                                                                             error:nil];
    NSArray *matches = [regex matchesInString:raw options:0 range:NSMakeRange(0, raw.length)];
    if (!matches.count) return nil;
    NSMutableArray *lines = [NSMutableArray array];
    for (NSTextCheckingResult *match in matches) {
        NSRange range = [match rangeAtIndex:1];
        if (range.location == NSNotFound) continue;
        NSString *line = [raw substringWithRange:range];
        line = [self decodeCaptionText:line];
        line = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (line.length && [line rangeOfString:@"[Music]"].location == NSNotFound) {
            [lines addObject:line];
        }
    }
    return lines.count ? lines : nil;
}

- (NSArray *)parseCaptionLinesFromJSON:(NSString *)raw {
    NSData *data = [raw dataUsingEncoding:NSUTF8StringEncoding];
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![obj isKindOfClass:[NSDictionary class]]) return nil;
    NSArray *events = [obj objectForKey:@"events"];
    if (![events isKindOfClass:[NSArray class]]) return nil;
    NSMutableArray *lines = [NSMutableArray array];
    for (NSDictionary *event in events) {
        if (![event isKindOfClass:[NSDictionary class]]) continue;
        NSArray *segs = [event objectForKey:@"segs"];
        if (![segs isKindOfClass:[NSArray class]]) continue;
        NSMutableString *buffer = [NSMutableString string];
        for (id seg in segs) {
            if (![seg isKindOfClass:[NSDictionary class]]) continue;
            NSString *utf8 = [seg objectForKey:@"utf8"];
            if (utf8.length) [buffer appendString:utf8];
        }
        NSString *trimmed = [buffer stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!trimmed.length) continue;
        if ([trimmed rangeOfString:@"[Music]"].location != NSNotFound) continue;
        [lines addObject:trimmed];
    }
    return lines.count ? lines : nil;
}

- (NSArray *)parseCaptionLinesFromVTT:(NSString *)raw {
    NSArray *allLines = [raw componentsSeparatedByString:@"\n"];
    NSMutableArray *lines = [NSMutableArray array];
    for (NSString *line in allLines) {
        NSString *candidate = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!candidate.length) continue;
        if ([candidate hasPrefix:@"WEBVTT"]) continue;
        if ([candidate rangeOfString:@"-->"].location != NSNotFound) continue;
        if ([candidate hasPrefix:@"<c."]) continue;
        NSString *stripped = [self stripVTTInlineTags:candidate];
        if (stripped.length && [stripped rangeOfString:@"[Music]"].location == NSNotFound) {
            [lines addObject:stripped];
        }
    }
    return lines.count ? lines : nil;
}

- (NSString *)stripVTTInlineTags:(NSString *)line {
    if ([line rangeOfString:@"<"].location == NSNotFound) return line;
    NSMutableString *out = [line mutableCopy];
    while (YES) {
        NSRange open = [out rangeOfString:@"<"];
        if (open.location == NSNotFound) break;
        NSRange close = [out rangeOfString:@">" options:NSLiteralSearch range:NSMakeRange(open.location, out.length - open.location)];
        if (close.location == NSNotFound) break;
        [out deleteCharactersInRange:NSMakeRange(open.location, close.location - open.location + 1)];
    }
    return out;
}

- (NSString *)decodeCaptionText:(NSString *)raw {
    if (!raw.length) return @"";
    NSMutableString *result = [raw mutableCopy];
    NSArray *pairs = @[
        @[@"&amp;", @"&"],
        @[@"&lt;", @"<"],
        @[@"&gt;", @">"],
        @[@"&quot;", @"\""],
        @[@"&#39;", @"'"],
        @[@"&nbsp;", @" "],
        @[@"♪", @""],
    ];
    for (NSArray *pair in pairs) {
        [result replaceOccurrencesOfString:[pair objectAtIndex:0]
                                withString:[pair objectAtIndex:1]
                                   options:NSLiteralSearch
                                     range:NSMakeRange(0, result.length)];
    }
    return result;
}

#pragma mark - Lyrics (YouTube Music)

// Fetches the official YouTube Music lyrics for a video, preferring the
// timestamped (synced) form returned by the mobile music client. On failure or
// when only raw text exists, yields the plain-text form; if the song has no
// lyric page at all, delegates to the caption-based path so the user still
// gets something readable.
- (void)fetchTimedLyricsForVideoId:(NSString *)videoId
                        completion:(void (^)(NSDictionary *result, NSError *error))completion {
    if (!videoId.length) {
        if (completion) completion(nil, [self errorWithCode:1 message:@"Missing video id"]);
        return;
    }
    // Step 1: watch playlist -> find the lyrics tab's browse id (MPLYt...).
    NSDictionary *body = @{
        @"context": [self webRemixContext],
        @"enablePersistentPlaylistPanel": @YES,
        @"isAudioOnly": @YES,
        @"tunerSettingValue": @"AUTOMIX_SETTING_NORMAL",
        @"videoId": videoId,
        @"playlistId": [NSString stringWithFormat:@"RDAMVM%@", videoId],
        @"watchEndpointMusicSupportedConfigs": @{
            @"watchEndpointMusicConfig": @{
                @"hasPersistentPlaylistPanel": @YES,
                @"musicVideoType": @"MUSIC_VIDEO_TYPE_ATV",
            }
        },
    };
    [self postToHost:@"music.youtube.com" path:@"next" body:body completion:^(id json, NSError *error) {
        if (error || ![json isKindOfClass:[NSDictionary class]]) {
            LTLog(@"LYRICS next failed videoId=%@ error=%@", videoId, error ?: @"bad-json");
            [self fetchLyricsForVideo:videoId completion:^(NSString *text, NSError *cerr) {
                if (completion) completion(text.length ? @{@"lyrics": text, @"source": @"", @"hasTimestamps": @NO} : nil, cerr);
            }];
            return;
        }
        NSString *browseId = [self lyricsBrowseIdFromWatchNext:json];
        if (!browseId.length) {
            LTLog(@"LYRICS no lyrics tab videoId=%@", videoId);
            [self fetchLyricsForVideo:videoId completion:^(NSString *text, NSError *cerr) {
                if (completion) completion(text.length ? @{@"lyrics": text, @"source": @"", @"hasTimestamps": @NO} : nil, cerr);
            }];
            return;
        }
        // Step 2: browse the lyrics page with the mobile music client for times.
        NSDictionary *browseBody = @{@"context": [self androidMusicContext], @"browseId": browseId};
        [self postToHost:@"music.youtube.com" path:@"browse" body:browseBody completion:^(id bjson, NSError *berr) {
            if (berr || ![bjson isKindOfClass:[NSDictionary class]]) {
                LTLog(@"LYRICS browse failed videoId=%@ browseId=%@ error=%@", videoId, browseId, berr ?: @"bad-json");
                if (completion) completion(nil, berr ?: [self errorWithCode:6 message:@"Lyrics browse failed"]);
                return;
            }
            NSDictionary *result = [self parseLyricsFromBrowse:bjson];
            if (result) {
                LTLog(@"LYRICS ok videoId=%@ hasTimestamps=%d lines=%d", videoId,
                      [[result objectForKey:@"hasTimestamps"] boolValue],
                      (int)[[result objectForKey:@"lines"] count]);
                if (completion) completion(result, nil);
                return;
            }
            // Timed + plain parsing both missed: fall back to captions.
            [self fetchLyricsForVideo:videoId completion:^(NSString *text, NSError *cerr) {
                if (completion) completion(text.length ? @{@"lyrics": text, @"source": @"", @"hasTimestamps": @NO} : nil, cerr);
            }];
        }];
    }];
}

// Walk the watch-playlist tabs for the tab whose page type is the lyrics page.
- (NSString *)lyricsBrowseIdFromWatchNext:(NSDictionary *)json {
    NSArray *tabs = LTPath(json,
        @"contents", @"singleColumnMusicWatchNextResultsRenderer",
        @"tabbedRenderer", @"watchNextTabbedResultsRenderer",
        @"tabs", nil);
    if (![tabs isKindOfClass:[NSArray class]]) return nil;
    for (id tab in tabs) {
        if (![tab isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *tabRenderer = [tab objectForKey:@"tabRenderer"];
        if (![tabRenderer isKindOfClass:[NSDictionary class]]) continue;
        if ([tabRenderer objectForKey:@"unselectable"]) continue;
        NSDictionary *endpoint = LTPath(tabRenderer, @"endpoint", @"browseEndpoint", nil);
        if (![endpoint isKindOfClass:[NSDictionary class]]) continue;
        NSString *pageType = LTPath(endpoint,
            @"browseEndpointContextSupportedConfigs",
            @"browseEndpointContextMusicConfig",
            @"pageType", nil);
        if ([pageType isEqualToString:@"MUSIC_PAGE_TYPE_TRACK_LYRICS"]) {
            NSString *bid = [endpoint objectForKey:@"browseId"];
            if ([bid isKindOfClass:[NSString class]] && bid.length) return bid;
        }
    }
    return nil;
}

// Parse the lyrics browse response: timed lines first, plain text as fallback.
- (NSDictionary *)parseLyricsFromBrowse:(NSDictionary *)json {
    NSDictionary *data = LTPath(json,
        @"contents", @"elementRenderer",
        @"newElement", @"type", @"componentType", @"model",
        @"timedLyricsModel", @"lyricsData", nil);
    if ([data isKindOfClass:[NSDictionary class]]) {
        NSArray *timed = [data objectForKey:@"timedLyricsData"];
        if ([timed isKindOfClass:[NSArray class]] && timed.count) {
            NSMutableArray *lines = [NSMutableArray array];
            for (id raw in timed) {
                if (![raw isKindOfClass:[NSDictionary class]]) continue;
                NSString *text = [raw objectForKey:@"lyricLine"];
                NSDictionary *cue = [raw objectForKey:@"cueRange"];
                NSNumber *start = [cue objectForKey:@"startTimeMilliseconds"];
                NSNumber *end = [cue objectForKey:@"endTimeMilliseconds"];
                if (![text isKindOfClass:[NSString class]]) continue;
                [lines addObject:@{
                    @"text": text,
                    @"start": start ?: @0,
                    @"end": end ?: @0,
                }];
            }
            if (lines.count) {
                NSString *source = [data objectForKey:@"sourceMessage"];
                return @{
                    @"lines": lines,
                    @"source": [source isKindOfClass:[NSString class]] ? source : @"",
                    @"hasTimestamps": @YES,
                };
            }
        }
    }
    // Plain-text shelf (non-timed browse response).
    NSString *plain = [self plainLyricsFromBrowse:json];
    if (plain.length) {
        NSString *source = LTPath(json,
            @"contents", @"sectionListRenderer", @"contents", @0,
            @"itemSectionRenderer", @"contents", @0,
            @"musicDescriptionShelfRenderer", @"runs", @0, @"text", nil);
        return @{
            @"lyrics": plain,
            @"source": [source isKindOfClass:[NSString class]] ? source : @"",
            @"hasTimestamps": @NO,
        };
    }
    return nil;
}

- (NSString *)plainLyricsFromBrowse:(NSDictionary *)json {
    id value = LTPath(json,
        @"contents", @"sectionListRenderer", @"contents", @0,
        @"itemSectionRenderer", @"contents", @0,
        @"musicDescriptionShelfRenderer", @"description", @"runs", @0, @"text", nil);
    if ([value isKindOfClass:[NSString class]] && [(NSString *)value length]) return value;
    // Some responses put the description runs directly on the shelf.
    value = LTPath(json,
        @"contents", @"sectionListRenderer", @"contents", @0,
        @"itemSectionRenderer", @"contents", @0,
        @"musicDescriptionShelfRenderer", @"description", nil);
    if ([value isKindOfClass:[NSString class]] && [(NSString *)value length]) return value;
    // Last-resort: the shelf itself may carry a "subheader" line.
    value = LTPath(json,
        @"contents", @"sectionListRenderer", @"contents", @0,
        @"itemSectionRenderer", @"contents", @0,
        @"musicDescriptionShelfRenderer", @"subheader", @"runs", @0, @"text", nil);
    if ([value isKindOfClass:[NSString class]] && [(NSString *)value length]) return value;
    return nil;
}

#pragma mark - Metadata

- (void)trackMetadataForVideoId:(NSString *)videoId
                     completion:(void (^)(NSString *title, NSString *artist, NSTimeInterval duration, NSString *thumbnailURL, NSError *error))completion {
    if (!videoId.length) {
        if (completion) completion(nil, nil, 0, nil, [self errorWithCode:1 message:@"Missing video id"]);
        return;
    }
    NSDictionary *body = @{
        @"context": [self androidVRContext],
        @"videoId": videoId,
        @"racyCheckOk": @YES,
        @"contentCheckOk": @YES,
    };
    __weak LTYouTubeClient *weakSelf = self;
    [self postToHost:@"www.youtube.com" path:@"player" body:body completion:^(id json, NSError *error) {
        if (error || !json) {
            if (completion) completion(nil, nil, 0, nil, error);
            return;
        }
        NSDictionary *details = [json objectForKey:@"videoDetails"];
        if (![details isKindOfClass:[NSDictionary class]]) {
            NSDictionary *playability = [json objectForKey:@"playabilityStatus"];
            NSString *reason = [playability objectForKey:@"reason"];
            if (!reason.length) reason = @"No metadata returned";
            LTLog(@"META status=%@ reason=%@ videoId=%@", [playability objectForKey:@"status"], reason, videoId);
            if (completion) completion(nil, nil, 0, nil, [weakSelf errorWithCode:2 message:reason]);
            return;
        }
        NSString *title = [details objectForKey:@"title"];
        NSString *author = [details objectForKey:@"author"];
        if ([author isKindOfClass:[NSString class]] && [author hasSuffix:@" - Topic"] && author.length > 8) {
            author = [author substringToIndex:(author.length - 8)];
        }
        NSTimeInterval duration = [[details objectForKey:@"lengthSeconds"] doubleValue];
        NSArray *thumbs = LTPath(details, @"thumbnail", @"thumbnails", nil);
        NSString *thumb = [weakSelf largestThumbnailURLFromArray:thumbs];
        if (completion) completion(title, author, duration, thumb, nil);
    }];
}

#pragma mark - Images

// Approximate decoded in-memory footprint of an image (bytes). Used as the
// NSCache cost so eviction respects real memory, not object count.
static NSUInteger LTDecodedImageCost(UIImage *image) {
    if (!image) return 0;
    CGSize px = CGSizeMake(image.size.width * image.scale, image.size.height * image.scale);
    NSUInteger bytes = (NSUInteger)(px.width * px.height * 4.0);
    return bytes ? bytes : 1;
}

static BOOL LTBorderRowUniform(const UInt8 *px, size_t W, size_t y,
                               size_t x0, size_t x1, const UInt8 *ref) {
    const UInt8 *row = px + y * W * 4;
    for (size_t x = x0; x < x1; x++) {
        const UInt8 *p = row + x * 4;
        if (abs(p[0] - ref[0]) > 18 || abs(p[1] - ref[1]) > 18 || abs(p[2] - ref[2]) > 18) return NO;
    }
    return YES;
}

static BOOL LTBorderColUniform(const UInt8 *px, size_t W, size_t x,
                               size_t y0, size_t y1, const UInt8 *ref) {
    for (size_t y = y0; y < y1; y++) {
        const UInt8 *p = px + (y * W + x) * 4;
        if (abs(p[0] - ref[0]) > 18 || abs(p[1] - ref[1]) > 18 || abs(p[2] - ref[2]) > 18) return NO;
    }
    return YES;
}

// Removes uniform border padding YouTube pads onto some cover art so the
// artwork always fills its square edge-to-edge. Topic-video thumbs are a
// square cover centered on letterbox AND pillarbox bars of different colors,
// so trimming re-references the corner color after each pass until stable.
// For i.ytimg.com thumbs (allowCenterCrop) the cover is always centered, so
// a final centered crop of the long edge removes any bars the border scan
// could not classify.
static UIImage *LTTrimmedArtworkImage(UIImage *image, BOOL allowCenterCrop) {
    CGImageRef cg = image.CGImage;
    if (!cg) return image;
    size_t W = CGImageGetWidth(cg);
    size_t H = CGImageGetHeight(cg);
    if (W < 64 || H < 64) return image;

    NSUInteger bpr = W * 4;
    UInt8 *px = (UInt8 *)malloc(bpr * H);
    if (!px) return image;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(px, W, H, 8, bpr, cs,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) {
        free(px);
        return image;
    }
    CGContextDrawImage(ctx, CGRectMake(0, 0, W, H), cg);
    CGContextRelease(ctx);

    size_t top = 0, bottom = H, left = 0, right = W;
    for (int pass = 0; pass < 4; pass++) {
        const UInt8 *ref = px + (top * W + left) * 4;
        size_t ot = top, ob = bottom, ol = left, orr = right;
        while (top < bottom - 1 && LTBorderRowUniform(px, W, top, left, right, ref)) top++;
        while (bottom > top + 1 && LTBorderRowUniform(px, W, bottom - 1, left, right, ref)) bottom--;
        while (left < right - 1 && LTBorderColUniform(px, W, left, top, bottom, ref)) left++;
        while (right > left + 1 && LTBorderColUniform(px, W, right - 1, top, bottom, ref)) right--;
        if (top == ot && bottom == ob && left == ol && right == orr) break;
        // Keep each stage only if it leaves a sane crop; later stages peel
        // letterbox bars off a different color than earlier ones, but must
        // never chew into the artwork itself.
        size_t cw = right - left, ch = bottom - top;
        if (cw < 32 || ch < 32 || cw * 2 < W || ch * 2 < H) {
            top = ot; bottom = ob; left = ol; right = orr;
            break;
        }
    }
    free(px);

    size_t cw = right - left;
    size_t ch = bottom - top;
    if (cw >= W && ch >= H) return image;
    if (allowCenterCrop && cw != ch) {
        if (cw > ch) {
            left += (cw - ch) / 2;
            cw = ch;
        } else {
            top += (ch - cw) / 2;
            ch = cw;
        }
    }

    CGImageRef sub = CGImageCreateWithImageInRect(cg, CGRectMake((CGFloat)left, (CGFloat)top, (CGFloat)cw, (CGFloat)ch));
    if (!sub) return image;
    UIImage *trimmed = [UIImage imageWithCGImage:sub scale:image.scale orientation:image.imageOrientation];
    CGImageRelease(sub);
    return trimmed ?: image;
}

- (void)loadImageWithURL:(NSString *)urlString
              completion:(void (^)(UIImage *image))completion {
    if (!urlString.length) {
        if (completion) completion(nil);
        return;
    }
    LTLog(@"IMG load url=%@", urlString);
    UIImage *cached = [self.imageCache objectForKey:urlString];
    if (cached) {
        if (completion) completion(cached);
        return;
    }
    NSString *diskPath = [self diskCachePathForURL:urlString];
    UIImage *diskImage = [UIImage imageWithContentsOfFile:diskPath];
    if (diskImage) {
        LTLog(@"IMG disk-hit url=%@", urlString);
        diskImage = LTTrimmedArtworkImage(diskImage, [urlString rangeOfString:@"i.ytimg.com"].location != NSNotFound);
        [self.imageCache setObject:diskImage forKey:urlString cost:LTDecodedImageCost(diskImage)];
        // Refresh the timestamp (at most hourly) so covers that are actually
        // being looked at survive eviction longer than untouched ones.
        dispatch_async(LTArtDiskCacheQueue(), ^{
            NSFileManager *fm = [NSFileManager defaultManager];
            NSDictionary *attrs = [fm attributesOfItemAtPath:diskPath error:NULL];
            NSDate *modified = [attrs objectForKey:NSFileModificationDate];
            if (!modified || -[modified timeIntervalSinceNow] > 3600.0) {
                [fm setAttributes:@{NSFileModificationDate: [NSDate date]}
                     ofItemAtPath:diskPath
                            error:NULL];
            }
        });
        if (completion) completion(diskImage);
        return;
    }
    NSString *fallback = nil;
    if ([urlString hasSuffix:@"maxresdefault.jpg"]) {
        fallback = [urlString stringByReplacingOccurrencesOfString:@"maxresdefault.jpg"
                                                        withString:@"sddefault.jpg"];
    }
    [self fetchImageAtURL:urlString fallbackURL:fallback diskPath:diskPath cacheKey:urlString completion:completion];
}

- (void)fetchImageAtURL:(NSString *)urlString
            fallbackURL:(NSString *)fallbackURL
               diskPath:(NSString *)diskPath
              cacheKey:(NSString *)cacheKey
             completion:(void (^)(UIImage *image))completion {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]
                                                            cachePolicy:NSURLRequestReturnCacheDataElseLoad
                                                        timeoutInterval:30.0];
    [request setValue:LTBrowserUserAgent forHTTPHeaderField:@"User-Agent"];

    void (^handleResponse)(NSData *, NSError *) = ^(NSData *data, NSError *connectionError) {
        UIImage *image = nil;
        if (!connectionError && data.length) image = [UIImage imageWithData:data];
        BOOL usable = image && ([cacheKey rangeOfString:@"maxresdefault"].location == NSNotFound || image.size.width >= 200);
        LTLog(@"ART fetch url=%@ len=%lu decoded=%dx%d usable=%d err=%@",
              urlString,
              (unsigned long)data.length,
              image ? (int)image.size.width : 0,
              image ? (int)image.size.height : 0,
              usable ? 1 : 0,
              connectionError ? connectionError.localizedDescription : @"none");
        if (!usable) {
            if (fallbackURL.length) {
                [self fetchImageAtURL:fallbackURL fallbackURL:nil diskPath:diskPath cacheKey:cacheKey completion:completion];
                return;
            }
            if (completion) completion(nil);
            return;
        }
        image = LTTrimmedArtworkImage(image, [cacheKey rangeOfString:@"i.ytimg.com"].location != NSNotFound);
        [self.imageCache setObject:image forKey:cacheKey cost:LTDecodedImageCost(image)];
        // Encode and cache on the artwork queue: JPEG-encoding a cover can take
        // long enough on an iPhone 4S to stall scrolling. Pruning runs there
        // too so the directory scan never blocks the interface.
        dispatch_async(LTArtDiskCacheQueue(), ^{
            NSData *encoded = UIImageJPEGRepresentation(image, 0.85);
            if (encoded && [encoded writeToFile:diskPath atomically:YES]) {
                [self pruneDiskArtworkCacheIfNeeded];
            }
        });
        // Always call completion on the main thread so UI updates work
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(image);
        });
    };

    // Use NSURLSession on iOS 7+ (NSURLConnection is deprecated and silently fails on iOS 10+)
    if (NSClassFromString(@"NSURLSession")) {
        NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                handleResponse(data, error);
            }];
        [task resume];
    } else {
        [NSURLConnection sendAsynchronousRequest:request queue:[NSOperationQueue mainQueue]
                               completionHandler:^(NSURLResponse *response, NSData *data, NSError *connectionError) {
            handleResponse(data, connectionError);
        }];
    }
}

- (NSString *)diskCachePathForURL:(NSString *)urlString {
    NSString *dir = [[LTPlaylistStore sharedStore] artDirectory];
    uint8_t digest[CC_MD5_DIGEST_LENGTH];
    CC_MD5([urlString UTF8String], (CC_LONG)[urlString lengthOfBytesUsingEncoding:NSUTF8StringEncoding], digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:(CC_MD5_DIGEST_LENGTH * 2)];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return [dir stringByAppendingPathComponent:[hex stringByAppendingString:@".jpg"]];
}

#pragma mark - Disk artwork cache maintenance

// Oldest-first eviction until the cache is back under both limits. Runs on
// LTArtDiskCacheQueue().
- (void)pruneDiskArtworkCache {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [[LTPlaylistStore sharedStore] artDirectory];
    NSArray *names = [fm contentsOfDirectoryAtPath:dir error:NULL];
    if (![names isKindOfClass:[NSArray class]]) return;

    NSMutableArray *entries = [NSMutableArray array];
    unsigned long long total = 0;
    for (NSString *name in names) {
        if (!LTIsManagedArtFileName(name)) continue;
        NSString *path = [dir stringByAppendingPathComponent:name];
        NSDictionary *attrs = [fm attributesOfItemAtPath:path error:NULL];
        if (!attrs) continue;
        unsigned long long size = [[attrs objectForKey:NSFileSize] unsignedLongLongValue];
        NSDate *modified = [attrs objectForKey:NSFileModificationDate] ?: [NSDate distantPast];
        [entries addObject:@{@"path": path, @"size": @(size), @"date": modified}];
        total += size;
    }
    if (total <= LTArtDiskCacheLimitBytes && entries.count <= LTArtDiskCacheLimitFiles) return;

    [entries sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSComparisonResult result = [[a objectForKey:@"date"] compare:[b objectForKey:@"date"]];
        if (result != NSOrderedSame) return result;
        return [[a objectForKey:@"path"] compare:[b objectForKey:@"path"]];
    }];

    NSUInteger count = entries.count;
    NSUInteger removed = 0;
    for (NSDictionary *entry in entries) {
        if (total <= LTArtDiskCacheLimitBytes && count <= LTArtDiskCacheLimitFiles) break;
        if ([fm removeItemAtPath:[entry objectForKey:@"path"] error:NULL]) {
            total -= [[entry objectForKey:@"size"] unsignedLongLongValue];
            count -= 1;
            removed += 1;
        }
    }
    LTLog(@"IMG disk cache trimmed %d files, %llu KB left", (int)removed, total / 1024);
}

// Scanning after every write would stat the whole directory far too often;
// once per handful of new covers is enough to keep the cache in bounds.
- (void)pruneDiskArtworkCacheIfNeeded {
    static NSUInteger writesSinceScan = 0;
    writesSinceScan += 1;
    if (writesSinceScan < LTArtDiskCacheWritesPerScan) return;
    writesSinceScan = 0;
    [self pruneDiskArtworkCache];
}

+ (unsigned long long)diskArtworkCacheSize {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [[LTPlaylistStore sharedStore] artDirectory];
    NSArray *names = [fm contentsOfDirectoryAtPath:dir error:NULL];
    if (![names isKindOfClass:[NSArray class]]) return 0;
    unsigned long long total = 0;
    for (NSString *name in names) {
        if (!LTIsManagedArtFileName(name)) continue;
        NSDictionary *attrs = [fm attributesOfItemAtPath:[dir stringByAppendingPathComponent:name] error:NULL];
        total += [[attrs objectForKey:NSFileSize] unsignedLongLongValue];
    }
    return total;
}

+ (void)clearDiskArtworkCache {
    [self clearDiskArtworkCacheWithCompletion:nil];
}

+ (void)clearDiskArtworkCacheWithCompletion:(void (^)(void))completion {
    LTYouTubeClient *client = [self sharedClient];
    [[client imageCache] removeAllObjects];
    dispatch_async(LTArtDiskCacheQueue(), ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *dir = [[LTPlaylistStore sharedStore] artDirectory];
        NSArray *names = [fm contentsOfDirectoryAtPath:dir error:NULL];
        NSUInteger removed = 0;
        if ([names isKindOfClass:[NSArray class]]) {
            for (NSString *name in names) {
                if (!LTIsManagedArtFileName(name)) continue;
                if ([fm removeItemAtPath:[dir stringByAppendingPathComponent:name] error:NULL]) removed += 1;
            }
        }
        LTLog(@"IMG disk cache cleared (%d files)", (int)removed);
        if (completion) dispatch_async(dispatch_get_main_queue(), completion);
    });
}

#pragma mark - Helpers

- (void)enumerateRenderersIn:(id)obj key:(NSString *)key block:(void (^)(NSDictionary *renderer))block {
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = obj;
        id value = [dict objectForKey:key];
        if ([value isKindOfClass:[NSDictionary class]]) block(value);
        for (id k in dict) {
            [self enumerateRenderersIn:[dict objectForKey:k] key:key block:block];
        }
    } else if ([obj isKindOfClass:[NSArray class]]) {
        for (id v in obj) {
            [self enumerateRenderersIn:v key:key block:block];
        }
    }
}

- (NSArray *)runsFromFlexColumn:(NSDictionary *)flex {
    if (![flex isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *col = [flex objectForKey:@"musicResponsiveListItemFlexColumnRenderer"];
    id runs = [col objectForKey:@"text"][@"runs"];
    if ([runs isKindOfClass:[NSArray class]]) return runs;
    id simple = [col objectForKey:@"text"][@"simpleText"];
    if ([simple isKindOfClass:[NSString class]] && [(NSString *)simple length]) {
        return @[@{@"text": simple}];
    }
    return nil;
}

- (NSString *)textFromRuns:(NSArray *)runs {
    if (![runs isKindOfClass:[NSArray class]]) return @"";
    NSMutableString *result = [NSMutableString string];
    for (id run in runs) {
        if (![run isKindOfClass:[NSDictionary class]]) continue;
        id text = [run objectForKey:@"text"];
        if ([text isKindOfClass:[NSString class]]) [result appendString:text];
    }
    return result;
}

- (NSArray *)filteredRuns:(NSArray *)runs {
    if (![runs isKindOfClass:[NSArray class]]) return nil;
    NSMutableArray *parts = [NSMutableArray array];
    for (id run in runs) {
        if (![run isKindOfClass:[NSDictionary class]]) continue;
        id text = [run objectForKey:@"text"];
        if (![text isKindOfClass:[NSString class]]) continue;
        NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!trimmed.length) continue;
        if ([trimmed rangeOfString:@"•"].location != NSNotFound) continue;
        [parts addObject:trimmed];
    }
    return parts;
}

- (NSString *)thumbnailFromItem:(NSDictionary *)item {
    NSArray *thumbs = LTPath(item, @"thumbnail", @"musicThumbnailRenderer", @"thumbnail", @"thumbnails", nil);
    return [self largestThumbnailURLFromArray:thumbs];
}

- (NSString *)squareAvatarURL:(NSString *)urlString size:(NSInteger)size {
    if (![urlString isKindOfClass:[NSString class]] || !urlString.length) return urlString;
    // yt3/lh3 service resolves size params against the ORIGINAL uploaded
    // square avatar, so rewriting the (possibly landscape-banner) spec to a
    // square request yields the artist's actual profile icon.
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"=w\\d+-h\\d+[a-z0-9_\\-]*$"
                                                                           options:0 error:nil];
    NSString *squareSpec = [NSString stringWithFormat:@"=w%ld-h%ld-p-l90-rj", (long)size, (long)size];
    if ([regex rangeOfFirstMatchInString:urlString options:0 range:NSMakeRange(0, urlString.length)].location != NSNotFound) {
        NSMutableString *result = [urlString mutableCopy];
        [regex replaceMatchesInString:result options:0 range:NSMakeRange(0, result.length) withTemplate:squareSpec];
        return result;
    }
    if ([urlString rangeOfString:@"googleusercontent.com"].location != NSNotFound) {
        return [urlString stringByAppendingString:squareSpec];
    }
    return urlString;
}

- (NSString *)compatThumbnailURL:(NSString *)urlString videoId:(NSString *)videoId {
    if (!urlString.length || !videoId.length) return urlString;
    if ([[[UIDevice currentDevice] systemVersion] intValue] >= 7) return urlString;
    if ([urlString rangeOfString:@"i.ytimg.com"].location != NSNotFound) return urlString;
    // Pre-7.0 iOS TLS cannot negotiate lh3.googleusercontent.com / ggpht TLS 1.2,
    // so fall back to the i.ytimg mirror, which is what offline tracks already use.
    return [NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/sddefault.jpg", videoId];
}

- (NSString *)largestThumbnailURLFromArray:(NSArray *)thumbs {
    if (![thumbs isKindOfClass:[NSArray class]] || thumbs.count == 0) return nil;
    NSDictionary *best = nil;
    NSInteger bestWidth = -1;
    for (id t in thumbs) {
        if (![t isKindOfClass:[NSDictionary class]]) continue;
        NSString *url = [t objectForKey:@"url"];
        if (![url isKindOfClass:[NSString class]] || !url.length) continue;
        NSInteger width = [[t objectForKey:@"width"] integerValue];
        if (!best || width > bestWidth) {
            best = t;
            bestWidth = width;
        }
    }
    NSString *url = [best objectForKey:@"url"];
    return ([url isKindOfClass:[NSString class]] && url.length) ? url : nil;
}

- (NSString *)highResThumbnailURL:(NSString *)urlString {
    if (![urlString isKindOfClass:[NSString class]] || urlString.length < 8) return urlString;
    // i.ytimg.com paths are left alone: sddefault is already disk-cached from
    // list browsing and trims to a clean square, while maxresdefault fetches
    // proved unreliable on device.
    NSMutableString *result = [urlString mutableCopy];
    NSArray *patterns = @[
        @[@"=w\\d+-h\\d+", @"=w1200-h1200"],
        @[@"/w\\d+-h\\d+", @"/w1200-h1200"],
    ];
    for (NSArray *pair in patterns) {
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:[pair objectAtIndex:0]
                                                                               options:0 error:nil];
        [regex replaceMatchesInString:result options:0 range:NSMakeRange(0, result.length)
                         withTemplate:[pair objectAtIndex:1]];
    }
    return result;
}

// A smaller grade for list rows and strip tiles: a ~60pt cell only needs a
// ~120–320px image, so pulling w1200 decodes ~16x the pixels for nothing
// (network time, CPU, and RAM — the big deal on a 512MB device).
- (NSString *)listThumbnailURL:(NSString *)urlString {
    if (![urlString isKindOfClass:[NSString class]] || urlString.length < 8) return urlString;
    // i.ytimg.com paths stay as-is (sddefault is already the disk-cached grade).
    NSMutableString *result = [urlString mutableCopy];
    NSArray *patterns = @[
        @[@"=w\\d+-h\\d+", @"=w320-h320"],
        @[@"/w\\d+-h\\d+", @"/w320-h320"],
    ];
    for (NSArray *pair in patterns) {
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:[pair objectAtIndex:0]
                                                                                options:0 error:nil];
        [regex replaceMatchesInString:result options:0 range:NSMakeRange(0, result.length)
                         withTemplate:[pair objectAtIndex:1]];
    }
    return result;
}

- (LTBrowseKind)kindForBrowseId:(NSString *)browseId {
    if ([browseId hasPrefix:@"MPREb_"]) return LTBrowseKindAlbum;
    if ([browseId hasPrefix:@"VL"]) return LTBrowseKindPlaylist;
    return LTBrowseKindArtist;
}

- (void)applySubtitleRuns:(NSArray *)runs toTrack:(LTTrack *)track {
    NSArray *parts = [self filteredRuns:runs];
    if (!parts.count) return;
    track.artist = [parts objectAtIndex:0];
    if (parts.count >= 2) track.album = [parts objectAtIndex:1];
    if (parts.count >= 3) track.duration = [[self class] timeFromString:[parts objectAtIndex:2]];
}

+ (NSTimeInterval)timeFromString:(NSString *)string {
    if (!string.length) return 0;
    NSArray *parts = [string componentsSeparatedByString:@":"];
    if (parts.count == 2) {
        return [[parts objectAtIndex:0] intValue] * 60 + [[parts objectAtIndex:1] intValue];
    }
    if (parts.count == 3) {
        return [[parts objectAtIndex:0] intValue] * 3600 + [[parts objectAtIndex:1] intValue] * 60 + [[parts objectAtIndex:2] intValue];
    }
    return [string doubleValue];
}

- (NSError *)errorWithCode:(NSInteger)code message:(NSString *)message {
    return [NSError errorWithDomain:LTYouTubeDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

@end
