#import <Foundation/Foundation.h>
#import "LTModel.h"

// Shared builder for the "Because you played …" radio-mix shelves used by
// both the Home screen and the Search idle state. Builds one shelf per
// recently played track (up to six seeds) from YouTube Music mixes
// (RDAMVM<videoId>), so the result follows what the user actually listened
// to. Needs no sign-in. Results are cached per seed set and shared between
// callers, so Home and Search never fetch the same mixes twice.
@interface LTPersonalShelves : NSObject

// The distinct recently played seed tracks, most recent first (up to six).
+ (NSArray *)currentSeeds;

// Builds the shelves and reports progress: the completion runs on the main
// queue after each mix request finishes with the ordered partial shelf array
// (each shelf is @{"title": NSString, @"items": NSArray<LTTrack *>}), and a
// final call with finished=YES once every request has completed. With no
// listening history it completes immediately with an empty array. Calls with
// an unchanged seed set while a build is in flight join the running build;
// once finished, the cached result is returned without refetching.
+ (void)buildShelvesWithCompletion:(void (^)(NSArray *shelves, BOOL finished))completion;

// Drops the cache so the next build refetches every mix (Home refresh).
+ (void)invalidate;

@end
