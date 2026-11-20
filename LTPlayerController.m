#import "LTPlayerController.h"
#import "LTYouTubeClient.h"
#import "LTPlaylistStore.h"
#import "LTLog.h"
#import <MediaPlayer/MediaPlayer.h>

NSString *const LTPlayerTrackDidChangeNotification = @"LTPlayerTrackDidChangeNotification";
NSString *const LTPlayerStateDidChangeNotification = @"LTPlayerStateDidChangeNotification";
NSString *const LTPlayerDidFinishQueueNotification = @"LTPlayerDidFinishQueueNotification";
NSString *const LTPlayerQueueDidChangeNotification = @"LTPlayerQueueDidChangeNotification";

@interface LTPlayerController () <NSURLConnectionDataDelegate, AVAudioPlayerDelegate>
@property (nonatomic, strong) AVAudioPlayer *audioPlayer;
@property (nonatomic, strong) AVPlayer *moviePlayer;
@property (nonatomic, assign) BOOL pendingMuxed;
@property (nonatomic, copy) NSArray *queue;
@property (nonatomic, copy) NSArray *sourceQueue;
@property (nonatomic, assign) NSInteger currentIndex;
@property (nonatomic, assign) BOOL shuffleEnabled;
@property (nonatomic, assign) BOOL isLoading;
@property (nonatomic, assign) BOOL userPaused;
@property (nonatomic, assign) BOOL resumeAfterInterruption;
@property (nonatomic, assign) BOOL radioPending;
@property (nonatomic, strong) MPMediaItemArtwork *nowPlayingArtwork;
@property (nonatomic, copy) NSString *pendingVideoId;
@property (nonatomic, strong) NSURLConnection *streamConnection;
@property (nonatomic, strong) NSMutableData *streamData;
@property (nonatomic, copy) NSString *streamVideoId;
@property (nonatomic, assign) NSInteger streamHTTPStatus;
@property (nonatomic, assign) NSInteger audioBitrateKbps;
@property (nonatomic, strong) NSTimer *statsTimer;
@property (nonatomic, assign) NSTimeInterval statsBaseTime;
// Continuous-playback recovery (see -recoverFromPlaybackFailure:videoId:).
@property (nonatomic, assign) NSInteger consecutiveLoadFailures;
@property (nonatomic, copy) NSString *lastRetriedVideoId;
@property (nonatomic, assign) BOOL suppressTrackStats;
@property (nonatomic, strong) NSTimer *streamWatchdog;
// Bumped by every -loadCurrentTrack. A stream fetch or download from an earlier
// generation is ignored, so a slow response cannot take over a track the user
// has since chosen.
@property (nonatomic, assign) NSUInteger loadGeneration;
// YES between interruption begin and end, so the end-of-item watchdog stays
// quiet during a call instead of restarting playback.
@property (nonatomic, assign) BOOL interrupted;
// Set once the watchdog has acted on the loaded item, so it cannot fire twice
// for the same track.
@property (nonatomic, assign) BOOL endRecoveryPending;
// Playback start is issued and then *verified* (see -attemptPlaybackStart).
// Identifying and loading the next track is not the same as hearing it, so the
// one -play call every transition used to make is now a bounded attempt that
// checks what the player actually did.
@property (nonatomic, assign) NSInteger startAttempts;
@property (nonatomic, strong) NSTimer *startVerifyTimer;
// The AVPlayerItem whose -status is being watched (muxed playback), kept so the
// observer is removed exactly once and late callbacks can be ignored.
@property (nonatomic, strong) AVPlayerItem *observedItem;
@end

@implementation LTPlayerController

+ (instancetype)sharedController {
    static LTPlayerController *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[LTPlayerController alloc] init];
    });
    return shared;
}

- (float)volume {
    NSNumber *saved = [[NSUserDefaults standardUserDefaults] objectForKey:@"LTPlaybackVolume"];
    return saved ? [saved floatValue] : 1.0f;
}

- (void)setVolume:(float)volume {
    if (volume < 0.0f) volume = 0.0f;
    if (volume > 1.0f) volume = 1.0f;
    [[NSUserDefaults standardUserDefaults] setObject:@(volume) forKey:@"LTPlaybackVolume"];
    self.audioPlayer.volume = volume;
    // AVPlayer only gained -volume in iOS 7; guard for older devices (3GS/iOS 6).
    if ([self.moviePlayer respondsToSelector:@selector(setVolume:)]) {
        self.moviePlayer.volume = volume;
    }
}

