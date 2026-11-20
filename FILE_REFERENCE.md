# ReinMusic — File Reference

This document describes every file in the ReinMusic repository (v1.0). ReinMusic is an Objective-C
iOS app built with Theos — a native YouTube Music client for legacy jailbroken iOS 6+ devices
(armv7) that also runs on modern arm64 hardware. It talks to YouTube's unofficial InnerTube API for
search, browsing, streaming and lyrics, and adds local playlists, offline downloads, listening
stats, account sign-in, peer-to-peer library sync, a web export feature, and even a full
iPod-classic emulator mode. Below, each file is listed with its purpose and a summary of the code it
contains. Header (`.h`) and implementation (`.m`) files for the same class are documented together
under the class name.

---

## 1. App core / entry point

### `main.m`
The C entry point of the app. It wraps `UIApplicationMain` in an `@autoreleasepool` and passes
`NSStringFromClass([LTAppDelegate class])` as the delegate class, so `LTAppDelegate` becomes the
application delegate. There is nothing else in the file — all real startup work lives in the app
delegate.

### `LTAppDelegate.h` / `LTAppDelegate.m`
The application delegate and the place where the app's root UI is assembled. The header declares
`LTAppDelegate : UIResponder <UIApplicationDelegate>` with a `window` property plus three class
methods: `makeTabBarController` (builds the five-tab root — Home, Search, Library, Now Playing,
Settings — each wrapped in a `UINavigationController`), `standardRootViewController` (wraps that tab
controller in `LTSplitContainerViewController` on iPad), and `applyDisplayModeAnimated:` (re-applies
the iPod-mode / one-handed-mode root). The implementation installs an uncaught-exception handler
that writes crash reports to `lt_crash.txt` in the temp directory, configures the `AVAudioSession`
for background playback, registers `MPRemoteCommandCenter` handlers (play/pause/next/previous/skip/
position) so lock-screen and headphone controls work, and handles `remoteControlReceivedWithEvent:`
for the old-style remote events used on legacy iOS. The remote "previous" handler calls
`rewindToPreviousTrack` rather than `previousTrack`, so the lock screen always returns to the last
track instead of restarting the current one. It also forwards delegate callbacks for
backgrounding/foregrounding to the player controller.

### `LTModel.h` / `LTModel.m`
The core data model file. It declares three plain model classes: `LTTrack` (title, artist, album,
videoId, thumbnailURL, duration) with `dictionaryRepresentation`/`trackWithDictionary:` for
JSON-style serialization; `LTBrowseItem` (an album/artist/playlist entry with an `LTBrowseKind`
enum, title, subtitle, browseId and thumbnail) used for search results and home shelves; and
`LTLocalPlaylist` (identifier, name, coverPath and a mutable `tracks` array) with the same
dictionary serialization. The `.m` implements those four serialize/deserialize methods with
type-safe field extraction.

### `LTTheme.h` / `LTTheme.m`
Central color palette for the app. Because ReinMusic is built against old SDKs (iOS 9.3 / 11.2) it
cannot use iOS 13 dynamic colors, so `LTTheme` detects dark mode at runtime (`+isDark`, always NO on
iOS 12 and older) and returns plain `UIColor`s per appearance: background, groupedBackground,
cellBackground, fill, placeholder, text, secondaryText, separator and accent. Every themed view in
the app pulls its colors from here, which keeps light/dark support on ancient SDKs manageable.

### `LTGraphics.h` / `LTGraphics.m`
The graphics/icon factory. It registers the bundled FontAwesome.ttf and Lucide-rendered fonts at
runtime, maps legacy Font Awesome code points to Lucide icon names (play, pause, shuffle, repeat,
house, search, settings, library, download, check, pen, …), and exposes typed icon builders:
`glyphIcon:size:color:`, `fontAwesomeGlyphIcon:`, `repeatIconOfSize:`, `repeatOneIconOfSize:`,
`playIcon`, `shuffleIcon`, `downloadIcon`, `checkmarkIcon`, `renameIcon`, plus the tab-bar icons
`homeIcon`, `searchIcon`, `popularIcon`, `settingsIcon`, `libraryIcon`. Beyond icons it implements
`blurredImageFromImage:` (a hand-rolled box/radius blur, since iOS 8 CIRemoteImage-style APIs aren't
uniformly available) and `dominantColorsFromImage:count:`, which extracts the brightest-normalized
dominant colors of an image for the player's glow/background palette.

### `LTFilePaths.h`
Header-only utility (no `.m`) with three `static inline` functions. `LTDirectoryIsWritable` probes a
path by creating and deleting a test file. `LTDataDirectory` returns the app's persistent storage
root: it prefers the legacy jailbreak location `/var/mobile/Documents/LegacyMusic` when writable and
otherwise falls back to `Documents/LegacyMusic` inside the app sandbox, so one binary works on
jailbroken iOS 6–9 and sandboxed modern iOS. `LTTempDirectory` likewise prefers `/tmp` and falls
back to `NSTemporaryDirectory()`. Used for playlists, downloads, artwork and log files.

### `LTLog.h`
Header-only logging helper (no `.m`). The `static inline` variadic function `LTLog(fmt, ...)`
formats the message, mirrors it to `NSLog`, and appends a timestamped line to `reinmusic.log` in
`LTTempDirectory()` (creating the file on demand). This gives a persistent on-device log that is
easy to pull off a jailbroken device.

### `LTSafeArea.h` / `LTSafeArea.m`
Safe-area helper for notched devices (iPhone X and newer). Because the armv7 slice is compiled
against the iOS 9.3 SDK where `safeAreaInsets` doesn't exist, the functions `LTSafeAreaInsets`,
`LTSafeAreaTop` and `LTSafeAreaBottom` are implemented with runtime checks that compile to zero
insets on the old SDK (32-bit devices are never notched anyway). Callers use these instead of raw
UIKit safe-area APIs throughout the layouts.

### `LTHaptics.h` / `LTHaptics.m`
A tiny wrapper around the vibration motor. `+pulse` produces a ~10 ms buzz by resolving the private
`AudioServicesPlaySystemSoundWithVibration` helper with `dlsym` (it is missing from the old SDKs'
link stubs), with a null check so it degrades to a no-op; `+pulseIfEnabledForKey:` does the same only
when the user hasn't disabled vibration for a given defaults key. Used for click-wheel and transport
feedback.

### `LTTextUtils.h` / `LTTextUtils.m`
Small text utility. Declares the constant `LTListTitleWidthFraction` and the function
`LTTruncatedTextToWidth(text, font, maxWidth)`, which truncates a string to fit a pixel width and
appends an ellipsis. Used by cells that must fit titles into fixed-width labels.

### `LTLucideIcons.h` / `LTLucideIcons.m`
Renders the exact Lucide icon geometry used by the audioNINJA desktop app, for visual parity with
the original AN Legacy client. The `.m` contains a large static dictionary `LTLucideIconDefinitions`
holding ~30 icons (play, pause, rewind, fast-forward, skip-back/forward, shuffle, repeat,
repeat-1, download, check, pen, house, search, settings, library, trending-up, x, plus, minus,
chevrons, arrows, music, list-music, sliders-horizontal, clock, mic-vocal, square, grip-vertical,
…) as path/circle/rect element arrays copied verbatim from lucide-react. `+iconNamed:size:color:`
draws them on a 24×24 grid scaled to the requested size with stroke-width 2 (scaled proportionally)
and returns a tinted `UIImage`; returns nil for unknown names.

