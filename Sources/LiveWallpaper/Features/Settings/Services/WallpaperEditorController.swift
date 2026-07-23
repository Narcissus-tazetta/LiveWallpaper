import AVFoundation
import Foundation

struct WallpaperEditDraft: Equatable {
    var path: String = ""
    var trimStart: Double = 0
    var trimEnd: Double?
    var loopStart: Double?
    var assetDuration: Double = 0

    func matches(path: String) -> Bool {
        self.path == path
    }

    var effectiveTrimEnd: Double {
        trimEnd ?? assetDuration
    }

    var hasCustomLoopStart: Bool {
        loopStart != nil
    }
}

/// トリム/ループ編集タブの状態とロジックの持ち主。FitEditorController と同じ
/// draft-then-commit パターンを踏襲する: プレビューはドラフトを参照し、保存操作
/// (commit)ではじめてモデルへ反映される。
@MainActor
final class WallpaperEditorController: ObservableObject {
    private let model: WallpaperModel

    @Published var selectedVideoPath: String?
    @Published var draft: WallpaperEditDraft = .init()
    @Published var playheadTime: Double = 0
    @Published var isPreviewPlaying: Bool = true
    @Published var showsSavedFeedback: Bool = false

    private(set) var isActive: Bool = false
    private var durationLoadTask: Task<Void, Never>?
    private var savedFeedbackTask: Task<Void, Never>?

    init(model: WallpaperModel) {
        self.model = model
    }

    func activate() {
        isActive = true
        syncSelectionWithCurrentVideoIfNeeded()
        syncDraftWithCurrentSelection()
    }

    func deactivate() {
        isActive = false
        durationLoadTask?.cancel()
        durationLoadTask = nil
    }

    func handleCurrentVideoPathChange() {
        if selectedVideoPath == nil {
            syncSelectionWithCurrentVideoIfNeeded()
        }
        syncDraftWithCurrentSelection()
    }

    func resolvedVideoPath() -> String? {
        let allPaths = model.allRegisteredVideoPaths
        if let selected = selectedVideoPath, allPaths.contains(selected) {
            return selected
        }
        if let current = model.currentVideoPath, allPaths.contains(current) {
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
        selectedVideoPath = path
        syncDraftWithCurrentSelection()
    }

    // MARK: - ドラフトの読み書き

    func syncDraftWithCurrentSelection() {
        guard isActive else {
            return
        }
        guard let path = resolvedVideoPath(), !path.isEmpty else {
            draft = WallpaperEditDraft()
            return
        }
        loadDraft(path: path)
    }

    func loadDraft(path: String) {
        let existing = model.wallpaperEdit(for: path)
        let loaded = WallpaperEditDraft(
            path: path,
            trimStart: existing?.trimStart ?? 0,
            trimEnd: existing?.trimEnd,
            loopStart: existing?.loopStart,
            assetDuration: draft.path == path ? draft.assetDuration : 0
        )
        if loaded.assetDuration <= 0 {
            loadAssetDuration(path: path)
        } else {
            draft = loaded
            return
        }
        draft = loaded
        playheadTime = loaded.trimStart
    }

    private func loadAssetDuration(path: String) {
        durationLoadTask?.cancel()
        let url = URL(fileURLWithPath: path)
        durationLoadTask = Task { [weak self] in
            let asset = AVURLAsset(url: url)
            let duration = (try? await asset.load(.duration).seconds) ?? 0
            guard let self, !Task.isCancelled, self.draft.path == path else {
                return
            }
            self.draft.assetDuration = max(duration, 0)
            if let trimEnd = self.draft.trimEnd, trimEnd > self.draft.assetDuration {
                self.draft.trimEnd = self.draft.assetDuration
            }
        }
    }

    func isDraftDirty(path: String) -> Bool {
        guard draft.matches(path: path) else {
            return false
        }
        let saved = model.wallpaperEdit(for: path) ?? WallpaperEditMetadata()
        return draft.trimStart != saved.trimStart
            || draft.trimEnd != saved.trimEnd
            || draft.loopStart != saved.loopStart
    }

    var hasOverride: Bool {
        guard let path = resolvedVideoPath() else {
            return false
        }
        return model.hasWallpaperEditOverride(path: path)
    }

    // MARK: - ドラフトの編集

    func setDraftTrimStart(_ value: Double) {
        let clamped = min(max(value, 0), draft.effectiveTrimEnd - minimumSegmentDuration)
        draft.trimStart = max(clamped, 0)
        if let loopStart = draft.loopStart, loopStart < draft.trimStart {
            draft.loopStart = draft.trimStart
        }
        playheadTime = draft.trimStart
    }

    func setDraftTrimEnd(_ value: Double) {
        let minEnd = draft.trimStart + minimumSegmentDuration
        let maxEnd = draft.assetDuration > 0 ? draft.assetDuration : value
        draft.trimEnd = min(max(value, minEnd), maxEnd)
        if let loopStart = draft.loopStart, let trimEnd = draft.trimEnd, loopStart >= trimEnd {
            draft.loopStart = nil
        }
    }

    func setDraftLoopStart(_ value: Double?) {
        guard let value else {
            draft.loopStart = nil
            return
        }
        let clamped = min(max(value, draft.trimStart), draft.effectiveTrimEnd - minimumSegmentDuration)
        draft.loopStart = max(clamped, draft.trimStart)
    }

    func toggleCustomLoopStart(_ enabled: Bool) {
        if enabled {
            draft.loopStart = draft.loopStart ?? midpoint(draft.trimStart, draft.effectiveTrimEnd)
        } else {
            draft.loopStart = nil
        }
    }

    private func midpoint(_ a: Double, _ b: Double) -> Double {
        (a + b) / 2
    }

    var minimumSegmentDuration: Double {
        0.5
    }

    // MARK: - 保存・破棄

    func commit(path: String) {
        model.setWallpaperEdit(
            trimStart: draft.trimStart,
            trimEnd: draft.trimEnd,
            loopStart: draft.loopStart,
            path: path
        )
        showSavedFeedback()
    }

    func resetDraft() {
        draft.trimStart = 0
        draft.trimEnd = nil
        draft.loopStart = nil
        playheadTime = 0
    }

    func discardDraftChanges(path: String) {
        loadDraft(path: path)
    }

    func clearOverride(path: String) {
        model.resetWallpaperEdit(path: path)
        loadDraft(path: path)
        showSavedFeedback()
    }

    /// ライブラリから消えた動画に紐づく選択・ドラフトを破棄する。
    /// draft を放置すると、resolvedVideoPath() が別の動画へフォールバックした
    /// 後もヘッダーとスクラバーが食い違ったまま(古い動画の尺・トリム範囲)
    /// 表示され続けてしまう。
    func pruneMissing(validPaths valid: Set<String>) {
        var needsResync = false
        if let selected = selectedVideoPath, !valid.contains(selected) {
            selectedVideoPath = nil
            needsResync = true
        }
        if !draft.path.isEmpty, !valid.contains(draft.path) {
            needsResync = true
        }
        if needsResync {
            syncDraftWithCurrentSelection()
        }
    }

    private func showSavedFeedback() {
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
}
