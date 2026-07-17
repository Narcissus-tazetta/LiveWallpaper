import SwiftUI

enum FitPreviewMode: String, CaseIterable {
    case video
    case still
}

/// フィット編集の未保存状態。どの動画・どの画面のドラフトかを key(path, screenID)で持つ。
struct FitEditorDraft: Equatable {
    var path: String = ""
    var screenID: String = ""
    var fitMode: VideoFitMode = .fill
    var zoom: Double = 1.0
    var offsetX: Double = 0.0
    var offsetY: Double = 0.0

    var isActive: Bool {
        !path.isEmpty || !screenID.isEmpty
    }

    func matches(path: String, screenID: String) -> Bool {
        self.path == path && self.screenID == screenID
    }
}

extension SettingsView {
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

    /// 「デスクトップ」タブが今どのスコープの割り当てを見せているか。
    /// 画面別と Space別は排他なので、2つの Optional を手で打ち消し合わせるのでは
    /// なく1つの値にする。スコープ Picker のタグはこの値をそのまま使う。
    enum WallpaperScope: Hashable {
        case shared
        case display(String)
        case space(String)
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
        case spaceWallpaper
        case suspendHighSensitivity
        case suspendFrontmostOnly
        case globalFitMode
        case perVideoFitMode
        case fitLiveApply
    }
}