- (id)init {
    self = [super init];
    if (self) {
        _currentIndex = -1;
        _repeatMode = LTRepeatModeOff;
        // Shuffle defaults to ON (user preference), stored so it survives
        // restarts and stays in sync with the Shuffle toggle in the player.
        id savedShuffle = [[NSUserDefaults standardUserDefaults] objectForKey:@"LTShuffleEnabled"];
        _shuffleEnabled = savedShuffle ? [savedShuffle boolValue] : YES;
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(appWillEnterForeground:)
                                                     name:UIApplicationWillEnterForegroundNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(appDidEnterBackground:)
                                                     name:UIApplicationDidEnterBackgroundNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(audioInterrupted:)
                                                     name:AVAudioSessionInterruptionNotification
                                                   object:nil];
        [self configureAudioSession];
        self.statsTimer = [NSTimer scheduledTimerWithTimeInterval:5.0
                                                           target:self
                                                         selector:@selector(statsTick:)
                                                         userInfo:nil
                                                          repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:self.statsTimer forMode:NSRunLoopCommonModes];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (BOOL)hasActivePlayer {
    return self.audioPlayer != nil || self.moviePlayer != nil;
}

- (BOOL)playerIsPlaying {
    if (self.moviePlayer) return self.moviePlayer.rate != 0.0;
    return self.audioPlayer.isPlaying;
}

- (NSTimeInterval)playerDuration {
    if (self.moviePlayer) {
        CMTime t = self.moviePlayer.currentItem.duration;
        return CMTIME_IS_NUMERIC(t) ? CMTimeGetSeconds(t) : 0.0;
    }
    return self.audioPlayer.duration;
}

- (NSTimeInterval)playerCurrentTime {
    if (self.moviePlayer) return CMTimeGetSeconds(self.moviePlayer.currentTime);
    return self.audioPlayer.currentTime;
}

- (void)playerSeekToTime:(NSTimeInterval)time {
    if (self.moviePlayer) {
        [self.moviePlayer seekToTime:CMTimeMakeWithSeconds(time, NSEC_PER_SEC)];
        self.statsBaseTime = time;
        return;
    }
    self.audioPlayer.currentTime = time;
    self.statsBaseTime = time;
}

// YES when the loaded item has finished (or failed): playing it again needs a
// rewind, and the end-of-item watchdog treats it as "should have advanced".
- (BOOL)activePlayerReachedEnd {
    if (self.moviePlayer) {
        AVPlayerItem *item = self.moviePlayer.currentItem;
        if (!item) return YES;
        if (item.status == AVPlayerItemStatusFailed) return YES;
        CMTime duration = item.duration;
        if (!CMTIME_IS_NUMERIC(duration) || CMTimeGetSeconds(duration) <= 0.0) return NO;
        CMTime position = item.currentTime;
        if (!CMTIME_IS_NUMERIC(position)) return NO;
        return (CMTimeGetSeconds(position) >= CMTimeGetSeconds(duration) - 0.75);
    }
    if (self.audioPlayer) {
        NSTimeInterval duration = self.audioPlayer.duration;
        if (duration <= 0.0) return NO;
        return (self.audioPlayer.currentTime >= duration - 0.75);
    }
    return NO;
}

#pragma mark - Listening stats

- (void)statsTick:(NSTimer *)timer {
    [self commitStatsDelta];
    [self checkForEndedPlayback];
    // Keep the lock screen / Control Center progress bar in step with playback.
    if ([self playerIsPlaying]) [self updateNowPlayingInfo];
}

// An item that ends without delivering its completion callback leaves the
// player silent while the app still believes it is mid-track. Advance once in
// that case; a normal pause, an interruption and a loading track are excluded,
// and endRecoveryPending keeps it to one attempt per track.
- (void)checkForEndedPlayback {
    if (![self hasActivePlayer] || self.userPaused || self.interrupted || self.isLoading) return;
    // A start that is being verified is in charge of this item: it is sitting at
    // position 0, so it cannot be a completion whose callback went missing.
    if (self.startVerifyTimer) return;
    if ([self playerIsPlaying]) {
        self.endRecoveryPending = NO;
        return;
    }
    if (self.endRecoveryPending) return;
    if (![self activePlayerReachedEnd]) return;
    self.endRecoveryPending = YES;
    LTLog(@"WATCHDOG item ended without a callback, advancing");
    [self nextTrack];
}

- (void)commitStatsDelta {
    LTTrack *track = [self currentTrack];
    if (!track || !track.videoId.length) return;
    NSTimeInterval now = [self playerCurrentTime];
    if (now <= self.statsBaseTime) {
        self.statsBaseTime = now;
        return;
    }
    NSTimeInterval delta = now - self.statsBaseTime;
    self.statsBaseTime = now;
    if (delta > 0) {
        [[LTPlaylistStore sharedStore] recordListenedSeconds:delta forTrack:track];
    }
}

- (void)startActivePlayer {
    if (self.moviePlayer) {
        [self.audioPlayer pause];
        [self.moviePlayer play];
    } else {
        [self.moviePlayer pause];
        [self.audioPlayer play];
    }
}

- (void)pauseActivePlayer {
    [self.audioPlayer pause];
    [self.moviePlayer pause];
}

- (void)stopAudioPlayer {
    [self.audioPlayer stop];
    self.audioPlayer = nil;
}

- (void)stopMoviePlayer {
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:AVPlayerItemDidPlayToEndTimeNotification
                                                  object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:AVPlayerItemFailedToPlayToEndTimeNotification
                                                  object:nil];
    if (self.observedItem) {
        // Removed by hand because a failed item can already have dropped its
        // observers; -removeObserver:forKeyPath: throws in that case.
        @try {
            [self.observedItem removeObserver:self forKeyPath:@"status"];
        } @catch (NSException *exception) {
            LTLog(@"ITEM observer removal failed: %@", exception);
        }
        self.observedItem = nil;
    }
    [self.moviePlayer pause];
    self.moviePlayer = nil;
}

// Kept separate from -configureAudioSession so the start attempts can call it
// without logging "session active" on every retry; failures are still reported.
- (BOOL)activateAudioSessionQuietly {
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *error = nil;
    BOOL ok = [session setCategory:AVAudioSessionCategoryPlayback error:&error];
    if (!ok) LTLog(@"AUDIO setCategory error: %@", error);
    error = nil;
    ok = [session setActive:YES error:&error];
    if (!ok) LTLog(@"AUDIO setActive error: %@", error);
    return ok;
}

- (void)configureAudioSession {
    if ([self activateAudioSessionQuietly]) LTLog(@"AUDIO session active");
}

#pragma mark - Verified playback start

// Every track, from every screen, reaches audio through -playMovie. That method
// used to issue -play once and trust it, which is how a transition could put
// the next track on screen while the underlying player stayed at rate 0: an
// AVAudioPlayer whose -play returned NO (inactive session) and an AVPlayer
// whose item was not ready both look exactly like a paused player, and nothing
// asked again. The start is now attempted, checked against the player's real
// state, re-activated and retried a bounded number of times, and finally
// reported as a failed load so the queue advances instead of hanging in silence.
//
// The interval is a check cadence, not a delay before playing: -play is issued
// immediately on every attempt.
static const NSInteger LTPlaybackStartAttemptLimit = 6;
static const NSTimeInterval LTPlaybackStartVerifyInterval = 0.75;

- (NSString *)playerStateDescription {
    if (self.moviePlayer) {
        AVPlayerItem *item = self.moviePlayer.currentItem;
        CMTime position = item ? item.currentTime : kCMTimeZero;
        CMTime duration = item ? item.duration : kCMTimeZero;
        return [NSString stringWithFormat:@"avplayer rate=%.2f status=%d t=%.2f/%.2f",
                self.moviePlayer.rate, item ? (int)item.status : -1,
                CMTimeGetSeconds(position), CMTimeGetSeconds(duration)];
    }
    if (self.audioPlayer) {
        return [NSString stringWithFormat:@"audioplayer playing=%d t=%.2f/%.2f",
                (int)self.audioPlayer.isPlaying,
                self.audioPlayer.currentTime, self.audioPlayer.duration];
    }
    return @"none";
}

// -playerIsPlaying reports intent (AVPlayer keeps a non-zero rate while it is
// still preparing to play). This asks whether the source can actually produce
// sound right now, which is what a successful start means.
- (BOOL)activePlayerIsProducingAudio {
    if (self.moviePlayer) {
        AVPlayerItem *item = self.moviePlayer.currentItem;
        return self.moviePlayer.rate != 0.0 && item != nil &&
               item.status == AVPlayerItemStatusReadyToPlay;
    }
    return self.audioPlayer.isPlaying;
}

- (void)startPlaybackWithVerification {
    self.startAttempts = 0;
    [self attemptPlaybackStart];
}

