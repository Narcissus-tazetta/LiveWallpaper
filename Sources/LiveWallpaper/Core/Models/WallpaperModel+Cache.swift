import AppKit
import Foundation

@MainActor
extension WallpaperModel {
    func openCacheFolder() {
        guard let directory: URL = cacheDirectoryURL() else {
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            NSWorkspace.shared.open(directory)
        } catch {
            return
        }
    }

    func clearCache() -> Bool {
        guard let directory = cacheDirectoryURL() else {
            return false
        }

        let thumbnailDirectory = thumbnailCacheDirectoryURL()

        do {
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
            if let thumbnailDirectory,
               FileManager.default.fileExists(atPath: thumbnailDirectory.path)
            {
                try FileManager.default.removeItem(at: thumbnailDirectory)
            }
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            if let thumbnailDirectory {
                try FileManager.default.createDirectory(
                    at: thumbnailDirectory,
                    withIntermediateDirectories: true
                )
            }
            playlists.removeAll()
            selectedPlaylistID = nil
            registeredVideoPaths.removeAll()
            UserDefaults.standard.removeObject(forKey: "registeredVideoPaths")
            registeredVideoDisplayNames.removeAll()
            UserDefaults.standard.set(
                registeredVideoDisplayNames,
                forKey: "registeredVideoDisplayNames"
            )
            wallpaperPresentationByPath.removeAll()
            UserDefaults.standard.removeObject(forKey: wallpaperPresentationStorageKey)
            clearWebWallpaperState()
            stopAllPlayers()
            currentVideoPath = nil
            currentVideoIndex = nil
            UserDefaults.standard.removeObject(forKey: "videoPath")
            persistPlaylistStateImmediately()
            evaluateForegroundCoverageState()
            NotificationCenter.default.post(name: .thumbnailCacheDidClear, object: nil)
            return true
        } catch {
            return false
        }
    }

    func cacheDirectoryURL() -> URL? {
        guard
            let appSupportURL: URL = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        else {
            return nil
        }

        return
            appSupportURL
                .appendingPathComponent("LiveWallpaper", isDirectory: true)
                .appendingPathComponent("Videos", isDirectory: true)
    }

    func thumbnailCacheDirectoryURL() -> URL? {
        guard
            let appSupportURL: URL = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        else {
            return nil
        }

        return
            appSupportURL
                .appendingPathComponent("LiveWallpaper", isDirectory: true)
                .appendingPathComponent("ThumbnailCache", isDirectory: true)
    }

    func importVideoToAppSupport(from sourceURL: URL) async -> URL? {
        let fileManager = FileManager.default
        guard let targetDirectory: URL = cacheDirectoryURL() else {
            return nil
        }

        do {
            try fileManager.createDirectory(
                at: targetDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            return nil
        }

        let ext: String = sourceURL.pathExtension.isEmpty ? "mp4" : sourceURL.pathExtension
        let targetURL: URL = targetDirectory.appendingPathComponent(
            "wallpaper-\(UUID().uuidString).\(ext)"
        )

        return await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            do {
                try fileManager.createDirectory(
                    at: targetDirectory,
                    withIntermediateDirectories: true
                )
                try fileManager.copyItem(at: sourceURL, to: targetURL)
                return targetURL
            } catch {
                return nil
            }
        }.value
    }
}
