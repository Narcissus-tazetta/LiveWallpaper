import Foundation

@MainActor
extension WallpaperModel {
    func refreshReconvertedWallpapers(itemIDs: [String], backupPath: String) async -> [String] {
        var failures: [String] = []
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = support.appendingPathComponent("we-import/Wallpapers")
        let backupRoot = URL(fileURLWithPath: backupPath).appendingPathComponent("Library", isDirectory: true)
        for id in itemIDs {
            guard let path = importedExternalWallpaperPaths["we-import.json/\(id)"] else { continue }
            let source = root.appendingPathComponent("we-\(id)")
            do {
                struct Metadata: Decodable { let isScene: Bool?; let isWeb: Bool? }
                let metadata = try JSONDecoder().decode(Metadata.self, from: Data(contentsOf: source.appendingPathComponent("info.json")))
                if metadata.isScene == true {
                    flushSceneSave(path: path)
                    cancelSceneBake(path: path)
                    let scene = try await Task.detached(priority: .utility) {
                        try await ReconvertedSceneFiles.replace(source: source.appendingPathComponent("wallpaper.scene"),
                                                                videoPath: path, backup: backupRoot.appendingPathComponent(id))
                    }.value
                    sceneHistories.removeValue(forKey: path)
                    sceneComparisonSnapshots.removeValue(forKey: path)
                    registerImportedScene(scene, path: path)
                    scheduleSceneBake(path: path)
                    reloadPlayback(forRewrittenPath: path)
                    NotificationCenter.default.post(name: .sceneDidBake, object: path)
                } else if metadata.isWeb == true {
                    guard let index = webWallpaperSources.firstIndex(where: { $0.url.path == path }),
                          let folder = webWallpaperSources[index].localFolderPath else { continue }
                    let wallpaperID = webWallpaperSources[index].id
                    let destination = URL(fileURLWithPath: folder)
                    let package = try await Task.detached(priority: .utility) {
                        let staging = destination.deletingLastPathComponent().appendingPathComponent(".reconvert-\(UUID().uuidString)")
                        try LocalWebWallpaperPackage.copy(from: source.appendingPathComponent("wallpaper.web"), to: staging)
                        do {
                            let package = try LocalWebWallpaperPackage.load(folder: staging)
                            try fm.createDirectory(at: backupRoot, withIntermediateDirectories: true)
                            try fm.copyItem(at: destination, to: backupRoot.appendingPathComponent("\(id).web"))
                            _ = try fm.replaceItemAt(destination, withItemAt: staging)
                            return package
                        } catch {
                            if fm.fileExists(atPath: staging.path) { try fm.removeItem(at: staging) }
                            throw error
                        }
                    }.value
                    guard let index = webWallpaperSources.firstIndex(where: { $0.id == wallpaperID }) else { continue }
                    localWebWallpaperServer.remove(folder: destination)
                    webWallpaperSources[index].url = destination.appendingPathComponent(package.entryPoint)
                    webWallpaperSources[index].warnings = package.warnings
                    webWallpaperSources[index].thumbnailPath = package.preview.map { destination.appendingPathComponent($0).path }
                    importedExternalWallpaperPaths["we-import.json/\(id)"] = webWallpaperSources[index].url.path
                    persistWebWallpaperState()
                    UserDefaults.standard.set(importedExternalWallpaperPaths, forKey: PrefsKey.importedExternalWallpapers)
                    NotificationCenter.default.post(name: .reconvertedWebWallpaper, object: wallpaperID)
                } else {
                    let destination = URL(fileURLWithPath: path)
                    try await Task.detached(priority: .utility) {
                        let staging = destination.deletingLastPathComponent().appendingPathComponent(".reconvert-\(UUID().uuidString).mp4")
                        try fm.copyItem(at: source.appendingPathComponent("video.mp4"), to: staging)
                        do {
                            try fm.createDirectory(at: backupRoot, withIntermediateDirectories: true)
                            try fm.copyItem(at: destination, to: backupRoot.appendingPathComponent("\(id).mp4"))
                            _ = try fm.replaceItemAt(destination, withItemAt: staging)
                        } catch {
                            if fm.fileExists(atPath: staging.path) { try fm.removeItem(at: staging) }
                            throw error
                        }
                    }.value
                    try await Task.detached(priority: .utility) {
                        try ReconvertedSceneFiles.writePreview(video: destination, destination: VideoThumbnailGenerator.expectedSidecarURL(for: path))
                    }.value
                    reloadPlayback(forRewrittenPath: path)
                    NotificationCenter.default.post(name: .sceneDidBake, object: path)
                }
            } catch {
                AppLog.externalWallpapers.error("library reconversion \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                failures.append("\(id): \(error.localizedDescription)")
            }
        }
        scheduleWindowRebuild(delay: 0.05)
        refreshLocalWebEnvironment()
        return failures
    }
}

extension Notification.Name {
    static let reconvertedWebWallpaper = Notification.Name("ReconvertedWebWallpaper")
}