- (void)attemptPlaybackStart {
    [self.startVerifyTimer invalidate];
    self.startVerifyTimer = nil;
    if (![self hasActivePlayer]) {
        LTLog(@"PLAY_ABORT nothing loaded");
        return;
    }
    if (self.userPaused || self.interrupted) {
        LTLog(@"PLAY_ABORT userPaused=%d interrupted=%d",
              (int)self.userPaused, (int)self.interrupted);
        return;
    }
    self.startAttempts += 1;
    // An item that is already at its end cannot be started; rewind it so a
    // retry after a finished item restarts it instead of failing forever.
    if ([self activePlayerReachedEnd]) {
        [self playerSeekToTime:0];
    }
    // Ahead of every attempt: a session that was deactivated behind our back
    // (route change, an interruption that never reported its end, backgrounding)
    // answers -play with NO and the track would stay silent.
    BOOL sessionActive = [self activateAudioSessionQuietly];
    [self startActivePlayer];
    LTLog(@"PLAY_ATTEMPT %d session=%d %@ videoId=%@",
          (int)self.startAttempts, (int)sessionActive,
          [self playerStateDescription], [self currentTrack].videoId);
    // Verify on the next turn of the run loop rather than trusting the call:
    // AVAudioPlayer may not have flipped -isPlaying yet, and AVPlayer reports a
    // rate it cannot honour until its item is ready.
    self.startVerifyTimer = [NSTimer scheduledTimerWithTimeInterval:LTPlaybackStartVerifyInterval
                                                             target:self
                                                           selector:@selector(verifyPlaybackStart:)
                                                           userInfo:nil
                                                            repeats:NO];
    [[NSRunLoop mainRunLoop] addTimer:self.startVerifyTimer forMode:NSRunLoopCommonModes];
}

- (void)verifyPlaybackStart:(NSTimer *)timer {
    self.startVerifyTimer = nil;
    // A pause, an interruption or a track change all cancel this attempt.
    if (self.userPaused || self.interrupted || ![self hasActivePlayer]) return;
    if ([self activePlayerIsProducingAudio]) {
        self.consecutiveLoadFailures = 0;
        self.lastRetriedVideoId = nil;
        self.endRecoveryPending = NO;
        self.isLoading = NO;
        LTLog(@"PLAY_CONFIRMED attempt=%d %@ videoId=%@",
              (int)self.startAttempts, [self playerStateDescription],
              [self currentTrack].videoId);
        // Now that sound is really coming out, publish the true rate/duration
        // so the lock screen and the player stop showing a paused track.
        [self updateNowPlayingInfo];
        [[NSNotificationCenter defaultCenter] postNotificationName:LTPlayerStateDidChangeNotification object:self];
        return;
    }
    // A track can also play and finish inside the window (a very short item):
    // that is a completion, not a start that failed.
    if ([self activePlayerReachedEnd]) {
        LTLog(@"PLAY_ENDED_DURING_VERIFY videoId=%@", [self currentTrack].videoId);
        [self nextTrack];
        return;
    }
    LTLog(@"PLAY_NOT_STARTED attempt=%d %@ videoId=%@",
          (int)self.startAttempts, [self playerStateDescription],
          [self currentTrack].videoId);
    if (self.startAttempts >= LTPlaybackStartAttemptLimit) {
        // A player that will not start is a failed load, not a paused track.
        // Recovery retries the track once, then moves on, so a transition can
        // never leave the app on a loaded track with silence behind it.
        LTLog(@"PLAY_FAILED giving up videoId=%@", [self currentTrack].videoId);
        self.isLoading = NO;
        NSError *error = [NSError errorWithDomain:@"LTPlayerController"
                                             code:1
                                         userInfo:@{NSLocalizedDescriptionKey: @"The player did not start playback."}];
        [self recoverFromPlaybackFailure:error videoId:[self currentTrack].videoId];
        return;
    }
    [self attemptPlaybackStart];
}

- (void)cancelStartVerification {
    [self.startVerifyTimer invalidate];
    self.startVerifyTimer = nil;
    self.startAttempts = 0;
}

- (void)appWillEnterForeground:(NSNotification *)notification {
    [self configureAudioSession];
}

- (void)appDidEnterBackground:(NSNotification *)notification {
    // An item that reached its end is not a paused player: restarting it here
    // would replay the old track over the top of the transition.
    if ([self hasActivePlayer] && !self.userPaused && ![self playerIsPlaying] &&
        ![self activePlayerReachedEnd]) {
        LTLog(@"PLAYER auto-resume in background");
        [self playMovie];
    }
}

- (void)audioInterrupted:(NSNotification *)notification {
    NSNumber *type = [[notification userInfo] objectForKey:AVAudioSessionInterruptionTypeKey];
    LTLog(@"AUDIO interruption type=%d", [type intValue]);
    if ([type intValue] == AVAudioSessionInterruptionTypeBegan) {
        self.interrupted = YES;
        [self cancelStartVerification];
        self.resumeAfterInterruption = [self playerIsPlaying];
        [self pauseActivePlayer];
    } else if ([type intValue] == AVAudioSessionInterruptionTypeEnded) {
        self.interrupted = NO;
        [self configureAudioSession];
        if (self.resumeAfterInterruption) {
            self.resumeAfterInterruption = NO;
            [self playMovie];
        }
    }
}

- (void)playMovie {
    self.userPaused = NO;
    // Play with nothing loaded (every source failed, an emptied session) used to
    // clear the flags, report a state change and leave silence behind. Load the
    // track instead, so a Play press always ends in audio.
    if (![self hasActivePlayer]) {
        if ([self currentTrack]) {
            LTLog(@"PLAY nothing loaded, reloading %@", [self currentTrack].videoId);
            [self loadCurrentTrack];
            return;
        }
        LTLog(@"PLAY ignored, nothing to play");
        [self cancelStartVerification];
        self.isLoading = NO;
        [self updateNowPlayingInfo];
        [[NSNotificationCenter defaultCenter] postNotificationName:LTPlayerStateDidChangeNotification object:self];
        return;
    }
    [self configureAudioSession];
    self.isLoading = NO;
    // Pressing Play on an item that already finished used to do nothing at all
    // (an ended player cannot be resumed), which is how the dead state after a
    // queue ran out looked from the lock screen. Rewind so it always restarts.
    if ([self activePlayerReachedEnd]) {
        [self playerSeekToTime:0];
    }
    self.statsBaseTime = [self playerCurrentTime];
    // Issues -play and keeps checking until the player really is producing
    // audio; the failure streak is only cleared once that is confirmed.
    [self startPlaybackWithVerification];
    [self updateNowPlayingInfo];
    BOOL keepAwake = [[NSUserDefaults standardUserDefaults] boolForKey:@"LTKeepAwake"];
    [[UIApplication sharedApplication] setIdleTimerDisabled:keepAwake];
    [[NSNotificationCenter defaultCenter] postNotificationName:LTPlayerStateDidChangeNotification object:self];
}

- (void)pausePlayback {
    // A deliberate pause cancels any start that is still being verified.
    [self cancelStartVerification];
    [self commitStatsDelta];
    LTLog(@"PAUSE videoId=%@ %@", [self currentTrack].videoId, [self playerStateDescription]);
    // Every caller of this is a deliberate pause (the in-app button, the lock
    // screen and headset commands, an emptied queue), and the end-of-item
    // watchdog must not treat one as a missed completion and skip ahead. This
    // is exactly what a pause within a second of the end looked like.
    self.userPaused = YES;
    [self pauseActivePlayer];
    [self updateNowPlayingInfo];
    [[UIApplication sharedApplication] setIdleTimerDisabled:NO];
    [[NSNotificationCenter defaultCenter] postNotificationName:LTPlayerStateDidChangeNotification object:self];
}

