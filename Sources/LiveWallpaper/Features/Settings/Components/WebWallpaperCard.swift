import SwiftUI

extension SettingsView {
    func webWallpaperCard(
        source: WebWallpaperSource,
        cardWidth: CGFloat,
        playlistEditingID: UUID? = nil,
        assignmentTarget: WallpaperAssignmentTarget = .desktop,
        displayScreenID: String? = nil
    ) -> some View {
        let thumbnailWidth = max(cardWidth - 8, 1)
        let thumbnailHeight = (thumbnailWidth * 9 / 16).rounded()
        let isActive = if let displayScreenID {
            model.webOverrideByScreenID[displayScreenID] == source.id
        } else {
            model.currentWebWallpaperID == source.id && model.isWebWallpaperActive
        }
        let isDisplayOverrideAssigned = model.hasLiveWebOverride(forSourceID: source.id)
        let strokeColor: Color = isActive ? Color.accentColor : .clear
        // Web壁紙はロック画面壁紙の概念を持たないため、ロック画面タブでは
        // 選択(適用)操作のみ無効化する。削除・プレイリスト編集はどちらのタブでも可能。
        let isSelectable = assignmentTarget == .desktop

        let thumbnailButton = Button {
            if let displayScreenID {
                model.setWebOverride(id: source.id, forScreenID: displayScreenID)
            } else {
                model.stopExternalWallpaper()
                model.selectWebWallpaper(id: source.id)
            }
        } label: {
            ZStack {
                WebWallpaperThumbnailView(
                    source: source,
                    isActive: isActive,
                    thumbnailStore: webThumbnailStore,
                    width: thumbnailWidth,
                    height: thumbnailHeight
                )

                VStack {
                    HStack {
                        webWallpaperStatusBadge(isActive: isActive)
                        if isDisplayOverrideAssigned {
                            Image(systemName: "rectangle.on.rectangle")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 18, height: 18)
                                .background(Color.purple, in: Circle())
                                .help(model.localizedString("画面別に割り当て中"))
                        }
                        Spacer(minLength: 0)
                        if isActive, displayScreenID == nil, model.pinCurrentVideo {
                            Label(model.localizedString("固定中"), systemImage: "pin.fill")
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 3)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                    }
                    .padding(.top, 4)
                    .padding(.horizontal, 4)
                    Spacer(minLength: 0)
                }
            }
            .frame(width: thumbnailWidth, height: thumbnailHeight)
            .opacity(isSelectable ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!isSelectable)
        .accessibilityLabel(source.displayName)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .help(isSelectable ? "" : model.localizedString("Web壁紙はロック画面に設定できません"))

        return VStack(alignment: .leading, spacing: 8) {
            thumbnailButton

            if let warnings = source.warnings, !warnings.isEmpty {
                Image(systemName: "exclamationmark.circle")
                    .foregroundColor(.secondary)
                    .help(warnings.joined(separator: "\n"))
                    .accessibilityLabel(warnings.joined(separator: "\n"))
            }
            if webWallpaperNameEdit?.id == source.id {
                inlineNameEditField(
                    placeholder: model.localizedString("名前"),
                    text: inlineNameEditInputBinding($webWallpaperNameEdit),
                    font: .system(size: 10),
                    id: source.id,
                    focus: $focusedWebWallpaperID,
                    onCommit: { commitWebWallpaperNameEdit(sourceID: source.id) },
                    onCancel: { cancelWebWallpaperNameEdit() }
                )
            } else {
                HStack(spacing: 2) {
                    Text(source.displayName)
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let playlistEditingID {
                        webWallpaperPlaylistMembershipCheckbox(
                            sourceID: source.id,
                            playlistID: playlistEditingID
                        )
                    }

                    Button {
                        startWebWallpaperNameEdit(sourceID: source.id)
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .iconHelp(model.localizedString("名前を編集"))
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
            Button(model.localizedString("適用")) {
                model.stopExternalWallpaper()
                model.selectWebWallpaper(id: source.id)
            }
            .disabled(!isSelectable)
            if model.availableDisplayScreens().count > 1 || model.webOverrideByScreenID.values.contains(source.id) {
                webDisplayOverrideMenu(sourceID: source.id)
            }
            Divider()
            playlistMembershipMenus(
                isContained: { model.playlistContainsWebWallpaper($0.id, sourceID: source.id) },
                add: { playlistID in _ = model.addWebWallpaper(sourceID: source.id, to: playlistID) },
                remove: { playlistID in
                    _ = model.removeWebWallpaper(sourceID: source.id, fromPlaylist: playlistID)
                },
                addToNewPlaylist: { addWebWallpaperToNewPlaylist(sourceID: source.id) }
            )
            Divider()
            if source.localFolderPath != nil {
                Button(model.localizedString("作品の設定")) { localWebSettingsSource = source }
            }
            Button(model.localizedString("名前を編集")) {
                startWebWallpaperNameEdit(sourceID: source.id)
            }
            Button(role: .destructive) {
                webThumbnailStore.remove(sourceID: source.id)
                model.removeWebWallpaper(id: source.id)
                if webWallpaperNameEdit?.id == source.id {
                    cancelWebWallpaperNameEdit()
                }
            } label: {
                Text(model.localizedString("削除"))
            }
        }
    }

    private func addWebWallpaperToNewPlaylist(sourceID: UUID) {
        guard let playlistID = model.createPlaylist() else {
            return
        }
        _ = model.addWebWallpaper(sourceID: sourceID, to: playlistID)
        model.selectPlaylist(playlistID)
    }

    /// プレイリスト編集中に名前行へ出すチェックボックス。ON=そのプレイリストに含まれる。
    private func webWallpaperPlaylistMembershipCheckbox(sourceID: UUID, playlistID: UUID) -> some View {
        membershipCheckbox(
            isOn: { model.playlistContainsWebWallpaper(playlistID, sourceID: sourceID) },
            setOn: { isOn in
                if isOn {
                    _ = model.addWebWallpaper(sourceID: sourceID, to: playlistID)
                } else {
                    _ = model.removeWebWallpaper(sourceID: sourceID, fromPlaylist: playlistID)
                }
            }
        )
    }

    @ViewBuilder
    private func webWallpaperStatusBadge(isActive: Bool) -> some View {
        if isActive, let (text, color) = webWallpaperStatusBadgeContent {
            Text(text)
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(color.opacity(0.85), in: Capsule())
        }
    }

    private var webWallpaperStatusBadgeContent: (String, Color)? {
        switch model.webWallpaperLoadState {
        case .loading:
            return (model.localizedString("読み込み中"), .secondary)
        case .loaded:
            return (model.localizedString("表示中"), .green)
        case .failed:
            return (model.localizedString("読み込み失敗"), .orange)
        case .idle:
            return nil
        }
    }

    /// この Web 壁紙を特定のディスプレイに固定表示するメニュー。
    /// 選択で割り当て、割り当て済みの画面を選ぶと解除(トグル)。
    @ViewBuilder
    func webDisplayOverrideMenu(sourceID: UUID) -> some View {
        Menu(model.localizedString("ディスプレイに割り当て…")) {
            ForEach(model.availableDisplayScreens()) { screen in
                Button {
                    if model.webOverrideByScreenID[screen.id] == sourceID {
                        model.setWebOverride(id: nil, forScreenID: screen.id)
                    } else {
                        model.setWebOverride(id: sourceID, forScreenID: screen.id)
                    }
                } label: {
                    if model.webOverrideByScreenID[screen.id] == sourceID {
                        Label(screen.name, systemImage: "checkmark")
                    } else {
                        Text(screen.name)
                    }
                }
            }
            if !model.webOverrideByScreenID.isEmpty {
                Divider()
                Button(model.localizedString("すべての割り当てを解除")) {
                    for screenID in Array(model.webOverrideByScreenID.keys) {
                        model.setWebOverride(id: nil, forScreenID: screenID)
                    }
                }
            }
        }
    }
}
