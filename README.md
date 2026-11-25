<img width="500" height="500" alt="Re:Cloud icon" src="https://github.com/user-attachments/assets/584752ec-659b-490a-b24a-dda66364ae09" />

# Re:Cloud

**Re:Cloud** is a native YouTube Music client for legacy jailbroken iOS devices, built with
[Theos](https://theos.dev). It targets iOS 6.0+ on armv7 and also builds for arm64, and talks to
YouTube's unofficial InnerTube API for browsing, search, playback and library access.

> The app still installs as `ReinMusic` with bundle id `com.legacymusic.app`, so existing updates
> and TLSFix exceptions keep working. Only the display name is Re:Cloud.

## Features

- **Account sign-in** from a pasted desktop-browser cookie - no Google SDK and no in-app web login,
  so old WebKit never has to render Google's login page
- Personalized **Home** with "Mixed for you", "Listen again", "New releases" and other
  recommendation shelves when signed in
- Your YouTube Music **library playlists** and **listening history** in the Library tab
- **Search** with Songs / Videos / Albums / Artists tabs and cached search history
- Browse albums, playlists and artist pages
- Streaming playback via `AVAudioPlayer` with configurable quality (Low / Medium / High)
- Background playback with lock-screen / headphone controls
- Download tracks for **offline playback**
- Local playlists (create, rename, delete, add tracks with the in-app picker)
- Recently played history and per-track listening stats (most played, top artists, total time)
- Dedicated **Now Playing** tab with artwork, seek bar, repeat and shuffle
- Blurred album-art background behind the player (toggleable)
- Queue view, song context menus, Shuffle All / Play All
- **Peer-to-peer sync**: exchange your full library between two phones over Wi-Fi via Bonjour,
  with no desktop or LAN server
- **Built-in updater** that downloads the IPA for the device's architecture
- Dark, light and system themes; one-handed and iPod-classic display modes
- Tab icons rendered from a bundled Font Awesome font

## Requirements

- [Theos](https://theos.dev) on a macOS/Linux host
- A jailbroken iPhone (armv7, iOS 6.0 or newer; arm64 also builds)
- iOS 6.0 deployment target (set in the `Makefile`)
- [TLSFix](https://github.com/nfzerox/TLSFix) installed and enabled for this app. It keeps the
  bundle id `com.legacymusic.app`, so an existing AN Legacy TLSFix entry keeps working. Legacy iOS
  ships outdated TLS that fails against modern HTTPS endpoints.

## Building

```sh
THEOS=/path/to/theos make package
```

To build and install directly to a device over SSH:

```sh
THEOS=/path/to/theos THEOS_DEVICE_IP=<ip> make package install
```

`./scripts/make_release.py` builds all four distributables (rootful and rootless `.deb`, plus the
64-bit and 32-bit `.ipa`) and copies them into `versions/<version>/` in the repo and into your
Downloads folder.

## Signing in

1. On a computer, open `music.youtube.com` and sign in.
2. Open DevTools -> **Network**, right-click any request and choose **Copy -> Copy as cURL**.
3. On the iPhone, open **Settings -> Account -> Paste a new cookie**, paste the block, and tap
   **Save**.

The app extracts the cookies itself; a plain `Cookie:` header or a `cookies.txt` export also works.
Keep the phone on the same Wi-Fi network as the computer while signing in, because Google ties the
session to the originating network.

## Syncing between two phones

In **Settings -> Sync**, press **Sync with Another Phone** on *both* phones. Each phone publishes and
discovers the other over Bonjour on the same Wi-Fi network and they exchange their full library
directly - no desktop or LAN server involved. Both phones must run the same app version; if the
versions differ, the sync is refused.

## Settings

- **Updates** - check for and install the matching IPA
- **Account** - sign in, check account access, sign out
- **Playback options** - Keep Screen Awake, Show kbps Counter
- **Appearance options** - Album Art Background, Enable Animations, Transition Speed, Recents Tile
  Size, theme
- **Data management** - Offline Downloads, Sync with Another Phone, Refresh Metadata & Artwork,
  Create Rein Mini Instance, Clear Offline Downloads
- **Credits / Branding** - project credits (Rein, iReaching), Exelorent and Discord `@s.tyx`

## Project layout

```text
src/
  App/        entry point, app delegate, tab bar, split container
  Account/    cookie auth and sign-in screens
  Core/       models, theme, graphics, icons, logging, paths, haptics
  Network/    InnerTube client, updater, peer sync, web export
  Player/     playback controller, Now Playing, queue
  Library/    library, playlists, downloads, iPod mode
  Browse/     home, search, artist, album and track lists
  Settings/   settings, transitions, stats, debug menu
  UI/         shared cells, menus, toasts, small utility screens
Resources/    bundled assets: icons, launch images, Info.plist, font
layout/       deb package layout and maintainer scripts
ipa_extras/   extra files injected into the modern IPA
scripts/      Python packaging and deb-to-ipa tools
docs/         file reference, disclaimer and legacy assets
```

The root keeps `Makefile`, `control`, `README.md` and `LICENSE`.

## Credits

- **Rein** - developer
- **iReaching** - developer
- **Exelorent** - branding
- **Discord `@s.tyx`** - branding

## License

This project is licensed under the **GNU General Public License v3.0 or later**. See
[LICENSE](LICENSE) for the full text.

## Disclaimer

This project uses unofficial Google/YouTube APIs and is provided as-is. See
[DISCLAIMER.md](docs/DISCLAIMER.md) for the full disclaimer, including the notice that the code was
AI-generated.