- (void)updateNowPlayingInfo {
    LTTrack *track = [self currentTrack];
    if (!track) {
        [[MPNowPlayingInfoCenter defaultCenter] setNowPlayingInfo:nil];
        return;
    }
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    if (track.title.length) [info setObject:track.title forKey:MPMediaItemPropertyTitle];
    if (track.artist.length) [info setObject:track.artist forKey:MPMediaItemPropertyArtist];
    if (track.album.length) [info setObject:track.album forKey:MPMediaItemPropertyAlbumTitle];
    NSTimeInterval dur = [self playerDuration];
    if (dur > 0) {
        [info setObject:@(dur) forKey:MPMediaItemPropertyPlaybackDuration];
    }
    [info setObject:@([self playerCurrentTime]) forKey:MPNowPlayingInfoPropertyElapsedPlaybackTime];
    [info setObject:@([self playerIsPlaying] ? 1.0 : 0.0) forKey:MPNowPlayingInfoPropertyPlaybackRate];
    [info setObject:@(self.currentIndex) forKey:MPNowPlayingInfoPropertyPlaybackQueueIndex];
    [info setObject:@((NSInteger)self.queue.count) forKey:MPNowPlayingInfoPropertyPlaybackQueueCount];
    if (self.nowPlayingArtwork) {
        [info setObject:self.nowPlayingArtwork forKey:MPMediaItemPropertyArtwork];
    }
    [[MPNowPlayingInfoCenter defaultCenter] setNowPlayingInfo:info];
}

#pragma mark - Playback

- (LTTrack *)currentTrack {
    if (self.currentIndex < 0 || self.currentIndex >= (NSInteger)self.queue.count) return nil;
    return [self.queue objectAtIndex:(NSUInteger)self.currentIndex];
}

- (LTTrack *)peekTrackOffset:(NSInteger)offset {
    if (offset == 0) return [self currentTrack];
    if (self.repeatMode == LTRepeatModeOff) {
        NSInteger idx = self.currentIndex + offset;
        if (idx < 0) return nil;
        if (idx >= (NSInteger)self.queue.count) return nil;
        return [self.queue objectAtIndex:(NSUInteger)idx];
    }
    NSInteger n = (NSInteger)self.queue.count;
    if (n <= 0) return nil;
    NSInteger idx = self.currentIndex + offset;
    while (idx < 0) idx += n;
    while (idx >= n) idx -= n;
    return [self.queue objectAtIndex:(NSUInteger)idx];
}

- (BOOL)isPlaying {
    return [self playerIsPlaying];
}

- (NSTimeInterval)duration {
    return [self playerDuration];
}

- (NSTimeInterval)currentTime {
    return [self playerCurrentTime];
}

- (void)playQueue:(NSArray *)tracks atIndex:(NSInteger)index {
    if (!tracks.count) return;
    [self commitStatsDelta];
    self.sourceQueue = [tracks copy];
    if (self.shuffleEnabled) {
        // Shuffle is on: the tapped song plays first and everything else
        // follows in random order (Spotify-style).
        NSMutableArray *ordered = [tracks mutableCopy];
        if (index < 0 || index >= (NSInteger)ordered.count) index = 0;
        id chosen = [ordered objectAtIndex:(NSUInteger)index];
        [ordered removeObjectAtIndex:(NSUInteger)index];
        NSMutableArray *queue = [NSMutableArray arrayWithObject:chosen];
        [queue addObjectsFromArray:[self shuffledArray:ordered]];
        self.queue = queue;
        self.currentIndex = 0;
    } else {
        self.queue = [tracks copy];
        if (index < 0) index = 0;
        if (index >= (NSInteger)tracks.count) index = 0;
        self.currentIndex = index;
    }
    [self postQueueChanged];
    [self loadCurrentTrack];
}

- (void)playQueue:(NSArray *)tracks shuffle:(BOOL)shuffle {
    if (!tracks.count) return;
    [self commitStatsDelta];
    self.sourceQueue = [tracks copy];
    self.queue = [tracks copy];
    self.shuffleEnabled = shuffle;
    [[NSUserDefaults standardUserDefaults] setObject:@(shuffle ? YES : NO) forKey:@"LTShuffleEnabled"];
    if (shuffle) {
        self.queue = [self shuffledArray:self.queue];
        self.currentIndex = 0;
    } else {
        self.currentIndex = 0;
    }
    [self postQueueChanged];
    [self loadCurrentTrack];
}

- (void)enqueueTracks:(NSArray *)tracks {
    if (!tracks.count) return;
    NSMutableArray *q = [self.queue mutableCopy] ?: [NSMutableArray array];
    NSMutableArray *src = [self.sourceQueue mutableCopy] ?: [NSMutableArray array];
    [q addObjectsFromArray:tracks];
    [src addObjectsFromArray:tracks];
    self.queue = q;
    self.sourceQueue = src;
    if (self.currentIndex < 0) {
        self.currentIndex = 0;
        [self postQueueChanged];
        [self loadCurrentTrack];
    } else {
        [self postQueueChanged];
    }
}

- (void)jumpToIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.queue.count) return;
    [self commitStatsDelta];
    self.currentIndex = index;
    [self postQueueChanged];
    [self loadCurrentTrack];
}

- (void)moveTrackAtIndex:(NSInteger)fromIndex toIndex:(NSInteger)toIndex {
    NSInteger count = (NSInteger)self.queue.count;
    if (fromIndex < 0 || fromIndex >= count) return;
    if (toIndex < 0 || toIndex >= count) return;
    if (fromIndex == toIndex) return;
    [self commitStatsDelta];

    NSMutableArray *q = [self.queue mutableCopy];
    id track = [q objectAtIndex:(NSUInteger)fromIndex];
    [q removeObjectAtIndex:(NSUInteger)fromIndex];
    [q insertObject:track atIndex:(NSUInteger)toIndex];
    self.queue = q;

    NSInteger idx = self.currentIndex;
    if (fromIndex == idx) {
        idx = toIndex;
    } else if (fromIndex < idx && toIndex >= idx) {
        idx -= 1;
    } else if (fromIndex > idx && toIndex <= idx) {
        idx += 1;
    }
    self.currentIndex = idx;

    if (self.shuffleEnabled) {
        // Manual reordering beats shuffle: cancel shuffle and adopt the new
        // order as the source order, Apple Music style.
        self.shuffleEnabled = NO;
        self.sourceQueue = [q copy];
    } else if (self.sourceQueue.count == self.queue.count) {
        // Keep the source (unshuffled) order in sync; when shuffle is off the
        // two arrays are identical copies.
        NSMutableArray *src = [self.sourceQueue mutableCopy];
        id srcTrack = [src objectAtIndex:(NSUInteger)fromIndex];
        [src removeObjectAtIndex:(NSUInteger)fromIndex];
        [src insertObject:srcTrack atIndex:(NSUInteger)toIndex];
        self.sourceQueue = src;
    }

    [self postQueueChanged];
}

