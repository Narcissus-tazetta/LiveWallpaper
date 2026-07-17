import AppKit
import SwiftUI

/// 矢印キーの keyCode(HIToolbox の kVK_* 相当)。
private enum FitArrowKeyCode {
    static let left: UInt16 = 123
    static let right: UInt16 = 124
    static let down: UInt16 = 125
    static let up: UInt16 = 126
}

/// フィット編集タブの状態とロジックの持ち主。
/// SettingsView に散らばっていた @State(ドラフト、静止画キャッシュ、デバウンス、
/// キーモニタ)を1箇所へ集約し、ビュー側は表示とバインディングだけを担当する。
@MainActor
final class FitEditorController: ObservableObject {
    private let model: WallpaperModel

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

    private var stillImageOrder: [String] = []
    private var stillImageInFlight: Set<String> = []
    private var stillImageTasks: [String: Task<Void, Never>] = [:]
    private var stillImageGeneration: [String: UUID] = [:]
    private var previewFrameSize: CGSize = .zero
    private var pathExistsCache: [String: Bool] = [:]

    private var liveApplyTask: Task<Void, Never>?
    private var savedFeedbackTask: Task<Void, Never>?
    private var normalizeThrottleTask: Task<Void, Never>?
    private var lastNormalizeAt: Date = .distantPast
    private var normalizeGeneration: Int = 0
    private var keyEventMonitor: Any?

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

    // MARK: - ドラフトの読み書き

    func syncDraftWithCurrentSelection() {
        guard isActive else {
            return
        }
        guard let path = resolvedVideoPath(), !path.isEmpty else {
            clearDraft()
            return
        }
        loadDraft(path: path, screenID: resolvedScreenID())
    }

    func loadDraft(path: String, screenID: String) {
        let loaded = FitEditorDraft(
            path: path,
            screenID: screenID,
            fitMode: model.wallpaperFitMode(path: path, screenID: screenID),
            zoom: model.wallpaperZoom(path: path, screenID: screenID),
            offsetX: model.wallpaperOffsetX(path: path, screenID: screenID),
            offsetY: model.wallpaperOffsetY(path: path, screenID: screenID)
        )

        guard draft != loaded else {
            return
        }

        cancelDeferredWork()
        draft = loaded
    }

    func clearDraft() {
        guard draft.isActive else {
            return
        }
        cancelDeferredWork()
        draft = FitEditorDraft()
    }

    /// ドラフトの切り替え時に、旧ドラフト宛の遅延処理(正規化・リアルタイム反映)を破棄する。
    private func cancelDeferredWork() {
        normalizeThrottleTask?.cancel()
        normalizeThrottleTask = nil
        normalizeGeneration &+= 1
        liveApplyTask?.cancel()
        liveApplyTask = nil
    }

    func ensureDraft(path: String, screenID: String) {
        if draft.matches(path: path, screenID: screenID) {
            return
        }
        loadDraft(path: path, screenID: screenID)
    }

    func fitMode(path: String, screenID: String) -> VideoFitMode {
        guard draft.matches(path: path, screenID: screenID) else {
            return model.wallpaperFitMode(path: path, screenID: screenID)
        }
        return draft.fitMode
    }

    func zoom(path: String, screenID: String) -> Double {
        guard draft.matches(path: path, screenID: screenID) else {
            return model.wallpaperZoom(path: path, screenID: screenID)
        }
        return draft.zoom
    }

    func offsetX(path: String, screenID: String) -> Double {
        guard draft.matches(path: path, screenID: screenID) else {
            return model.wallpaperOffsetX(path: path, screenID: screenID)
        }
        return draft.offsetX
    }

    func offsetY(path: String, screenID: String) -> Double {
        guard draft.matches(path: path, screenID: screenID) else {
            return model.wallpaperOffsetY(path: path, screenID: screenID)
        }
        return draft.offsetY
    }

    func isDraftDirty(path: String, screenID: String) -> Bool {
        guard draft.matches(path: path, screenID: screenID) else {
            return false
        }
        return draft.fitMode != model.wallpaperFitMode(path: path, screenID: screenID)
            || draft.zoom != model.wallpaperZoom(path: path, screenID: screenID)
            || draft.offsetX != model.wallpaperOffsetX(path: path, screenID: screenID)
            || draft.offsetY != model.wallpaperOffsetY(path: path, screenID: screenID)
    }

    // MARK: - ドラフトの編集

    /// ドラフト変更後の共通処理。オフセット正規化と、有効時のリアルタイム反映を予約する。
    private func draftDidChange(path: String, screenID: String) {
        throttledNormalizeDraftOffsets(path: path, screenID: screenID)
        scheduleLiveApplyIfNeeded(path: path, screenID: screenID)
    }

