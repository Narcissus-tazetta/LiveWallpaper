import Foundation

/// Undo/Redo が復元するトリム編集の状態。`WallpaperEditDraft` から
/// 「やり直しの対象になる値」だけを抜き出したもの(パスや尺は履歴で戻さない)。
struct TrimEditSnapshot: Equatable {
    var trimStart: Double
    var trimEnd: Double?
    var loopStart: Double?
}

typealias TrimEditHistory = EditHistory<TrimEditSnapshot>

/// 編集の取り消し履歴(トリム編集とシーン編集で共用)。
///
/// ドラッグやキーリピートは1操作で何十回も値を書き換えるため、素直に毎回
/// 積むと ⌘Z が1ピクセルずつしか戻らず使い物にならない。`coalescingKey` が
/// 同じ間は最初の1つだけを残し、別の操作が挟まる(= キーが変わる、または
/// `breakCoalescing()` が呼ばれる)と次から新しい区切りになる。
///
/// 時間ベースの合流にしていないのは、テストが実時間に依存してしまうのと、
/// 「ドラッグが終わった」という確かな境界がUI側にあるため。
struct EditHistory<Snapshot> {
    /// 保持する上限。壁紙1本の編集でこれ以上遡りたいことはまず無く、
    /// 上限を設けないと長時間の編集で際限なく積み上がる。
    static var limit: Int {
        100
    }

    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var lastKey: String?

    var canUndo: Bool {
        !undoStack.isEmpty
    }

    var canRedo: Bool {
        !redoStack.isEmpty
    }

    /// Every state undo or redo can bring back.
    var snapshots: [Snapshot] {
        undoStack + redoStack
    }

    /// 別の動画を読み込んだときなど、履歴ごと捨てる。
    mutating func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
        lastKey = nil
    }

    /// 値を書き換える **直前** の状態を記録する。
    /// - Parameter coalescingKey: 連続操作をまとめる単位。nil なら常に独立した
    ///   1手として積む。
    mutating func record(_ snapshot: Snapshot, coalescingKey: String?) {
        redoStack.removeAll()
        if let coalescingKey, coalescingKey == lastKey, !undoStack.isEmpty {
            // 同じ操作の続き: 最初に積んだ「操作前の状態」をそのまま活かす。
            return
        }
        lastKey = coalescingKey
        undoStack.append(snapshot)
        if undoStack.count > Self.limit {
            undoStack.removeFirst(undoStack.count - Self.limit)
        }
    }

    /// 次の `record` を必ず新しい1手にする(ドラッグ終了、フォーカス移動など)。
    mutating func breakCoalescing() {
        lastKey = nil
    }

    mutating func undo(current: Snapshot) -> Snapshot? {
        guard let previous = undoStack.popLast() else {
            return nil
        }
        redoStack.append(current)
        lastKey = nil
        return previous
    }

    mutating func redo(current: Snapshot) -> Snapshot? {
        guard let next = redoStack.popLast() else {
            return nil
        }
        undoStack.append(current)
        lastKey = nil
        return next
    }
}
