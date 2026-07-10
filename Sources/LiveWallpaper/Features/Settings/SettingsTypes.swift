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

    /// 壁紙の設定先。将来「サブディスプレイ」タブを足す場合はここに case を追加し、
    /// availableAssignmentTargets に並べるだけでタブが増える。
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
        case batteryAwareQuality
        case videoLoop
        case menuBarOpaque
        case suspendHighSensitivity
        case suspendFrontmostOnly
        case globalFitMode
        case perVideoFitMode
    }
}