- (void)removeTrackAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.queue.count) return;
    NSMutableArray *q = [self.queue mutableCopy];
    [q removeObjectAtIndex:(NSUInteger)index];
    NSMutableArray *src = [self.sourceQueue mutableCopy];
    if (index < (NSInteger)src.count) {
        [src removeObjectAtIndex:(NSUInteger)index];
    }
    self.queue = q;
    self.sourceQueue = src;
    if (self.queue.count == 0) {
        self.currentIndex = -1;
        [self pausePlayback];
        [self postQueueChanged];
        return;
    }
    if (index < self.currentIndex) {
        self.currentIndex -= 1;
    } else if (index == self.currentIndex) {
        if (self.currentIndex >= (NSInteger)self.queue.count) {
            self.currentIndex = (NSInteger)self.queue.count - 1;
        }
        [self postQueueChanged];
        [self loadCurrentTrack];
        return;
    }
    [self postQueueChanged];
}

- (void)loadNowPlayingArtworkForTrack:(LTTrack *)track {
    if (!track.thumbnailURL.length) return;
    __weak LTPlayerController *weakSelf = self;
    NSString *artURL = [[LTYouTubeClient sharedClient] highResThumbnailURL:track.thumbnailURL];
    [[LTYouTubeClient sharedClient] loadImageWithURL:artURL completion:^(UIImage *image) {
        LTPlayerController *strongSelf = weakSelf;
        if (!strongSelf || !image) return;
        strongSelf.nowPlayingArtwork = [[MPMediaItemArtwork alloc] initWithImage:image];
        [strongSelf updateNowPlayingInfo];
    }];
}

- (void)loadCurrentTrack {
    LTTrack *track = [self currentTrack];
    if (!track) return;
    // Anything still being verified belongs to the track being replaced.
    [self cancelStartVerification];
    // A new load invalidates everything still in flight: the stream fetch and
    // the download for the previous track must not be able to start playing
    // over this one, and the end-of-item watchdog starts fresh.
    self.loadGeneration += 1;
    self.endRecoveryPending = NO;
    if (self.streamConnection) {
        [self.streamConnection cancel];
        self.streamConnection = nil;
        [self stopStreamWatchdog];
        self.streamData = nil;
    }
    if (!self.suppressTrackStats) {
        [[LTPlaylistStore sharedStore] recordRecentTrack:track];
        [[LTPlaylistStore sharedStore] recordTrackPlay:track];
        [[NSNotificationCenter defaultCenter] postNotificationName:LTPlayerTrackDidChangeNotification object:self];
    }
    self.suppressTrackStats = NO;
    self.statsBaseTime = 0;
    // Name the new track on the lock screen straight away, before the stream
    // (and its artwork) arrives.
    [self updateNowPlayingInfo];

    self.nowPlayingArtwork = nil;
    if (track.thumbnailURL.length) {
        [self loadNowPlayingArtworkForTrack:track];
    } else {
        __weak LTPlayerController *weakSelf = self;
        [[LTPlaylistStore sharedStore] resolveThumbnailForTrack:track completion:^(NSString *thumbnailURL) {
            if (thumbnailURL.length) {
                [weakSelf loadNowPlayingArtworkForTrack:track];
            }
        }];
    }

    // Set before the local-file branch too: recovery compares failure reports
    // against this, and a stale id used to short-circuit them into silence.
    self.pendingVideoId = track.videoId;

    NSString *localPath = [[LTPlaylistStore sharedStore] existingLocalFilePathForVideoId:track.videoId];
    if (localPath.length) {
        LTLog(@"OFFLINE playing videoId=%@ title=%@", track.videoId, track.title);
        self.isLoading = NO;
        self.audioBitrateKbps = [[LTPlaylistStore sharedStore] bitrateKbpsForVideoId:track.videoId];
        [self loadLocalFileAtPath:localPath];
        return;
    }

    self.isLoading = YES;
    LTLog(@"LOAD videoId=%@ title=%@", track.videoId, track.title);
    NSUInteger generation = self.loadGeneration;
    __weak LTPlayerController *weakSelf = self;
    [[LTYouTubeClient sharedClient] streamURLForVideo:track.videoId completion:^(NSString *streamURL, BOOL muxedStream, NSInteger audioBitrateKbps, NSError *error) {
        LTPlayerController *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (strongSelf.loadGeneration != generation) return; // a newer track was chosen
        if (![strongSelf.pendingVideoId isEqualToString:track.videoId]) return;
        if (error) {
            LTLog(@"ERROR fetch stream: %@", error);
            strongSelf.isLoading = NO;
            [strongSelf recoverFromPlaybackFailure:error videoId:track.videoId];
            return;
        }
        strongSelf.pendingMuxed = muxedStream;
        strongSelf.audioBitrateKbps = audioBitrateKbps;
        [[LTPlaylistStore sharedStore] recordBitrateKbps:audioBitrateKbps forVideoId:track.videoId];
        LTLog(@"FETCH_OK downloading stream for %@ muxed=%d", track.videoId, muxedStream);
        [strongSelf downloadAndPlayURL:streamURL videoId:track.videoId];
    }];
}

- (void)loadLocalFileAtPath:(NSString *)path {
    NSURL *fileURL = [NSURL fileURLWithPath:path];
    if ([[path pathExtension] caseInsensitiveCompare:@"mp4"] == NSOrderedSame) {
        LTLog(@"MUXED playing via AVPlayer %@", path);
        [self loadMuxedFileAtURL:fileURL];
        return;
    }
    [self stopMoviePlayer];
    NSError *error = nil;
    AVAudioPlayer *player = [[AVAudioPlayer alloc] initWithContentsOfURL:fileURL error:&error];
    if (!player) {
        LTLog(@"AUDIOPLAYER init error: %@", error);
        self.isLoading = NO;
        [self recoverFromPlaybackFailure:error videoId:self.pendingVideoId];
        return;
    }
    self.audioPlayer = player;
    self.audioPlayer.delegate = self;
    self.audioPlayer.volume = self.volume;
    self.audioPlayer.meteringEnabled = YES;
    [self.audioPlayer prepareToPlay];
    [self updateNowPlayingInfo];
    [self playMovie];
}

- (void)loadMuxedFileAtURL:(NSURL *)fileURL {
    [self stopAudioPlayer];
    // Drops the old player *and* its observers. Only the end observers used to
    // be removed by hand, so every muxed track left a failed-to-play observer
    // behind pointing at an item that was long gone.
    [self stopMoviePlayer];
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:fileURL];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(playerItemDidEnd:)
                                                 name:AVPlayerItemDidPlayToEndTimeNotification
                                               object:item];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(playerItemFailed:)
                                                 name:AVPlayerItemFailedToPlayToEndTimeNotification
                                               object:item];
    self.moviePlayer = [[AVPlayer alloc] initWithPlayerItem:item];
    // -play on an item whose status is still Unknown is what could leave a muxed
    // track loaded and silent with no callback to rescue it. Start from the
    // item's readiness instead of assuming it.
    [item addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionNew context:NULL];
    self.observedItem = item;
    if ([self.moviePlayer respondsToSelector:@selector(setVolume:)]) {
        self.moviePlayer.volume = self.volume; // iOS 7+ only
    }
    [self updateNowPlayingInfo];
    [self playMovie];
}

