import SwiftUI

/// いま編集中のカット・ループ設定を、他の壁紙にもまとめて適用するためのピッカー。
///
/// 同じ素材から切り出した動画群や、同じ長さのループ素材をまとめて整えるときの
/// 手数を大幅に減らす。カット範囲は秒の絶対値なので、コピー先が短すぎると
/// そのままでは使えない — その判定と丸めは `TrimEditCopyPlanner` が持ち、
/// ここは選択だけを担当する。
extension SettingsView {
    var trimCopyPickerSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.localizedString("カット・ループ設定をコピーする壁紙を選択"))
                        .font(.system(size: 16, weight: .semibold))
                    Text(
                        model.localizedString(
                            "選んだ壁紙の設定を上書きします。尺が足りない壁紙は変更されません"
                        )
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)
                }

                Spacer(minLength: 0)

                Button(model.localizedString("閉じる")) {
                    isTrimCopyPickerPresented = false
                }
                .buttonStyle(.bordered)
            }

            SearchField(
                placeholder: model.localizedString("壁紙を検索"),
                text: $trimCopySearchText,
                isFocused: $isTrimCopySearchFocused
            )

            let candidates = trimCopyCandidatePaths()

            if candidates.isEmpty {
                SearchEmptyState(
                    isSearchActive: !trimCopySearchText.trimmingCharacters(in: .whitespaces)
                        .isEmpty,
                    noContentText: model.localizedString("コピーできる壁紙がありません"),
                    noMatchText: model.localizedString("一致する壁紙がありません"),
                    clearButtonTitle: model.localizedString("検索をクリア"),
                    onClearSearch: { trimCopySearchText = "" }
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(candidates, id: \.self) { path in
                            trimCopyRow(path: path)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(minHeight: 240, maxHeight: 360)
            }

            HStack(spacing: 8) {
                Button(model.localizedString("すべて選択")) {
                    trimCopySelection = Set(candidates)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(candidates.isEmpty)

                Button(model.localizedString("選択を解除")) {
                    trimCopySelection = []
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(trimCopySelection.isEmpty)

                Spacer(minLength: 0)

                Button(model.localizedString("コピーする")) {
                    wallpaperEditor.copyCurrentEdit(to: Array(trimCopySelection))
                    isTrimCopyPickerPresented = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(trimCopySelection.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 420)
    }

    /// コピー先の候補。編集中の動画自身は対象外(自分に自分をコピーしても
    /// 何も起きないうえ、未保存の内容を上書き保存したように見えてしまう)。
    private func trimCopyCandidatePaths() -> [String] {
        let current = wallpaperEditor.resolvedVideoPath()
        let query = trimCopySearchText.trimmingCharacters(in: .whitespaces).lowercased()
        return model.allRegisteredVideoPaths.filter { path in
            guard path != current else {
                return false
            }
            guard !query.isEmpty else {
                return true
            }
            return model.registeredVideoDisplayName(for: path).lowercased().contains(query)
        }
    }

    private func trimCopyRow(path: String) -> some View {
        let isSelected = trimCopySelection.contains(path)
        return Button {
            if isSelected {
                trimCopySelection.remove(path)
            } else {
                trimCopySelection.insert(path)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundColor(isSelected ? .accentColor : .secondary)

                if let image = thumbnailCache.image(for: path) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 48, height: 27)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(width: 48, height: 27)
                }

                Text(model.registeredVideoDisplayName(for: path))
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)

                if model.hasWallpaperEditOverride(path: path) {
                    Text(model.localizedString("設定あり"))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        )
    }
}
