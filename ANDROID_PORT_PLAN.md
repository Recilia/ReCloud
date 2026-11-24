# ReCloud for Android

## Source audit

The fork and upstream resolve to e02b331 at inspection. LTModel serializes tracks and browse entries by video/browse ID. LTYouTubeClient walks several nested InnerTube renderer formats for search, browse, radio, account shelves, captions and stream selection. LTAuth and the cookie tutorial construct a session signature from manually exported Google cookies. These mechanisms are platform and service specific.

LTAppDelegate, LTTheme, LTTabBarController, LTHomeViewController and LTPlayerViewController supply the five destinations, horizontal shelves, near-black/red palette, large square artwork and scrubber. Resources includes original raster transport controls and the app icon. LTPlayerController and system remote commands manage interruptions, queue order, progress and stats. LTPlaylistStore persists separate library, playlist, recent, statistics and download files. Audio and artwork have different lifetimes.

LTP2PSync advertises `_anlegacy-p2p._tcp.`, sends JSON to `POST /api/merge`, checks CFBundleVersion and returns the snapshot taken before merging. LTPlaylistStore exchanges library, recents, playlist, listened-ID and statistics sections. The original automatic LAN exchange lacks explicit authenticated pairing. Other iOS-only surfaces include an iPod wheel, one-handed layout, web export, in-app updater and debug menu. GPL-3.0-or-later, upstream credits and the repository disclaimer apply.

## Architecture and implementation sequence

1. Isolate the port in an Android Studio project. Pin Gradle, AGP and Kotlin. Build from the wrapper.
2. Separate discovery, metadata lookup, authorized playback and account access. Use Internet Archive's public search and metadata APIs for recordings carrying recognized Creative Commons licenses. Preserve artist, source and license attribution. Use the system document picker for personal audio.
3. Build Compose Home, Search and browse screens around a lifecycle ViewModel, Flow, cancellable requests and useful offline/empty states.
4. Own ExoPlayer in a MediaSessionService. Delegate audio focus, noisy-device handling and system transports to Media3.
5. Connect mini-player, artwork, seeking, shuffle, repeat and editable queue to the session. Save queue and position for a paused restore.
6. Use Room transactions for library metadata, playlist membership, recents and device-attributed listening totals. Keep local URIs and downloaded files private to each installation.
7. Request YouTube read-only access through Google Play services for signed builds registered with Google. Keep short-lived tokens in memory. Open YouTube playback through its supported player.
8. Use WorkManager for bounded, cancellable offline transfers. Pair peers explicitly while the sync screen is open, validate versions and bounds, and merge metadata transactionally. Never import another device's local filesystem grants.
9. Adapt the iOS artwork, palette, shelves, transport and settings to Android insets, themes and accessible touch targets.
10. Run builds at integration milestones, JVM tests and lint. Exercise available device paths. Provide build artifacts, signing instructions and an explicit validation ledger.

## Technical constraints

Archive indexes releases whereas individual audio files live in item metadata. Song discovery therefore requires drilling into release metadata. A local file grant is per device. Offline copies need atomic publication and storage limits. Repeated sync must preserve newer edits and avoid double-counting. Android and iOS have different content identifiers, account authorization models and conflict semantics. Document compatibility decisions and verification separately in the parity checklist.


## Next implementation pass after successful account and video playback

The user confirmed Google account access and video playback on their installation. Treat that as a working baseline. The comparison below groups Objective-C methods by the user action they implement. The [Android parity checklist](android/PARITY.md) describes existing components and automated coverage.

