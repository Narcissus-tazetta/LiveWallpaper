import Foundation

/// 設定エクスポート/インポートで使う JSON スナップショット。
/// 全フィールド optional のため、別バージョンのファイルでも存在するキーだけが適用される。
/// enum は生の文字列で持ち、未知の値は読み込み時に無視される。
struct SettingsSnapshot: Codable {
    var formatVersion: Int = 1

    var clickThrough: Bool?
    var displayMode: String?
    var fitMode: String?
    var lightweightMode: Bool?
    var audioEnabled: Bool?
    var audioVolume: Float?
    var frameRateLimit: String?
    var decodeMode: String?
    var workProfile: String?
    var qualityPreset: String?
    var videoLoopEnabled: Bool?
    var autoSwitchIntervalMinutes: Int?
    var playlistPlaybackEnabled: Bool?
    var shufflePlaybackEnabled: Bool?
    var autoFrameRateEnabled: Bool?
    var batteryAwareQualityEnabled: Bool?
    var desktopLevelOffset: Int?
    var useFullScreenAuxiliary: Bool?
    var menuBarOpaqueEnabled: Bool?
    var advancedSharingEnabled: Bool?
    var webWallpaperFeatureEnabled: Bool?
    var suspendWhenOtherAppFullScreen: Bool?
    var suspendHighSensitivityEnabled: Bool?
    var suspendWhenOtherAppFrontmost: Bool?
    var suspendExclusionBundleIDs: [String]?
    /// 動画パス → 画面ID → フィット設定。パスが存在しない環境では単に使われないだけ。
    var wallpaperPresentationByPath: [String: [String: WallpaperModel.WallpaperPresentation]]?
    /// 画面ID → 固定表示する動画パス。ファイルが存在するエントリだけ適用される。
    var videoOverrideByScreenID: [String: String]?
    /// 自動停止の対象から除外する画面ID。
    var suspendDisabledDisplayIDs: [String]?
    /// 画面ID → その画面が従うプレイリストID(文字列表現)。
    var screenPlaylistByScreenID: [String: String]?
    /// Space別壁紙機能のオン/オフ。
    var spaceWallpaperFeatureEnabled: Bool?
    /// Space uuid → 固定表示する動画パス。別Macでは uuid が一致せず単に不発になる。
    var videoBySpaceUUID: [String: String]?
    /// メニューバーのデスクトップ番号表示。
    var menuBarSpaceNumberEnabled: Bool?
}

