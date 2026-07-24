import SwiftUI

/// インライン名前編集の状態。動画/Web壁紙/プレイリストの3箇所で全く同じ形
/// (対象の識別子 + 編集中の入力文字列)だったため、識別子の型だけをジェネリック
/// にして共通化してある。
struct InlineNameEdit<ID: Hashable>: Equatable {
    var id: ID
    var input: String
}

extension SettingsView {
    /// 動画名・プレイリスト名・Web壁紙名、いずれかの編集を開始する前に他の編集を閉じる。
    /// 複数の名前編集フィールドが同時に開いたままになるのを防ぐ。
    func cancelAllNameEdits() {
        cancelInlineNameEdit(state: $playlistNameEdit, focus: $focusedPlaylistID)
        cancelInlineNameEdit(state: $wallpaperNameEdit, focus: $focusedWallpaperPath)
        cancelInlineNameEdit(state: $webWallpaperNameEdit, focus: $focusedWebWallpaperID)
    }

    /// 名前編集を開始する。他の編集は自動的に閉じ、対応する `@FocusState` へ即座に
    /// フォーカスを移す。
    func beginInlineNameEdit<ID: Hashable>(
        id: ID,
        initialValue: String,
        state: Binding<InlineNameEdit<ID>?>,
        focus: FocusState<ID?>.Binding
    ) {
        cancelAllNameEdits()
        state.wrappedValue = InlineNameEdit(id: id, input: initialValue)
        focus.wrappedValue = id
    }

    /// 編集中の入力値を確定して `apply` へ渡し、編集状態を閉じる。編集中でなければ
    /// 何もしない(確定ボタンの二重タップ等への防御)。
    func commitInlineNameEdit<ID: Hashable>(
        state: Binding<InlineNameEdit<ID>?>,
        focus: FocusState<ID?>.Binding,
        apply: (ID, String) -> Void
    ) {
        guard let editing = state.wrappedValue else {
            return
        }
        apply(editing.id, editing.input)
        cancelInlineNameEdit(state: state, focus: focus)
    }

    /// 変更を破棄して編集状態を閉じる。
    func cancelInlineNameEdit<ID: Hashable>(
        state: Binding<InlineNameEdit<ID>?>,
        focus: FocusState<ID?>.Binding
    ) {
        state.wrappedValue = nil
        focus.wrappedValue = nil
    }

    /// TextField に渡す `Binding<String>`。編集中でなければ空文字を返す
    /// (カード側は `state?.id == 対象` を見てからしかこのBindingを使わないため、
    /// 実際に空文字が表示されることはない)。
    func inlineNameEditInputBinding<ID: Hashable>(
        _ state: Binding<InlineNameEdit<ID>?>
    ) -> Binding<String> {
        Binding<String>(
            get: { state.wrappedValue?.input ?? "" },
            set: { state.wrappedValue?.input = $0 }
        )
    }

    /// インライン名前編集のUI本体(TextField + 確定ボタン + キャンセルボタン)。
    /// 動画カード・Web壁紙カード・プレイリストフィルタの3箇所で見た目まで
    /// 完全に同一だったパターンを1つに集約する。
    func inlineNameEditField<ID: Hashable>(
        placeholder: String,
        text: Binding<String>,
        font: Font,
        fieldWidth: CGFloat? = nil,
        id: ID,
        focus: FocusState<ID?>.Binding,
        onCommit: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 4) {
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .font(font)
                .frame(width: fieldWidth)
                .focused(focus, equals: id)
                .onSubmit(onCommit)

            Button(action: onCommit) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .controlSize(.mini)
            .buttonStyle(.borderless)

            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .controlSize(.mini)
            .buttonStyle(.borderless)
        }
    }

    // MARK: - 動画(壁紙)の名前編集

    func startWallpaperNameEdit(path: String) {
        beginInlineNameEdit(
            id: path,
            initialValue: model.registeredVideoDisplayName(for: path),
            state: $wallpaperNameEdit,
            focus: $focusedWallpaperPath
        )
    }

    func commitWallpaperNameEdit(path: String) {
        commitInlineNameEdit(state: $wallpaperNameEdit, focus: $focusedWallpaperPath) { id, name in
            model.setRegisteredVideoDisplayName(name, for: id)
        }
    }

    func cancelWallpaperNameEdit() {
        cancelInlineNameEdit(state: $wallpaperNameEdit, focus: $focusedWallpaperPath)
    }

    // MARK: - プレイリストの名前編集

    func startPlaylistNameEdit(playlistID: UUID) {
        beginInlineNameEdit(
            id: playlistID,
            initialValue: model.playlistName(for: playlistID),
            state: $playlistNameEdit,
            focus: $focusedPlaylistID
        )
    }

    func commitPlaylistNameEdit(playlistID: UUID) {
        commitInlineNameEdit(state: $playlistNameEdit, focus: $focusedPlaylistID) { id, name in
            model.setPlaylistName(name, for: id)
        }
    }

    func cancelPlaylistNameEdit() {
        cancelInlineNameEdit(state: $playlistNameEdit, focus: $focusedPlaylistID)
    }

    // MARK: - Web壁紙の名前編集

    func startWebWallpaperNameEdit(sourceID: UUID) {
        guard let source = model.webWallpaperSources.first(where: { $0.id == sourceID }) else {
            return
        }
        beginInlineNameEdit(
            id: sourceID,
            initialValue: source.displayName,
            state: $webWallpaperNameEdit,
            focus: $focusedWebWallpaperID
        )
    }

    func commitWebWallpaperNameEdit(sourceID: UUID) {
        commitInlineNameEdit(state: $webWallpaperNameEdit, focus: $focusedWebWallpaperID) { id, name in
            model.setWebWallpaperDisplayName(name, for: id)
        }
    }

    func cancelWebWallpaperNameEdit() {
        cancelInlineNameEdit(state: $webWallpaperNameEdit, focus: $focusedWebWallpaperID)
    }
}