| Area and iOS reference | Current Android behavior and remaining work |
| --- | --- |
| Home and discovery — LTHomeViewController, LTPersonalShelves, LTSearchViewController, LTArtistViewController | Home has local recents, an artist-based shelf and popular Archive releases. Search supports YouTube videos, channels and playlists plus Archive releases. Music-specific album/artist relationships, multi-seed recommendation shelves and artist artwork are partial. Source local recommendations from recent listening and label the source. |
| Account and library — LTAuth, LTSignInViewController, LTCookieSignInViewController, LTLibraryViewController | Keep the working Google OAuth integration. Android exposes account playlists on Home; iOS also offers account playlists in Library alongside songs, artists and albums. Add those Library entry points and explicit loading, retry and empty states. |
| Playlist browsing — LTTrackListViewController, LTLocalPlaylistDetailViewController | Android paginates the list of owned playlists, but YouTubeCatalog.list returns only the first 50 entries of a selected playlist. The account screen calls openVideo for a single row. Return a continuation token and add Play All, Shuffle All and play-from-this-row using the visible player. Public playlist URL import is a related Android enhancement. |
| Native transport — LTPlayerController, LTPlayerViewController, LTAppDelegate | Media3 already handles background audio, focus, seeking and system controls. iOS also offers artwork swipe navigation, volume adjustment, lyrics and queue drawers, and automatic radio continuation. Add swipe and accessible equivalent buttons to native audio first. Keep YouTube transport within the visible player. |
| Queue and song menus — LTQueueViewController, LTSongMenu, LTTableSongMenu, LTPlaylistPicker | Android supports append, jump, remove and moving a native queue entry up one position. Add direct drag reordering and accessible move-down. Distinguish queue order from the saved playlist's member order. |
| Library editing — LTLibrarySongsViewController, LTPlaylistStore, LTCoverPickerViewController | Local playlist CRUD, favorites and metadata persistence exist. Add album and artist grouping for saved tracks, custom playlist covers and contextual removal of downloaded audio. Cover files should survive artwork-cache clearing. |
| History and statistics — LTStatsViewController, LTStatsDetailViewController | Android reports recent tracks, top songs, top artists and listening time for native audio. Add reset and richer drill-down. Design reset propagation before exposing it: syncing with an older peer can otherwise restore cleared counters. |
| Downloads — LTDownloadQueueViewController, LTPlaylistStore | Android provides progress, retries, cancel, limits and clear-all. Add batch enqueue for licensed releases/playlists and pause/resume of pending work. Define whether an interrupted file restarts or resumes before labeling the control. |
| Sync and export — LTP2PSync, LTSyncServer, LTWebExporter, LTPlaylistSelectViewController | Paired Android sync and iOS playlist JSON interchange exist. Rein Mini's selected-playlist web export is a separate feature. Cross-platform live sync would require a shared paired protocol and agreement on identifiers and conflict rules on both platforms. |
| Appearance and alternate layouts — LTTheme, LTAppIcon, LTTransitionSettings, LTRecentsTileSizeViewController, LTSplitContainerViewController, LTOneHandedMode, LTiPodViewController | The Android theme, transport artwork, mini-player, tiles and transition settings exist. Alternate launcher icons, one-handed positioning, tablet split navigation and the click-wheel interface are separate UI projects. Prioritize tablet navigation ahead of the optional skins. |
| Maintenance and platform support — LTSettingsViewController, LTUpdater, LTDebugMenuViewController, LTLog, LTHaptics and shared UIKit views | Android has metadata/artwork refresh and search-history clearing. Add independent artwork-cache controls and version/build information. Use Android distribution for updates. UIKit drawing, safe-area workarounds, legacy TLS and jailbreak package installation are platform-specific. |
| Service-dependent features — LTYouTubeClient | Private recommendation mixes, remote account listening history, extracted captions/lyrics and raw YouTube audio streams have different access requirements. Keep authorized playback. Local lyrics files and local recommendation shelves can be scoped independently. |

### Suggested delivery order and acceptance checks

1. **Account playlists end to end.** Open the same playlist from Home and Library. With a fixture containing 51 or more entries, reach track 51 without duplicates, recover from a failed second page, and start a foreground video queue at a selected row. Cover empty, private and deleted entries. Preserve single-video playback and account sign-out.
2. **Library organization.** Group saved tracks by artist and album, allow playlist covers, and support arbitrary queue reordering. Verify duplicate album names, missing tags, restart persistence and reordering the currently playing item.
3. **Offline management and statistics.** Batch-download eligible tracks, pause and resume the queue, and expose cache management independently of downloaded music. Verify cancellation, storage exhaustion, repeated enqueue and sync following a stats reset.
4. **Player and device refinements.** Add native artwork gestures, tablet navigation and optional local lyrics. Test rotation, accessibility controls, headset interruptions and two physical phones pairing before taking on optional iPod mode or web export.