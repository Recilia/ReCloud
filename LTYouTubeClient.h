#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "LTModel.h"

extern NSString *const LTAPIKey;
extern NSString *const LTBrowserUserAgent;

@interface LTYouTubeClient : NSObject

+ (instancetype)sharedClient;


// Populated when a stream format is successfully selected by
// streamURLForVideo:completion:. Keys: videoId, clientName, itag,
// mimeType, bitrate (bps), audioSampleRate, muxed.
@property (nonatomic, copy) NSDictionary *lastFormatInfo;

- (void)searchWithQuery:(NSString *)query type:(NSString *)type
             completion:(void (^)(NSArray *items, NSError *error))completion;

- (void)searchVideosWithQuery:(NSString *)query
                   completion:(void (^)(NSArray *tracks, NSError *error))completion;

- (void)browseAlbum:(NSString *)browseId
         completion:(void (^)(NSDictionary *info, NSArray *tracks, NSError *error))completion;

- (void)browsePlaylist:(NSString *)browseId
            completion:(void (^)(NSDictionary *info, NSArray *tracks, NSError *error))completion;

- (void)browseArtist:(NSString *)browseId
          completion:(void (^)(NSDictionary *info, NSArray *topSongs, NSArray *albums, NSError *error))completion
          avatarURL:(void (^)(NSString *avatarURL))avatarBlock;

- (void)channelAvatarURLForBrowseId:(NSString *)browseId
                         completion:(void (^)(NSString *avatarURL))completion;

- (void)resolveArtistAvatarForName:(NSString *)name
                        completion:(void (^)(NSString *avatarURL))completion;


// Authenticated (Google account) content. Returns nil shelves/errors when
// not signed in — callers should check LTAuth first.
// Home shelves: NSArray of @{@"title": NSString, @"items": NSArray} where
// items are LTTrack or LTBrowseItem.

// Library playlists as LTBrowseItem (kind Playlist).
- (void)fetchLibraryPlaylistsWithCompletion:(void (^)(NSArray *items, NSError *error))completion;

// Account listening history as LTTrack.
- (void)fetchAccountHistoryWithCompletion:(void (^)(NSArray *tracks, NSError *error))completion;

// Display name of the signed-in account.
- (void)fetchAccountNameWithCompletion:(void (^)(NSString *name, NSError *error))completion;

// Same check, authenticated with a candidate cookie header instead of the
// stored one. Nothing is saved by this call; a name back means the cookie
// works. Used to validate a paste before it replaces a working sign-in.
- (void)fetchAccountNameWithCookieHeader:(NSString *)cookieHeader
                              completion:(void (^)(NSString *name, NSError *error))completion;

// Mix/radio playlist ids (RD..., e.g. from home shelves) load through the
// "next" endpoint rather than browse.
- (void)fetchRadioTracksForPlaylistId:(NSString *)playlistId
                           completion:(void (^)(NSArray *tracks, NSError *error))completion;

- (void)streamURLForVideo:(NSString *)videoId
               completion:(void (^)(NSString *streamURL, BOOL muxedStream, NSInteger audioBitrateKbps, NSError *error))completion;

- (void)trackMetadataForVideoId:(NSString *)videoId
                     completion:(void (^)(NSString *title, NSString *artist, NSTimeInterval duration, NSString *thumbnailURL, NSError *error))completion;

- (void)loadImageWithURL:(NSString *)urlString
              completion:(void (^)(UIImage *image))completion;

// Bounded on-disk artwork cache (32 MB / 400 images, oldest evicted first).
// `diskArtworkCacheSize` reports the current footprint in bytes and
// `clearDiskArtworkCache` empties it; both ignore playlist covers.
+ (unsigned long long)diskArtworkCacheSize;
+ (void)clearDiskArtworkCache;
+ (void)clearDiskArtworkCacheWithCompletion:(void (^)(void))completion;

- (void)fetchLyricsForVideo:(NSString *)videoId
                 completion:(void (^)(NSString *lyricsText, NSError *error))completion;

// Fetches YouTube Music lyrics for a video. Yields either timestamped lines
// (NSArray of @{"text", "start", "end"} in ms, "hasTimestamps"=YES) or a raw
// plain-text lyric blob ({"lyrics":..., "hasTimestamps"=NO}). "source" carries
// the attribution string ("Source: LyricFind"). Falls back gracefully.
- (void)fetchTimedLyricsForVideoId:(NSString *)videoId
                        completion:(void (^)(NSDictionary *result, NSError *error))completion;

- (NSString *)highResThumbnailURL:(NSString *)urlString;
// Smaller grade for list rows / strip tiles (~60pt cells): saves decode + RAM.
- (NSString *)listThumbnailURL:(NSString *)urlString;

- (NSString *)channelAvatarURL:(NSString *)urlString size:(NSInteger)size;

@end
