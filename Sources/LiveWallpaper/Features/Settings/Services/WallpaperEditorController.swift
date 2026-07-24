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
    /// 実測のフレームレート。矢印キーの1コマ送りに使う。読めなかった場合の
    /// 30fps は「それらしく動く」ためのフォールバックで、正確さは求めない。
    var frameRate: Double = 30

    func matches(path: String) -> Bool {
        self.path == path
    }

    /// カット終了位置として UI で作ってよい上限。実尺そのものではなく
    /// `loopEndGuard` ぶん内側に取る。保存時にどうせここへ丸められる
    /// (`loopSafeTrimEnd`)ので、編集中から同じ値にしておかないと
    /// 「保存した瞬間に終了時刻の表示が動く」ことになる。
    var maximumTrimEnd: Double {
        guard assetDuration > 0 else {
            return 0
        }
        return max(assetDuration - WallpaperLoopBuilder.loopEndGuard, 0)
    }

    var effectiveTrimEnd: Double {
        trimEnd ?? maximumTrimEnd
    }

    var hasCustomLoopStart: Bool {
        loopStart != nil
    }

    /// 1コマぶんの秒数。フレームレートが壊れていても必ず正の値を返す。
    var frameDuration: Double {
        guard frameRate.isFinite, frameRate > 0 else {
            return 1.0 / 30.0
        }
        return 1.0 / min(max(frameRate, 1), 240)
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

    /// Undo/Redo が出し入れする値だけを取り出したもの。
    var snapshot: TrimEditSnapshot {
        TrimEditSnapshot(trimStart: trimStart, trimEnd: trimEnd, loopStart: loopStart)
    }

    mutating func apply(_ snapshot: TrimEditSnapshot) {
        trimStart = snapshot.trimStart
        trimEnd = snapshot.trimEnd
        loopStart = snapshot.loopStart
    }
}

/// トリム/ループ編集タブの状態とロジックの持ち主。FitEditorController と同じ
/// draft-then-commit パターンを踏襲する: プレビューはドラフトを参照し、保存操作
/// (commit)ではじめてモデルへ反映される。
///
/// 大きくなったため、責務ごとに extension を分けてある:
/// - `+Timeline`: ズーム/スクロールとキーフレーム吸着
/// - `+Keyboard`: 矢印キー・I/O/L・⌘Z のキーモニタ
/// - `+Transfer`: 他の壁紙へのコピーとファイル書き出し
@MainActor
final class WallpaperEditorController: ObservableObject {
    let model: WallpaperModel

    @Published var selectedVideoPath: String?
    @Published var draft: WallpaperEditDraft = .init()
    @Published var playheadTime: Double = 0 {
        didSet {
            followPlayheadIfNeeded()
        }
    }

    @Published var seekRequest: SeekToken?
    @Published var isPreviewPlaying: Bool = true
    @Published var showsSavedFeedback: Bool = false

    /// 尺の読み込みに失敗した(ファイルが壊れている・消えている)。UIは無限に
    /// スピナーを回すのではなく、ここを見てエラーと再試行を出す。
    @Published var didFailToLoadAsset: Bool = false

    /// タイムラインが今映している範囲(ズーム/スクロール)。
    @Published var timelineWindow: TrimTimelineWindow = .full(assetDuration: 0)

    /// スクラバーの実測幅(pt)。キーフレーム吸着の許容誤差を「見た目の距離」で
    /// 決めるため、ビューから書き戻してもらう。
    @Published var scrubberWidth: Double = 0

    /// 「ループ区間だけを再生する」。ONの間はイントロ(初回だけカット開始位置から)
    /// を挟まず、2周目以降と同じ区間だけを繰り返す。継ぎ目の作り込み用。
    @Published var previewsLoopOnly: Bool = false {
        didSet {
            UserDefaults.standard.set(previewsLoopOnly, forKey: Self.previewsLoopOnlyKey)
        }
    }

    /// ハンドルのドラッグをキーフレームへ吸着させる。
    @Published var snapsToKeyframes: Bool = true {
        didSet {
            UserDefaults.standard.set(snapsToKeyframes, forKey: Self.snapsToKeyframesKey)
            if snapsToKeyframes {
                loadKeyframesIfNeeded()
            }
        }
    }

    /// 現在の動画のキーフレーム時刻(昇順)。空なら吸着しない。
    /// 書き込むのは `+Timeline` の索引読み込みだけ。
    @Published var keyframeTimes: [Double] = []
    @Published var isLoadingKeyframes: Bool = false

    @Published private(set) var canUndo: Bool = false
    @Published private(set) var canRedo: Bool = false

    /// 未保存の変更があるまま別の動画へ切り替えようとしている。確認ダイアログの
    /// 表示条件であり、確定するまで選択は変えない。
    @Published var pendingSelectionPath: String?