- (void)playerItemDidEnd:(NSNotification *)notification {
    // A player item from an earlier track may still be winding down.
    if (self.moviePlayer && notification.object != self.moviePlayer.currentItem) {
        LTLog(@"FINISH ignoring end from a stale item");
        return;
    }
    // An advance is already in flight for this item: keeps the 5s watchdog from
    // advancing a second time in the window before the next track loads.
    self.endRecoveryPending = YES;
    LTLog(@"FINISH avplayer item end videoId=%@", [self currentTrack].videoId);
    [self nextTrack];
}

- (void)playerItemFailed:(NSNotification *)notification {
    if (self.moviePlayer && notification.object != self.moviePlayer.currentItem) {
        LTLog(@"FINISH ignoring failure from a stale item");
        return;
    }
    NSError *error = [[notification userInfo] objectForKey:AVPlayerItemFailedToPlayToEndTimeErrorKey];
    LTLog(@"FINISH avplayer item failed: %@", error);
    [self recoverFromPlaybackFailure:error videoId:[self currentTrack].videoId];
}

// Readiness of the muxed item that is currently loaded. A transition waits for
// this instead of playing into an item that cannot start yet.
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                        change:(NSDictionary *)change context:(void *)context {
    if (![keyPath isEqualToString:@"status"] || ![object isKindOfClass:[AVPlayerItem class]]) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    AVPlayerItem *item = (AVPlayerItem *)object;
    if (item != self.observedItem) return; // a track already replaced this one
    LTLog(@"ITEM status=%d %@ videoId=%@", (int)item.status,
          [self playerStateDescription], [self currentTrack].videoId);
    if (item.status == AVPlayerItemStatusReadyToPlay) {
        // Ready now: this is the moment a start attempt that was waiting on the
        // source can take effect.
        if (!self.userPaused && !self.interrupted && ![self activePlayerIsProducingAudio]) {
            [self attemptPlaybackStart];
        }
    } else if (item.status == AVPlayerItemStatusFailed) {
        LTLog(@"ITEM failed: %@", item.error);
        [self recoverFromPlaybackFailure:item.error videoId:[self currentTrack].videoId];
    }
}

#pragma mark - Failure recovery

// Continuous playback: a stream that cannot be fetched, or a player that dies
// mid-track, must not end the listening session. The track is retried once with
// a freshly fetched stream URL (the previous URL may have expired), and after
// that the player skips ahead. Only a run of failures — i.e. the network is
// really gone — stops playback, and then it says why.
static const NSInteger LTPlaybackFailureStreakLimit = 3;

- (void)recoverFromPlaybackFailure:(NSError *)error videoId:(NSString *)videoId {
    LTTrack *track = [self currentTrack];
    if (!track) {
        self.isLoading = NO;
        [self pausePlayback];
        return;
    }
    if (videoId.length && track.videoId.length && ![videoId isEqualToString:track.videoId]) {
        // The failure belongs to a track the user has already left.
        return;
    }
    self.consecutiveLoadFailures += 1;
    LTLog(@"RECOVER failure %d/%d videoId=%@ err=%@",
          (int)self.consecutiveLoadFailures, (int)LTPlaybackFailureStreakLimit,
          track.videoId, error.localizedDescription ?: @"(no error)");
    if (self.consecutiveLoadFailures > LTPlaybackFailureStreakLimit) {
        self.isLoading = NO;
        self.consecutiveLoadFailures = 0;
        [self pausePlayback];
        NSError *shown = error ?: [NSError errorWithDomain:NSURLErrorDomain
                                                      code:NSURLErrorNotConnectedToInternet
                                                  userInfo:@{NSLocalizedDescriptionKey: @"Playback keeps failing. Check the connection."}];
        [self showError:shown];
        return;
    }
    BOOL alreadyRetried = (track.videoId.length && [self.lastRetriedVideoId isEqualToString:track.videoId]);
    if (!alreadyRetried) {
        self.lastRetriedVideoId = track.videoId;
        LTLog(@"RECOVER retrying %@ with a fresh stream", track.videoId);
        self.suppressTrackStats = YES;
        [self loadCurrentTrack];
        return;
    }
    self.lastRetriedVideoId = nil;
    LTLog(@"RECOVER skipping to the next track");
    [self nextTrack];
}

#pragma mark - Download watchdog

// A connection that stops sending bytes (cell hand-off, Wi-Fi dropping) can sit
// silent until the 120s request timeout, which is far too long between songs.
// Any 30s gap with no data restarts the track instead.
- (void)resetStreamWatchdog {
    [self.streamWatchdog invalidate];
    self.streamWatchdog = nil;
    if (!self.streamConnection) return;
    self.streamWatchdog = [NSTimer scheduledTimerWithTimeInterval:30.0
                                                          target:self
                                                        selector:@selector(streamWatchdogFired:)
                                                        userInfo:nil
                                                         repeats:NO];
    [[NSRunLoop mainRunLoop] addTimer:self.streamWatchdog forMode:NSRunLoopCommonModes];
}

- (void)stopStreamWatchdog {
    [self.streamWatchdog invalidate];
    self.streamWatchdog = nil;
}

- (void)streamWatchdogFired:(NSTimer *)timer {
    self.streamWatchdog = nil;
    NSURLConnection *connection = self.streamConnection;
    if (!connection) return;
    LTLog(@"DL_STALL no data for 30s, retrying track");
    self.streamConnection = nil;
    [connection cancel];
    self.isLoading = NO;
    NSError *error = [NSError errorWithDomain:NSURLErrorDomain
                                          code:NSURLErrorTimedOut
                                      userInfo:@{NSLocalizedDescriptionKey: @"The stream stopped sending data."}];
    [self recoverFromPlaybackFailure:error videoId:self.streamVideoId];
}

- (void)downloadAndPlayURL:(NSString *)urlString videoId:(NSString *)videoId {
    // Use the id the caller fetched the URL for; falling back to the pending id
    // let an old track's download label itself as the new one.
    self.streamVideoId = videoId.length ? videoId : self.pendingVideoId;
    self.streamHTTPStatus = 0;
    [self.streamConnection cancel];
    self.streamConnection = nil;
    self.streamData = [NSMutableData data];
    NSString *path = [LTTempDirectory() stringByAppendingPathComponent:(self.pendingMuxed ? @"lt_track.mp4" : @"lt_track.m4a")];
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:120.0];
    [request setValue:@"bytes=0-" forHTTPHeaderField:@"Range"];
    BOOL hasN = ([urlString rangeOfString:@"&n="].location != NSNotFound || [urlString rangeOfString:@"?n="].location != NSNotFound);
    LTLog(@"START_DOWNLOAD videoId=%@ host=%@ hasN=%d fullurl=%@", self.streamVideoId, [request.URL host], hasN, urlString);
    self.streamConnection = [[NSURLConnection alloc] initWithRequest:request delegate:self startImmediately:YES];
    [self resetStreamWatchdog];
}

