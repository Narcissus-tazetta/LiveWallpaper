# LiveWallpaper

[![macOS](https://img.shields.io/badge/macOS-12.0+-000000.svg?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Japanese README: [README.md](README.md)

Sry I'm not good at english so this document is using AI

LiveWallpaper lets you set your favorite videos as your Mac desktop wallpaper.
It is designed to reduce system load (battery and CPU usage) while you are working.

## Features

- Video wallpaper support: Use local video files such as mp4 and mov as your wallpaper.
- Multi-display support: Choose main display only or all connected displays.
- Playlist support: Register multiple videos and play them in sequence.
- Audio controls: Adjust wallpaper audio volume from within the app.
- Mac-focused optimization settings:
    - Automatically pauses playback when another app heavily covers the screen.
    - Supports exclusion rules for apps that should not trigger pause.
    - Supports frame rate and decode mode settings tuned for different Mac workloads.
- Auto updates: Integrated with Sparkle for in-app updates.
- Auto updates: Integrated with Sparkle for in-app updates.

<video src="https://github.com/user-attachments/assets/166b9fb1-67c6-412b-a253-e15498f99399" width="60%" controls autoplay loop muted></video>

## Other Features (Detailed)

- **Wallpaper export & sharing**: From Settings you can select any registered wallpaper to share. Exporting lets you choose an output folder and writes a `.lwpkg` (wallpaper package) alongside the original video (`.mov`/`.mp4`). Exports include thumbnails and metadata such as presentation/fit settings and playlist information.
- **Package import**: `.lwpkg` files can be imported into the app. The importer restores presentation settings and playlists from the package metadata. Duplicate video handling (replace or abort) is supported during import.
- **Playlists & shuffle**: Create playlists to play videos in sequence. Supports shuffle playback and controls for previous/next video and playlist selection.
- **Fit editor (per-display layout)**: Edit how a video is presented on each display (fit mode, zoom, X/Y offset) and save per-screen presentation settings.
- **Display / output options**: Choose to show wallpaper on the main display only or on all displays. Frame rate limits (30fps / 60fps / unlimited) and decode mode options help tune performance.
- **Auto-pause & exclusion rules**: The app can automatically pause playback when other windows cover the screen, and you can exclude specific apps from triggering pause so playback continues.
- **Thumbnail cache**: Video thumbnails are cached in memory and on disk to provide fast listing and previews. The app prewarms thumbnails and provides cache clearing functionality.
- **Audio controls**: Mute or adjust wallpaper audio volume from the app.
- **Drag & drop and file operations**: Add videos via drag & drop, drag videos into playlists, and edit registered video display names.
- **Developer / distribution scripts**: Build and packaging scripts are included for generating DMGs, producing Sparkle appcast entries, signing, and (optionally) notarization.

## Install And Launch

1. Download the latest `LiveWallpaper-macos-vX.Y.Z.dmg` from the [Releases](../../releases) page.
2. Open the DMG and move `LiveWallpaper.app` to your **Applications** folder.
3. If it is already installed, replace the existing app with the new one.

To ensure auto-update and related features work correctly, always launch from the Applications folder.

If an update fails, use the "Manual Download" action in Settings to open Releases and reinstall the latest version.

Important first-launch note:
Since the app is currently not Apple-notarized, macOS may block it with a security warning.
If that happens:

1. Open System Settings.
2. Go to Privacy & Security.
3. In the Security section, click Open Anyway.
4. Confirm with your password.
5. If needed, open the app again from Applications.

## Usage

After launch, an icon appears in the menu bar.
Open Settings from the menu bar, then add videos or playlists from the wallpaper tab.

## System Requirements

- macOS 12.0 (Monterey) or later

## Development

This app is built with Swift, SwiftUI, and AppKit.
If you want to build it yourself, clone this repository, open it in Xcode, resolve dependencies (including Sparkle), and build.

## License

This project is released under the [MIT License](LICENSE).