### `LTAppIcon.h` / `LTAppIcon.m`
Home-screen icon management. The bundle ships loose PNGs at every icon slot, but modern iOS only
honors the primary 57pt slot, so alternate icons (the iOS 10.3+ `setAlternateIconName:` API) are the
only way to show the rounded/modern artwork. The class declares the alternate icon names
(`classicIconName` = nil, `roundedIconName` = "Icon7", `modernIconName` = "Icon11"), reports
`isPickerSupported` (meaningful on iOS 11+), tracks `currentIconName`/`currentIconLabel`, applies an
icon by name while recording the user's choice, and `applyModernIconIfNeeded` performs a one-shot
first-run switch to the modern icon without ever overriding a deliberate user choice.

### `LTAppTabBar.h` / `LTAppTabBar.m`
A trivial `UITabBar` subclass whose only implementation overrides `traitCollection` to force a
compact vertical size class, which makes the tab bar render at its smaller height in one-handed
mode. `LTTabBarController` swaps this bar in via KVC at init.

### `LTTabBarController.h` / `LTTabBarController.m`
The app's custom `UITabBarController`. It installs an `LTAppTabBar`, drives animated cross-fade /
slide transitions between tabs using a content snapshot (`snapshotContentOfView:inRect:scale:`) and
QuartzCore animations honoring `LTTransitionSettings`, and reports selection changes through the
`selectionDidChange` block so the iPad sidebar can stay in sync. It owns the "dock mode" rule that
only the Now Playing tab may rotate to landscape while every other tab stays portrait, asserts a
bar-less full-height layout when `tabBarForcedHidden` is set (set by the iPad split container), and
includes extensive debug logging of the settled dock hierarchy. `showNowPlaying` selects the
Now Playing tab (also making its icon light up during playback).

### `LTSpinnerView.h` / `LTSpinnerView.m`
A custom deterministic spinner view: a `UIView` subclass with `lineWidth` and `hidesWhenStopped`
properties, drawn as a rotating arc with `startAnimating`/`stopAnimating`/`isAnimating`. Used in
place of `UIActivityIndicatorView` where a themed look is wanted (search overlay, per-row download
spinners).

---

## 2. YouTube / networking

### `LTYouTubeClient.h` / `LTYouTubeClient.m`
The heart of the app: a singleton wrapper around YouTube's unofficial InnerTube JSON API
(`https://<host>/youtubei/v1/<endpoint>?key=<API_KEY>`), using the public web API key and a desktop
Chrome user-agent. The `.m` (~2200 lines) implements: the generic `postToHost:path:body:completion:`
POST helper that attaches SAPISIDHASH `Authorization` + `Cookie` headers when signed in and captures
`responseContext.visitorData` for later requests; InnerTube client contexts for WEB_REMIX, ANDROID_VR,
IOS, ANDROID and ANDROID_MUSIC; search (`searchWithQuery:type:` with per-type param tokens,
`searchVideosWithQuery:`) and its renderer parsers (`trackFromVideoRenderer:`,
`trackFromCompactVideoRenderer:`, `parseSearchResults:`/`parseSearchItem:` including album/artist/
playlist result kinds); browsing (`browseAlbum`, `browsePlaylist`, `browseArtist`) with header
info/subtitle/thumbnail extraction and artist top-songs/albums shelf parsing; channel avatar
resolution (`channelAvatarURLForBrowseId:`, `resolveArtistAvatarForName:`); trending songs via the
music charts; authenticated content (`fetchHomeRecommendations`, `fetchLibraryPlaylists`,
`fetchAccountHistory`, `fetchAccountName`); mix/radio playlists via the `next` endpoint; streaming
(`streamURLForVideo:` → `fetchStreamURLWithContext:` hitting the `player` endpoint with a fallback
chain ANDROID → ANDROID_VR → IOS, preferring adaptive audio itags 141/140/139 (256/128/48 kbps) and
falling back to the muxed itag 18, recording `lastFormatInfo`); lyrics (caption track discovery via
the player response, the watch page's `ytInitialPlayerResponse` scrape, and caption text download
with XML/JSON/VTT parsers; plus `fetchTimedLyricsForVideoId:`/`fetchLyricsForVideo:` using the
YouTube Music lyrics browse response for timestamped or plain lyrics with source attribution); and
`trackMetadataForVideoId:` (title/artist/duration/thumbnail via `next`). It also provides async
image loading with an `NSCache` and a disk cache, plus thumbnail URL upgraders
(`highResThumbnailURL`, `channelAvatarURL:size:`, `squareAvatarURL`, `compatThumbnailURL`). A
varargs `LTPath` helper safely walks nested dict/array JSON.

### `LTAuth.h` / `LTAuth.m`
Singleton holding Google account credentials for authenticated InnerTube calls, using the same
cookie-based SAPISIDHASH scheme the YouTube Music web client uses:
`Authorization: SAPISIDHASH <unixtime>_<sha1("<time> <origin> <SAPISID>")>`. The SAPISID cookie comes from the
in-app Google page or is pasted from a desktop browser signed into YouTube Music (see
`LTSignInViewController` and `LTCookieSignInViewController`). The API exposes `signedIn`, `accountName`, `sapisid`
(SAPISID, then `__Secure-3PAPISID`, then `__Secure-1PAPISID`), `cookieHeader`, and methods
`setCredentialsWithCookieHeader:accountName:`, `cookieHeaderFromSharedStorage` (the whitelisted shared
cookies as one header, without storing them), `authorizationHeaderForOrigin:`, `authorizationHeaderForCookieHeader:origin:` (the same header built from
an arbitrary cookie header, so a candidate sign-in can be tested without storing it),
`normalizedCookieHeaderFromInput:` (the bare-token/whole-header normalisation, without writing
anything) and `signOut`. Credentials persist in NSUserDefaults and changes are
broadcast via `LTAuthDidChangeNotification`.

### `LTWebExporter.h` / `LTWebExporter.m`
Singleton that packages selected local playlists into a self-contained offline "Rein Mini" web
player under `<data dir>/web-export/`. `exportWithSelectedPlaylists:completion:` runs on a
background queue; `buildExportWithSelected:error:` copies the bundled `web_template.html`, computes
an MD5-hex playlist fingerprint, writes the playlist/track data as JSON injected at the
`<!--WEB_DATA-->` marker, and downloads any missing track artwork into an `art/` folder (with a
blank-art fallback via `writeBlankArtTo:`). The completion reports the output directory (or error)
on the main thread.

---

## 3. Browsing UI

### `LTHomeViewController.h` / `LTHomeViewController.m`
The Home tab. A table-view controller whose sections mix a "Recently played" horizontal strip
(inner `LTHomeRecentsCell` with a scroll of square tiles sized by the `LTHomeTileSize` preference,
min 90 / max 130 pt), a grid of kind tiles for browsing (search types, charts, moods — inner cell
with `setItems:` and `kindLabel:`), and, when signed in, personalized InnerTube shelves from
`fetchHomeRecommendations` ("Mixed for you", "Listen again", etc.). It builds a sign-in banner
(`buildBanner`/`updateBannerText`), loads account content lazily (`loadAccountContentIfNeeded`),
observes auth and playlist-store notifications, supports row editing (removing recents/local
playlists), routing taps to track lists / artist pages / playlist detail / stats, and exposes the
tile-size constants `kHomeTileMinWidth`/`kHomeTileMaxWidth`.

