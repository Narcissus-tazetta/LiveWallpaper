import AppKit

/// ディスプレイごとの Web 壁紙固定。
/// 指定した画面だけ別の Web 壁紙を表示し、それ以外の画面は共有の壁紙(動画または
/// 共有の Web 壁紙)に従う。画面ごとの動画固定(videoOverrideByScreenID)とは排他。
///
/// 割り切り:
/// - 固定した画面の Web 壁紙は消音(音は共有の壁紙だけ)。
/// - 共有が Web 壁紙のとき、別の画面を動画に固定することはできない。
/// - 再生キュー・自動切り替え・Space 別壁紙の対象外。
@MainActor
extension WallpaperModel {
    /// いまウィンドウに載っている Web ビュー。共有の Web 壁紙でも、固定した画面でも、
    /// 画面に出ている WebPlayerView はここに現れる。
    var webPlayerViews: [WebPlayerView] {
        webDisplayEntries.map(\.view)
    }

    var webDisplayEntries: [(displayID: String, view: WebPlayerView)] {
        windows.enumerated().compactMap { index, window in
            guard let view = window.contentView as? WebPlayerView else {
                return nil
            }
            return (displayIDForWindow(at: index), view)
        }
    }

    /// 固定が有効なら、その画面に固定された Web 壁紙。機能OFFや削除済みの壁紙を
    /// 指す固定は無いものとして扱う(割り当てデータ自体は残る)。
    func webOverrideSource(forScreenID screenID: String) -> WebWallpaperSource? {
        guard webWallpaperFeatureEnabled,
              let id = webOverrideByScreenID[screenID]
        else {
            return nil
        }
        return webWallpaperSources.first { $0.id == id }
    }

    func hasWebOverride(forScreenID screenID: String) -> Bool {
        webOverrideSource(forScreenID: screenID) != nil
    }

    /// この画面に表示する Web 壁紙。固定が優先、なければ共有の Web 壁紙。
    func webSource(forScreenID screenID: String) -> WebWallpaperSource? {
        if let source = webOverrideSource(forScreenID: screenID) {
            return source
        }
        return isWebWallpaperActive ? activeWebWallpaperSource : nil
    }

    /// 接続中の画面のどれかに、この Web 壁紙が固定されているか。壁紙一覧のバッジ用。
    func hasLiveWebOverride(forSourceID id: UUID) -> Bool {
        let connected = Set(availableDisplayScreens().map(\.id))
        return webOverrideByScreenID.contains { screenID, assigned in
            assigned == id && connected.contains(screenID)
        }
    }

    /// 接続中の画面のどれかが Web 壁紙を表示するか(共有でも固定でも)。
    var hasWebDisplay: Bool {
        isWebWallpaperActive || targetScreens().contains { hasWebOverride(forScreenID: displayIDString(for: $0)) }
    }

    func setWebOverride(id: UUID?, forScreenID screenID: String) {
        if let id {
            guard webWallpaperFeatureEnabled,
                  webWallpaperSources.contains(where: { $0.id == id }),
                  webOverrideByScreenID[screenID] != id
            else {
                return
            }
            setVideoOverride(path: nil, forScreenID: screenID)
            webOverrideByScreenID[screenID] = id
        } else {
            guard webOverrideByScreenID.removeValue(forKey: screenID) != nil else {
                return
            }
        }
        persistWebOverrides()
        applyWebOverrideChange()
    }

    /// 動画の固定を設定した画面から Web の固定を外す。動画側の applyVideoOverride が呼ぶ。
    func removeWebOverrideForVideoAssignment(forScreenID screenID: String) {
        guard webOverrideByScreenID.removeValue(forKey: screenID) != nil else {
            return
        }
        persistWebOverrides()
        applyWebOverrideChange()
    }

    /// 削除する Web 壁紙への固定をすべて外す。
    func clearWebOverrides(forSourceID id: UUID) {
        let screenIDs = webOverrideByScreenID.filter { $0.value == id }.map(\.key)
        for screenID in screenIDs {
            webOverrideByScreenID.removeValue(forKey: screenID)
        }
        guard !screenIDs.isEmpty else {
            return
        }
        persistWebOverrides()
        applyWebOverrideChange()
    }