    /// 書き出しの進捗(0...1)。nil なら書き出していない。
    @Published var exportProgress: Double?
    /// 直近の書き出し/コピー結果。UIに1行で出して数秒で消す。
    @Published var transferMessage: String?
    @Published var transferMessageIsError: Bool = false

    private(set) var isActive: Bool = false
    /// 「編集」タブ内でトリム編集が前面にいるか。キーモニタはこれがONの間だけ
    /// 効かせる — フィット編集も同時に activate されており、矢印キーを両方が
    /// 拾うと壁紙のパンとタイムライン送りが同時に起きてしまう。
    private(set) var isSubModeActive: Bool = false

    var history = TrimEditHistory()
    var durationLoadTask: Task<Void, Never>?
    var keyframeLoadTask: Task<Void, Never>?
    var exportTask: Task<Void, Never>?
    var transferMessageTask: Task<Void, Never>?
    var keyEventMonitor: Any?
    private var savedFeedbackTask: Task<Void, Never>?
    /// キーフレーム索引を作り終えたパス。ONにするたびに再走査しないための目印。
    var keyframeIndexedPath: String?

    static let previewsLoopOnlyKey = "trimEditorPreviewsLoopOnly"
    static let snapsToKeyframesKey = "trimEditorSnapsToKeyframes"

    init(model: WallpaperModel) {
        self.model = model
        let defaults = UserDefaults.standard
        previewsLoopOnly = defaults.bool(forKey: Self.previewsLoopOnlyKey)
        snapsToKeyframes =
            defaults.object(forKey: Self.snapsToKeyframesKey) as? Bool ?? true
    }

    func activate() {
        isActive = true
        syncSelectionWithCurrentVideoIfNeeded()
        syncDraftWithCurrentSelection()
        installKeyMonitorIfNeeded()
    }

    func deactivate() {
        isActive = false
        durationLoadTask?.cancel()
        durationLoadTask = nil
        keyframeLoadTask?.cancel()
        keyframeLoadTask = nil
        removeKeyMonitor()
    }

