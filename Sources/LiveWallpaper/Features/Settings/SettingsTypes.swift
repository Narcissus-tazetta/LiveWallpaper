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
        case store
        case settings
    }

    /// Groups the settings tab's sections so it shows a handful at a time instead of one
    /// long form. Searching ignores the category and looks through every section.
    enum SettingsCategory: CaseIterable, Hashable {
        case general
        case display
        case integrations
        case other

        var sections: [SettingsSection] {
            switch self {
            case .general: return [.video, .language, .update]
            case .display: return [.display]
            case .integrations: return [.share, .webWallpaper, .hotKeys, .screenSaver]
            case .other: return [.cache, .reset, .support]
            }
        }

        var titleKey: String {
            switch self {
            case .general: return "一般"
            case .display: return "表示"
            case .integrations: return "連携"
            case .other: return "その他"
            }
        }

        var subtitleKey: String {
            switch self {
            case .general: return "起動・動画と音声・言語・アップデート"
            case .display: return "壁紙の表示方法・切り替え・省電力"
            case .integrations: return "共有・Web壁紙・ショートカット・スクリーンセーバー"
            case .other: return "キャッシュ・設定の管理・サポート"
            }
        }

        var systemImage: String {
            switch self {
            case .general: return "gearshape.fill"
            case .display: return "display"
            case .integrations: return "link"
            case .other: return "ellipsis"
            }
        }

        var tint: Color {
            switch self {
            case .general: return .gray
            case .display: return .blue
            case .integrations: return .green
            case .other: return .gray
            }
        }
    }

    enum WallpaperTransitionChoice: Hashable {
        case off
        case style(WallpaperTransitionStyle)
    }

    /// 「編集」タブ内のサブモード。フィット(表示位置)とトリム(カット/ループ)は
    /// 別々のコントローラ(FitEditorController/WallpaperEditorController)が持つが、
    /// タブとしては1つにまとめて切り替えられるようにする。
    enum EditorSubMode: String, CaseIterable, Hashable {
        case fit
        case trim
    }

    enum StoreShareStatus: Equatable {
        case idle
        case submitting
        case success(status: String)
        case failure(message: String)
    }

    /// Storeタブ内の表示モード。みんなの投稿を眺める「ブラウズ」と、この端末から
    /// 投稿した分の審査状況を確認する「自分の投稿」を切り替える。
    enum StoreTabMode: String, CaseIterable, Hashable {
        case browse
        case mine
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
        case reduceMotion
        case fullScreenAuxiliary
        case batteryAwareQuality
        case batteryPlaybackPolicy
        case wallpaperTransition
        case videoLoop
        case menuBarOpaque
        case spaceWallpaper
        case suspendHighSensitivity
        case suspendFrontmostOnly
        case globalFitMode
        case perVideoFitMode
        case fitLiveApply
        case desktopReadabilityDim
        case scheduleFollowAppearance
        case scheduleAdvancedRules
    }

    /// スケジュールのターゲット壁紙ポップオーバーが今どの選択スロットに対して
    /// 開いているか。簡易UI(ライト/ダーク/昼/夜)も高度ルールも、対象の
    /// ScheduleRule の id をそのままキーに使う。集中モードのモード行は
    /// modeIdentifier をキーに使う。
    enum ScheduleTargetPickerContext: Hashable {
        case rule(UUID)
        case focusMode(String)
    }
}
