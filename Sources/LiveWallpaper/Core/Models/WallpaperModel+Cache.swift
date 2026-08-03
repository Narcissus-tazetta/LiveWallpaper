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
            libraryVideoPaths.removeAll()
            registeredVideoPaths.removeAll()
            registeredWebWallpaperIDs.removeAll()
            UserDefaults.standard.removeObject(forKey: PrefsKey.libraryVideoPaths)
            UserDefaults.standard.removeObject(forKey: PrefsKey.registeredVideoPaths)
            registeredVideoDisplayNames.removeAll()
            UserDefaults.standard.set(
                registeredVideoDisplayNames,
                forKey: PrefsKey.registeredVideoDisplayNames
            )
            wallpaperPresentationByPath.removeAll()
            UserDefaults.standard.removeObject(forKey: wallpaperPresentationStorageKey)
            clearWebWallpaperState()
            stopAllPlayers()
            currentVideoPath = nil
            currentVideoIndex = nil
            UserDefaults.standard.removeObject(forKey: PrefsKey.videoPath)
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

        if AnimatedImageTranscoder.isSupportedImageExtension(sourceURL.pathExtension) {
            return await importAnimatedImage(from: sourceURL, targetDirectory: targetDirectory)
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

    /// アニメ画像(GIF/APNG/WebP)をループ動画へ変換してApp Supportに保存する。
    /// 元ファイルはコピーせず、変換後のmp4のみがライブラリに入る。
    private func importAnimatedImage(from sourceURL: URL, targetDirectory: URL) async -> URL? {
        let targetURL = targetDirectory.appendingPathComponent(
            "wallpaper-\(UUID().uuidString).mp4"
        )

        mediaImportErrorMessage = nil
        mediaImportProgress = 0
        isImportingMedia = true
        defer {
            isImportingMedia = false
            activeMediaImportTask = nil
        }

        let throttle = MediaImportProgressThrottle()
        let task = Task.detached(priority: .userInitiated) { [self] () -> Result<URL, Error> in
            do {
                try await AnimatedImageTranscoder.transcode(
                    imageURL: sourceURL,
                    to: targetURL
                ) { value in
                    guard throttle.shouldReport(value) else {
                        return
                    }
                    Task { @MainActor in
                        self.mediaImportProgress = value
                    }
                }
                return .success(targetURL)
            } catch {
                return .failure(error)
            }
        }
        activeMediaImportTask = task

        switch await task.value {
        case .success(let url):
            mediaImportProgress = 1
            return url
        case .failure(let error):
            mediaImportErrorMessage = mediaImportErrorText(for: error)
            return nil
        }
    }

    /// 進行中のアニメ画像変換を中断する(トランスコーダがtmpファイルを掃除する)。
    func cancelMediaImport() {
        activeMediaImportTask?.cancel()
    }

    private func mediaImportErrorText(for error: Error) -> String {
        guard let transcodeError = error as? AnimatedImageTranscoder.TranscodeError else {
            return localizedString("動画への変換に失敗しました。ディスクの空き容量を確認してください。")
        }
        switch transcodeError {
        case .unreadableImage:
            return localizedString("画像を読み込めませんでした。ファイルが壊れている可能性があります。")
        case .zeroFrames, .frameDecodeFailed:
            return localizedString("アニメーションのフレームを取得できませんでした。")
        case .writerSetupFailed, .writerFailed:
            return localizedString("動画への変換に失敗しました。ディスクの空き容量を確認してください。")
        case .cancelled:
            return localizedString("変換をキャンセルしました")
        }
    }
}

/// 進捗更新のMainActorホップがフレーム毎に積み上がらないよう間引く
private final class MediaImportProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastReported: Double = -1

    func shouldReport(_ value: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard value >= 1.0 || value - lastReported >= 0.01 else {
            return false
        }
        lastReported = value
        return true
    }
}
