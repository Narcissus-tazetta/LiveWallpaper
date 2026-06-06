import SwiftUI
import UniformTypeIdentifiers

extension SettingsView {
    func wallpaperCard(
        path: String,
        cardWidth: CGFloat,
        canDragToPlaylist: Bool = false,
        switchToWallpaperTabOnSelect: Bool = true,
        isSelected: Bool? = nil,
        onSelect: (() -> Void)? = nil
    ) -> some View {
        let thumbnailWidth = max(cardWidth - 8, 1)

        let thumbnailButton = Button {
            if let onSelect {
                onSelect()
            } else {
                model.selectRegisteredVideo(path: path)
                if switchToWallpaperTabOnSelect {
                    selectedTab = .wallpaper
                }
            }
        } label: {
            ZStack {
                if let image = thumbnailCache.image(for: path) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle().fill(Color.secondary.opacity(0.15))
                    Image(systemName: "film")
                        .font(.system(size: 18))
                        .foregroundColor(.secondary)
                }

                if model.pinCurrentVideo, model.currentVideoPath == path {
                    VStack {
                        HStack {
                            Spacer(minLength: 0)
                            HStack(spacing: 3) {
                                Image(systemName: "pin.fill")
                                    .font(.system(size: 8, weight: .semibold))
                                Text(model.localizedString("固定中"))
                                    .font(.system(size: 8, weight: .semibold))
                            }
                            .padding(.horizontal, 5)
                            .padding(.vertical, 3)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(4)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(width: thumbnailWidth, height: 60)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onAppear {
                setThumbnailVisibility(path: path, isVisible: true)
            }
            .onDisappear {
                setThumbnailVisibility(path: path, isVisible: false)
            }
        }
        .buttonStyle(.plain)

        return VStack(alignment: .leading, spacing: 8) {
            Group {
                if canDragToPlaylist {
                    thumbnailButton
                        .onDrag {
                            NSItemProvider(object: path as NSString)
                        }
                } else {
                    thumbnailButton
                }
            }

            if editingWallpaperPath == path {
                HStack(spacing: 4) {
                    TextField(
                        model.localizedString("名前"),
                        text: $editingWallpaperNameInput
                    )
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .font(.system(size: 10))
                    .focused($focusedWallpaperPath, equals: path)
                    .onSubmit {
                        commitWallpaperNameEdit(path: path)
                    }

                    Button {
                        commitWallpaperNameEdit(path: path)
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .controlSize(.mini)
                    .buttonStyle(.borderless)

                    Button {
                        cancelWallpaperNameEdit()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .controlSize(.mini)
                    .buttonStyle(.borderless)
                }
            } else {
                HStack(spacing: 2) {
                    Text(model.registeredVideoDisplayName(for: path))
                        .font(.system(size: 9))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        startWallpaperNameEdit(path: path)
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(4)
        .frame(width: cardWidth, alignment: .leading)
        .clipped()
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    (isSelected ?? (model.currentVideoPath == path)) ? Color.accentColor : Color
                        .clear,
                    lineWidth: 1.5
                )
        )
        .contextMenu {
            Button(model.localizedString("この壁紙に切り替え")) {
                model.selectRegisteredVideo(path: path)
            }
            Menu(model.localizedString("プレイリストに追加…")) {
                if model.playlists.isEmpty {
                    Button(model.localizedString("新規プレイリストを作成して追加")) {
                        addToNewPlaylist(path: path)
                    }
                    .disabled(!model.canAddPlaylist)
                } else {
                    ForEach(model.playlists) { playlist in
                        Button(playlist.name) {
                            _ = model.addRegisteredVideo(path: path, to: playlist.id)
                        }
                        .disabled(model.playlistContainsVideo(playlist.id, path: path))
                    }
                    Divider()
                    Button(model.localizedString("新規プレイリストを作成して追加")) {
                        addToNewPlaylist(path: path)
                    }
                    .disabled(!model.canAddPlaylist)
                }
            }
            Divider()
            Button(model.localizedString("共有…")) {
                beginShareWallpaperSelection(path: path)
            }
            Divider()
            Button(model.localizedString("名前を編集")) {
                startWallpaperNameEdit(path: path)
            }
            Button(model.localizedString("登録から削除")) {
                model.removeRegisteredVideo(path: path)
            }
        }
    }
}
