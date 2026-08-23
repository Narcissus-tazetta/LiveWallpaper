# LiveWallpaper

[![macOS](https://img.shields.io/badge/macOS-13.0+-000000.svg?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Japanese README: [README.ja.md](README.ja.md)

LiveWallpaper lets you set your favorite videos as your Mac desktop wallpaper.
It is designed to reduce system load (battery and CPU usage) while you are working.

## Install And Launch

### Homebrew (recommended)

```bash
brew install --cask narcissus-tazetta/tap/livewallpaper
```

To update:

```bash
brew update
brew upgrade --cask livewallpaper
```

### Manual install

1. Download the latest `LiveWallpaper-macos-vX.Y.Z.dmg` from the [Releases](../../releases) page.
2. Open the DMG and move `LiveWallpaper.app` to your **Applications** folder.
3. If it is already installed, replace the existing app.

Always launch from the Applications folder so auto-update and related features work correctly.

If an update fails, use **Manual Download** in Settings to open Releases and reinstall the latest version.

### First Launch

This app is distributed without Apple notarization. macOS may show a security warning on first launch.

If that happens:

1. Open **System Settings**
2. Go to **Privacy & Security** → **Security**
3. Click **Open Anyway** and confirm with your password
4. If needed, open the app again from Applications

## Features

- **Video wallpaper**: Use local video files such as mp4 and mov as your wallpaper.
- **Animated images**: Import GIF / APNG / animated WebP files; they are converted to video and played like any other wallpaper.
- **Web wallpaper (experimental)**: Register a web page or a YouTube / Vimeo URL and run it as your wallpaper. Turn it on in Settings to make the section appear.
- **Separate desktop and lock screen videos**: Assign different videos for desktop live wallpaper and lock screen sync (lock screen sync requires macOS 26 or later).
- **Multi-display support**: Main display only or all connected displays, with per-display assignments.
- **Per-desktop (Space) wallpapers**: Assign a different wallpaper to each Mission Control desktop, and optionally show the desktop number in the menu bar.
- **Automatic switching**: Switch wallpapers by macOS light/dark appearance, by weekday and time-of-day rules, or by Focus mode.
- **Playlists**: Register multiple videos and play them in sequence, with shuffle and previous/next.
- **Trim / loop editor**: Cut a video down to the part you want, set a separate loop start point (the first pass plays as an intro), snap to keyframes, zoom the timeline, and undo/redo.
- **Fit editor**: Edit per-display fit mode, zoom, and offset, then save the layout per screen.
- **Store**: Browse wallpapers shared by other users and download them, or submit your own for review.
- **Audio controls**: Adjust wallpaper audio volume from within the app.
- **Desktop icon visibility**: Show or hide desktop icons, similar to macOS System Settings.
- **Readability options**: Dim the wallpaper so desktop icons stay readable, and make the menu bar opaque.
- **Global shortcuts & automation**: System-wide hotkeys and a `livewallpaper://` URL scheme for Shortcuts, Raycast, or `open`.
- **Mac-focused optimization**:
    - Automatically pauses playback when another app heavily covers the screen.
    - Supports exclusion rules for apps and displays that should not trigger pause.
    - Quality preset, work profile, frame rate limits (30fps / 60fps / unlimited), and decode mode settings.
    - Lowers playback load automatically when the battery drops to 10% or less.
    - Freezes the wallpaper when the system's **Reduce Motion** accessibility setting is on.
- **Localization**: Full UI translation (menus, Settings, notifications) in Japanese, English, Traditional Chinese, Vietnamese, and Turkish. Follows your macOS language automatically, or can be set manually in Settings.
- **Auto updates**: Integrated with Sparkle for in-app updates.

<video src="https://github.com/user-attachments/assets/b5f19e23-928b-4f37-a03b-d229949b905a" width="60%" controls autoplay loop muted></video>

## Other Features

- **Wallpaper export & sharing**: Export a registered wallpaper as a `.lwpkg` package with the original video, thumbnails, and metadata.
- **Package import**: Import `.lwpkg` files and restore presentation settings and playlists. Duplicate handling (replace or abort) is supported.
- **Store submissions**: Sharing to the Store uploads the video together with its saved trim and fit settings, and publishes only after review. The **My Submissions** tab shows the review status of everything sent from this Mac, and lets you withdraw a submission or report someone else's.
- **Thumbnail cache**: Fast library browsing with disk and memory thumbnail caching.
- **Drag & drop**: Add videos by drag and drop, organize playlists, and rename entries.
- **Search**: Filter the wallpaper library, playlists, web wallpapers, and the Store catalog from the search field at the top of each list.

## Automatic Switching

Three independent rules can pick the wallpaper for you. All of them are configured in the **Wallpaper** tab.

- **Appearance**: Choose a light-mode wallpaper and a dark-mode wallpaper, and the shared wallpaper follows macOS Dark Mode.
- **Weekly schedule**: Build rules from weekday + time range + appearance. Rules higher in the list win, and the first match applies. Overnight ranges such as 22:00–06:00 are supported. If you pick a wallpaper manually while a rule is active, your choice stays until the next time boundary.
- **Focus modes**: Assign a wallpaper per Focus mode. macOS does not expose Focus state to apps, so this reads the notification-center database directly and therefore needs **Full Disk Access**; the app walks you through granting it.

## Automation

### Global shortcuts

Turn on **Global Shortcuts** in Settings to control the wallpaper without bringing the app forward. The defaults are:

| Action | Default |
| --- | --- |
| Next wallpaper | ⌃⌥⌘ ] |
| Previous wallpaper | ⌃⌥⌘ [ |
| Toggle audio | ⌃⌥⌘ M |
| Show / hide desktop icons | ⌃⌥⌘ D |

Each shortcut can be re-recorded, and one that conflicts with the system or another app is flagged as inactive.

### URL scheme

The app handles `livewallpaper://` URLs, so it can be driven from Shortcuts.app ("Open URL"), Raycast, AppleScript, or the `open` command:

```bash
open "livewallpaper://next"
```

| URL | What it does |
| --- | --- |
| `livewallpaper://next` / `livewallpaper://previous` | Play the next / previous wallpaper |
| `livewallpaper://audio?on=1` | Turn audio on (omit `on` to toggle) |
| `livewallpaper://volume?level=0.3` | Set volume (0.0–1.0) |
| `livewallpaper://desktop-icons?visible=0` | Show / hide desktop icons (omit to toggle) |
| `livewallpaper://playlist?on=1` | Turn playlist playback on / off (omit to toggle) |
| `livewallpaper://shuffle?on=1` | Turn shuffle on / off (omit to toggle) |
| `livewallpaper://refresh` | Re-evaluate playback state |
| `livewallpaper://settings` / `livewallpaper://wallpaper` | Open Settings / the Wallpaper tab |

Unknown commands are ignored.

## Performance

Video wallpapers have a reputation for being heavy. LiveWallpaper is designed to keep
the load low by auto-pausing and releasing resources whenever the wallpaper is covered,
and by relying on hardware video decoding.

**Rough measurements** (MacBook Air 13-inch, M5, 24 GB RAM / one 1080p 30fps video)

| State | CPU | Memory | Energy Impact |
| --- | --- | --- | --- |
| Covered by other windows, playback paused | ~0% (peak ~16%) | ~63 MB | Minimal |
| Playing (visible) | a few % | ~60–110 MB | Low |
| Brief spike right after launch | up to ~18% | up to ~112 MB | — |

> **These are just examples.** Actual numbers vary a lot depending on the video's
> resolution, frame rate, codec, length and file size; your Mac (Apple Silicon vs. Intel);
> the number and resolution of connected displays; and whatever else is running at the
> time. 4K video, high frame rates, or multiple displays will use more than shown above.

**How the load is kept low**

- Playback auto-pauses when the wallpaper is fully covered by other windows.
- If it stays covered, the heavy decoding resources are released to save memory
  (it resumes smoothly from a still frame when shown again).
- App Nap is supported, reducing CPU wakes while inactive.
- A lightweight playback mode generates smaller proxy videos for power saving.
- Quality preset, work profile, frame rate (30 / 60fps) and decode mode are configurable
  to match your Mac's headroom, and quality is lowered automatically on a low battery.

## Usage

After launch, an icon appears in the menu bar.

1. Open **Settings** from the menu bar
2. Add videos, animated images, or playlists from the **Wallpaper** tab
3. Use the **assignment target** picker (Desktop / Lock Screen) to assign wallpapers
4. Within the Desktop tab, switch scope to assign per display or per Mission Control desktop
5. For lock screen, enable sync in the lock screen panel and tap **Apply Now**
6. Use the **Edit** tab to adjust fit (position/zoom) and trim (cut range, loop start)

The status bar shows the current desktop and lock screen wallpapers separately.

## System Requirements

- macOS 13.0 (Ventura) or later
- Lock screen video sync: macOS 26 or later
- Focus-mode switching: Full Disk Access permission

## Development

Built with Swift, SwiftUI, and AppKit.

```bash
# Resolve dependencies and build
swift build -c release
```

```bash
# Run the unit tests
swift test
```

```bash
# Create distributable .app / .zip / .dmg (ad-hoc signing only)
# The build number is derived from the version automatically; omit it.
./scripts/package_zip.sh 1.0.0
```

Distribution uses ad-hoc signing only; Apple notarization and Developer ID signing are not used. Sparkle appcast signing (Ed25519) is handled separately via `scripts/sign_zip.py`.

The Store backend lives in [`store-worker/`](store-worker) — a Cloudflare Worker (TypeScript) with its own `bun install` / `bun run test` / `bun run deploy` workflow.

## License

This project is released under the [MIT License](LICENSE).