#pragma mark - NSURLConnectionDataDelegate

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
    if (connection != self.streamConnection) return;
    NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
    LTLog(@"DL_RESPONSE status=%d expected=%lld", (int)[http statusCode], [response expectedContentLength]);
    self.streamHTTPStatus = [http statusCode];
    [self.streamData setLength:0];
    [self resetStreamWatchdog];
    if ([http statusCode] >= 400) {
        // An expired stream URL answers 403/404 immediately; retry with a fresh
        // URL instead of waiting for a body that will never arrive.
        LTLog(@"DL_HTTP_ERROR status=%d — recovering", (int)[http statusCode]);
        self.streamConnection = nil;
        [connection cancel];
        [self stopStreamWatchdog];
        self.isLoading = NO;
        [self recoverFromPlaybackFailure:[NSError errorWithDomain:NSURLErrorDomain
                                                             code:[http statusCode]
                                                         userInfo:nil]
                                 videoId:self.streamVideoId];
    }
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
    if (connection != self.streamConnection) return;
    [self resetStreamWatchdog];
    [self.streamData appendData:data];
    if ((self.streamData.length / 262144) != ((self.streamData.length - data.length) / 262144)) {
        LTLog(@"DL_PROGRESS bytes=%d", (int)self.streamData.length);
    }
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
    if (connection != self.streamConnection) return; // cancelled/replaced: already handled
    LTLog(@"DL_ERROR %@", error);
    self.streamConnection = nil;
    [self stopStreamWatchdog];
    self.isLoading = NO;
    [self recoverFromPlaybackFailure:error videoId:self.streamVideoId];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
    if (connection != self.streamConnection) return;
    LTLog(@"DL_FINISH bytes=%d status=%d", (int)self.streamData.length, (int)self.streamHTTPStatus);
    self.streamConnection = nil;
    [self stopStreamWatchdog];
    if (![self.streamVideoId isEqualToString:self.pendingVideoId]) {
        LTLog(@"DL_STALE ignoring");
        return;
    }
    if (self.streamHTTPStatus >= 400 || !self.streamData.length) {
        self.isLoading = NO;
        NSString *reason = self.streamHTTPStatus
            ? [NSString stringWithFormat:@"Stream download failed (HTTP %d).", (int)self.streamHTTPStatus]
            : @"Stream download failed.";
        [self recoverFromPlaybackFailure:[NSError errorWithDomain:NSURLErrorDomain code:self.streamHTTPStatus
                                                        userInfo:@{NSLocalizedDescriptionKey: reason}]
                                 videoId:self.streamVideoId];
        return;
    }
    NSString *path = [LTTempDirectory() stringByAppendingPathComponent:(self.pendingMuxed ? @"lt_track.mp4" : @"lt_track.m4a")];
    [self.streamData writeToFile:path atomically:YES];
    LTLog(@"WROTE file, playing %@", self.streamVideoId);
    [self loadLocalFileAtPath:path];
}

- (void)nextTrack {
    [self commitStatsDelta];
    // A start still being verified belongs to the track being left.
    [self cancelStartVerification];
    LTLog(@"NEXT index=%d count=%d repeat=%d from=%@",
          (int)self.currentIndex, (int)self.queue.count, (int)self.repeatMode,
          [self currentTrack].videoId ?: @"(none)");
    if (self.repeatMode == LTRepeatModeOne && self.currentIndex >= 0) {
        [self replayCurrentTrack];
        return;
    }
    if (self.currentIndex + 1 < (NSInteger)self.queue.count) {
        self.currentIndex += 1;
        [self postQueueChanged];
        [self loadCurrentTrack];
        return;
    }
    if (self.repeatMode == LTRepeatModeAll && self.queue.count) {
        self.currentIndex = 0;
        [self postQueueChanged];
        [self loadCurrentTrack];
        return;
    }
    // Queue exhausted. A listening session is a radio, so ask the mix endpoint
    // for the next set of tracks — whether or not shuffle is on. Only a source
    // that has genuinely run dry ends playback.
    if ([self tryExtendQueueWithRadio]) return;
    [self finishQueueAtEnd];
}

// Repeat One, and Previous at the start of a track, replay what is already
// loaded instead of fetching it again: no download gap, no second play count,
// and nothing left sitting in a finished state.
- (void)replayCurrentTrack {
    if (![self hasActivePlayer]) {
        [self loadCurrentTrack];
        return;
    }
    self.isLoading = NO;
    self.consecutiveLoadFailures = 0;
    self.lastRetriedVideoId = nil;
    self.endRecoveryPending = NO;
    [self playerSeekToTime:0];
    self.statsBaseTime = 0;
    [self playMovie];
}

- (void)finishQueueAtEnd {
    // Keep the current track and index: the last item stays loaded, so Play
    // (in-app or on the lock screen) resumes something rather than nothing and
    // the metadata stays put.
    LTLog(@"QUEUE nothing left to play");
    self.isLoading = NO;
    [self pausePlayback]; // deliberate stop, so the watchdog stays quiet
    [self postQueueChanged];
    [[NSNotificationCenter defaultCenter] postNotificationName:LTPlayerDidFinishQueueNotification object:self];
}

// Appends a YT Music mix (RDAMVM<videoId>) seeded from the track that just
// ended. Returns YES if the expansion was started (nextTrack should simply
// wait for the async completion) or is already in flight.
- (BOOL)tryExtendQueueWithRadio {
    if (self.radioPending) return YES; // already fetching; wait for it
    LTTrack *seed = [self currentTrack];
    if (!seed.videoId.length) return NO;
    [self extendQueueWithSeed:seed.videoId allowFallback:YES];
    return YES;
}

// One mix request. Mixes overlap heavily with what has already played, so a
// response can be entirely duplicates; when that happens the queue retries with
// a second seed before giving up. Trusting the first response is what used to
// end a session after a handful of tracks.
- (void)extendQueueWithSeed:(NSString *)seedVideoId allowFallback:(BOOL)allowFallback {
    NSString *radioId = [NSString stringWithFormat:@"RDAMVM%@", seedVideoId];
    self.radioPending = YES;
    NSUInteger generation = self.loadGeneration;
    NSUInteger baseCount = [self.queue count];
    LTLog(@"RADIO extending queue with %@", radioId);
    __weak LTPlayerController *weakSelf = self;
    [[LTYouTubeClient sharedClient] fetchRadioTracksForPlaylistId:radioId completion:^(NSArray *tracks, NSError *error) {
        __strong LTPlayerController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.radioPending = NO;
        // The user changed track or queue while the mix was in flight.
        if (strongSelf.loadGeneration != generation || strongSelf.queue.count != baseCount) return;
        if (error) LTLog(@"RADIO fetch failed: %@", error);

        NSMutableArray *queue = [strongSelf.queue mutableCopy];
        NSMutableArray *source = [strongSelf.sourceQueue mutableCopy] ?: [NSMutableArray array];
        NSUInteger added = 0;
        for (LTTrack *track in tracks) {
            if (!track.videoId.length) continue;
            if ([track.videoId isEqualToString:seedVideoId]) continue;
            if ([strongSelf indexOfTrackWithVideoId:track.videoId] >= 0) continue;
            [queue addObject:track];
            [source addObject:track];
            added += 1;
        }
        if (added == 0) {
            NSString *fallbackSeed = allowFallback ? [strongSelf radioSeedExcluding:seedVideoId] : nil;
            if (fallbackSeed.length) {
                LTLog(@"RADIO no new tracks from %@, trying %@", seedVideoId, fallbackSeed);
                [strongSelf extendQueueWithSeed:fallbackSeed allowFallback:NO];
                return;
            }
            [strongSelf finishQueueAtEnd];
            return;
        }
        strongSelf.queue = queue;
        strongSelf.sourceQueue = source;
        [strongSelf postQueueChanged];
        // baseCount is the index of the first appended track.
        strongSelf.currentIndex = (NSInteger)baseCount;
        [strongSelf loadCurrentTrack];
    }];
}