    func setDraftFitMode(_ fitMode: VideoFitMode, path: String, screenID: String) {
        ensureDraft(path: path, screenID: screenID)
        draft.fitMode = fitMode
        draftDidChange(path: path, screenID: screenID)
    }

    /// anchor はプレビューキャンバス中心を原点とした y 下向きの座標。
    /// 指定するとその点直下のコンテンツを保ったままズームする(カーソル中心ズーム)。
    func setDraftZoom(
        _ zoom: Double,
        anchor: CGPoint? = nil,
        path: String,
        screenID: String
    ) {
        ensureDraft(path: path, screenID: screenID)
        let newZoom = WallpaperGeometry.clampZoom(zoom)
        if let anchor, newZoom != draft.zoom {
            let container = resolvedConstraintFrameSize(screenID: screenID)
            let before = model.wallpaperRenderGeometry(
                path: path,
                screenID: screenID,
                containerSize: container,
                fitMode: draft.fitMode,
                zoom: draft.zoom,
                offsetX: draft.offsetX,
                offsetY: draft.offsetY
            )
            let after = model.wallpaperRenderGeometry(
                path: path,
                screenID: screenID,
                containerSize: container,
                fitMode: draft.fitMode,
                zoom: newZoom,
                offsetX: draft.offsetX,
                offsetY: draft.offsetY
            )
            let contentX =
                (Double(anchor.x) - Double(before.translation.width))
                / max(Double(before.renderedSize.width), 1)
            let contentY =
                (Double(anchor.y) - Double(before.translation.height))
                / max(Double(before.renderedSize.height), 1)
            let translationX = Double(anchor.x) - contentX * Double(after.renderedSize.width)
            let translationY = Double(anchor.y) - contentY * Double(after.renderedSize.height)
            draft.offsetX = normalizedOffset(
                translation: translationX,
                maxPan: Double(after.maxPan.width)
            )
            draft.offsetY = normalizedOffset(
                translation: translationY,
                maxPan: Double(after.maxPan.height)
            )
        }
        draft.zoom = newZoom
        draftDidChange(path: path, screenID: screenID)
    }

    func setDraftOffsetX(_ offsetX: Double, path: String, screenID: String) {
        ensureDraft(path: path, screenID: screenID)
        draft.offsetX = WallpaperGeometry.clampOffset(offsetX)
        draftDidChange(path: path, screenID: screenID)
    }

    func setDraftOffsetY(_ offsetY: Double, path: String, screenID: String) {
        ensureDraft(path: path, screenID: screenID)
        draft.offsetY = WallpaperGeometry.clampOffset(offsetY)
        draftDidChange(path: path, screenID: screenID)
    }

    func moveDraftOffset(dx: Double, dy: Double, path: String, screenID: String) {
        ensureDraft(path: path, screenID: screenID)
        draft.offsetX = WallpaperGeometry.clampOffset(draft.offsetX + dx)
        draft.offsetY = WallpaperGeometry.clampOffset(draft.offsetY + dy)
        draftDidChange(path: path, screenID: screenID)
    }

    // MARK: - ビュー用バインディング

    func fitModeBinding(path: String, screenID: String) -> Binding<VideoFitMode> {
        Binding(
            get: { self.fitMode(path: path, screenID: screenID) },
            set: { self.setDraftFitMode($0, path: path, screenID: screenID) }
        )
    }

    func zoomBinding(path: String, screenID: String) -> Binding<Double> {
        Binding(
            get: { self.zoom(path: path, screenID: screenID) },
            set: { self.setDraftZoom($0, path: path, screenID: screenID) }
        )
    }

    func offsetXBinding(path: String, screenID: String) -> Binding<Double> {
        Binding(
            get: { self.offsetX(path: path, screenID: screenID) },
            set: { self.setDraftOffsetX($0, path: path, screenID: screenID) }
        )
    }

    func offsetYBinding(path: String, screenID: String) -> Binding<Double> {
        Binding(
            get: { self.offsetY(path: path, screenID: screenID) },
            set: { self.setDraftOffsetY($0, path: path, screenID: screenID) }
        )
    }

    // MARK: - オフセットの正規化

