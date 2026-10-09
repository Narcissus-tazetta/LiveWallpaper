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
        // currentVideoPath はWeb壁紙へ切り替えた後もフォールバック用に保持され続けるため、
        // Web壁紙が実際に表示中のときは動画側を「デスクトップに設定中」として扱わない。
        let isDesktopAssigned = model.currentVideoPath == path && !model.isWebWallpaperActive
        let isLockScreenAssigned = model.lockScreenVideoPath == path
        let isDisplayOverrideAssigned = model.hasLiveDisplayOverride(forPath: path)
        let isHovered = hoveredWallpaperPath == path
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

                if hoverPreviewPath == path {
                    LoopingVideoView(path: path)
                        .transition(.opacity)
                }

                VStack {
                    HStack(alignment: .top, spacing: 4) {
                        wallpaperAssignmentBadges(
                            isDesktopAssigned: isDesktopAssigned,
                            isLockScreenAssigned: isLockScreenAssigned,
                            isDisplayOverrideAssigned: isDisplayOverrideAssigned
                        )
                        Spacer(minLength: 0)
                        if model.pinCurrentVideo, isDesktopAssigned {
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
        .overlay(alignment: .topTrailing) {
            if isHovered {
                // A borderless Menu drops any background drawn in its label, so the circle
                // sits behind the menu instead.
                Menu {
                    wallpaperCardMenuItems(path: path)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .bold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .tint(.white)
                .frame(width: 24, height: 24)
                .background(.black.opacity(0.4), in: Circle())
                .background(.ultraThinMaterial, in: Circle())
                .overlay(
                    Circle()
                        .strokeBorder(Color.white.opacity(0.3), lineWidth: 1)
                        .allowsHitTesting(false)
                )
                .padding(6)
                .help(model.localizedString("その他の操作"))
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
        }

        return VStack(alignment: .leading, spacing: 8) {
            thumbnailButton

            if wallpaperNameEdit?.id == path {
                inlineNameEditField(
                    placeholder: model.localizedString("名前"),
                    text: inlineNameEditInputBinding($wallpaperNameEdit),
                    font: .system(size: 10),
                    id: path,
                    focus: $focusedWallpaperPath,
                    onCommit: { commitWallpaperNameEdit(path: path) },
                    onCancel: { cancelWallpaperNameEdit() }
                )
            } else {
                HStack(spacing: 4) {
                    Text(model.registeredVideoDisplayName(for: path))
                        .font(.system(size: 11))
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
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(isHovered ? 0.16 : 0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(strokeColor, lineWidth: strokeColor == .clear ? 0 : 2)
        )
        .shadow(
            color: strokeColor == .clear ? .black.opacity(isHovered ? 0.3 : 0) : strokeColor.opacity(0.4),
            radius: isHovered ? 10 : 6,
            y: isHovered ? 5 : 0
        )
        .scaleEffect(isHovered && !reduceMotion ? 1.03 : 1)
        .zIndex(isHovered ? 1 : 0)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isHovered)
        .animation(.easeOut(duration: 0.25), value: hoverPreviewPath == path)
        .onHover { hovering in
            handleWallpaperCardHover(path: path, hovering: hovering)
        }
        .contextMenu {
            wallpaperCardMenuItems(path: path)
        }
    }

    /// Plays the hovered card only after the pointer rests on it, so sweeping across the grid
    /// doesn't open a player per card. One card plays at a time.
    func handleWallpaperCardHover(path: String, hovering: Bool) {
        if hovering {
            hoveredWallpaperPath = path
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                if hoveredWallpaperPath == path {
                    hoverPreviewPath = path
                }
            }
        } else if hoveredWallpaperPath == path {
            hoveredWallpaperPath = nil
            hoverPreviewPath = nil
        }
    }

    @ViewBuilder
    func wallpaperCardMenuItems(path: String) -> some View {
        Button(model.localizedString("デスクトップに設定")) {
            model.selectRegisteredVideo(path: path)
        }
        Button(model.localizedString("ロック画面に設定")) {
            model.selectLockScreenVideo(path: path)
        }
        .disabled(!model.lockScreenSyncService.isSupported)
        // 新規割り当てには2台以上が必要だが、接続解除後も残った古い割り当て
        // (このパス宛て)を解除する手段は画面数によらず必ず出す。
        if model.availableDisplayScreens().count > 1
            || model.videoOverrideByScreenID.values.contains(path)
        {
            displayOverrideMenu(path: path)
        }
        if model.spaceWallpaperFeatureEnabled, model.isSpaceWallpaperAvailable,
           !model.knownDesktopSpaces.isEmpty
        {
            spaceOverrideMenu(path: path)
        }
        playlistMembershipMenus(
            isContained: { model.playlistContainsVideo($0.id, path: path) },
            add: { playlistID in _ = model.addRegisteredVideo(path: path, to: playlistID) },
            remove: { playlistID in _ = model.removeVideo(path: path, fromPlaylist: playlistID) },
            addToNewPlaylist: { addToNewPlaylist(path: path) }
        )
        Divider()
        Button(model.localizedString("共有…")) {
            beginShareWallpaperSelection(path: path)
        }
        Button(model.localizedString("Storeに共有…")) {
            beginStoreShare(path: path)
        }
        Divider()
        Button(model.localizedString("名前を編集")) {
            startWallpaperNameEdit(path: path)
        }
        Button(model.localizedString("登録から削除")) {
            model.removeRegisteredVideo(path: path)
        }
    }

    /// この動画を特定のディスプレイに固定表示するメニュー。
    /// 選択で割り当て、割り当て済みの画面を選ぶと解除(トグル)。
    @ViewBuilder
    func displayOverrideMenu(path: String) -> some View {
        Menu(model.localizedString("ディスプレイに割り当て…")) {
            ForEach(model.availableDisplayScreens()) { screen in
                Button {
                    if model.videoOverride(forScreenID: screen.id) == path {
                        model.setVideoOverride(path: nil, forScreenID: screen.id)
                    } else {
                        model.setVideoOverride(path: path, forScreenID: screen.id)
                    }
                } label: {
                    if model.videoOverride(forScreenID: screen.id) == path {
                        Label(screen.name, systemImage: "checkmark")
                    } else {
                        Text(screen.name)
                    }
                }
            }
            if !model.videoOverrideByScreenID.isEmpty {
                Divider()
                Button(model.localizedString("すべての割り当てを解除")) {
                    for screenID in Array(model.videoOverrideByScreenID.keys) {
                        model.setVideoOverride(path: nil, forScreenID: screenID)
                    }
                }
            }
        }
    }

    /// この動画を特定のデスクトップ(Space)に固定表示するメニュー。
    /// 選択で割り当て、割り当て済みのデスクトップを選ぶと解除(トグル)。
    @ViewBuilder
    func spaceOverrideMenu(path: String) -> some View {
        Menu(model.localizedString("デスクトップに割り当て…")) {
            ForEach(model.knownDesktopSpaces) { space in
                Button {
                    if model.spaceVideo(forSpaceUUID: space.uuid) == path {
                        model.setSpaceVideo(path: nil, forSpaceUUID: space.uuid)
                    } else {
                        model.setSpaceVideo(path: path, forSpaceUUID: space.uuid)
                    }
                } label: {
                    if model.spaceVideo(forSpaceUUID: space.uuid) == path {
                        Label(desktopSpaceDisplayName(for: space), systemImage: "checkmark")
                    } else {
                        Text(desktopSpaceDisplayName(for: space))
                    }
                }
            }
            if !model.videoBySpaceUUID.isEmpty {
                Divider()
                Button(model.localizedString("すべての割り当てを解除")) {
                    for uuid in Array(model.videoBySpaceUUID.keys) {
                        model.setSpaceVideo(path: nil, forSpaceUUID: uuid)
                    }
                }
            }
        }
    }

    /// プレイリスト編集中に名前行へ出すチェックボックス。ON=そのプレイリストに含まれる。
    private func playlistMembershipCheckbox(path: String, playlistID: UUID) -> some View {
        membershipCheckbox(
            isOn: { model.playlistContainsVideo(playlistID, path: path) },
            setOn: { isOn in
                if isOn {
                    _ = model.addRegisteredVideo(path: path, to: playlistID)
                } else {
                    _ = model.removeVideo(path: path, fromPlaylist: playlistID)
                }
            }
        )
    }

    @ViewBuilder
    func wallpaperAssignmentBadges(
        isDesktopAssigned: Bool,
        isLockScreenAssigned: Bool,
        isDisplayOverrideAssigned: Bool = false
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
            if isDisplayOverrideAssigned {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Color.purple, in: Circle())
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
