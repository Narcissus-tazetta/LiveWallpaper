import SwiftUI
import UniformTypeIdentifiers

extension SettingsView {
    var playlistSettingsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(model.localizedString("プレイリスト・設定"), systemImage: "list.bullet.rectangle")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                Text(model.playlistCapacityText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 10) {
                Text("\(model.localizedString("選択中")): \(model.selectedPlaylistName)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer(minLength: 0)
                Text("\(model.registeredVideoPaths.count) \(model.localizedString("本"))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack(alignment: .center, spacing: 10) {
                if model.playlists.isEmpty {
                    Text(model.localizedString("プレイリストはありません。「新規プレイリスト」で作成できます"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(model.playlists) { playlist in
                                playlistChip(playlist)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button(model.localizedString("新規プレイリスト")) {
                    if let created = model.createPlaylist() {
                        model.selectPlaylist(created)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!model.canAddPlaylist)
            }

            if !model.registeredVideoPaths.isEmpty {
                let registeredCount = model.registeredVideoPaths.count
                VStack(alignment: .leading, spacing: 6) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            compactToggle(
                                model.localizedString("ループ再生"),
                                isOn: Binding<Bool>(
                                    get: { model.videoLoopEnabled },
                                    set: { model.setVideoLoopEnabled($0) }
                                )
                            )
                            .disabled(!model.isVideoLoopSettingEnabled)

                            helpIconButton(for: .videoLoop)
                                .disabled(false)
                        }

                        if expandedHelpTopics.contains(.videoLoop) {
                            Text(
                                model.localizedString(
                                    "動画が1本のときは常にループします。複数あるときは、連続再生中は次の動画へ進みます。"
                                )
                            )
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    HStack(spacing: 14) {
                        compactToggle(
                            model.localizedString("プレイリスト連続再生"),
                            isOn: Binding<Bool>(
                                get: { model.playlistPlaybackEnabled },
                                set: { model.setPlaylistPlaybackEnabled($0) }
                            )
                        )

                        compactToggle(
                            model.localizedString("シャッフル"),
                            isOn: Binding<Bool>(
                                get: { model.shufflePlaybackEnabled },
                                set: { model.setShufflePlaybackEnabled($0) }
                            )
                        )
                        .disabled(
                            !model.playlistPlaybackEnabled
                                || registeredCount < 2
                                || model.pinCurrentVideo
                        )

                        Spacer(minLength: 12)

                        if let index = model.currentVideoIndex {
                            Text("\(index + 1) / \(registeredCount)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    HStack(spacing: 8) {
                        Button {
                            model.playPreviousVideo()
                        } label: {
                            Label(model.localizedString("前へ"), systemImage: "backward.fill")
                        }
                        .buttonStyle(.bordered)
                        .disabled(registeredCount < 2)

                        Button {
                            model.playNextVideo()
                        } label: {
                            Label(model.localizedString("次へ"), systemImage: "forward.fill")
                        }
                        .buttonStyle(.bordered)
                        .disabled(registeredCount < 2)

                        Spacer(minLength: 0)
                    }

                    GeometryReader { proxy in
                        let layout = wallpaperGridLayout(for: proxy.size.width)
                        ScrollView {
                            LazyVGrid(
                                columns: layout.0,
                                alignment: .leading,
                                spacing: wallpaperGridRowSpacing
                            ) {
                                ForEach(model.registeredVideoPaths, id: \.self) { path in
                                    wallpaperCard(path: path, cardWidth: layout.1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 2)
                        }
                    }
                    .frame(minHeight: wallpaperLibraryGridMinHeight, maxHeight: 260)
                }
            } else {
                Text(model.localizedString("このプレイリストに動画がありません"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isPlaylistSectionDropTargeted ? Color.accentColor : Color.clear,
                    lineWidth: 2
                )
        )
        .onDrop(of: [UTType.text], isTargeted: $isPlaylistSectionDropTargeted) { providers in
            handleDraggedWallpaperDropToSelectedPlaylist(providers)
        }
    }

    func playlistChip(_ playlist: WallpaperPlaylist) -> some View {
        Group {
            if editingPlaylistID == playlist.id {
                HStack(spacing: 4) {
                    TextField(model.localizedString("プレイリスト名"), text: $editingPlaylistNameInput)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .font(.system(size: 11, weight: .medium))
                        .frame(minWidth: 120, idealWidth: 150, maxWidth: 180)
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
            } else {
                Button {
                    model.selectPlaylist(playlist.id)
                } label: {
                    HStack(spacing: 4) {
                        Text(playlist.name)
                            .lineLimit(1)
                        Image(systemName: "pencil")
                            .font(.system(size: 10, weight: .semibold))
                            .opacity(0.75)
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(minWidth: 72, maxWidth: 180)
                    .background(
                        Capsule()
                            .fill(
                                model.isSelectedPlaylist(playlist.id)
                                    ? Color.accentColor : Color.secondary.opacity(0.16)
                            )
                    )
                    .foregroundColor(model.isSelectedPlaylist(playlist.id) ? .white : .primary)
                }
                .buttonStyle(.plain)
                .overlay(
                    Capsule()
                        .stroke(
                            hoveredPlaylistDropTargetID == playlist.id
                                ? Color.accentColor
                                : Color
                                    .clear,
                            lineWidth: 2
                        )
                )
                .onDrop(
                    of: [UTType.text],
                    isTargeted: playlistDropTargetBinding(for: playlist.id)
                ) {
                    providers in
                    handleDraggedWallpaperDrop(providers, to: playlist.id)
                }
                .contextMenu {
                    Button(model.localizedString("このプレイリストに切り替え")) {
                        model.selectPlaylist(playlist.id)
                    }
                    Button(model.localizedString("名前を編集")) {
                        startPlaylistNameEdit(playlistID: playlist.id)
                    }
                    Button(model.localizedString("プレイリストを削除")) {
                        model.removePlaylist(playlist.id)
                    }
                }
            }
        }
    }
}