    /// wallpaperRenderGeometry の再計算コストを避けるため、正規化は最大60Hzに間引く。
    /// 直近の呼び出しから間隔が空いていない場合は末尾に1回分だけ予約し、取りこぼしを防ぐ。
    private func throttledNormalizeDraftOffsets(path: String, screenID: String) {
        let minInterval: TimeInterval = 1.0 / 60.0
        let now = Date()
        let expectedGeneration = normalizeGeneration
        if now.timeIntervalSince(lastNormalizeAt) >= minInterval {
            normalizeThrottleTask?.cancel()
            normalizeThrottleTask = nil
            lastNormalizeAt = now
            normalizeDraftOffsets(path: path, screenID: screenID)
            return
        }
        guard normalizeThrottleTask == nil else {
            return
        }
        normalizeThrottleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(minInterval * 1_000_000_000))
            guard let self, !Task.isCancelled else {
                return
            }
            normalizeThrottleTask = nil
            guard normalizeGeneration == expectedGeneration else {
                return
            }
            guard draft.matches(path: path, screenID: screenID) else {
                return
            }
            lastNormalizeAt = Date()
            normalizeDraftOffsets(path: path, screenID: screenID)
        }
    }

    func updatePreviewFrameSize(_ frameSize: CGSize, path: String, screenID: String) {
        guard previewFrameSize != frameSize else {
            return
        }
        previewFrameSize = frameSize
        guard draft.matches(path: path, screenID: screenID) else {
            return
        }
        normalizeDraftOffsets(path: path, screenID: screenID)
    }

    func normalizeDraftOffsets(path: String, screenID: String) {
        ensureDraft(path: path, screenID: screenID)

        let constraintFrame = resolvedConstraintFrameSize(screenID: screenID)
        let geometry = model.wallpaperRenderGeometry(
            path: path,
            screenID: screenID,
            containerSize: constraintFrame,
            fitMode: draft.fitMode,
            zoom: draft.zoom,
            offsetX: draft.offsetX,
            offsetY: draft.offsetY
        )

        draft.offsetX = normalizedOffset(
            translation: Double(geometry.translation.width),
            maxPan: Double(geometry.maxPan.width)
        )
        draft.offsetY = normalizedOffset(
            translation: Double(geometry.translation.height),
            maxPan: Double(geometry.maxPan.height)
        )
    }

    func resolvedConstraintFrameSize(screenID: String) -> CGSize {
        if previewFrameSize.width > 1, previewFrameSize.height > 1 {
            return previewFrameSize
        }

        let aspect = max(screenAspect(for: screenID), 0.2)
        let width: CGFloat = 420
        let height = width / aspect
        return CGSize(width: width, height: height)
    }

    private func normalizedOffset(translation: Double, maxPan: Double) -> Double {
        guard maxPan > 0.5 else {
            return 0
        }
        let clampedTranslation = min(max(translation, -maxPan), maxPan)
        return WallpaperGeometry.clampOffset(clampedTranslation / maxPan)
    }

    // MARK: - 保存・破棄

    func applyDraft(path: String, screenID: String, showFeedback: Bool = true) {
        ensureDraft(path: path, screenID: screenID)
        normalizeThrottleTask?.cancel()
        normalizeThrottleTask = nil
        lastNormalizeAt = Date()
        normalizeDraftOffsets(path: path, screenID: screenID)
        model.setWallpaperPresentation(
            fitMode: draft.fitMode,
            zoom: draft.zoom,
            offsetX: draft.offsetX,
            offsetY: draft.offsetY,
            path: path,
            screenID: screenID
        )
        loadDraft(path: path, screenID: screenID)
        if showFeedback {
            showSavedFeedback()
        }
    }

    func resetDraft(path: String, screenID: String) {
        ensureDraft(path: path, screenID: screenID)
        draft.fitMode = model.fitMode
        draft.zoom = 1.0
        draft.offsetX = 0.0
        draft.offsetY = 0.0
        draftDidChange(path: path, screenID: screenID)
    }

    /// 未保存の編集を破棄して、保存済みの値へ戻す。
    func discardDraftChanges(path: String, screenID: String) {
        loadDraft(path: path, screenID: screenID)
    }

    /// 個別設定を削除して既定値へ戻し、ドラフトも同期する。
    func clearOverride(path: String, screenID: String) {
        model.clearWallpaperPresentation(path: path, screenID: screenID)
        loadDraft(path: path, screenID: screenID)
        showSavedFeedback()
    }

    /// 現在のドラフトを保存したうえで、すべての画面へ同じ設定をコピーする。
    func applyDraftToAllScreens(path: String, screenID: String) {
        applyDraft(path: path, screenID: screenID, showFeedback: false)
        model.applyWallpaperPresentationToAllScreens(path: path, fromScreenID: screenID)
        showSavedFeedback()
    }

    func setLiveApplyEnabled(_ enabled: Bool, path: String, screenID: String) {
        liveApplyEnabled = enabled
        guard enabled else {
            liveApplyTask?.cancel()
            liveApplyTask = nil
            return
        }
        if isDraftDirty(path: path, screenID: screenID) {
            applyDraft(path: path, screenID: screenID, showFeedback: false)
        }
    }

    /// リアルタイム反映。連続操作(ドラッグ・スライダー)中の書き込み連打を避けるため 250ms デバウンスする。
    private func scheduleLiveApplyIfNeeded(path: String, screenID: String) {
        guard liveApplyEnabled else {
            return
        }
        liveApplyTask?.cancel()
        liveApplyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled else {
                return
            }
            liveApplyTask = nil
            guard liveApplyEnabled else {
                return
            }
            guard draft.matches(path: path, screenID: screenID) else {
                return
            }
            applyDraft(path: path, screenID: screenID, showFeedback: false)
        }
    }

    func showSavedFeedback() {
        savedFeedbackTask?.cancel()
        showsSavedFeedback = true
        savedFeedbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard let self, !Task.isCancelled else {
                return
            }
            savedFeedbackTask = nil
            showsSavedFeedback = false
        }
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

    // MARK: - 静止画プレビュー

    private var stillImageLimit: Int {
        10
    }

    func setPreviewMode(_ mode: FitPreviewMode) {
        guard previewMode != mode else {
            return
        }
        previewMode = mode
        prepareStillImageIfNeeded()
    }

    func prepareStillImageIfNeeded() {
        guard isActive else {
            return
        }
        guard previewMode == .still else {
            return
        }
        guard let path = resolvedVideoPath(), !path.isEmpty else {
            return
        }
        requestStillImage(path: path)
    }

    func requestStillImage(path: String) {
        guard isActive else {
            return
        }
        guard previewMode == .still else {
            return
        }
        guard path == resolvedVideoPath() else {
            return
        }
        guard stillImages[path] == nil else {
            return
        }
        guard !stillImageInFlight.contains(path) else {
            return
        }
        guard FileManager.default.fileExists(atPath: path) else {
            return
        }

        stillImageInFlight.insert(path)

        let generation = UUID()
        stillImageGeneration[path] = generation

        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let image = await FitPreviewService.generateStillImage(path: path)
            await MainActor.run { [weak self] in
                guard let self else {
                    return
                }
                // A newer request for the same path may have superseded this one
                // (e.g. rapid A -> B -> A selection); only this generation's
                // completion may mutate the shared in-flight/task bookkeeping.
                guard stillImageGeneration[path] == generation else {
                    return
                }
                if !Task.isCancelled, let image {
                    stillImages[path] = image
                    stillImageOrder.removeAll { $0 == path }
                    stillImageOrder.append(path)
                    trimStillImagesIfNeeded()
                }
                stillImageInFlight.remove(path)
                stillImageTasks.removeValue(forKey: path)
                stillImageGeneration.removeValue(forKey: path)
            }
        }
        stillImageTasks[path] = task
    }

    private func trimStillImagesIfNeeded() {
        guard stillImageOrder.count > stillImageLimit else {
            return
        }
        let overflow = stillImageOrder.count - stillImageLimit
        for path in stillImageOrder.prefix(overflow) {
            stillImages.removeValue(forKey: path)
        }
        stillImageOrder.removeFirst(overflow)
    }

    func cancelStillGeneration(exceptPath: String?) {
        for (path, task) in stillImageTasks where path != exceptPath {
            task.cancel()
            stillImageTasks.removeValue(forKey: path)
            stillImageInFlight.remove(path)
            stillImageGeneration.removeValue(forKey: path)
        }
    }

    /// ライブラリから消えた動画に紐づく状態(キャッシュ・進行中タスク・選択)を破棄する。
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

    // MARK: - キーボード操作

    func installKeyMonitorIfNeeded() {
        guard keyEventMonitor == nil else {
            return
        }

        keyEventMonitor =
            NSEvent
            .addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, isActive else {
                    return event
                }
                // A text field (name edit, search, ...) is being edited: let the
                // arrow keys move the caret/selection instead of panning the
                // preview. The field editor backing any focused NSTextField or
                // SwiftUI TextField is an NSTextView, a subclass of NSText.
                if (event.window ?? NSApp.keyWindow)?.firstResponder is NSText {
                    return event
                }
                guard let path = resolvedVideoPath(), !path.isEmpty else {
                    return event
                }

                let step = event.modifierFlags.contains(.shift) ? 0.01 : 0.002
                let screenID = resolvedScreenID()

                switch event.keyCode {
                case FitArrowKeyCode.left:
                    moveDraftOffset(dx: -step, dy: 0, path: path, screenID: screenID)
                    return nil
                case FitArrowKeyCode.right:
                    moveDraftOffset(dx: step, dy: 0, path: path, screenID: screenID)
                    return nil
                case FitArrowKeyCode.down:
                    moveDraftOffset(dx: 0, dy: step, path: path, screenID: screenID)
                    return nil
                case FitArrowKeyCode.up:
                    moveDraftOffset(dx: 0, dy: -step, path: path, screenID: screenID)
                    return nil
                default:
                    return event
                }
            }
    }

    func removeKeyMonitor() {
        guard let monitor = keyEventMonitor else {
            return
        }
        NSEvent.removeMonitor(monitor)
        keyEventMonitor = nil
    }
}
