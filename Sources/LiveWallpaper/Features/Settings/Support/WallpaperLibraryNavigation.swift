import SwiftUI

extension SettingsView {
    func selectLibrarySource(_ source: WallpaperLibrarySource) {
        selectedLibrarySource = source
        resetLibrarySearchState()

        if case .playlist(let playlistID) = source {
            model.selectPlaylist(playlistID)
        }
    }

    func resetLibrarySearchState() {
        librarySearchText = ""
        isLibrarySearchFocused = false
    }

    func syncLibrarySourceWithSelectedPlaylist(_ playlistID: UUID?) {
        guard let playlistID else {
            return
        }
        guard model.playlists.contains(where: { $0.id == playlistID }) else {
            return
        }

        // Only follow the model's playlist selection when the user is already
        // viewing a playlist. When they are deliberately on All or Web, an
        // implicit selection change (e.g. auto-creating "プレイリスト1" on the
        // first added video) must not yank them into a playlist view.
        guard case .playlist(let currentID) = selectedLibrarySource else {
            return
        }
        guard currentID != playlistID else {
            return
        }

        selectedLibrarySource = .playlist(playlistID)
        resetLibrarySearchState()
    }

    /// Single reconciliation point for both `model.playlists` and `model.selectedPlaylistID`
    /// changes. Both can be mutated together by a single model call (e.g. deleting the
    /// viewed playlist reassigns `selectedPlaylistID` to another playlist as a side effect),
    /// so keeping this in one function makes the outcome independent of which SwiftUI
    /// `onChange` fires first — checking "is the viewed playlist gone?" always takes
    /// priority over following `selectedPlaylistID` to whatever it was reassigned to.
    func reconcileLibrarySource() {
        if case .playlist(let id) = selectedLibrarySource,
           !model.playlists.contains(where: { $0.id == id })
        {
            selectLibrarySource(.all)
            return
        }
        syncLibrarySourceWithSelectedPlaylist(model.selectedPlaylistID)
    }

    var activePlaylistLibrarySourceID: UUID? {
        guard case .playlist(let playlistID) = selectedLibrarySource else {
            return nil
        }
        return playlistID
    }

    var isViewingActivePlaylist: Bool {
        guard let activePlaylistLibrarySourceID,
              let selectedPlaylistID = model.selectedPlaylistID
        else {
            return false
        }
        return activePlaylistLibrarySourceID == selectedPlaylistID
    }
}
