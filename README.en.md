# LiveWallpaper

[![macOS](https://img.shields.io/badge/macOS-13.0+-000000.svg?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Japanese README: [README.md](README.md)

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
- **Separate desktop and lock screen videos**: Assign different videos for desktop live wallpaper and lock screen sync (lock screen sync requires macOS 26 or later).
- **Multi-display support**: Choose main display only or all connected displays.
- **Playlists**: Register multiple videos and play them in sequence.
- **Audio controls**: Adjust wallpaper audio volume from within the app.
- **Desktop icon visibility**: Show or hide desktop icons, similar to macOS System Settings.
- **Mac-focused optimization**:
    - Automatically pauses playback when another app heavily covers the screen.
    - Supports exclusion rules for apps that should not trigger pause.
    - Frame rate limits (30fps / 60fps / unlimited) and decode mode settings.
- **Localization**: Japanese, English, Traditional Chinese, Vietnamese, and Turkish.
- **Auto updates**: Integrated with Sparkle for in-app updates.

<video src="https://github.com/user-attachments/assets/b5f19e23-928b-4f37-a03b-d229949b905a" width="60%" controls autoplay loop muted></video>

## Other Features

- **Wallpaper export & sharing**: Export a registered wallpaper as a `.lwpkg` package with the original video, thumbnails, and metadata.
- **Package import**: Import `.lwpkg` files and restore presentation settings and playlists. Duplicate handling (replace or abort) is supported.
- **Playlists & shuffle**: Create playlists, shuffle playback, and use previous/next controls.
- **Fit editor**: Edit per-display fit mode, zoom, and offset, then save per-screen layout.
- **Lock screen sync**: Choose a lock screen video and apply it to the macOS lock screen when sync is enabled. You can also reset to match the desktop wallpaper.
- **Display / output options**: Main display only or all displays, with frame rate and decode mode tuning.
- **Auto-pause & exclusion rules**: Pause when other windows cover the screen, with per-app exclusions.
- **Thumbnail cache**: Fast library browsing with disk and memory thumbnail caching.
- **Drag & drop**: Add videos by drag and drop, organize playlists, and rename entries.

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
- Frame rate (30 / 60fps) and decode mode are configurable to match your Mac's headroom.

## Usage

After launch, an icon appears in the menu bar.

1. Open **Settings** from the menu bar
2. Add videos or playlists from the **Wallpaper** tab
3. Use the **assignment target** picker (Desktop / Lock Screen) to assign wallpapers
4. For lock screen, enable sync in the lock screen panel and tap **Apply Now**

The status bar shows the current desktop and lock screen wallpapers separately.

## System Requirements

- macOS 13.0 (Ventura) or later
- Lock screen video sync: macOS 26 or later

## Known Limitations

- During macOS Space (Mission Control) switching, the app may occasionally bounce to a neighboring Space due to interaction with foreground-app Space routing. This is more likely when moving from a Space with an active app to an empty Space.
- If it happens, moving to the same Space again usually stabilizes it.
- We are continuing to improve this behavior. Because this depends on macOS Space internals, frequency can vary by environment.

## Development

Built with Swift, SwiftUI, and AppKit.

```bash
# Resolve dependencies and build
swift build -c release

# Create distributable .app / .zip / .dmg (ad-hoc signing only)
./scripts/package_zip.sh 1.0.0 1
```

Distribution uses ad-hoc signing only; Apple notarization and Developer ID signing are not used. Sparkle appcast signing (Ed25519) is handled separately via `scripts/sign_zip.py`.

## License

This project is released under the [MIT License](LICENSE).
