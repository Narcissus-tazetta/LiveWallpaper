import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension SettingsView {
    func setThumbnailVisibility(path: String, isVisible: Bool) {
        thumbnailCache.setVisible(path: path, isVisible: isVisible)
    }

    func requestWallpaperThumbnail(path: String) {
        thumbnailCache.request(path: path)
    }

    func processThumbnailQueue() {
        thumbnailCache.processQueue()
    }

    func pruneMissingWallpaperThumbnails() {
        let valid = Set(model.allRegisteredVideoPaths)
        thumbnailCache.prune(validPaths: valid)
        fitEditor.pruneMissing(validPaths: valid)
        wallpaperEditor.pruneMissing(validPaths: valid)
        if let editingPath = wallpaperNameEdit?.id, !valid.contains(editingPath) {
            cancelWallpaperNameEdit()
        }
    }

    func addToNewPlaylist(path: String) {
        guard let playlistID = model.createPlaylist() else {
            return
        }
        _ = model.addRegisteredVideo(path: path, to: playlistID)
        model.selectPlaylist(playlistID)
    }

    func handleDroppedVideoProviders(_ providers: [NSItemProvider]) -> Bool {
        guard
            let provider = providers.first(where: {
                $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            })
        else {
            return false
        }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            var resolvedURL: URL?
            if let data = item as? Data {
                resolvedURL = URL(dataRepresentation: data, relativeTo: nil)
            } else if let url = item as? URL {
                resolvedURL = url
            } else if let text = item as? String,
                      let url = URL(string: text)
            {
                resolvedURL = url
            }

            guard let url = resolvedURL else {
                return
            }

            DispatchQueue.main.async {
                prepareDroppedVideo(url)
            }
        }

        return true
    }

    /// ドロップされた動画・画像をそのままライブラリへ登録して再生する。
    /// アニメ画像(GIF等)は動画へ変換し、静止画はシーン(レイヤー)にして取り込む。
    /// プレイリスト選択中はそのプレイリストにも追加される(setVideoの挙動に従う)。
    func prepareDroppedVideo(_ url: URL) {
        let fileURL = url.isFileURL ? url : URL(fileURLWithPath: url.path)
        guard fileURL.isFileURL else {
            return
        }
        let ext = fileURL.pathExtension
        let type = UTType(filenameExtension: ext)
        let isMovie = type?.conforms(to: .movie) ?? false
        let isImage = type?.conforms(to: .image) ?? false
        guard isMovie || isImage else {
            return
        }
        Task { @MainActor in
            await model.setVideo(path: fileURL.path)
            selectedTab = .wallpaper
        }
    }

    func resetLibrarySearchState() {
        librarySearchText = ""
        isLibrarySearchFocused = false
    }
}
