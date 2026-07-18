import Foundation

@MainActor
extension WallpaperModel {
    /// restoreState() が意図的に省いた「登録済み動画がまだ実在するか」の確認を、
    /// 起動後にバックグラウンドでまとめて行い、消えているものを間引く。
    ///
    /// 間引きの結果は復元時にフィルタしていた頃と同じだが、stat がメインスレッド
    /// から外れるので、外付け・ネットワークボリューム上の動画を登録していても
    /// 起動が止まらない。
    func verifyRestoredVideoPaths() {
        let candidates = restoredVideoPathCandidates()
        guard !candidates.isEmpty else {
            return
        }
        Task.detached(priority: .utility) { [weak self] in
            let missing = candidates.filter { !FileManager.default.fileExists(atPath: $0) }
            guard !missing.isEmpty else {
                return
            }
            await self?.pruneMissingVideoPaths(missing)
        }
    }

    private func restoredVideoPathCandidates() -> [String] {
        var candidates = Set(libraryVideoPaths)
        candidates.formUnion(playlists.flatMap(\.videoPaths))
        candidates.formUnion(videoOverrideByScreenID.values)
        candidates.formUnion(videoBySpaceUUID.values)
        if let currentVideoPath {
            candidates.insert(currentVideoPath)
        }
        return Array(candidates)
    }

    /// 欠損パスを間引く順番。再生中の動画は必ず最後に回す。
    /// removeRegisteredVideo() は再生中の動画を消すと残りのキューから次を選んで
    /// 再生し直すので、先に他の欠損を片付けておかないと「同じく存在しない動画」を
    /// 選んでしまい、実在する動画に落ち着くまで無駄な再生開始を繰り返す。
    static func orderedMissingPathsForPruning(
        _ missing: [String],
        currentPath: String?
    ) -> [String] {
        missing.filter { $0 != currentPath } + missing.filter { $0 == currentPath }
    }

    private func pruneMissingVideoPaths(_ missing: [String]) {
        let ordered = Self.orderedMissingPathsForPruning(missing, currentPath: currentVideoPath)

        for path in ordered {
            // ライブラリ登録済みなら、プレイリスト・ディスプレイ別/Space別の割り当て・
            // 表示名・ロック画面・再生中参照まで既存の削除経路がまとめて片付ける。
            if libraryVideoPaths.contains(path) {
                removeRegisteredVideo(path: path)
                continue
            }
            // ライブラリに無いのに割り当てだけ残っている参照(旧データなど)。
            clearVideoOverrides(forPath: path)
            clearSpaceVideos(forPath: path)
            clearLockScreenVideoIfMissing(path: path)
        }
        pruneWallpaperPresentationsForExistingPaths()
        AppLog.persistence.debug(
            "pruned missing video paths count=\(ordered.count)"
        )
    }
}
