import SwiftUI
import UniformTypeIdentifiers

extension SettingsView {
    func wallpaperCard(
        path: String,
        cardWidth: CGFloat,
        switchToWallpaperTabOnSelect: Bool = true,
        assignmentTarget: WallpaperAssignmentTarget = .desktop,
        playlistEditingID: UUID? = nil,
        isSelected: Bool? = nil,
        onSelect: (() -> Void)? = nil
    ) -> some View {
        let thumbnailWidth = max(cardWidth - 8, 1)
        let thumbnailHeight = (thumbnailWidth * 9 / 16).rounded()
        let isDesktopAssigned = model.currentVideoPath == path
        let isLockScreenAssigned = model.lockScreenVideoPath == path
        let strokeColor = wallpaperCardStrokeColor(
            path: path,
            assignmentTarget: assignmentTarget,
            isDesktopAssigned: isDesktopAssigned,
            isLockScreenAssigned: isLockScreenAssigned,
            isSelected: isSelected
        )

        let thumbnailButton = Button {
            if let onSelect {
                onSelect()
            } else {
                switch assignmentTarget {
                case .desktop:
                    model.selectRegisteredVideo(path: path)
                case .lockScreen:
                    model.selectLockScreenVideo(path: path)
                }
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

                VStack {
                    HStack(alignment: .top, spacing: 4) {
                        wallpaperAssignmentBadges(
                            isDesktopAssigned: isDesktopAssigned,
                            isLockScreenAssigned: isLockScreenAssigned
                        )
                        Spacer(minLength: 0)
                        if model.pinCurrentVideo, model.currentVideoPath == path {
                            HStack(spacing: 3) {
                                Image(systemName: "pin.fill")
                                    .font(.system(size: 8, weight: .semibold))
                                Text(model.localizedString("固定中"))
                                    .font(.system(size: 9, weight: .semibold))
                            }
                            .padding(.horizontal, 5)
                            .padding(.vertical, 3)
                            .background(.ultraThinMaterial, in: Capsule())
                        }
                    }
                    .padding(.top, 6)
                    .padding(.horizontal, 6)
                    Spacer(minLength: 0)
                }
            }
            .frame(width: thumbnailWidth, height: thumbnailHeight)
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
            thumbnailButton

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
                HStack(spacing: 4) {
                    Text(model.registeredVideoDisplayName(for: path))
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let playlistEditingID {
                        playlistMembershipCheckbox(path: path, playlistID: playlistEditingID)
                    }

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
                .stroke(strokeColor, lineWidth: strokeColor == .clear ? 0 : 1.5)
        )
        .contextMenu {
            Button(model.localizedString("デスクトップに設定")) {
                model.selectRegisteredVideo(path: path)
            }
            Button(model.localizedString("ロック画面に設定")) {
                model.selectLockScreenVideo(path: path)
            }
            .disabled(!model.lockScreenSyncService.isSupported)
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
            if playlistsContainingVideo(path: path).isEmpty == false {
                Menu(model.localizedString("プレイリストから外す…")) {
                    ForEach(playlistsContainingVideo(path: path)) { playlist in
                        Button(playlist.name) {
                            _ = model.removeVideo(path: path, fromPlaylist: playlist.id)
                        }
                    }
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

    private func playlistsContainingVideo(path: String) -> [WallpaperPlaylist] {
        model.playlists.filter { $0.videoPaths.contains(path) }
    }

    /// プレイリスト編集中に名前行へ出すチェックボックス。ON=そのプレイリストに含まれる。
    private func playlistMembershipCheckbox(path: String, playlistID: UUID) -> some View {
        Toggle(
            "",
            isOn: Binding(
                get: { model.playlistContainsVideo(playlistID, path: path) },
                set: { isOn in
                    if isOn {
                        _ = model.addRegisteredVideo(path: path, to: playlistID)
                    } else {
                        _ = model.removeVideo(path: path, fromPlaylist: playlistID)
                    }
                }
            )
        )
        .toggleStyle(.checkbox)
        .labelsHidden()
        .controlSize(.small)
        .help(model.localizedString("チェックでこのプレイリストに追加・解除"))
    }

    @ViewBuilder
    func wallpaperAssignmentBadges(
        isDesktopAssigned: Bool,
        isLockScreenAssigned: Bool
    ) -> some View {
        HStack(spacing: 4) {
            if isDesktopAssigned {
                Image(systemName: "display")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Color.accentColor, in: Circle())
            }
            if isLockScreenAssigned {
                Image(systemName: "lock.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Color.orange, in: Circle())
            }
        }
        .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
    }

    func wallpaperCardStrokeColor(
        path: String,
        assignmentTarget: WallpaperAssignmentTarget,
        isDesktopAssigned: Bool,
        isLockScreenAssigned: Bool,
        isSelected: Bool?
    ) -> Color {
        if let isSelected {
            return isSelected ? Color.accentColor : .clear
        }
        switch assignmentTarget {
        case .desktop:
            return isDesktopAssigned ? Color.accentColor : .clear
        case .lockScreen:
            return isLockScreenAssigned ? Color.orange : .clear
        }
    }
}