- (NSInteger)indexOfTrackWithVideoId:(NSString *)videoId {
    if (!videoId.length) return -1;
    for (NSInteger i = 0; i < (NSInteger)self.queue.count; i++) {
        LTTrack *existing = [self.queue objectAtIndex:(NSUInteger)i];
        if ([existing.videoId isEqualToString:videoId]) return i;
    }
    return -1;
}

// A different seed for a retry, away from the track whose mix just came back
// empty, so the second request is not the same dead end again.
- (NSString *)radioSeedExcluding:(NSString *)excludedVideoId {
    NSMutableArray *candidates = [NSMutableArray array];
    for (LTTrack *track in self.queue) {
        if (!track.videoId.length) continue;
        if ([track.videoId isEqualToString:excludedVideoId]) continue;
        [candidates addObject:track.videoId];
    }
    if (!candidates.count) return nil;
    NSUInteger pick = arc4random_uniform((uint32_t)candidates.count);
    return [candidates objectAtIndex:pick];
}

// Lock screen / Control Center "previous": always go back to the last track,
// rather than restarting the current one the way the in-app button does when
// playback is past the three second mark.
- (void)rewindToPreviousTrack {
    [self commitStatsDelta];
    if (self.currentIndex > 0) {
        self.currentIndex -= 1;
        [self postQueueChanged];
        [self loadCurrentTrack];
        return;
    }
    if (self.repeatMode == LTRepeatModeAll && self.queue.count) {
        self.currentIndex = (NSInteger)self.queue.count - 1;
        [self postQueueChanged];
        [self loadCurrentTrack];
        return;
    }
    [self playerSeekToTime:0];
    [self updateNowPlayingInfo];
}

- (void)previousTrack {
    [self commitStatsDelta];
    if (self.currentIndex > 0) {
        self.currentIndex -= 1;
        [self postQueueChanged];
        [self loadCurrentTrack];
    } else if ([self playerCurrentTime] > 3.0) {
        [self playerSeekToTime:0];
    } else {
        [self replayCurrentTrack];
    }
}

- (void)toggleShuffle {
    self.shuffleEnabled = !self.shuffleEnabled;
    [[NSUserDefaults standardUserDefaults] setObject:@(self.shuffleEnabled ? YES : NO) forKey:@"LTShuffleEnabled"];
    if (self.shuffleEnabled) {
        LTTrack *current = [self currentTrack];
        NSMutableArray *rest = [NSMutableArray array];
        for (NSInteger i = self.currentIndex + 1; i < (NSInteger)self.queue.count; i++) {
            [rest addObject:[self.queue objectAtIndex:(NSUInteger)i]];
        }
        rest = [[self shuffledArray:rest] mutableCopy];
        NSMutableArray *newQueue = [NSMutableArray array];
        if (current) [newQueue addObject:current];
        [newQueue addObjectsFromArray:rest];
        self.queue = newQueue;
        self.currentIndex = 0;
        LTLog(@"SHUFFLE on");
    } else {
        NSInteger target = 0;
        LTTrack *current = [self currentTrack];
        self.queue = [self.sourceQueue copy];
        if (current) {
            for (NSInteger i = 0; i < (NSInteger)self.queue.count; i++) {
                if ([[self.queue objectAtIndex:(NSUInteger)i] isEqual:current]) { target = i; break; }
            }
        }
        self.currentIndex = target;
        LTLog(@"SHUFFLE off");
    }
    [self postQueueChanged];
}

- (NSArray *)shuffledArray:(NSArray *)array {
    NSMutableArray *m = [array mutableCopy];
    for (NSInteger i = (NSInteger)m.count - 1; i > 0; i--) {
        NSUInteger j = (NSUInteger)arc4random_uniform((uint32_t)(i + 1));
        [m exchangeObjectAtIndex:(NSUInteger)i withObjectAtIndex:j];
    }
    return m;
}

- (void)cycleRepeatMode {
    self.repeatMode = (LTRepeatMode)((self.repeatMode + 1) % 3);
    LTLog(@"REPEAT mode=%d", (int)self.repeatMode);
    [self postQueueChanged];
}

- (void)setRepeatMode:(LTRepeatMode)repeatMode {
    _repeatMode = repeatMode;
    LTLog(@"REPEAT mode=%d", (int)repeatMode);
    [self postQueueChanged];
}

- (void)postQueueChanged {
    [[NSNotificationCenter defaultCenter] postNotificationName:LTPlayerQueueDidChangeNotification object:self];
}

- (void)togglePlayPause {
    if ([self playerIsPlaying]) {
        [self pausePlayback];
        return;
    }
    // Nothing loaded yet but a track is still arriving: there is no paused
    // player to start, and loading it again would restart the download.
    if (![self hasActivePlayer] && self.isLoading) return;
    // With nothing loaded otherwise, -playMovie loads the current track instead
    // of a Play press doing nothing at all.
    [self playMovie];
}

- (void)seekToTime:(NSTimeInterval)time {
    [self playerSeekToTime:time];
    [self updateNowPlayingInfo];
}

#pragma mark - AVAudioPlayerDelegate

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    // The delegate is still pointed at this controller when a player is
    // replaced, and a late callback from the old one would skip twice.
    if (player != self.audioPlayer) {
        LTLog(@"FINISH ignoring end from a replaced player");
        return;
    }
    LTLog(@"FINISH success=%d videoId=%@", flag, [self currentTrack].videoId);
    if (flag) {
        // Stops the watchdog advancing the same finished item a second time.
        self.endRecoveryPending = YES;
        [self nextTrack];
        return;
    }
    // A truncated download or a decode that died used to just stop playback.
    [self recoverFromPlaybackFailure:nil videoId:[self currentTrack].videoId];
}

- (void)audioPlayerDecodeErrorDidOccur:(AVAudioPlayer *)player error:(NSError *)error {
    if (player != self.audioPlayer) return; // belongs to a track already replaced
    LTLog(@"AUDIOPLAYER decode error: %@", error);
    [self recoverFromPlaybackFailure:error videoId:[self currentTrack].videoId];
}

#pragma mark - Errors

- (void)showError:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Playback Failed"
                                                        message:[error localizedDescription]
                                                       delegate:nil
                                              cancelButtonTitle:@"OK"
                                              otherButtonTitles:nil];
        [alert show];
    });
}

@end
