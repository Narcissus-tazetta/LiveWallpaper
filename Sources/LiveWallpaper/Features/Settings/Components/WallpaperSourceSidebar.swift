import SwiftUI
import UniformTypeIdentifiers

extension SettingsView {
    var wallpaperSourceSidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                sidebarRow(
                    title: model.localizedString("すべての壁紙"),
                    systemImage: "square.grid.2x2",
                    countText: "\(model.allRegisteredVideoPaths.count)",
                    isSelected: selectedLibrarySource == .all
                ) {
                    selectLibrarySource(.all)
                }

                sidebarRow(
                    title: model.localizedString("Web壁紙"),
                    systemImage: "globe",
                    countText: "\(model.webWallpaperSources.count)",
                    isSelected: selectedLibrarySource == .web,
                    isActive: model.isWebWallpaperActive
                ) {
                    selectLibrarySource(.web)
                }

                ForEach(model.playlists) { playlist in
                    playlistSidebarRow(playlist)
                }
            }

            Button {
                if let created = model.createPlaylist() {
                    selectLibrarySource(.playlist(created))
                }
            } label: {
                Label(model.localizedString("新規プレイリスト"), systemImage: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)
            .disabled(!model.canAddPlaylist)
            .padding(.horizontal, 8)
            .padding(.top, 2)

            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: wallpaperSidebarWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    @ViewBuilder
    private func playlistSidebarRow(_ playlist: WallpaperPlaylist) -> some View {
        if editingPlaylistID == playlist.id {
            HStack(spacing: 4) {
                TextField(model.localizedString("プレイリスト名"), text: $editingPlaylistNameInput)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .font(.system(size: 11, weight: .medium))
                    .focused($focusedPlaylistID, equals: playlist.id)
                    .onSubmit {
                        commitPlaylistNameEdit(playlistID: playlist.id)
                    }

                Button {
                    commitPlaylistNameEdit(playlistID: playlist.id)
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                .controlSize(.mini)
                .buttonStyle(.borderless)

                Button {
                    cancelPlaylistNameEdit()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                .controlSize(.mini)
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        } else {
            sidebarRow(
                title: playlist.name,
                systemImage: "list.bullet.rectangle",
                countText: "\(playlist.videoPaths.count)",
                isSelected: selectedLibrarySource == .playlist(playlist.id)
            ) {
                selectLibrarySource(.playlist(playlist.id))
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        hoveredPlaylistDropTargetID == playlist.id
                            ? Color.accentColor
                            : Color.clear,
                        lineWidth: 2
                    )
            )
            .onDrop(
                of: [UTType.text],
                isTargeted: playlistDropTargetBinding(for: playlist.id)
            ) { providers in
                handleDraggedWallpaperDrop(providers, to: playlist.id)
            }
            .contextMenu {
                Button(model.localizedString("名前を編集")) {
                    startPlaylistNameEdit(playlistID: playlist.id)
                }
                Button(model.localizedString("プレイリストを削除")) {
                    model.removePlaylist(playlist.id)
                }
            }
        }
    }

    private func sidebarRow(
        title: String,
        systemImage: String,
        countText: String,
        isSelected: Bool,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if isActive {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                }
                Text(countText)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
            )
            .foregroundColor(isSelected ? .accentColor : .primary)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}
