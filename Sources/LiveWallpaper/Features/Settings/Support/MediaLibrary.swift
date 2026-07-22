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
        if let editingPath = editingWallpaperPath, !valid.contains(editingPath) {
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

    /// ドロップされた動画・アニメ画像をそのままライブラリへ登録して再生する。
    /// アニメ画像(GIF等)は取り込み時に動画へ変換される。
    /// プレイリスト選択中はそのプレイリストにも追加される(setVideoの挙動に従う)。
    func prepareDroppedVideo(_ url: URL) {
        let fileURL = url.isFileURL ? url : URL(fileURLWithPath: url.path)
        guard fileURL.isFileURL else {
            return
        }
        let ext = fileURL.pathExtension
        let isMovie = UTType(filenameExtension: ext)?.conforms(to: .movie) ?? false
        guard isMovie || AnimatedImageTranscoder.isSupportedImageExtension(ext) else {
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

    /// 動画名・プレイリスト名・Web壁紙名、いずれかの編集を開始する前に他の編集を閉じる。
    /// 複数の名前編集フィールドが同時に開いたままになるのを防ぐ。
    func cancelAllNameEdits() {
        cancelPlaylistNameEdit()
        cancelWallpaperNameEdit()
        cancelWebWallpaperNameEdit()
    }

    func startWallpaperNameEdit(path: String) {
        cancelAllNameEdits()
        editingWallpaperPath = path
        editingWallpaperNameInput = model.registeredVideoDisplayName(for: path)
        focusedWallpaperPath = path
    }

    func startPlaylistNameEdit(playlistID: UUID) {
        cancelAllNameEdits()
        editingPlaylistID = playlistID
        editingPlaylistNameInput = model.playlistName(for: playlistID)
        focusedPlaylistID = playlistID
    }

    func commitPlaylistNameEdit(playlistID: UUID) {
        model.setPlaylistName(editingPlaylistNameInput, for: playlistID)
        cancelPlaylistNameEdit()
    }

    func cancelPlaylistNameEdit() {
        editingPlaylistID = nil
        editingPlaylistNameInput = ""
        focusedPlaylistID = nil
    }

    func commitWallpaperNameEdit(path: String) {
        model.setRegisteredVideoDisplayName(editingWallpaperNameInput, for: path)
        cancelWallpaperNameEdit()
    }

    func cancelWallpaperNameEdit() {
        editingWallpaperPath = nil
        editingWallpaperNameInput = ""
        focusedWallpaperPath = nil
    }
}
