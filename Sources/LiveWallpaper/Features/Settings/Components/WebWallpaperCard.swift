import SwiftUI

extension SettingsView {
    func webWallpaperCard(
        source: WebWallpaperSource,
        cardWidth: CGFloat,
        playlistEditingID: UUID? = nil,
        assignmentTarget: WallpaperAssignmentTarget = .desktop
    ) -> some View {
        let thumbnailWidth = max(cardWidth - 8, 1)
        let thumbnailHeight = (thumbnailWidth * 9 / 16).rounded()
        let isActive = model.currentWebWallpaperID == source.id && model.isWebWallpaperActive
        let strokeColor: Color = isActive ? Color.accentColor : .clear
        // Web壁紙はロック画面壁紙の概念を持たないため、ロック画面タブでは
        // 選択(適用)操作のみ無効化する。削除・プレイリスト編集はどちらのタブでも可能。
        let isSelectable = assignmentTarget == .desktop

        let thumbnailButton = Button {
            model.selectWebWallpaper(id: source.id)
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
                        Spacer(minLength: 0)
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
        .help(isSelectable ? "" : model.localizedString("Web壁紙はロック画面に設定できません"))

        return VStack(alignment: .leading, spacing: 8) {
            thumbnailButton

            if editingWebWallpaperID == source.id {
                HStack(spacing: 4) {
                    TextField(
                        model.localizedString("名前"),
                        text: $editingWebWallpaperNameInput
                    )
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .font(.system(size: 10))
                    .focused($focusedWebWallpaperID, equals: source.id)
                    .onSubmit {
                        commitWebWallpaperNameEdit(sourceID: source.id)
                    }

                    Button {
                        commitWebWallpaperNameEdit(sourceID: source.id)
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .controlSize(.mini)
                    .buttonStyle(.borderless)

                    Button {
                        cancelWebWallpaperNameEdit()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .controlSize(.mini)
                    .buttonStyle(.borderless)
                }
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
                model.selectWebWallpaper(id: source.id)
            }
            .disabled(!isSelectable)
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
            Button(model.localizedString("名前を編集")) {
                startWebWallpaperNameEdit(sourceID: source.id)
            }
            Button(role: .destructive) {
                webThumbnailStore.remove(sourceID: source.id)
                model.removeWebWallpaper(id: source.id)
                if editingWebWallpaperID == source.id {
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

    func startWebWallpaperNameEdit(sourceID: UUID) {
        guard let source = model.webWallpaperSources.first(where: { $0.id == sourceID }) else {
            return
        }
        cancelAllNameEdits()
        editingWebWallpaperID = sourceID
        editingWebWallpaperNameInput = source.displayName
        focusedWebWallpaperID = sourceID
    }

    func commitWebWallpaperNameEdit(sourceID: UUID) {
        model.setWebWallpaperDisplayName(editingWebWallpaperNameInput, for: sourceID)
        cancelWebWallpaperNameEdit()
    }

    func cancelWebWallpaperNameEdit() {
        editingWebWallpaperID = nil
        editingWebWallpaperNameInput = ""
        focusedWebWallpaperID = nil
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
}