### `LTSearchViewController.h` / `LTSearchViewController.m`
The Search tab: a `UISearchBar` plus a segmented control (Songs / Videos / Albums / Artists, or a
local-playlists mode when `initWithType:` asks for it). `performSearch` queries
`LTYouTubeClient.searchWithQuery:type:` while showing a custom spinner overlay, merges a "From your
library" section of local tracks matching the query (`libraryTracksMatchingQuery:`), and supports
browsing past queries via `showSearchHistory` (recorded by `LTPlaylistStore`). Results route to
`LTTrackListViewController` (album/playlist) or `LTArtistViewController` (artist) and play videos
directly; rows offer the shared song menu, an add-to-playlist picker, downloads, swipe/commit
deletion for history rows, empty-state and toast messages, and live re-layout across appearance
changes. A `Home` bar button (`backToHomeTapped:`) drops the keyboard and switches to the Home
tab, so the keyboard can never trap the user on this screen.

### `LTArtistViewController.h` / `LTArtistViewController.m`
Artist page, constructed with `initWithBrowseId:title:`. `loadContent` calls
`LTYouTubeClient.browseArtist:` to fetch header info, top songs and albums, rendering them as
sections of a table (`numberOfSections` derived from what came back), with an `LTHeaderView`-style
header for artwork/subtitle. Selecting a song starts playback with the whole top-song list;
`songPlusTapped:` opens the shared song menu for the row. Handles trait/appearance changes.

### `LTTrackListViewController.h` / `LTTrackListViewController.m`
Generic track-list page for an album or playlist browse ID (`initWithBrowseId:kind:title:`).
`loadContent` calls `browseAlbum:`/`browsePlaylist:`; `buildHeaderView` creates the artwork plus a
row of buttons (play all, shuffle, download, add-all to a playlist, save to library) wired to
`playAllTapped:`, `shuffleTapped:`, `downloadTapped:` (enqueues a batch through `LTPlaylistStore`
with progress toasts), `addAllTapped:` and `saveTapped:`. `updateHeader`/`updateDownloadState`
refresh counts and per-row download spinners/badges, `setArtworkURL:`/`fallbackArtwork` load art
asynchronously, and the table plays the tapped track within the loaded list.

### `LTHeaderView.h` / `LTHeaderView.m`
A simple reusable header view for detail pages: fixed-width init (`initWithWidth:`), an artwork
`UIImageView`, `titleLabel` and `subtitleLabel`, plus `setArtworkURL:` which loads the remote image
through `LTYouTubeClient` with a placeholder fallback. Used by artist/track-list style screens.

### `LTMediaCell.h` / `LTMediaCell.m`
The workhorse table cell with square artwork, title and subtitle. `setImageFromURL:` loads art
asynchronously (with the shared image cache) and `lt_updateTruncatedTitle` re-truncates the title on
layout using `LTTextUtils`. Widely reused by home, search, library and stats tables.

### `LTSimpleCell.h` / `LTSimpleCell.m`
A minimal `UITableViewCell` subclass with consistent paddings/typography for text-only rows
(search history, queue, settings-style lists). Its only custom logic is `layoutSubviews` adjusting
the label frames.

### `LTSplitContainerViewController.h` / `LTSplitContainerViewController.m`
iPad-only root container. In portrait it shows the normal tab bar; in landscape it replaces it with
a left sidebar listing the five destinations (rail mode: 56 pt icon strip; full mode: 260 pt with
titles) plus a scrolling "Playlists" section (`rebuildPlaylistRows`) with real cover thumbnails
(`playlistCoverImageForPlaylist:`, `loadPlaylistThumbnail:intoButton:`,
`styledSidebarThumbnail:`). Because the same `LTTabBarController` owns all children in both layouts,
`sidebarTapped:` just switches its `selectedIndex`, while `tabBarForcedHidden` + `layoutChildren
Animated:`/`layoutTabBarHidden:inBounds:` keep a full-height layout with no dead bar strip.
`+isSupported` gates it to iPad idioms.

### `LTRecentsTileSizeViewController.h` / `LTRecentsTileSizeViewController.m`
Settings sub-screen for the Home "Recents" tile size: a grouped table with a `UISlider`
(`sliderChanged:`) constrained between `kHomeTileMinWidth` and `kHomeTileMaxWidth`, persisting to
the `LTHomeTileSize` default and showing a live textual size (`currentSizeText`).

---

## 4. Playback

### `LTPlayerController.h` / `LTPlayerController.m`
The singleton playback engine behind the whole app. It owns the queue (`playQueue:atIndex:`,
`playQueue:shuffle:`, `enqueueTracks:`, `jumpToIndex:`, `moveTrackAtIndex:toIndex:`,
`removeTrackAtIndex:`, `peekTrackOffset:`), shuffle (rebuilds a shuffled order while keeping the
current track, `shuffledArray:`) and the repeat enum (off/all/one via `cycleRepeatMode`). Playback
uses `AVAudioPlayer` for audio streams and `AVPlayer` for muxed video itag 18 (`playMovie`), and
loads sources in order: an already-downloaded local file (`loadLocalFileAtPath:`), a cached muxed
file (`loadMuxedFileAtURL:`), or streaming — either direct progressive download into a temp file via
an `NSURLConnection` delegate chain (`downloadAndPlayURL:videoId:`) that begins playback from the
buffered file. It resolves stream URLs through `LTYouTubeClient.streamURLForVideo:`, records the
kbps bitrate for the settings counter, updates `MPNowPlayingInfoCenter` and artwork
(`updateNowPlayingInfo`, `loadNowPlayingArtworkForTrack:`), configures the audio session, handles
interruptions/backgrounding with resume, tracks listened time for stats (`statsTick:`,
`commitStatsDelta` with a periodic timer), posts `LTPlayerTrackDidChange`/`StateDidChange`/
`QueueDidChange`/`DidFinishQueue` notifications, and stores volume in NSUserDefaults.

Playback is continuous by design: `recoverFromPlaybackFailure:videoId:` retries a track once with a
freshly fetched stream URL (expired URLs and dropped connections answer 403/404 or fail outright),
then skips to the next track, and only stops with an explanatory alert after
`LTPlaybackFailureStreakLimit` failures in a row. Every failure path feeds it — stream URL fetch,
HTTP ≥ 400 detected in `didReceiveResponse:`, connection errors, an empty download, `AVAudioPlayer`
init/decode failures, `AVPlayerItemFailedToPlayToEndTime`, and a 30-second no-data stall caught by
the `streamWatchdog` timer — and a successful start in `playMovie` resets the streak. Retries set
`suppressTrackStats` so a retried track is not counted as a second play. For the lock screen,
`rewindToPreviousTrack` always goes back to the previous track (or the end of the queue when
repeating), `updateNowPlayingInfo` is re-published on track change and from `statsTick:` so elapsed
time and the progress bar stay accurate, and the artwork refreshes when it loads.

