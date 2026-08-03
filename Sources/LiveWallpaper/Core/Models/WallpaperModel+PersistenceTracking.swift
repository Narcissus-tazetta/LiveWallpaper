import Foundation

@MainActor
extension WallpaperModel {
    private var persistenceFailureThreshold: Int {
        3
    }

    private var statePersistDelay: TimeInterval {
        0.25
    }

    func recordPersistenceSuccess() {
        persistenceFailureCount = 0
        persistenceFailureMessage = nil
    }

    func recordPersistenceFailure(key: String, error: Error) {
        persistenceFailureCount += 1
        AppLog.persistence.error("failed key=\(key, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        guard persistenceFailureCount >= persistenceFailureThreshold else {
            return
        }
        persistenceFailureMessage = localizedString(
            "設定の保存に失敗しています。空き容量などを確認してください。"
        )
    }

    func schedulePersistedStateFlush() {
        statePersistWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.flushPersistedState()
        }
        statePersistWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + statePersistDelay, execute: workItem)
    }

    func persistPlaylistStateImmediately() {
        statePersistWorkItem?.cancel()
        statePersistWorkItem = nil
        flushPersistedState()
    }

    func flushPersistedState() {
        do {
            let playlistData = try JSONEncoder().encode(playlists)
            UserDefaults.standard.set(playlistData, forKey: PrefsKey.playlistsData)
            UserDefaults.standard.set(libraryVideoPaths, forKey: PrefsKey.libraryVideoPaths)
            // 旧バージョンへ戻した場合の移行元として、旧キーにもライブラリ全体を書いておく
            UserDefaults.standard.set(libraryVideoPaths, forKey: PrefsKey.registeredVideoPaths)
            UserDefaults.standard.set(selectedPlaylistID?.uuidString, forKey: PrefsKey.selectedPlaylistID)
            let presentationData = try JSONEncoder().encode(wallpaperPresentationByPath)
            UserDefaults.standard.set(presentationData, forKey: wallpaperPresentationStorageKey)
            let editData = try JSONEncoder().encode(wallpaperEditByPath)
            UserDefaults.standard.set(editData, forKey: wallpaperEditStorageKey)
            let webData = try JSONEncoder().encode(webWallpaperSources)
            UserDefaults.standard.set(webData, forKey: PrefsKey.webWallpaperSourcesData)
            let scheduleData = try JSONEncoder().encode(scheduleRules)
            UserDefaults.standard.set(scheduleData, forKey: PrefsKey.scheduleRulesData)
            UserDefaults.standard.set(
                focusFilterIntegrationEnabled, forKey: PrefsKey.focusFilterIntegrationEnabled
            )
            let focusAssignmentsData = try JSONEncoder().encode(focusModeAssignments)
            UserDefaults.standard.set(focusAssignmentsData, forKey: PrefsKey.focusModeAssignmentsData)
            UserDefaults.standard.set(wallpaperKind.rawValue, forKey: PrefsKey.wallpaperKind)
            if let webID = currentWebWallpaperID {
                UserDefaults.standard.set(webID.uuidString, forKey: PrefsKey.currentWebWallpaperID)
            } else {
                UserDefaults.standard.removeObject(forKey: PrefsKey.currentWebWallpaperID)
            }
            recordPersistenceSuccess()
        } catch {
            recordPersistenceFailure(key: "persistedState", error: error)
        }
    }
}
