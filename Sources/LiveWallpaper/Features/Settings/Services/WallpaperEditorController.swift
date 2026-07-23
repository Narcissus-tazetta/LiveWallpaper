import AVFoundation
import Foundation

/// トリム編集プレビューへの明示的なシーク指示。ユーザーがハンドル/トラックを
/// 操作した瞬間だけ発行し、再生中に player→UI へ流れてくる currentTime の
/// レポート(一方向)とは独立させることで、フィードバックループを避ける。
struct SeekToken: Equatable {
    let id = UUID()
    let time: Double
}

struct WallpaperEditDraft: Equatable {
    var path: String = ""
    var trimStart: Double = 0
    var trimEnd: Double?
    /// 「途中からループする」がONのときの、2周目以降の開始位置。
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

    /// 2周目以降が実際に始まる位置(ループ開始位置が無ければカット開始位置)。
    var effectiveLoopStart: Double {
        loopStart ?? trimStart
    }

    /// 実際にループ区間の終端として使ってよい値。`AVPlayerLooper` の timeRange は
    /// アセットの実尺をはみ出すと `.failed` になり再生自体が始まらないため
    /// (`WallpaperLoopBuilder.makeLooper` 参照)、尺が判明していれば必ずその内側へ
    /// 収める。尺がまだ読めていない(assetDuration == 0)間は nil を返し、
    /// 呼び出し側を timeRange 無しの全体ループへフォールバックさせる。
    var loopSafeTrimEnd: Double? {
        guard assetDuration > 0 else {
            return nil
        }
        let maxEnd = assetDuration - WallpaperLoopBuilder.loopEndGuard
        let end = min(effectiveTrimEnd, maxEnd)
        guard end > trimStart else {
            return nil
        }
        return end
    }

    /// 保存してよいループ開始位置。カット範囲の内側に収まらない値(カット開始位置
    /// より手前、カット終了位置に達している)は破棄して nil にする。壊れた値を
    /// 保存すると再生側の区間計算が黙って trimStart へ落ちるため、そもそも
    /// 保存しない。
    /// - Parameter minimumSegment: ループ区間として最低限確保する長さ。
    func loopSafeLoopStart(minimumSegment: Double) -> Double? {
        guard let loopStart, let end = loopSafeTrimEnd ?? trimEnd else {
            return nil
        }
        guard loopStart > trimStart, loopStart <= end - minimumSegment else {
            return nil
        }
        return loopStart
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
    @Published var seekRequest: SeekToken?
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
            let duration = await (try? asset.load(.duration).seconds) ?? 0
            guard let self, !Task.isCancelled, draft.path == path else {
                return
            }
            draft.assetDuration = max(duration, 0)
            if let trimEnd = draft.trimEnd, trimEnd > draft.assetDuration {
                draft.trimEnd = draft.assetDuration
            }
            if let loopStart = draft.loopStart, loopStart >= draft.effectiveTrimEnd {
                draft.loopStart = nil
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
        seek(to: draft.trimStart)
    }

    func setDraftTrimEnd(_ value: Double) {
        let minEnd = draft.trimStart + minimumSegmentDuration
        let maxEnd = draft.assetDuration > 0 ? draft.assetDuration : value
        draft.trimEnd = min(max(value, minEnd), maxEnd)
        // ループ開始位置が新しいカット終了位置に追い越されたら、指定ごと捨てる
        // (半端な位置に丸めるより「途中ループOFF」へ戻した方が分かりやすい)。
        if let loopStart = draft.loopStart,
           loopStart > draft.effectiveTrimEnd - minimumSegmentDuration
        {
            draft.loopStart = nil
        }
        seek(to: draft.effectiveTrimEnd)
    }

    /// ループ開始位置(オレンジのハンドル)。カット範囲の内側へ必ずクランプする。
    func setDraftLoopStart(_ value: Double?) {
        guard let value else {
            draft.loopStart = nil
            return
        }
        let upperBound = draft.effectiveTrimEnd - minimumSegmentDuration
        guard upperBound > draft.trimStart else {
            // カット範囲が短すぎて、イントロを置く余地がない。
            draft.loopStart = nil
            return
        }
        let clamped = min(max(value, draft.trimStart), upperBound)
        draft.loopStart = clamped
        seek(to: clamped)
    }

    /// 「途中からループする」チェックボックス。ONにしたときの初期値はカット範囲の
    /// 中間点(どこに置けばよいか分からないハンドルを、まず見える位置に出す)。
    func toggleCustomLoopStart(_ enabled: Bool) {
        guard enabled else {
            draft.loopStart = nil
            return
        }
        guard draft.loopStart == nil else {
            return
        }
        setDraftLoopStart((draft.trimStart + draft.effectiveTrimEnd) / 2)
    }

    /// トラック上の空白部分をクリック/ドラッグした際のシーク。ハンドル操作と
    /// 違ってドラフトの値は変えず、プレビューの再生位置だけを動かす。
    func seek(to time: Double) {
        let clamped = min(max(time, 0), draft.assetDuration > 0 ? draft.assetDuration : time)
        playheadTime = clamped
        seekRequest = SeekToken(time: clamped)
    }

    var minimumSegmentDuration: Double {
        0.5
    }

    // MARK: - 保存・破棄

    /// 保存では trimEnd を **必ず実尺の内側の具体値**にして渡す。nil のまま保存すると
    /// 再生側はループ区間の終端を決められず、全体ループへフォールバックしてしまう
    /// (かつては nil を `.positiveInfinity` として扱っており、AVPlayerLooper が
    /// `.failed` になって再生が始まらない不具合になっていた)。
    func commit(path: String) {
        let committedTrimEnd = draft.loopSafeTrimEnd ?? draft.trimEnd
        let committedLoopStart = draft.loopSafeLoopStart(minimumSegment: minimumSegmentDuration)
        model.setWallpaperEdit(
            trimStart: draft.trimStart,
            trimEnd: committedTrimEnd,
            loopStart: committedLoopStart,
            path: path
        )
        // 保存した値をドラフトへ書き戻さないと、trimEnd を丸めたぶんだけ
        // isDraftDirty が永久に true のままになり「保存して再適用」が押せ続ける。
        draft.trimEnd = committedTrimEnd
        draft.loopStart = committedLoopStart
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