### `LTPlayerViewController.h` / `LTPlayerViewController.m`
The Now Playing tab — the largest UI file (~2000 lines). It builds the full-screen player: large
artwork with a blurred dominant-color background (`artworkBackgroundEnabled`,
`applyArtworkBackdrop` via `LTGraphics.blurredImageFromImage` + `dominantColorsFromImage`, cached
in NSCache per videoId), title/artist/source/bitrate labels, an elapsed/remaining time pair around a
`UISlider`, and a five-button transport (prev, play/pause, next, shuffle, repeat) rendered from
`LTGraphics`/`LTLucideIcons` with per-button circles or a shared pill (`useTransportBarInRect:` /
`useTransportCircles`) and a press "glow" halo (`transportKeyDown/Up`). Horizontal swipes on the
artwork cross-fade to the previous/next track (`handlePan:`, `prepareIncomingArtForDirection:`), a
vertical pan reveals the full queue, and two draggable drawers — the queue pane (`buildQueuePane`,
with reorder/remove table editing) and a stats/lyrics pane (`buildStatsPane`) — slide from the top
corners (`slideDrawerAtIndex:open:animated:`, drag gesture handlers). Distinct layout routines cover
regular phones (`layoutControls`), tall/notched screens, iPad side-by-side
(`layoutPadSideBySideWithWidth:...`) and a landscape "dock" layout (`layoutDockWithWidth:...`,
`layoutPages`). The lyrics view (`refreshLyricsForCurrentTrack`, `renderLyricLinesAnimated:`,
`updateLyricHighlightForTime:`) displays timestamped lyrics with a karaoke-style highlight and
auto-scroll, or plain text; a sync/refresh timer pair keeps progress and lyric highlighting live.

