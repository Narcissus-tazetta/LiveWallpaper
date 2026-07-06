import SwiftUI

extension SettingsView {
    enum FitPreviewMode: String, CaseIterable {
        case video
        case still
    }

    enum SettingsTab: Hashable {
        case wallpaper
        case wallpaperFit
        case settings
    }

    enum WallpaperAssignmentTarget: String, CaseIterable, Hashable {
        case desktop
        case lockScreen
    }

    enum HelpTopic: Hashable {
        case qualityPreset
        case workProfile
        case frameRate
        case decode
        case desktopLevel
        case desktopIcons
        case fullScreenAuxiliary
        case videoLoop
        case menuBarOpaque
    }
}
