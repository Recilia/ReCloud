#import "LTPersonalShelves.h"
#import "LTPlaylistStore.h"
#import "LTYouTubeClient.h"
#import "LTLog.h"

// Seed set the current cache was built from.
static NSArray *_cachedSeeds;
// Ordered shelves from the last finished build (may be empty on failure).
static NSArray *_cachedShelves;
static BOOL _building;
// Completions waiting on the in-flight build (plus the caller that started it).
static NSMutableArray *_pendingCompletions;

@implementation LTPersonalShelves

+ (NSArray *)currentSeeds {
    NSArray *recentTracks = [[LTPlaylistStore sharedStore] recentTracks];
    // Distinct seeds, most recent first.
    NSMutableArray *seeds = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (LTTrack *track in recentTracks) {
        if (!track.videoId.length || [seen containsObject:track.videoId]) continue;
        [seen addObject:track.videoId];
        [seeds addObject:track];
        if (seeds.count >= 6) break;
    }
    return seeds;
}

+ (void)invalidate {
    _cachedSeeds = nil;
    _cachedShelves = nil;
}

+ (void)buildShelvesWithCompletion:(void (^)(NSArray *shelves, BOOL finished))completion {
    if (!completion) return;
    NSArray *seeds = [self currentSeeds];
    if (!seeds.count) {
        completion(@[], YES);
        return;
    }
    if (!_building && [_cachedSeeds isEqualToArray:seeds]) {
        completion(_cachedShelves ?: @[], YES);
        return;
    }
    if (!_pendingCompletions) _pendingCompletions = [NSMutableArray array];
    [_pendingCompletions addObject:completion];
    if (_building) return;
    _building = YES;
    _cachedSeeds = [seeds copy];

    LTYouTubeClient *client = [LTYouTubeClient sharedClient];
    // index -> shelf, so shelves appear in recency order however the
    // parallel requests happen to finish.
    __block NSMutableDictionary *shelfByIndex = [NSMutableDictionary dictionary];
    __block NSInteger remaining = (NSInteger)seeds.count;

    [seeds enumerateObjectsUsingBlock:^(LTTrack *seed, NSUInteger idx, BOOL *stop) {
        [client fetchRadioTracksForPlaylistId:[NSString stringWithFormat:@"RDAMVM%@", seed.videoId]
                                   completion:^(NSArray *tracks, NSError *error) {
            if (error) LTLog(@"SHELVES mix error for %@ %@", seed.videoId, error);
            if (!error && tracks.count) {
                NSMutableArray *items = [NSMutableArray array];
                NSMutableSet *ids = [NSMutableSet setWithObject:seed.videoId];
                for (LTTrack *track in tracks) {
                    if (!track.videoId.length || [ids containsObject:track.videoId]) continue;
                    [ids addObject:track.videoId];
                    [items addObject:track];
                    if (items.count >= 12) break;
                }
                if (items.count >= 2) {
                    NSString *title = [NSString stringWithFormat:@"Because you played %@", seed.title];
                    NSDictionary *shelf = @{ @"title": title, @"items": items };
                    [shelfByIndex setObject:shelf forKey:@(idx)];
                }
            }
            NSMutableArray *ordered = [NSMutableArray array];
            for (NSUInteger i = 0; i < seeds.count; i++) {
                id shelf = [shelfByIndex objectForKey:@(i)];
                if (shelf) [ordered addObject:shelf];
            }
            BOOL finished = (remaining <= 1);
            remaining -= 1;
            if (finished) {
                _building = NO;
                _cachedShelves = ordered;
            }
            NSArray *callers = _pendingCompletions;
            if (finished) _pendingCompletions = nil;
            for (void (^block)(NSArray *, BOOL) in callers) {
                block(ordered, finished);
            }
        }];
    }];
}

@end