    /// 「編集」タブのサブモード(フィット/トリム)切り替え。
    func setSubModeActive(_ active: Bool) {
        isSubModeActive = active
        if active {
            installKeyMonitorIfNeeded()
            loadKeyframesIfNeeded()
        } else {
            removeKeyMonitor()
        }
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

    /// 未保存の変更を持ったまま別の動画を選ぼうとしたら、いきなり捨てずに
    /// 確認を挟む(`pendingSelectionPath`)。同じ動画なら何もしない。
    /// - Returns: その場で切り替えたら true。確認待ちなら false。
    @discardableResult
    func requestSelectVideo(path: String) -> Bool {
        guard model.allRegisteredVideoPaths.contains(path) else {
            return true
        }
        guard path != resolvedVideoPath() else {
            return true
        }
        guard let current = draft.path.isEmpty ? nil : draft.path,
              isDraftDirty(path: current)
        else {
            selectVideo(path: path)
            return true
        }
        pendingSelectionPath = path
        return false
    }

    /// 確認ダイアログの「破棄して切り替える」。
    func confirmPendingSelection(savingFirst: Bool) {
        guard let path = pendingSelectionPath else {
            return
        }
        if savingFirst, !draft.path.isEmpty {
            commit(path: draft.path)
        }
        pendingSelectionPath = nil
        selectVideo(path: path)
    }

    func cancelPendingSelection() {
        pendingSelectionPath = nil
    }

    func selectVideo(path: String) {
        guard model.allRegisteredVideoPaths.contains(path) else {
            return
        }
        selectedVideoPath = path
        syncDraftWithCurrentSelection()
    }

    // MARK: - ドラフトの読み書き

    /// - Parameter force: 未保存の変更があっても読み直す(「変更を破棄」用)。
    func syncDraftWithCurrentSelection(force: Bool = false) {
        guard isActive else {
            return
        }
        guard let path = resolvedVideoPath(), !path.isEmpty else {
            draft = WallpaperEditDraft()
            history.clear()
            refreshHistoryFlags()
            return
        }
        // 同じ動画を編集し続けている最中の再読み込みは、未保存の変更を黙って
        // 捨てることになる。タブを往復しただけ・スケジュールや集中モードが
        // 壁紙を切り替えただけでも呼ばれる経路なので、dirty なら見送る。
        if !force, draft.matches(path: path), isDraftDirty(path: path) {
            return
        }
        loadDraft(path: path)
    }

    func loadDraft(path: String) {
        let existing = model.wallpaperEdit(for: path)
        let isSamePath = draft.path == path
        var loaded = WallpaperEditDraft(
            path: path,
            trimStart: existing?.trimStart ?? 0,
            trimEnd: existing?.trimEnd,
            loopStart: existing?.loopStart,
            assetDuration: isSamePath ? draft.assetDuration : 0
        )
        loaded.frameRate = isSamePath ? draft.frameRate : 30

        draft = loaded
        history.clear()
        refreshHistoryFlags()

        if loaded.assetDuration <= 0 {
            loadAssetDuration(path: path)
        } else {
            resetTimelineWindow()
        }
        playheadTime = loaded.trimStart
        seekRequest = SeekToken(time: loaded.trimStart)

        if !isSamePath {
            keyframeTimes = []
            keyframeIndexedPath = nil
        }
        loadKeyframesIfNeeded()
    }

    private func loadAssetDuration(path: String) {
        durationLoadTask?.cancel()
        didFailToLoadAsset = false
        let url = URL(fileURLWithPath: path)
        durationLoadTask = Task { [weak self] in
            let asset = AVURLAsset(url: url)
            let duration = await (try? asset.load(.duration).seconds) ?? 0
            let frameRate = await Self.loadFrameRate(asset: asset)
            guard let self, !Task.isCancelled, draft.path == path else {
                return
            }
            guard duration.isFinite, duration > 0 else {
                // ここで諦めないと、UIは永久にスピナーを回し続ける。
                didFailToLoadAsset = true
                return
            }
            draft.assetDuration = duration
            draft.frameRate = frameRate
            if let trimEnd = draft.trimEnd, trimEnd > draft.maximumTrimEnd {
                draft.trimEnd = draft.maximumTrimEnd
            }
            if let loopStart = draft.loopStart, loopStart >= draft.effectiveTrimEnd {
                draft.loopStart = nil
            }
            resetTimelineWindow()
        }
    }

    private static func loadFrameRate(asset: AVURLAsset) async -> Double {
        guard
            let tracks = try? await asset.loadTracks(withMediaType: .video),
            let track = tracks.first,
            let rate = try? await track.load(.nominalFrameRate),
            rate.isFinite, rate > 0
        else {
            return 30
        }
        return Double(rate)
    }

    /// 尺の読み込みに失敗したあとの「再試行」。
    func retryAssetLoad() {
        guard let path = resolvedVideoPath(), !path.isEmpty else {
            return
        }
        loadAssetDuration(path: path)
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

    /// 値を書き換えるときに履歴へ積む共通処理。`coalescingKey` が同じ操作が
    /// 続く間は1手にまとまる(ドラッグ1回で ⌘Z 1回)。
    ///
    /// 値が実際に変わらなかった呼び出し(端でクランプされ続けるドラッグ、
    /// 既にnilのものをnilにする操作)は履歴に積まない。積んでしまうと ⌘Z が
    /// 何度押しても何も起きない「空打ち」になる。
    func mutateDraft(coalescingKey: String?, _ body: () -> Void) {
        let before = draft.snapshot
        body()
        guard draft.snapshot != before else {
            return
        }
        history.record(before, coalescingKey: coalescingKey)
        refreshHistoryFlags()
    }

    func refreshHistoryFlags() {
        canUndo = history.canUndo
        canRedo = history.canRedo
    }

    /// ドラッグやキーリピートの区切り。次の編集から新しい1手にする。
    func endInteractiveEdit() {
        history.breakCoalescing()
    }

    func undo() {
        guard let previous = history.undo(current: draft.snapshot) else {
            return
        }
        draft.apply(previous)
        refreshHistoryFlags()
        seek(to: draft.trimStart)
    }

    func redo() {
        guard let next = history.redo(current: draft.snapshot) else {
            return
        }
        draft.apply(next)
        refreshHistoryFlags()
        seek(to: draft.trimStart)
    }

    /// - Parameter snapping: ドラッグ由来の呼び出しだけ true。キーフレーム吸着は
    ///   「掴んで動かした」ときの補助であって、数値入力やI/Oキーで指定した位置を
    ///   勝手にずらすべきではない。
    func setDraftTrimStart(_ value: Double, snapping: Bool = false) {
        mutateDraft(coalescingKey: "trimStart") {
            let snapped = snapping ? snappedToKeyframe(value) : value
            let clamped = min(max(snapped, 0), draft.effectiveTrimEnd - minimumSegmentDuration)
            draft.trimStart = max(clamped, 0)
            if let loopStart = draft.loopStart, loopStart < draft.trimStart {
                draft.loopStart = draft.trimStart
            }
        }
        seek(to: draft.trimStart)
    }

    func setDraftTrimEnd(_ value: Double, snapping: Bool = false) {
        mutateDraft(coalescingKey: "trimEnd") {
            let snapped = snapping ? snappedToKeyframe(value) : value
            let minEnd = draft.trimStart + minimumSegmentDuration
            let maxEnd = draft.assetDuration > 0 ? draft.maximumTrimEnd : snapped
            draft.trimEnd = min(max(snapped, minEnd), maxEnd)
            // ループ開始位置が新しいカット終了位置に追い越されたら、指定ごと捨てる
            // (半端な位置に丸めるより「途中ループOFF」へ戻した方が分かりやすい)。
            if let loopStart = draft.loopStart,
               loopStart > draft.effectiveTrimEnd - minimumSegmentDuration
            {
                draft.loopStart = nil
            }
        }
        seek(to: draft.effectiveTrimEnd)
    }

    /// ループ開始位置(オレンジのハンドル)。カット範囲の内側へ必ずクランプする。
    ///
    /// 下限が `trimStart` ちょうどではなく `introMinimumLeadIn` ぶん内側なのは、
    /// カット開始位置と同じ値は保存時に `loopSafeLoopStart` が捨ててしまい、
    /// 「保存したのにチェックが外れる」という食い違いになるため。UIで作れる値は
    /// 常に保存できる値と一致させる。
    func setDraftLoopStart(_ value: Double?, snapping: Bool = false) {
        guard let value else {
            mutateDraft(coalescingKey: nil) {
                draft.loopStart = nil
            }
            return
        }
        let lowerBound = draft.trimStart + WallpaperLoopBuilder.introMinimumLeadIn
        let upperBound = draft.effectiveTrimEnd - minimumSegmentDuration
        guard upperBound >= lowerBound else {
            // カット範囲が短すぎて、イントロを置く余地がない。
            mutateDraft(coalescingKey: nil) {
                draft.loopStart = nil
            }
            return
        }
        var clamped = value
        mutateDraft(coalescingKey: "loopStart") {
            let snapped = snapping ? snappedToKeyframe(value) : value
            clamped = min(max(snapped, lowerBound), upperBound)
            draft.loopStart = clamped
        }
        seek(to: clamped)
    }

    /// 「途中からループする」チェックボックス。ONにしたときの初期値はカット範囲の
    /// 中間点(どこに置けばよいか分からないハンドルを、まず見える位置に出す)。
    func toggleCustomLoopStart(_ enabled: Bool) {
        endInteractiveEdit()
        guard enabled else {
            mutateDraft(coalescingKey: nil) {
                draft.loopStart = nil
            }
            return
        }
        guard draft.loopStart == nil else {
            return
        }
        setDraftLoopStart((draft.trimStart + draft.effectiveTrimEnd) / 2)
        endInteractiveEdit()
    }

    /// トラック上の空白部分をクリック/ドラッグした際のシーク。ハンドル操作と
    /// 違ってドラフトの値は変えず、プレビューの再生位置だけを動かす。
    func seek(to time: Double) {
        let upperBound = draft.assetDuration > 0 ? draft.assetDuration : time
        let clamped = min(max(time.isFinite ? time : 0, 0), upperBound)
        playheadTime = clamped
        seekRequest = SeekToken(time: clamped)
    }

    var minimumSegmentDuration: Double {
        0.5
    }

    // MARK: - 再生位置からハンドルを置く

    func setTrimStartToPlayhead() {
        endInteractiveEdit()
        setDraftTrimStart(playheadTime)
        endInteractiveEdit()
    }

    func setTrimEndToPlayhead() {
        endInteractiveEdit()
        setDraftTrimEnd(playheadTime)
        endInteractiveEdit()
    }

    func setLoopStartToPlayhead() {
        endInteractiveEdit()
        setDraftLoopStart(playheadTime)
        endInteractiveEdit()
    }

    func togglePlayback() {
        isPreviewPlaying.toggle()
    }

    /// 矢印キーの1コマ送り。再生中に動かすとすぐ流されて意味がないので止める。
    func stepPlayhead(byFrames frames: Double) {
        isPreviewPlaying = false
        seek(to: playheadTime + frames * draft.frameDuration)
    }

    func stepPlayhead(bySeconds seconds: Double) {
        isPreviewPlaying = false
        seek(to: playheadTime + seconds)
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
        endInteractiveEdit()
        showSavedFeedback()
    }

    func resetDraft() {
        endInteractiveEdit()
        mutateDraft(coalescingKey: nil) {
            draft.trimStart = 0
            draft.trimEnd = nil
            draft.loopStart = nil
        }
        resetTimelineWindow()
        seek(to: 0)
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
        if let pending = pendingSelectionPath, !valid.contains(pending) {
            pendingSelectionPath = nil
        }
        if needsResync {
            // 消えた動画のドラフトは「未保存だから残す」対象ではない。
            syncDraftWithCurrentSelection(force: true)
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
