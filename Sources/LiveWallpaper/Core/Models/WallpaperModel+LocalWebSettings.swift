import Foundation

@MainActor
extension WallpaperModel {
    func localWebConfiguration(for source: WebWallpaperSource) throws
        -> (LocalWebWallpaperPackage, LocalWebSettings)
    {
        let package = try LocalWebWallpaperPackage
            .load(folder: URL(fileURLWithPath: source.localFolderPath!))
        return try (package, LocalWebSettings.load(id: source.id))
    }

    func saveLocalWebSettings(_ settings: LocalWebSettings, source: WebWallpaperSource) throws {
        try settings.save(id: source.id)
        refreshLocalWebEnvironment()
    }

    func configureLocalWebProperties(_ view: WebPlayerView) {
        // Each screen may show its own wallpaper, so the view's screen picks the source.
        let source = webDisplayEntries.first { $0.view === view }.flatMap { webSource(forScreenID: $0.displayID) }
        guard let source, source.localFolderPath != nil else {
            view.setDisplayAdjustment(WebDisplayAdjustment())
            return
        }
        do {
            let (package, settings) = try localWebConfiguration(for: source)
            var values = Dictionary((package.properties ?? []).map { (
                $0.id,
                $0.value
            ) }, uniquingKeysWith: { _, last in last })
            values.merge(settings.values) { _, new in new }
            view.setLocalConfiguration(
                values: values,
                settings: settings,
                assets: (package.properties ?? []).filter { $0.kind == "file" }.map(\.id)
            )
            view.setDisplayAdjustment(WebDisplayAdjustment(keys: package.displayAdjustment, values: values))
        } catch {
            webWallpaperErrorMessage = error.localizedDescription
            AppLog.externalWallpapers
                .error("web settings failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func importLocalWebPropertyFile(_ url: URL, source: WebWallpaperSource) async throws -> String {
        let folder = URL(fileURLWithPath: source.localFolderPath!)
        let relative = ".livewallpaper-assets/\(UUID().uuidString).\(url.pathExtension)"
        let destination = folder.appendingPathComponent(relative)
        try await Task.detached(priority: .userInitiated) {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: url, to: destination)
        }.value
        return relative
    }

    func hasAuthorSettings(forPath path: String) -> Bool {
        if let properties = sceneDocumentsByPath[path]?.properties {
            return !properties.isEmpty
        }
        let propURL = SceneStore.folderURL(forVideoPath: path).appendingPathComponent("properties.json")
        if FileManager.default.fileExists(atPath: propURL.path) {
            if let data = try? Data(contentsOf: propURL),
               let props = try? JSONDecoder().decode([LocalWebProperty].self, from: data) {
                return !props.isEmpty
            }
            return false
        }
        if let properties = legacyAuthorProperties(forPath: path) {
            return !properties.isEmpty
        }
        let sceneURL = SceneStore.folderURL(forVideoPath: path).appendingPathComponent("scene.json")
        if FileManager.default.fileExists(atPath: sceneURL.path) {
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: sceneURL.path)[.size] as? Int64) ?? 0
            if fileSize > 0, fileSize <= 5 * 1024 * 1024,
               let data = try? Data(contentsOf: sceneURL),
               let header = try? JSONDecoder().decode(ScenePropertiesHeader.self, from: data),
               let props = header.properties {
                return !props.isEmpty
            }
        }
        return false
    }

    private func legacyAuthorProperties(forPath path: String) -> [LocalWebProperty]? {
        guard let externalID = importedExternalWallpaperPaths.first(where: { $0.value == path })?.key else { return nil }
        let wallpaper = externalWallpapers.first { $0.id == externalID }
        if let properties = wallpaper?.properties { return properties }
        var folders = wallpaper?.sceneFolderPath.map { [URL(fileURLWithPath: $0)] } ?? []
        let prefix = "we-import.json/"
        if externalID.hasPrefix(prefix) {
            let itemID = String(externalID.dropFirst(prefix.count))
            if !itemID.isEmpty, itemID.allSatisfy({ $0.isASCII && $0.isNumber }) {
                let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                folders.append(support.appendingPathComponent("we-import/Wallpapers/we-\(itemID)/wallpaper.scene"))
            }
        }
        for folder in folders {
            let file = folder.appendingPathComponent("properties.json")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            do {
                return try JSONDecoder().decode([LocalWebProperty].self, from: Data(contentsOf: file))
            } catch {
                AppLog.externalWallpapers.error("legacy author settings schema failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        return nil
    }

    func hasAuthorSettings(forExternalWallpaper wallpaper: ExternalWallpaper) -> Bool {
        if let source = wallpaper.webSource, let folder = source.localFolderPath {
            guard let package = try? LocalWebWallpaperPackage.load(folder: URL(fileURLWithPath: folder)) else { return false }
            return !(package.properties ?? []).isEmpty || package.supportsSpectrum == true || package.supportsMedia == true
        }
        if let props = wallpaper.properties {
            return !props.isEmpty
        }
        if let sceneFolder = wallpaper.sceneFolderPath {
            let propURL = URL(fileURLWithPath: sceneFolder).appendingPathComponent("properties.json")
            if FileManager.default.fileExists(atPath: propURL.path) {
                if let data = try? Data(contentsOf: propURL),
                   let props = try? JSONDecoder().decode([LocalWebProperty].self, from: data) {
                    return !props.isEmpty
                }
                return false
            }
        }
        return false
    }

    func authorSettingsContext(for source: WebWallpaperSource) -> WallpaperAuthorSettingsContext? {
        guard let folderPath = source.localFolderPath,
              let package = try? LocalWebWallpaperPackage.load(folder: URL(fileURLWithPath: folderPath))
        else { return nil }
        let properties = package.properties ?? []
        return WallpaperAuthorSettingsContext(
            id: source.id.uuidString,
            title: source.displayName,
            properties: properties,
            supportsSpectrum: package.supportsSpectrum ?? false,
            supportsMedia: package.supportsMedia ?? false,
            loadSettings: { [weak self] in
                guard let self else { return LocalWebSettings() }
                return try self.localWebConfiguration(for: source).1
            },
            saveSettings: { [weak self] newSettings in
                guard let self else { return }
                try self.saveLocalWebSettings(newSettings, source: source)
            },
            importFile: { [weak self] url in
                guard let self else { throw CocoaError(.fileWriteUnknown) }
                return try await self.importLocalWebPropertyFile(url, source: source)
            }
        )
    }

    func authorSettingsContext(forExternalWallpaper wallpaper: ExternalWallpaper) -> WallpaperAuthorSettingsContext? {
        if let source = wallpaper.webSource {
            return authorSettingsContext(for: source)
        }
        var properties = wallpaper.properties ?? []
        if properties.isEmpty, let sceneFolder = wallpaper.sceneFolderPath {
            let propURL = URL(fileURLWithPath: sceneFolder).appendingPathComponent("properties.json")
            if FileManager.default.fileExists(atPath: propURL.path) {
                if let data = try? Data(contentsOf: propURL),
                   let props = try? JSONDecoder().decode([LocalWebProperty].self, from: data) {
                    properties = props
                }
            }
        }
        guard !properties.isEmpty else { return nil }
        let settingsKey = "authorSettings.external." + wallpaper.id
        return WallpaperAuthorSettingsContext(
            id: wallpaper.id,
            title: wallpaper.name,
            properties: properties,
            loadSettings: {
                try LocalWebSettings.load(key: settingsKey)
            },
            saveSettings: { [weak self] newSettings in
                guard let self else { return }
                try newSettings.save(key: settingsKey)
                try self.applyExternalAuthorSettings(forWallpaper: wallpaper, settings: newSettings)
            },
            applySettings: { [weak self] newSettings in
                guard let self else { return }
                guard self.isExternalWallpaperReady(wallpaper) else {
                    throw SceneAuthorSettingsConversion.ConversionError(message: "壁紙の準備が終わってから、もう一度適用してください。")
                }
                try await self.reconvertSceneAuthorSettings(
                    path: wallpaper.path, externalID: wallpaper.id,
                    sourceFolder: wallpaper.sceneFolderPath, settings: newSettings
                )
                try newSettings.save(key: settingsKey)
            }
        )
    }

    func applyExternalAuthorSettings(forWallpaper wallpaper: ExternalWallpaper, settings: LocalWebSettings) throws {
        var anyViewShowingScene = false
        if !wallpaper.path.isEmpty {
            let normalizedPath = URL(fileURLWithPath: wallpaper.path).standardizedFileURL.path
            try settings.save(key: "authorSettings.scene." + normalizedPath)
            for view in playerViews {
                let matches = view.sceneVideoPath == wallpaper.path
                    || (view.sceneVideoPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path } == normalizedPath)
                if matches {
                    view.updateSceneUserProperties(settings.values)
                    if view.isShowingScene {
                        anyViewShowingScene = true
                    }
                }
            }
        }
        if wallpaper.sceneFolderPath != nil {
            if sceneDocumentsByPath[wallpaper.path] == nil {
                if let loaded = try? SceneStore.load(videoPath: wallpaper.path) {
                    registerImportedScene(loaded, path: wallpaper.path)
                } else if let folder = wallpaper.sceneFolderPath,
                          let data = try? Data(contentsOf: URL(fileURLWithPath: folder).appendingPathComponent("scene.json")),
                          let doc = try? JSONDecoder().decode(SceneDocument.self, from: data) {
                    registerImportedScene(doc, path: wallpaper.path)
                }
            }
            if SceneStore.hasScene(videoPath: wallpaper.path) {
                try SceneStore.markVideoOutOfDate(videoPath: wallpaper.path)
            }
            sceneStaleVideoPaths.insert(wallpaper.path)
            scheduleSceneBake(path: wallpaper.path)
            if !anyViewShowingScene {
                refreshSceneHosts()
            }
        }
    }

    func applySceneAuthorSettings(forPath path: String, settings: LocalWebSettings) throws {
        let userProperties = settings.values
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        var anyViewShowingScene = false
        for view in playerViews {
            let matches = view.sceneVideoPath == path
                || (view.sceneVideoPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path } == normalizedPath)
            if matches {
                view.updateSceneUserProperties(userProperties)
                if view.isShowingScene {
                    anyViewShowingScene = true
                }
            }
        }
        if sceneDocumentsByPath[path] == nil, let loaded = try? SceneStore.load(videoPath: path) {
            sceneDocumentsByPath[path] = SceneScriptPermissions.restored(loaded, path: path)
        }
        if SceneStore.hasScene(videoPath: path) {
            try SceneStore.markVideoOutOfDate(videoPath: path)
        }
        sceneStaleVideoPaths.insert(path)
        scheduleSceneBake(path: path)
        if !anyViewShowingScene {
            refreshSceneHosts()
        }
    }

    func authorSettingsContext(forPath path: String) -> WallpaperAuthorSettingsContext? {
        var properties: [LocalWebProperty]? = sceneDocumentsByPath[path]?.properties
        if properties == nil {
            let propURL = SceneStore.folderURL(forVideoPath: path).appendingPathComponent("properties.json")
            if FileManager.default.fileExists(atPath: propURL.path) {
                if let data = try? Data(contentsOf: propURL),
                   let props = try? JSONDecoder().decode([LocalWebProperty].self, from: data) {
                    properties = props
                }
            } else {
                properties = legacyAuthorProperties(forPath: path)
            }
            if properties == nil {
                let sceneURL = SceneStore.folderURL(forVideoPath: path).appendingPathComponent("scene.json")
                if FileManager.default.fileExists(atPath: sceneURL.path) {
                    let fileSize = (try? FileManager.default.attributesOfItem(atPath: sceneURL.path)[.size] as? Int64) ?? 0
                    if fileSize > 0, fileSize <= 5 * 1024 * 1024,
                       let data = try? Data(contentsOf: sceneURL),
                       let header = try? JSONDecoder().decode(ScenePropertiesHeader.self, from: data) {
                        properties = header.properties
                    }
                }
            }
        }
        guard let properties, !properties.isEmpty else { return nil }
        let title = registeredVideoDisplayName(for: path)
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let settingsKey = "authorSettings.scene." + normalizedPath
        return WallpaperAuthorSettingsContext(
            id: path,
            title: title,
            properties: properties,
            loadSettings: {
                try LocalWebSettings.loadScene(videoPath: path)
            },
            saveSettings: { [weak self] newSettings in
                guard let self else { return }
                try newSettings.save(key: settingsKey)
                try self.applySceneAuthorSettings(forPath: path, settings: newSettings)
            },
            applySettings: { [weak self] newSettings in
                guard let self else { return }
                try await self.reconvertSceneAuthorSettings(path: path, settings: newSettings)
            }
        )
    }

    func reconvertSceneAuthorSettings(
        path: String, externalID: String? = nil, sourceFolder: String? = nil, settings: LocalWebSettings
    ) async throws {
        let externalID = externalID ?? importedExternalWallpaperPaths.first(where: { $0.value == path })?.key
        let itemID = externalID.flatMap { $0.hasPrefix("we-import.json/") ? String($0.dropFirst("we-import.json/".count)) : nil }
        let document: SceneDocument?
        if let loaded = sceneDocumentsByPath[path] {
            document = loaded
        } else {
            document = try await Task.detached {
                if let sourceFolder {
                    return try JSONDecoder().decode(SceneDocument.self, from: Data(contentsOf:
                        URL(fileURLWithPath: sourceFolder).appendingPathComponent("scene.json")))
                }
                return try SceneStore.load(videoPath: path)
            }.value
        }
        guard document?.authorSourceDirectory != nil || itemID != nil else {
            throw SceneAuthorSettingsConversion.ConversionError(message: "元作品の情報がありません。取り込み元アプリで作品を再変換してから追加し直してください。")
        }
        try await SceneAuthorSettingsConversion.apply(
            sourceDirectory: document?.authorSourceDirectory, itemID: itemID, values: settings.values
        ) { source in
            if let current = self.sceneDocumentsByPath[path], current != document {
                throw SceneAuthorSettingsConversion.ConversionError(message: "シーンが編集中に変更されました。もう一度適用してください。")
            }
            self.flushSceneSave(path: path)
            self.cancelSceneBake(path: path)
            let backup = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("LiveWallpaper/AuthorSettingsBackups/\(UUID().uuidString)", isDirectory: true)
            let converted = try await Task.detached(priority: .userInitiated) {
                try await ReconvertedSceneFiles.replace(source: source, videoPath: path, backup: backup, userProperties: settings.values)
            }.value
            let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
            try settings.save(key: "authorSettings.scene." + normalized)
            self.sceneHistories.removeValue(forKey: path)
            self.sceneComparisonSnapshots.removeValue(forKey: path)
            self.registerImportedScene(converted, path: path)
            try self.applySceneAuthorSettings(forPath: path, settings: settings)
            self.reloadPlayback(forRewrittenPath: path)
            self.requestSceneScriptApproval(id: externalID ?? path, name: self.registeredVideoDisplayName(for: path), path: path)
            NotificationCenter.default.post(name: .sceneDidBake, object: path)
        }
    }
}

struct ScenePropertiesHeader: Decodable {
    var properties: [LocalWebProperty]?
}

struct WallpaperAuthorSettingsContext: Identifiable {
    let id: String
    let title: String
    let properties: [LocalWebProperty]
    var supportsSpectrum: Bool = false
    var supportsMedia: Bool = false
    let loadSettings: () throws -> LocalWebSettings
    let saveSettings: (LocalWebSettings) throws -> Void
    var importFile: ((URL) async throws -> String)? = nil
    var applySettings: ((LocalWebSettings) async throws -> Void)? = nil
}