@MainActor
enum SettingsTransfer {
    static func export(from model: WallpaperModel, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot(from: model))
        try data.write(to: url, options: .atomic)
    }

    static func importSettings(from url: URL, into model: WallpaperModel) throws {
        let data = try Data(contentsOf: url)
        let snapshot = try JSONDecoder().decode(SettingsSnapshot.self, from: data)
        apply(snapshot, to: model)
    }

    static func snapshot(from model: WallpaperModel) -> SettingsSnapshot {
        SettingsSnapshot(
            clickThrough: model.clickThrough,
            displayMode: model.displayMode.rawValue,
            fitMode: model.fitMode.rawValue,
            lightweightMode: model.lightweightMode,
            audioEnabled: model.audioEnabled,
            audioVolume: model.audioVolume,
            frameRateLimit: model.frameRateLimit.rawValue,
            decodeMode: model.decodeMode.rawValue,
            workProfile: model.workProfile.rawValue,
            qualityPreset: model.qualityPreset.rawValue,
            videoLoopEnabled: model.videoLoopEnabled,
            autoSwitchIntervalMinutes: model.autoSwitchIntervalMinutes,
            playlistPlaybackEnabled: model.playlistPlaybackEnabled,
            shufflePlaybackEnabled: model.shufflePlaybackEnabled,
            autoFrameRateEnabled: model.autoFrameRateEnabled,
            batteryAwareQualityEnabled: model.batteryAwareQualityEnabled,
            desktopLevelOffset: model.desktopLevelOffset.rawValue,
            useFullScreenAuxiliary: model.useFullScreenAuxiliary,
            menuBarOpaqueEnabled: model.menuBarOpaqueEnabled,
            advancedSharingEnabled: model.advancedSharingEnabled,
            webWallpaperFeatureEnabled: model.webWallpaperFeatureEnabled,
            suspendWhenOtherAppFullScreen: model.suspendWhenOtherAppFullScreen,
            suspendHighSensitivityEnabled: model.suspendHighSensitivityEnabled,
            suspendWhenOtherAppFrontmost: model.suspendWhenOtherAppFrontmost,
            suspendExclusionBundleIDs: model.suspendExclusionBundleIDs,
            wallpaperPresentationByPath: model.wallpaperPresentationByPath,
            videoOverrideByScreenID: model.videoOverrideByScreenID,
            suspendDisabledDisplayIDs: Array(model.suspendDisabledDisplayIDs),
            screenPlaylistByScreenID: model.screenPlaylistByScreenID.mapValues(\.uuidString),
            spaceWallpaperFeatureEnabled: model.spaceWallpaperFeatureEnabled,
            videoBySpaceUUID: model.videoBySpaceUUID,
            menuBarSpaceNumberEnabled: model.menuBarSpaceNumberEnabled
        )
    }

    static func apply(_ snapshot: SettingsSnapshot, to model: WallpaperModel) {
        applyPlaybackSettings(snapshot, to: model)
        applyDisplaySettings(snapshot, to: model)
        applySuspendSettings(snapshot, to: model)
        applyPresentationOverrides(snapshot, to: model)
    }

    private static func applyPlaybackSettings(
        _ snapshot: SettingsSnapshot,
        to model: WallpaperModel
    ) {
        if let value = snapshot.lightweightMode {
            model.setLightweightMode(value)
        }
        if let value = snapshot.audioEnabled {
            model.setAudioEnabled(value)
        }
        if let value = snapshot.audioVolume {
            model.setAudioVolume(min(max(value, 0), 1))
        }
        if let raw = snapshot.frameRateLimit, let value = FrameRateLimit(rawValue: raw) {
            model.setFrameRateLimit(value)
        }
        if let raw = snapshot.decodeMode, let value = DecodeMode(rawValue: raw) {
            model.setDecodeMode(value)
        }
        if let raw = snapshot.workProfile, let value = WorkProfile(rawValue: raw) {
            model.setWorkProfile(value)
        }
        if let raw = snapshot.qualityPreset, let value = QualityPreset(rawValue: raw) {
            model.setQualityPreset(value)
        }
        if let value = snapshot.videoLoopEnabled {
            model.setVideoLoopEnabled(value)
        }
        if let value = snapshot.autoSwitchIntervalMinutes, value >= 0 {
            model.setAutoSwitchInterval(minutes: value)
        }
        if let value = snapshot.playlistPlaybackEnabled {
            model.setPlaylistPlaybackEnabled(value)
        }
        if let value = snapshot.shufflePlaybackEnabled {
            model.setShufflePlaybackEnabled(value)
        }
        if let value = snapshot.autoFrameRateEnabled {
            model.setAutoFrameRateEnabled(value)
        }
        if let value = snapshot.batteryAwareQualityEnabled {
            model.setBatteryAwareQualityEnabled(value)
        }
    }

    private static func applyDisplaySettings(
        _ snapshot: SettingsSnapshot,
        to model: WallpaperModel
    ) {
        if let value = snapshot.clickThrough {
            model.setClickThrough(value)
        }
        if let raw = snapshot.displayMode, let value = DisplayMode(rawValue: raw) {
            model.setDisplayMode(value)
        }
        if let raw = snapshot.fitMode, let value = VideoFitMode(rawValue: raw) {
            model.setFitMode(value)
        }
        if let raw = snapshot.desktopLevelOffset, let value = DesktopLevelOffset(rawValue: raw) {
            model.setDesktopLevelOffset(value)
        }
        if let value = snapshot.useFullScreenAuxiliary {
            model.setFullScreenAuxiliary(value)
        }
        if let value = snapshot.menuBarOpaqueEnabled {
            model.setMenuBarOpaqueEnabled(value)
        }
        if let value = snapshot.advancedSharingEnabled {
            model.setAdvancedSharingEnabled(value)
        }
        if let value = snapshot.webWallpaperFeatureEnabled {
            model.setWebWallpaperFeatureEnabled(value)
        }
    }

    private static func applySuspendSettings(
        _ snapshot: SettingsSnapshot,
        to model: WallpaperModel
    ) {
        if let value = snapshot.suspendWhenOtherAppFullScreen {
            _ = model.setSuspendWhenOtherAppFullScreen(value)
        }
        if let value = snapshot.suspendHighSensitivityEnabled {
            _ = model.setSuspendHighSensitivityEnabled(value)
        }
        if let value = snapshot.suspendWhenOtherAppFrontmost {
            _ = model.setSuspendWhenOtherAppFrontmost(value)
        }
        if let bundleIDs = snapshot.suspendExclusionBundleIDs {
            model.suspendExclusionBundleIDs = []
            UserDefaults.standard.removeObject(forKey: PrefsKey.suspendExclusionBundleIDs)
            for bundleID in bundleIDs {
                model.addSuspendExclusionBundleID(bundleID)
            }
        }
    }

    private static func applyPresentationOverrides(
        _ snapshot: SettingsSnapshot,
        to model: WallpaperModel
    ) {
        if let overrides = snapshot.videoOverrideByScreenID {
            // setVideoOverride 側でファイルの存在確認と永続化が行われる。
            for (screenID, path) in overrides {
                model.setVideoOverride(path: path, forScreenID: screenID)
            }
        }
        if let value = snapshot.spaceWallpaperFeatureEnabled {
            model.setSpaceWallpaperFeatureEnabled(value)
        }
        if let spaceVideos = snapshot.videoBySpaceUUID {
            // setSpaceVideo 側でファイルの存在確認と永続化が行われる。
            // 別Macからのインポートでは Space uuid が一致せず単に不発になる。
            for (uuid, path) in spaceVideos {
                model.setSpaceVideo(path: path, forSpaceUUID: uuid)
            }
        }
        if let value = snapshot.menuBarSpaceNumberEnabled {
            model.setMenuBarSpaceNumberEnabled(value)
        }
        if let suspendDisabled = snapshot.suspendDisabledDisplayIDs {
            for screenID in suspendDisabled {
                model.setSuspendDisabled(true, forScreenID: screenID)
            }
        }
        if let screenPlaylists = snapshot.screenPlaylistByScreenID {
            for (screenID, rawUUID) in screenPlaylists {
                if let playlistID = UUID(uuidString: rawUUID) {
                    // インポートは非対話的な適用なので、動画の割り当て(上の
                    // videoOverrideByScreenID 処理)がファイル不在などで失敗しても
                    // ここでローカルの別動画を勝手に選ばせない。
                    model.setScreenPlaylist(
                        playlistID,
                        forScreenID: screenID,
                        autoAssignFirstVideo: false
                    )
                }
            }
        }
        guard let presentations = snapshot.wallpaperPresentationByPath else {
            return
        }
        // setWallpaperPresentation を経由することで clamp と永続化を既存経路に任せる。
        for (path, byScreen) in presentations {
            for (screenID, presentation) in byScreen {
                model.setWallpaperPresentation(
                    fitMode: presentation.fitMode,
                    zoom: presentation.zoom,
                    offsetX: presentation.offsetX,
                    offsetY: presentation.offsetY,
                    path: path,
                    screenID: screenID
                )
            }
        }
    }
}
