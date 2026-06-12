import Foundation

extension Notification.Name {
    static let chooseVideo = Notification.Name("ChooseVideo")
    static let createPlaylistAndChooseVideo = Notification.Name("CreatePlaylistAndChooseVideo")
    static let openWallpaperTab = Notification.Name("OpenWallpaperTab")
    static let openWallpaperFitTab = Notification.Name("OpenWallpaperFitTab")
    static let openWallpaperShareSheet = Notification.Name("OpenWallpaperShareSheet")
    static let openSettingsTab = Notification.Name("OpenSettingsTab")
    static let toggleLaunchAtLogin = Notification.Name("ToggleLaunchAtLogin")
    static let openCacheFolder = Notification.Name("OpenCacheFolder")
    static let clearCache = Notification.Name("ClearCache")
    static let thumbnailCacheDidClear = Notification.Name("ThumbnailCacheDidClear")
    static let toggleAutoUpdate = Notification.Name("ToggleAutoUpdate")
    static let checkUpdatesNow = Notification.Name("CheckUpdatesNow")
    static let refreshPlayback = Notification.Name("RefreshPlayback")
    static let openReleasePage = Notification.Name("OpenReleasePage")
}
