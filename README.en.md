# LiveWallpaper

[![macOS](https://img.shields.io/badge/macOS-12.0+-000000.svg?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Japanese README: [README.md](README.md)

sry Im not good at english so this document is using AI

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

## Install And Launch

1. Download the latest `LiveWallpaper.app.zip` from the [Releases](../../releases) page.
2. Unzip and move `LiveWallpaper.app` to your **Applications** folder.

To ensure auto-update and related features work correctly, always launch from the Applications folder.

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
