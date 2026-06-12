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
        NSLog("[Persistence] failed key=\(key) error=\(error.localizedDescription)")
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
            UserDefaults.standard.set(playlistData, forKey: "playlistsData")
            UserDefaults.standard.set(registeredVideoPaths, forKey: "registeredVideoPaths")
            UserDefaults.standard.set(selectedPlaylistID?.uuidString, forKey: "selectedPlaylistID")
            let presentationData = try JSONEncoder().encode(wallpaperPresentationByPath)
            UserDefaults.standard.set(presentationData, forKey: wallpaperPresentationStorageKey)
            recordPersistenceSuccess()
        } catch {
            recordPersistenceFailure(key: "persistedState", error: error)
        }
    }
}