    private func applyWebOverrideChange() {
        scheduleWindowRebuild(delay: 0.05)
        evaluateForegroundCoverageState()
    }

    func restoreWebOverrides() {
        guard let saved = UserDefaults.standard.dictionary(forKey: PrefsKey.webOverrideByScreenID)
            as? [String: String]
        else {
            return
        }
        // 壁紙が削除されている場合は webOverrideSource が nil を返して無視する。
        webOverrideByScreenID = saved.compactMapValues { UUID(uuidString: $0) }
    }

    func persistWebOverrides() {
        UserDefaults.standard.set(
            webOverrideByScreenID.mapValues(\.uuidString),
            forKey: PrefsKey.webOverrideByScreenID
        )
    }

    /// ウィンドウに載っている各 Web ビューへ、その画面の壁紙を読み込む。
    /// 同じ壁紙を表示済みのビューは、force でなければ読み込み直さない(別の画面の
    /// 固定を変えただけで、無関係な画面のページが再読み込みされないように)。
    func loadWebDisplays(force: Bool = false) {
        let entries = webDisplayEntries
        guard !entries.isEmpty else {
            webWallpaperLoadState = .loading
            return
        }

        // 共有の壁紙は音あり、固定した画面は消音。同じ壁紙でも音の有無でリクエストが変わる。
        struct Group {
            let source: WebWallpaperSource
            let audio: Bool
            var entries: [(displayID: String, view: WebPlayerView)]
        }
        var groups: [Group] = []
        for entry in entries {
            guard let source = webSource(forScreenID: entry.displayID) else {
                continue
            }
            let audio = audioEnabled && !hasWebOverride(forScreenID: entry.displayID)
            if let index = groups.firstIndex(where: { $0.source.id == source.id && $0.audio == audio }) {
                groups[index].entries.append(entry)
            } else {
                groups.append(Group(source: source, audio: audio, entries: [entry]))
            }
        }

        localWebLoadTask?.cancel()
        // 読み込み状態の表示は、共有の壁紙(なければ最初の画面)のビューに限る。
        let stateReporter = (groups.first { $0.audio || isWebWallpaperActive } ?? groups.first)?.entries.first?.view
        for entry in entries {
            entry.view.onLoadStateChanged = entry.view === stateReporter
                ? { [weak self] state in self?.webWallpaperLoadState = state }
                : nil
        }

        localWebLoadTask = Task { [weak self] in
            guard let self else { return }
            for group in groups {
                let pending = group.entries.filter {
                    force || $0.view.loadedSourceID != group.source.id || $0.view.loadedWithAudio != group.audio
                }
                guard !pending.isEmpty else { continue }
                do {
                    let request = try await webPlaybackRequest(for: group.source, audio: group.audio)
                    try Task.checkCancellation()
                    for entry in pending where webSource(forScreenID: entry.displayID)?.id == group.source.id {
                        configureLocalWebEnvironment(entry.view)
                        entry.view.loadedSourceID = group.source.id
                        entry.view.loadedWithAudio = group.audio
                        entry.view.load(request: request, audioEnabled: group.audio)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    webWallpaperLoadState = .failed
                    webWallpaperErrorMessage = error.localizedDescription
                    AppLog.externalWallpapers.error("local web load failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private func webPlaybackRequest(for source: WebWallpaperSource, audio: Bool) async throws -> WebWallpaperPlaybackRequest {
        if let folder = source.localFolderPath {
            let url = try await localWebWallpaperServer.url(folder: URL(fileURLWithPath: folder))
            return WebWallpaperPlaybackRequest(
                loadContent: .url(url), layoutMode: .generic,
                canonicalKey: "local:\(source.id)", isLocalPackage: true
            )
        }
        return WebWallpaperURLResolver.resolve(originalURL: source.url, audioEnabled: audio)
    }
}
