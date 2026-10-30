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
            guard let path = importedExternalWallpaperPaths["we-import.json/\(id)"], fm.fileExists(atPath: path) else { continue }
            let source = root.appendingPathComponent("we-\(id)")
            do {
                struct Metadata: Decodable { let isScene: Bool?; let isWeb: Bool? }
                let metadata = try JSONDecoder().decode(Metadata.self, from: Data(contentsOf: source.appendingPathComponent("info.json")))
                if metadata.isScene == true {
                    flushSceneSave(path: path)
                    cancelSceneBake(path: path)
                    // The document is only in memory once the wallpaper has been shown this session;
                    // without it the allowed scripts could not be recognised after the rewrite.
                    var previous = sceneDocumentsByPath[path]
                    if previous == nil {
                        do {
                            previous = try SceneStore.load(videoPath: path).map { SceneScriptPermissions.restored($0, path: path) }
                        } catch {
                            AppLog.externalWallpapers.error("previous scene of \(id, privacy: .public) not read: \(error.localizedDescription, privacy: .public)")
                        }
                    }
                    let scene = try await Task.detached(priority: .utility) {
                        try await ReconvertedSceneFiles.replace(source: source.appendingPathComponent("wallpaper.scene"),
                                                                videoPath: path, backup: backupRoot.appendingPathComponent(id))
                    }.value
                    sceneHistories.removeValue(forKey: path)
                    sceneComparisonSnapshots.removeValue(forKey: path)
                    SceneScriptPermissions.carry(scene, replacing: previous, path: path)
                    registerImportedScene(scene, path: path)
                    let unapproved = sceneDocumentsByPath[path]?.scripts.filter { !$0.isAuthorized }.count ?? -1
                    AppLog.externalWallpapers.info("""
                    reconverted \(id, privacy: .public): previous \(previous == nil ? "none" : "found", privacy: .public), \
                    previous scripts \(previous?.scripts.count ?? -1, privacy: .public) allowed \(previous?.scripts.allSatisfy(\.isAuthorized) == true, privacy: .public), \
                    origin \(scene.scriptOrigin == nil ? "none" : (scene.scriptOrigin == previous?.scriptOrigin ? "same" : "changed"), privacy: .public), \
                    unapproved after \(unapproved, privacy: .public)
                    """)
                    requestSceneScriptApproval(id: "we-import.json/\(id)", name: registeredVideoDisplayName(for: path), path: path)
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
