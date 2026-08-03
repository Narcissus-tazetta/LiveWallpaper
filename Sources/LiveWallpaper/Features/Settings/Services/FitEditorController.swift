import AppKit
import SwiftUI

/// フィット編集タブの状態とロジックの持ち主。
/// SettingsView に散らばっていた @State(ドラフト、静止画キャッシュ、デバウンス、
/// キーモニタ)を1箇所へ集約し、ビュー側は表示とバインディングだけを担当する。
///
/// 実装は関心事ごとに拡張ファイルへ分割している:
/// - この本体: 表示状態・画面/動画選択・ファイル存在キャッシュ
/// - `+Draft`: ドラフトの読み書き・編集・バインディング・正規化・保存
/// - `+StillPreview`: 静止画プレビューの生成とキャッシュ
/// - `+Keyboard`: 矢印キーによるパン操作
@MainActor
final class FitEditorController: ObservableObject {
    let model: WallpaperModel

    @Published var selectedVideoPath: String?
    @Published var selectedScreenID: String = ""
    @Published var draft: FitEditorDraft = .init()
    @Published var liveApplyEnabled: Bool = false
    @Published var showsSavedFeedback: Bool = false
    @Published var isInteractionEnabled: Bool = false
    @Published var previewMode: FitPreviewMode = .still
    @Published var stillImages: [String: NSImage] = [:]

    /// フィット編集タブが表示されているか。タブ外ではキー操作・静止画生成を止める。
    private(set) var isActive: Bool = false

    /// 「編集」タブの中でフィット編集が前面にいるか。トリム編集も同じタブで
    /// 同時に activate されており、矢印キーを両方が拾うと壁紙のパンと
    /// タイムライン送りが同時に起きてしまうため、前面の方だけに効かせる。
    private(set) var isSubModeActive: Bool = true

    var stillImageOrder: [String] = []
    var stillImageInFlight: Set<String> = []
    var stillImageTasks: [String: Task<Void, Never>] = [:]
    var stillImageGeneration: [String: UUID] = [:]
    var previewFrameSize: CGSize = .zero
    private var pathExistsCache: [String: Bool] = [:]

    var liveApplyTask: Task<Void, Never>?
    var savedFeedbackTask: Task<Void, Never>?
    var normalizeThrottleTask: Task<Void, Never>?
    var lastNormalizeAt: Date = .distantPast
    var normalizeGeneration: Int = 0
    var keyEventMonitor: Any?

    init(model: WallpaperModel) {
        self.model = model
    }

    // MARK: - タブの表示状態

    func activate() {
        isActive = true
        ensureScreenSelection()
        syncSelectionWithCurrentVideoIfNeeded()
        syncDraftWithCurrentSelection()
        invalidatePathExistsCache(path: resolvedVideoPath())
        isInteractionEnabled = false
        installKeyMonitorIfNeeded()
        prepareStillImageIfNeeded()
    }

    func deactivate() {
        isActive = false
        removeKeyMonitor()
    }

    func handleCurrentVideoPathChange() {
        if selectedVideoPath == nil {
            syncSelectionWithCurrentVideoIfNeeded()
        }
        syncDraftWithCurrentSelection()
        prepareStillImageIfNeeded()
    }

    /// 「編集」タブのサブモード切り替え。
    func setSubModeActive(_ active: Bool) {
        isSubModeActive = active
    }

    // MARK: - 画面の選択

    var screens: [WallpaperModel.DisplayScreenInfo] {
        model.availableDisplayScreens()
    }

    func screenAspect(for screenID: String) -> CGFloat {
        if let screen = screens.first(where: { $0.id == screenID }) {
            let width = max(screen.frame.width, 1)
            let height = max(screen.frame.height, 1)
            return width / height
        }
        return 16.0 / 9.0
    }

    /// 選択中の画面が接続一覧から消えていたら先頭の画面へ寄せる。activate() だけで
    /// なく画面構成が変わるたびに呼ぶこと。Picker の選択はタグ一致で描画されるため、
    /// 外した画面のIDを持ったままだと選択が空欄になる。
    func ensureScreenSelection() {
        let screens = screens
        if screens.isEmpty {
            selectedScreenID = ""
            return
        }
        if screens.contains(where: { $0.id == selectedScreenID }) {
            return
        }
        selectedScreenID = screens[0].id
        syncDraftWithCurrentSelection()
    }

    func resolvedScreenID() -> String {
        if screens.contains(where: { $0.id == selectedScreenID }) {
            return selectedScreenID
        }
        return screens.first?.id ?? "main"
    }

    func selectScreen(_ screenID: String) {
        selectedScreenID = screenID
        syncDraftWithCurrentSelection()
    }

    // MARK: - 動画の選択

    func resolvedVideoPath() -> String? {
        let allPaths = model.allRegisteredVideoPaths
        if let selected = selectedVideoPath,
            allPaths.contains(selected)
        {
            return selected
        }
        if let current = model.currentVideoPath,
            allPaths.contains(current)
        {
            return current
        }
        return allPaths.first
    }

    func syncSelectionWithCurrentVideoIfNeeded() {
        selectedVideoPath = resolvedVideoPath()
    }

    func selectVideo(path: String) {
        guard model.allRegisteredVideoPaths.contains(path) else {
            return
        }
        cancelStillGeneration(exceptPath: path)
        invalidatePathExistsCache(path: path)
        selectedVideoPath = path
        isInteractionEnabled = false
        syncDraftWithCurrentSelection()
        prepareStillImageIfNeeded()
    }

    // MARK: - ファイル存在キャッシュ

    func pathExists(_ path: String) -> Bool {
        // 欠損も含めてキャッシュする。プレビュー本体は毎ドラッグフレームで再評価される
        // ため、ここで毎回 stat を叩くと欠損ファイル表示中の負荷が跳ね上がる。
        if let cached = pathExistsCache[path] {
            return cached
        }
        let exists = FileManager.default.fileExists(atPath: path)
        pathExistsCache[path] = exists
        return exists
    }

    /// 欠損キャッシュはファイル復活(復元・差し替え)を検出できないため、
    /// 動画の選択時とタブ表示時に該当エントリを破棄して再確認させる。
    func invalidatePathExistsCache(path: String?) {
        guard let path else {
            return
        }
        if pathExistsCache[path] == false {
            pathExistsCache.removeValue(forKey: path)
        }
    }

    /// ライブラリから消えた動画に紐づく状態(存在キャッシュ・静止画キャッシュ・進行中タスク・選択)を破棄する。
    func pruneMissing(validPaths valid: Set<String>) {
        pathExistsCache = pathExistsCache.filter { valid.contains($0.key) }
        stillImages = stillImages.filter { valid.contains($0.key) }
        stillImageOrder = stillImageOrder.filter { valid.contains($0) }
        stillImageInFlight = stillImageInFlight.filter { valid.contains($0) }
        for (path, task) in stillImageTasks where !valid.contains(path) {
            task.cancel()
            stillImageTasks.removeValue(forKey: path)
        }
        stillImageGeneration = stillImageGeneration.filter { valid.contains($0.key) }
        if let selected = selectedVideoPath, !valid.contains(selected) {
            selectedVideoPath = nil
        }
    }
}
