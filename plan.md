# Split Plan (Optimized)

Goal: Reduce mega-files, clarify responsibilities, and align folder boundaries with features and services.

## 1) Target End-State Structure

Sources/LiveWallpaper/
  App/
    AppConfig.swift
    AppDelegate.swift
    LiveWallpaper.swift
  Core/
    Models/
      AppLanguage.swift
      PackageTypes.swift
      WallpaperGeometry.swift
      WallpaperTypes.swift
      WallpaperModel.swift (thin facade only)
    Playback/
      WallpaperPlaybackController.swift
      PlaybackProfileResolver.swift
      PlaybackEnvironment.swift
      PlaybackSettingsStore.swift
    Windowing/
      WallpaperWindowCoordinator.swift
      ScreenSignature.swift
      WindowOptions.swift
    Playlists/
      PlaylistStore.swift
      PlaylistModels.swift
      PlaylistPersistence.swift
    Presentation/
      WallpaperPresentationStore.swift
      PresentationCache.swift
    Services/
      AppLocalization.swift
      LocalizationManager.swift
      DiskThumbnailCache.swift
      PackageExporter/
        PackageExporter.swift (orchestrator)
        PackageManifestBuilder.swift
        PackageArchiveWriter.swift
        ThumbnailGenerator.swift
        ExportFileNameSanitizer.swift
  Features/
    Settings/
      Views/
        SettingsView.swift (routing only)
        Tabs/
          WallpaperTabView.swift
          WallpaperFitTabView.swift
          SettingsTabView.swift
        Components/
          CurrentStatusSection.swift
          WallpaperLibraryPanel.swift
          PlaylistSettingsPanel.swift
          FitEditorPanel.swift
          FitLibraryPanel.swift
          HelpPopover.swift
      Services/
        FitPreviewService.swift
        WallpaperShareService.swift
      State/
        SettingsViewState.swift

Notes:
- This keeps current folder names mostly intact but introduces clear subdomains.
- WallpaperModel becomes a facade that coordinates the new components.

## 2) WallpaperModel Split (Largest Payoff)

Current responsibilities (mixed):
- App state (settings, language)
- AVPlayer lifecycle and playback profile
- Window creation and screen sync
- Playlist and persistence
- Presentation (fit/zoom/offset) store
- Accessibility-based suspension

Planned extraction:
1) Playback
- Move all AVPlayer creation, playback reconfiguration, profile resolution, auto-frame-rate, and playback startup validation.
- New types:
  - WallpaperPlaybackController
  - PlaybackProfileResolver
  - PlaybackEnvironment
  - PlaybackSettingsStore (UserDefaults keys + restore/apply)

2) Windowing
- Move NSWindow/PlayerView management, screen sync, window rebuild scheduling.
- New types:
  - WallpaperWindowCoordinator
  - ScreenSignature
  - WindowOptions (level, click-through, auxiliary)

3) Playlists
- Move playlist CRUD, selected playlist logic, registeredVideoPaths, display names, persistence.
- New types:
  - PlaylistStore
  - PlaylistPersistence
  - PlaylistModels (WallpaperPlaylist, etc.)

4) Presentation
- Move fit/zoom/offset storage, cache keys, per-screen presentation lookup.
- New types:
  - WallpaperPresentationStore
  - PresentationCache

5) Foreground coverage / suspension
- Move AX observer, coverage evaluation, exclusion list into Windowing or a new ForegroundCoverageService.

Facade responsibilities (WallpaperModel remains):
- Published properties (aggregated view-model state)
- Wiring and delegation to sub-components
- Minimal orchestration between components

## 3) SettingsView Split (UI Clarity)

Current problems:
- One view holds tabs, state, media logic, helper utilities, and share flow.

Planned split:
- SettingsView.swift: only tab switching + top-level layout
- Tabs:
  - WallpaperTabView (wallpaper list + playlist)
  - WallpaperFitTabView (fit editor + fit library)
  - SettingsTabView (settings sections)
- Components:
  - CurrentStatusSection
  - WallpaperLibraryPanel
  - PlaylistSettingsPanel
  - FitEditorPanel
  - FitLibraryPanel
  - HelpPopover
- Services:
  - FitPreviewService (thumbnail selection, best-frame logic)
  - WallpaperShareService (export/share flow)
- State:
  - SettingsViewState (all @State variables grouped)

Migration steps:
1) Extract child views first (low risk).
2) Move helper methods into Services or Components (medium).
3) Replace local @State with SettingsViewState (medium/high).

## 4) PackageExporter Split (Service Boundaries)

Planned extraction:
- PackageExporter (orchestrator): coordinates the workflow
- PackageManifestBuilder: builds manifest from model data
- PackageArchiveWriter: wraps ditto and file writes
- ThumbnailGenerator: AVAssetImageGenerator wrapper
- ExportFileNameSanitizer: single-responsibility filename cleanup

Outcome:
- Easier testing (manifest and name sanitation separately)
- Smaller files (< 200 lines each)

## 5) Naming and Boundaries Cleanup

- Avoid "+Helpers" files; prefer "+UI", "+Actions", or per-feature components.
- Keep Core/Models strictly for data types; move behavior into Core/Playback, Core/Windowing, Core/Playlists, Core/Presentation.
- Keep Features/Settings for UI only; move logic to Services/State.

## 6) Step-by-Step Execution Order

1) Extract PlaylistStore and PlaylistModels (low impact).
2) Extract PresentationStore and PresentationCache (low impact).
3) Extract PlaybackProfileResolver + PlaybackEnvironment (medium).
4) Extract WallpaperPlaybackController (medium).
5) Extract WindowCoordinator + ScreenSignature (medium/high).
6) Extract FitPreviewService and Settings child views (medium).
7) Split PackageExporter (medium).
8) Make WallpaperModel a facade (final cleanup).

## 7) Quality Gates

- Compile after each extraction step.
- Keep public API stable for Settings views until the final step.
- Add temporary adapter methods in WallpaperModel to avoid large refactors.