### `LTQueueViewController.h` / `LTQueueViewController.m`
Standalone full-screen queue view (pushed separately from the player's drawer). Lists
`LTPlayerController.queue` in a table with artwork cells, highlights the current row, supports
reordering (`canMoveRowAtIndexPath` → `moveRowAtIndexPath:`) and swipe-to-remove, plays the tapped
row, and optionally mirrors the player's blurred artwork background
(`artworkBackgroundEnabled`, `applyBackgroundPref`, `loadBackgroundArt`). It observes queue-change
notifications and manages an Edit/Done toolbar button.

### `LTCustomActionSheet.h` / `LTCustomActionSheet.m`
A hand-built replacement for `UIActionSheet` with a consistent modern look: initialized with a
title, an array of button titles and a destructive index, `show` fades a dimmed background plus the
button panel up from the bottom of the window, `buttonTapped:` dismisses and reports the tapped
index through the `LTCustomActionSheetDelegate`, and `dismiss` reverses the animation. Used where
the legacy `UIActionSheet` look was undesirable (e.g. playlist rename/menus).

### `LTSongMenu.h` / `LTSongMenu.m`
The shared per-song context menu ("Add to Queue / Add to Playlist / Download") presented from any
screen. `presentForTrack:fromViewController:` shows a `UIActionSheet`; `showPlaylistPickerForTrack:`
opens `LTPlaylistPicker` (with an inline "New Playlist…" creation flow handled in
`alertView:clickedButtonAtIndex:`), adds the track to the chosen playlist, and reports results with
a toast. Implemented as a small object conforming to `UIActionSheetDelegate` and
`UIAlertViewDelegate`.

### `LTPlaylistPicker.h` / `LTPlaylistPicker.m`
A custom bottom-panel replacement for playlist picking: `presentFromViewController:panelTitle:
onPicked:onCreateNew:` builds a dark rounded panel (`buildPanelWithTitle:`) listing playlists by
object reference (immune to duplicate names) as stacked rows (`addRowWithTitle:...` with
touch-down/up highlight feedback), an inline "New Playlist…" row that prompts via
`alertView:clickedButtonAtIndex:` and `promptForName`, outside-tap dismissal (`dismiss`), and
callbacks for either picking an existing playlist or creating a new one with the typed name.

### `LTPlaylistSelectViewController.h` / `LTPlaylistSelectViewController.m`
Modal multi-select table for playlists, used by the web exporter ("Create Rein Mini Instance").
Initialized with `initWithPlaylists:completion:` (all default-selected), it renders checkmark rows,
updates a selected-count footer (`updateFooter`), and finishes with a completion block returning the
selected identifiers and whether the user cancelled (Cancel / Create buttons).

---

## 5. Library & playlists

### `LTLibraryViewController.h` / `LTLibraryViewController.m`
The Library tab: a segmented view over the local library buckets (Albums / Artists / Playlists)
managed by `LTPlaylistStore`. `reloadModels`/`reloadForSegment` build row arrays
(`sortedByName:`, `currentItems`, with an "Unknown Album" placeholder rule) and each row shows a
count and formatted total duration; artist rows resolve avatars asynchronously
(`resolveAvatarForArtistName:`). The right bar button switches between Shuffle All / Play All /
New Playlist by segment (`shuffleAllTapped`, `playAllTapped`, `newPlaylistTapped` with a name
prompt via `alertView:clickedButtonAtIndex:`), rows offer a remove accessory (`rowRemoveTapped:`,
deleting playlists or pruning downloads), and empty-state, toast and themed styling are handled
throughout. Tapping a row pushes the appropriate detail screen.

### `LTLibrarySongsViewController.h` / `LTLibrarySongsViewController.m`
A flat song list over any subset of library tracks (`initWithTracks:title:`) — used for "Songs" and
other bucket drilldowns. Shows artwork rows with per-row remove accessory buttons
(`rowRemoveTapped:`), a toolbar with Shuffle All / Play All (`shuffleAllTapped`, `playAllTapped`,
`updateToolbarEnabled`), live updates when the store changes (`storeDidChange:`), and duration
formatting; tapping a row plays the list via `LTPlayerController`.

### `LTLocalPlaylistDetailViewController.h` / `LTLocalPlaylistDetailViewController.m`
Detail screen for a local playlist (`initWithPlaylist:`). `buildHeaderView` renders the cover art
(loaded from the stored cover image or derived from track thumbnails via `loadArtwork`) with a
button row: play all, shuffle, download-all (`downloadTapped:` enqueues the whole playlist with
progress UI via `setDownloadingUI:`), rename (`renamePlaylistTapped:` → alert / custom action
sheet), and change-cover (`artworkTapped:` → `UIImagePickerController` or
`LTCoverPickerViewController`, handled in `imagePickerController:didFinishPickingMediaWithInfo:`).
The table lists tracks with per-row download buttons/spinners/queued badges
(`rowDownloadButtonForRow:`, `rowSpinnerForRow:`, `rowQueuedBadge`, `rowRemoveTapped:`), reacts to
store/track/download-progress notifications, and supports editing-style deletion.

### `LTCoverPickerViewController.h` / `LTCoverPickerViewController.m`
Two-page cover chooser presented modally via `+presentFromViewController:delegate:`. Page one
(`loadAlbums`) lists the device's music library album covers (from the iPod media query) as
candidates; page two (`loadPhotos`, `layoutGrid`, `photoTapped:`) shows the saved photo library as a
scrolling grid. Selecting an image reports it through `LTCoverPickerDelegate` (`coverPicker:
didSelectImage:`); `cancelTapped:` reports cancellation. Gives playlist covers on-device without
syncing to a computer.

### `LTPlaylistStore.h` / `LTPlaylistStore.m`
The persistent data store and download engine — the app's second-biggest file (~1400 lines). As a
singleton it owns: local playlists (create/delete/rename, cover images saved to disk,
`addTrack:toPlaylist:`, `removeTrackAtIndex:fromPlaylist:`), the saved library
(`addTrackToLibrary:`, `libraryTracks`), recents (`recordRecentTrack:`, `recentTracks`), listened
song IDs, search history (`recordSearchTerm:`, `clearSearchHistory`), per-track listening stats
(`recordTrackPlay:`, `recordListenedSeconds:forTrack:` with a stats file dict, `statsEntries`,
`mostPlayedTracks`, `topArtists`, `totalListeningTime`, `totalPlayCount`), artist avatar URL cache,
and per-video bitrate records. It manages offline downloads end-to-end: directories
(`baseDirectory`/`audioDirectory`/`artDirectory` via `LTFilePaths`), a **persistent** download queue
surviving relaunches (`loadDownloadQueue`/`saveDownloadQueue`, `enqueueDownloads:` with
`LTDownloadBatch` bookkeeping so per-caller completions fire exactly once), a serial
`NSURLConnection`-based downloader (`startNextDownload`, `startDownloadURL:videoId:`,
`connection:didReceiveData:`...) writing audio and muxed files, pause/resume/cancel
(`resumePendingDownloads`, `pausePendingDownloads`, `cancelPendingDownloads`, `clearDownloadFailures`,
`removeDownloadsFromQueue:`), queries (`isTrackDownloaded:`, `isTrackPendingDownload:`,
`pendingDownloadCount`, `downloadedTracks`, `offlineTrackCount`), downloaded-file path mapping
(`localFilePathForVideoId:`, `existingLocalFilePathForVideoId:`), metadata refresh for offline
tracks (`refreshOfflineMetadataWithProgress:completion:`, `resolveThumbnailForTrack:`), and JSON
import/export of playlists. Finally it produces and merges full-state sync payloads for the peer
sync features (`syncArrayRepresentation`, `mergeSyncArray:`, `librarySyncArray`, `recentsSyncArray`,
`statsSyncDict`, `syncPayload`, `mergeSyncPayload:`, `syncDeviceId`) and posts
`LTPlaylistsDidChange`/`LTRecentsDidChange`/download-progress notifications that drive most UI.

### `LTiPodViewController.h` / `LTiPodViewController.m`
A full-screen iPod-classic emulator ("iPod mode") that can replace the app's entire UI. The
implementation (~2000 lines) contains: class-level enable/apply plumbing (`isEnabled`,
`setEnabled:`, `applyiPodModeAnimated:`, `standardRootViewController`); a `LTiPodPane` list view
with wheel-driven scrolling (`rowHeight`, `visibleRows`, `setContentOffsetImmediate:`,
`snapSelection`, custom `drawRect:` with left icons); a `LTiPodWheelView` that draws the click wheel
(`prepareMetrics`, `drawRect:`, `buttonAtPoint:`, `isRingZone:`), translates touches into rotation
deltas (`touchesBegan/Moved/Ended`, `angleAtPoint:`, `unwrapDelta:`) and fires buttons via the
`LTiPodWheelDelegate`; menu panes (main menu, music, per-item submenus built from the library —
`mainMenuPane`, `musicPane`, `submenuPaneForItem:`, `settingsPane`, `aboutPane`), a now-playing
screen with artwork and progress, a search screen where the wheel "types" letters
(`presentSearchScreen`, `advanceSearchKeyByDegrees:`, `performSearchKeyAction`,
`performYouTubeSearch`) and result panes; synthesized click sounds generated at runtime as mono
16-bit PCM WAVs (`LTWriteToneWAV`, `playScrollClickForOffset:`, click/vibes preferences) and
haptics via `LTHaptics`; momentum scrolling (`startMomentumWithVelocity:`, `momentumTick:`), volume
adjustment by wheel rotation with a timeout (`adjustVolumeByDegrees:`, `volumeModeExpired:`), a
title-bar LCD with clock (`buildTitleBarInHost`, `clockTick:`), and player notifications to refresh
playback state.

---

## 6. Downloads

### `LTDownloadQueueViewController.h` / `LTDownloadQueueViewController.m`
Screen for the persistent download queue. Builds its own header (`buildHeader`) with a running
progress indicator and pause/resume toggle (`toggleTapped:` → `LTPlaylistStore.pausePendingDownloads`
/`resumePendingDownloads`), a Clear button with confirm alert (`clearTapped:` →
`clearDownloadFailures`/cancel), and a table of pending tracks with per-row remove buttons
(`removeButtonForRow:`, `removeTapped:` → `removeDownloadsFromQueue:`). `reload` refreshes on
`LTPlaylistDownloadProgressNotification`, shows an empty-state label (`buildEmptyLabel`), and shows
completed/failed state per row. Tapping a row opens the normal song menu.

---

## 7. Stats & settings

### `LTStatsViewController.h` / `LTStatsViewController.m`
"Listening Stats" screen. `reloadData` pulls from `LTPlaylistStore` (`mostPlayedTracks`,
`topArtists`, `totalListeningTime`, `totalPlayCount`, `listenedSongsCount`) and renders a header
with three totals (total time, songs, plays) plus short "Most played" and "Top artists" sections
with "See all" buttons (`seeAllTapped:`) pushing `LTStatsDetailViewController`. Supports themed
custom section headers (`viewForHeaderInSection:`) and starts playback from any listed track.

### `LTStatsDetailViewController.h` / `LTStatsDetailViewController.m`
Full list behind the stats "See all" buttons, created with `initWithType:` for
`LTStatsDetailTypeTracks` or `LTStatsDetailTypeArtists`. `viewWillAppear` reloads the corresponding
store data, rows show rank, artwork/title/artist (for tracks) or artist name with play counts, and
selecting a track row plays it (artists navigate to a filtered song list via the library songs
screen). Handles appearance/trait changes.

### `LTSettingsViewController.h` / `LTSettingsViewController.m`
The Settings tab, organized into sections (Account, Playback, Appearance, Data, About, Credits via
`LTSettingsSection`). Playback rows: Keep Screen Awake and Show kbps Counter switches. Appearance:
Album Art Background, Enable Animations (`LTTransitionSettings`), Transition Speed →
`LTTransitionSpeedViewController`, Recents Tile Size → `LTRecentsTileSizeViewController`, One-Handed
Mode → `LTOneHandedModeViewController`, App Icon picker (`presentIconPicker` with alert options),
and an iPod mode switch. Data management: Offline Downloads (opens `LTDownloadQueueViewController`),
Sync with Another Phone (`LTP2PSync`), Refresh Metadata & Artwork (background job with progress
alert via `startMetadataRefresh`), Create Rein Mini Instance (`exportToWebTapped` →
`LTPlaylistSelectViewController` + `LTWebExporter`), and Clear Offline Downloads (with confirmation
alerts through `alertView:clickedButtonAtIndex:`). Account now has three rows — Google Sign-In (pushes
`LTSignInViewController`), Cookies Sign-In (pushes `LTCookieSignInViewController`), and Log Out
(confirming through `confirmSignOut`, dimmed while signed out) — with the signed-in account name in
the section footer (`titleForFooterInSection:`); `authDidChange:` reloads the table.
About contains version info with a hidden debug egg (`handleVersionTap` →
`LTDebugMenuViewController`) and label helpers (`speedLabel`, `tileSizeLabel`). Applies its own
theme on trait changes.

### `LTSignInViewController.h` / `LTSignInViewController.m`
Google's own sign-in page in an in-app browser, pushed from Settings → Account → Google Sign-In. It
loads `accounts.google.com/ServiceLogin` with the `music.youtube.com` continuation URL, spoofing an
Android 2.3 browser so Google serves its lightweight login page. Which web view hosts it depends on
the OS, because cookies have to be read back out afterwards and the two engines keep them
differently: **iOS 11+ uses `WKWebView`** (`openWKWebViewInFrame:`, chosen by
`canReadCookiesFromWKWebView`), whose cookies live in `WKWebsiteDataStore` and are polled every 1.5s from
`WKHTTPCookieStore` (`getAllCookies:`, reached through the local `LTWKHTTPCookieStoreLike` protocol
so the iOS 9.3 armv7 SDK still compiles). The web view itself is typed as the local
`LTWKWebViewLike` protocol (`loadRequest:`, `stopLoading`, `isLoading`, `setCustomUserAgent:`) rather
than poked with string-key KVC, so a wrong signature fails the build; the poll timer's target is a
`LTWeakTimerProxy` so it cannot retain the controller, and it is invalidated in `dealloc` too.
`adoptWKCookies:` keeps the `google`/`youtube` cookies, requires SAPISID to be among them, and then
hands the sorted header to `startCookieCheck:` — nothing is stored from the page itself, so an expired
session cannot replace a working sign-in. **Everything else keeps `UIWebView`** (iOS 6-10, 32-bit included)
(`openUIWebViewInFrame:`), which shares cookies with `NSHTTPCookieStorage`, so `webViewDidFinishLoad:`
reads them out with `cookieHeaderFromSharedStorage` and checks them via `tryAdoptCookies`. The screen is offered on every version of the app, but it degrades instead of showing a blank browser.
`+webSignInSupported` is NO on 32-bit hardware, where Google's page crashes the legacy WebKit engine
natively: the page is never loaded and `showFallbackWithMessage:canRetry:` puts an explanation plus a
**Use Cookies Sign-In** button on screen. The same panel replaces the browser on a failed load
(`handleWebFailure:`, fed by the UIWebView delegate or the `LTWKNavigationDelegateLike` callbacks) and
on `webViewWebContentProcessDidTerminate:`, with a **Try Again** button as well. `openCookieSignInTapped:`
swaps this screen for `LTCookieSignInViewController` in the navigation stack, so a successful cookie
sign-in pops back to Settings rather than to this dead end.
WebKit is never linked: the armv7 SDK has it only as a private framework, so `LTEnsureWebKitLoaded`
dlopens it on demand on the iOS 11+ path and iOS 6-10 launches never touch it. `viewWillDisappear:` stops the cookie poll timer. The cookie route has its own screen,
`LTCookieSignInViewController`. `startCookieCheck:` is the single write path for the web route: it calls
`fetchAccountNameWithCookieHeader:` with the candidate, ignores a candidate it has already asked about
(`lastCheckedHeader`) and refuses to overlap checks (`validating`). That dedupe is skipped when
`forceNextCheck` is set — a one-shot flag `checkTapped:` arms, which survives the asynchronous WK
adopt hop so an explicit Check retries a set the poll already rejected, while the poll itself keeps
deduping, and only a name coming back lets
`setCredentialsWithCookieHeader:accountName:` run before `finishSignInWithAccountName:` pops the screen.
A rejected candidate leaves the stored credentials alone and just updates the hint. `checkTapped:`
re-runs that check by hand. The bar carries `Cancel` on the left (`cancelTapped:`) and `Check` on the right.

### `LTCookieSignInViewController.h` / `LTCookieSignInViewController.m`
Cookie sign-in GUI (Settings → Account → Cookies Sign-In). A `UITextView` accepts a bare SAPISID
value or a full Cookie header, with a placeholder overlay (`textViewDidChange:`) and keyboard insets
on a `UIScrollView` (`keyboardWillShow:` / `keyboardWillHide:`). `signInTapped:` rejects empty input and
then validates before storing: the candidate header goes through
`fetchAccountNameWithCookieHeader:` (which authenticates that one request with it, via
`postToHost:path:body:cookieHeader:completion:`) and only a name coming back lets
`setCredentialsWithCookieHeader:accountName:` replace the stored credentials. A rejected cookie
shows an alert and leaves an existing sign-in untouched; a good one is saved with the account name
and the screen pops back to Settings. `guideTapped:` pushes `LTCookieTutorialViewController`.

### `LTCookieTutorialViewController.h` / `LTCookieTutorialViewController.m`
The guide behind "How do I get my cookies?": a read-only scrolling `UITextView` (`guideText`) that
walks through opening music.youtube.com on a desktop, finding the cookie table in the Chrome / Edge /
Firefox / Safari developer tools, copying the SAPISID (or `__Secure-3PAPISID` / `__Secure-1PAPISID`)
value and pasting it into Cookies Sign-In, plus notes on whole-cookie-line pastes and keeping the
cookie valid.

### `LTTransitionSettings.h` / `LTTransitionSettings.m`
Reads/writes the transition speed multiplier stored in NSUserDefaults (key `LTTransitionSpeed`; 1.0
normal, lower = faster) plus a global animations-enabled flag. `durationFor:` scales a base
animation duration by the multiplier, returning 0 when animations are disabled so callers can skip
animation entirely. Used by the tab controller and other animated views.

### `LTTransitionSpeedViewController.h` / `LTTransitionSpeedViewController.m`
Settings sub-screen with a slider for the animation speed multiplier (`sliderChanged:`), a preview
of the effect, and persistence through `LTTransitionSettings`. Mostly UI construction in
`viewDidLoad`.

### `LTDebugSettings.h` / `LTDebugSettings.m`
Tiny defaults-backed flags used to test layout edge cases: `forceNonWidescreen` and `forceWidescreen`
(BOOL accessors over NSUserDefaults). Consulted by layout code (e.g. the player) to simulate
small/large screens on any device.

### `LTDebugMenuViewController.h` / `LTDebugMenuViewController.m`
Hidden debug screen (unlocked by repeatedly tapping the version row in Settings). Presents
toggles for the two `LTDebugSettings` widescreen overrides (`nonWideSwitch`, `wideSwitch` with
change handlers) and a table of additional debug actions/info rows with header/footer text
explaining what each flag does.

### `LTOneHandedMode.h` / `LTOneHandedMode.m`
"One-handed mode": shrinks the whole app to the classic 320×480 non-widescreen layout pinned to a
bottom corner, offered only on iPhone 6-sized screens and up (`+isSupported`). Stores an
`LTOneHandedCorner` (off / bottom-left / bottom-right) in defaults, exposes `isActive`,
`virtualSize` (the logical 320×480 drawing size), `frameInBounds:` (where the app root goes inside
the screen) and human-readable labels (`labelForMode:`, `currentLabel`). The app delegate uses this
to size and offset the window's root view.

### `LTOneHandedModeViewController.h` / `LTOneHandedModeViewController.m`
Settings sub-screen for choosing the one-handed corner: a table listing Off / Bottom-Left /
Bottom-Right with checkmarks, a footer explaining the feature, and live re-rendering on trait
changes; selection writes through `LTOneHandedMode.setMode:`.

---

## 8. Sync

### `LTP2PSync.h` / `LTP2PSync.m`
Phone-to-phone library sync over the local Wi-Fi network (no desktop or LAN server). Both phones
publish a Bonjour service of type `_anlegacy-p2p._tcp.` (via an embedded `LTSyncServer`) and browse
for peers; whichever phone discovers the other connects with a minimal blocking HTTP client over a
BSD socket (`LTP2PHTTPClient postPayload:toHost:port:error:`), POSTs its own full sync payload from
`LTPlaylistStore.syncPayload`, and the server merges it and returns its own payload in the response,
which the client merges too — converging both libraries (playlists, library, recents, stats, known
listened IDs). The class drives the UI flow (`beginFromViewController:` with status alerts,
`showStatus:`, `showDoneAlert`, `showFailure:`), resolves services and filters its own addresses
(`netServiceDidResolveAddress:`, `isLocalAddress:`), guards version mismatches between the two
phones (`versionMismatchInPayload:`, `versionErrorJSON`), and tracks a single active sync via
`+isSyncing`. (The header comment mentions the older GameKit design; the implementation uses
Bonjour + sockets.)

### `LTSyncServer.h` / `LTSyncServer.m`
Minimal embedded HTTP server used by the sync features (both P2P and the desktop "web sync"
protocol). `start:` opens a BSD `SOCK_STREAM` listener, spawns an accept thread and a network
thread, publishes a Bonjour `NSNetService` of the configured `serviceType` (default
`_anlegacy-sync._tcp.`) with a republish loop, and serves connections sequentially: each request is
read into a buffer until complete (`readRequestIntoBuffer:fd:`), parsed into method/path/body
(`parseRequest:method:path:body:`), dispatched through the `requestHandler` block to produce a
status + response body, and written back. `stop:` unpublishes and closes everything. Properties
also include `onConnectionFinished` (notifying the owner after serving a request) and the read-only
`port`.

---

## 9. Build & packaging

### `Makefile`
Theos build configuration. Notably it pins **per-architecture SDKs**: armv7 builds against the iOS
9.3 SDK for iOS 6–10 devices, while arm64 stays on the iOS 11.2 SDK (deployment target 11.0)
because newer SDKs auto-link AVFAudio and other new symbols that break launches on iOS 11–13; the
notched-device/letterbox fixes are applied post-build by `make_modern_ipa.py`. Lists all ~50 source
files in `ReinMusic_FILES`, links UIKit/Foundation/CoreGraphics/QuartzCore/MediaPlayer, enables ARC
with a couple of warning suppressions, and includes `application.mk` to produce the `.app`/`.deb`.

### `control`
Debian package metadata for the rootful Theos build: package id `com.legacymusic.app`, name
ReinMusic, version 1, architecture `iphoneos-arm`, description, maintainer/author
(`Rein <rein@localhost>`), and Multimedia section. Consumed by `make package`.

### `ReinMusic.plist`
The Theos-provided base Info.plist for the app bundle: bundle id `com.legacymusic.app`, executable
ReinMusic, `MinimumOSVersion 6.0`, iPhone-only `UIDeviceFamily`, portrait-only orientations, the
`CFBundleIconFiles`/`CFBundlePrimaryIcon` icon slot list, and `UIRequiredDeviceCapabilities: armv7`.
A deliberately minimal counterpart to the richer `Resources/Info.plist`.

### `make_release.py`
One-shot release orchestrator. It runs `make package` (or reuses `--deb`/the newest existing
rootful deb with `--no-build`), derives the shared version from the deb filename, then builds every
distributable: the rootful deb (armv7+arm64, iOS 6+), the modern 64-bit .ipa via `make_modern_ipa`,
the legacy 32-bit .ipa via `make_legacy_ipa`, and the rootless deb via `make_rootless_deb`
(the rootless payload is the modern, letterbox-fixed app). Supports `--skip-ipas`/`--skip-debs`,
prints an artifact table with human sizes, and archives everything into `versions/<version>/` with
self-explanatory names (`ReinMusic-r<rev>-rootful.deb`, `-64bit.ipa`, `-32bit.ipa`, `-rootless.deb`).
The same four files are then copied into the Downloads folder — `downloads_dir()` honours
`REIN_DOWNLOADS_DIR`, otherwise uses the folder containing the repo when it is named `Downloads`,
otherwise `~/Downloads` — so the newest build is always one double-click away.

### `make_legacy_ipa.py`
Produces the legacy armv7-only sideload .ipa from the rootful deb. It reuses
`deb_to_ipa.convert_deb_to_ipa`, then `lipo -thin armv7` (deliberately leaving the Mach-O load
commands alone, since the armv7 slice already reports minos 6.0 / sdk 9.3), patches Info.plist
(`MinimumOSVersion 6.0`, `DTSDKName iphoneos9.3`, armv7 capabilities, no launch storyboard — those
would only risk iOS 6), removes signature/provisioning leftovers so sideloaders can re-sign, and
repacks the zip. Defaults derive the output name from the deb version.

### `make_modern_ipa.py`
Produces the modern arm64-only sideload .ipa. After the deb→ipa conversion it thins to arm64 with
`lipo`, then uses `vtool -set-build-version` to write a real `LC_BUILD_VERSION` (platform iOS,
minos 11.0, **sdk 14.0** — staying below the iOS 26 SDK that triggers the Liquid Glass redesign,
which breaks the hand-built UI). It copies the precompiled launch storyboard from
`ipa_extras/LaunchScreen.storyboardc` into the bundle and sets `UILaunchStoryboardName`, patches
Info.plist (min OS 11.0, arm64 capabilities, DTSDKName/DTPlatformVersion 14.0), strips the code
signature, and repacks — together these stop iOS from letterboxing the app on notched devices.

### `make_rootless_deb.py`
Builds the rootless .deb for iOS 15+ jailbreaks (Dopamine, palera1n -l) that install under
`/var/jb`. It unpacks the modern .ipa payload (so the jailbroken install is byte-for-byte the
sideloaded app), ad-hoc signs every Mach-O in the bundle with `ldid -S` (fixing permission bits
first, executable last), stages it under `var/jb/Applications/ReinMusic.app`, writes a control file
with package id `com.legacymusic.app.rootless` and architecture `iphoneos-arm64`, adds a postinst
that registers the app via `uicache`, and assembles the deb with Theos' `dm.pl` under
`fakeroot.sh` (lzma-compressed).

### `deb_to_ipa.py`
The core deb→ipa converter used by both IPA builders. Five steps: extract the .deb with `ar` (7z
fallback), extract `data.tar.*` (tarfile with shell fallback), locate `Applications/*.app` (apps
only, not tweaks), copy the bundle into a `Payload/` directory, and zip it into an .ipa. Exposes
`convert_deb_to_ipa(deb_path, out_path)` for import plus a CLI.

### `deb_to_ipa_gui.py`
A desktop GUI wrapper (customtkinter, dark theme) around `deb_to_ipa.convert_deb_to_ipa`: file
pickers via zenity/kdialog with a tkinter fallback, an output path field, a Convert button that runs
the conversion on a background thread, and a progress bar/status label that report stage progress
and success/failure dialogs.

### `ipa_extras/LaunchScreen.storyboardc/` (3 files)
The precompiled launch storyboard consumed by `make_modern_ipa.py`:
- `ipa_extras\LaunchScreen.storyboardc\Info.plist` — the storyboard container's metadata plist
  (binary-encoded; read by iOS to enumerate the compiled storyboard contents).
- `ipa_extras\LaunchScreen.storyboardc\01J-lp-oVM-view-Ze5-6b-2t3.nib` — the compiled nib for the
  storyboard's root view (a plain full-screen view) used as the launch screen.
- `ipa_extras\LaunchScreen.storyboardc\UIViewController-01J-lp-oVM.nib` — the compiled nib for the
  storyboard's view controller.
Together they declare to modern iOS that the app supports every screen size, preventing
letterboxing on notched devices.

---

## 10. Resources/ folder

### `Resources/Info.plist`
The rich bundle Info.plist: bundle id `com.legacymusic.app`, `MinimumOSVersion 6.0`, iPhone + iPad
device families, portrait + landscape orientations, background audio mode, `UIAppFonts` registering
FontAwesome.ttf, `NSAppTransportSecurity` allowing arbitrary loads (HTTPS with legacy TLS needs it),
Bonjour service `_anlegacy-p2p._tcp` with a local-network usage description, photo-library usage
description (playlist covers), file sharing enabled, `UIApplicationSupportsAlternateIcons` with the
`Icon7` and `Icon11` alternate icon declarations, and the full icon file list.

### `Resources/PkgInfo`
The classic 8-byte bundle type file containing `APPL????`, required in every .app bundle.

### `Resources/FontAwesome.ttf`
The Font Awesome webfont (426 KB) bundled so the app can render glyph-based icons; registered at
runtime by `LTGraphics` (and declared in `UIAppFonts`), used for legacy code-point icons and some
iPod-mode text.

### `Resources/web_template.html`
The HTML/CSS/JS template for the offline "ReinMusic Mini" web player produced by `LTWebExporter`.
A Material-3-styled dark single-page app (CSS custom properties, top bar, sidebar with nav buttons
and a playlist list, playlist/track grids, an embedded audio player with transport controls) whose
`<script>` section contains a `<!--WEB_DATA-->` marker that the exporter replaces with the exported
playlist JSON.

### App icons (bundle artwork; binary PNGs, noted by role)
- `Icon.png` / `Icon@2x.png` — the classic iOS 6 57pt home-screen icon and its @2x variant.
- `Icon-72.png` / `Icon-72@2x.png` — iPad (72pt) icon slot variants.
- `Icon-76.png` / `Icon-76@2x.png` — iOS 7–9 iPad Pro slot variants.
- `Icon-120.png` — 60pt@2x iPhone icon slot (also used as the "Icon7" alternate icon artwork).
- `Icon-167.png` — iPad Pro 12.9" icon slot.
- `Icon-180.png` — 60pt@3x iPhone icon slot (also used as the "Icon11" alternate icon artwork).

### Launch images
- `Default.png` — launch/splash image for legacy non-Retina devices.
- `Default-568h@2x.png` — launch image for 4-inch (iPhone 5-era) screens.
- `Default-667h@3x.png` — launch image for 4.7-inch screens.
- `Default-736h@3x.png` — launch image for 5.5-inch screens.

### Transport & control glyphs (small tint-able PNGs, grouped by pattern)
- `IcoPlay.png` / `IcoPlayBlue.png` — play icon, normal and blue "active playback" variants.
- `IcoPause.png` / `IcoPauseBlue.png` — pause icon, normal and blue variants.
- `IcoNext.png` / `IcoNextBlue.png` — next-track icon, normal and blue variants.
- `IcoPrev.png` / `IcoPrevBlue.png` — previous-track icon, normal and blue variants.
- `IcoQueue.png` / `IcoQueueBlue.png` — queue icon, normal and blue variants.
- `IcoRepeat.png` / `IcoRepeatBlue.png` — repeat-all icon, normal and blue variants.
- `IcoRepeatOne.png` / `IcoRepeatOneBlue.png` — repeat-one icon, normal and blue variants.
- `IcoShuffle.png` / `IcoShuffleBlue.png` — shuffle icon, normal and blue variants.
(Used by `LTPlayerViewController.applyTransportImages` — blue images mark the enabled/active state.)

### Tab bar icons
- `TabAlbums.png` — albums glyph for the library segments.
- `TabArtists.png` — artists glyph.
- `TabPlaylists.png` — playlists glyph.
- `TabSongs.png` — songs glyph.

---

## 11. Root misc files

### `README.md`
Project readme: describes ReinMusic as a native, jailbreak-only YouTube Music client for iOS 6.0+
(armv7) built with Theos and the unofficial InnerTube API; lists features (search tabs, Google
account sign-in with personalized shelves, browsing, streaming with quality settings, offline
downloads, local playlists, recents/stats, Now Playing tab, blurred artwork background, animated
tab transitions, queue/menus, peer-to-peer sync, Font Awesome tab icons); documents requirements
(Theos, jailbroken iPhone, TLSFix for legacy TLS), build/install commands, the two-phone sync flow,
the settings overview, the project structure, and the GPLv3+ license with a pointer to
DISCLAIMER.md.

### `LICENSE`
The full text of the GNU General Public License v3.0 (29 June 2007), under which the project is
released ("v3.0 or later" per the README).

### `DISCLAIMER.md`
The project disclaimer: the code was substantially AI-generated and is not professionally reviewed;
the software is provided as-is with no warranty; it relies on Google's undocumented InnerTube API
and is not affiliated with or endorsed by Google/YouTube; and streaming/downloading may violate
YouTube's ToS in some jurisdictions, so users are solely responsible for their use.

### `.gitignore`
Ignores Theos build output (`.theos/`, `packages/`, `*.deb`), Xcode debris, macOS `.DS_Store`,
object/archive files (`*.o`, `*.a`, `*.log`), built `.ipa`s, the versioned `versions/` release
archives, Python bytecode, and WSL helper scripts (`*.sh`).

### `ANLegacySkeuo.png`
App artwork PNG (≈187 KB). Skeuomorphic-style artwork kept from the AN Legacy client lineage — used
as a reference/source image for the app's visual identity (kept at the repo root, not bundled).

### `icon7.png`
Home-screen icon artwork (≈187 KB, same dimensions/size as the other root icon file) representing
the "Icon7" (rounded, iOS 7-flavored) alternate icon; the source from which the bundled `Icon-120`
slot art is produced.

### `icon11.png`
Home-screen icon artwork (≈187 KB) representing the "Icon11" (modern) alternate icon; the source
from which the bundled `Icon-180` slot art is produced.
