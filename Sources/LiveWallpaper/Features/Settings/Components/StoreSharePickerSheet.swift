import SwiftUI

extension SettingsView {
    /// 右クリックメニューやStoreタブの「動画を共有」から呼ぶ共通の起点。
    /// トリム編集タブの選択状態は変えず、共有シート専用の対象パスだけを差し替える。
    func beginStoreShare(path: String) {
        isStoreSharePickerPresented = false
        storeShareTargetPath = path
        storeShareStatus = .idle
        storeShareTitle = model.registeredVideoDisplayName(for: path)
        storeShareAuthor = ""
        storeShareLicense = ""
        isStoreShareSheetPresented = true
    }

    var storeSharePickerSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.localizedString("Storeに共有する壁紙を選択"))
                        .font(.system(size: 18, weight: .semibold))
                    Text(
                        model.localizedString(
                            "保存済みのトリム・フィット設定と一緒に、選んだ動画をコミュニティStoreに公開します"
                        )
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)
                }

                Spacer(minLength: 0)

                Button(model.localizedString("閉じる")) {
                    isStoreSharePickerPresented = false
                }
                .buttonStyle(.bordered)
            }

            if model.allRegisteredVideoPaths.isEmpty {
                Text(model.localizedString("共有できる壁紙がありません"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                GeometryReader { proxy in
                    let layout = wallpaperGridLayout(for: proxy.size.width)
                    ScrollView {
                        LazyVGrid(
                            columns: layout.0,
                            alignment: .leading,
                            spacing: wallpaperGridRowSpacing
                        ) {
                            ForEach(model.allRegisteredVideoPaths, id: \.self) { path in
                                storeShareSelectionCard(path: path, cardWidth: layout.1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                    }
                }
                .frame(minHeight: 280, maxHeight: 520)
            }
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 460)
    }

    private func storeShareSelectionCard(path: String, cardWidth: CGFloat) -> some View {
        Button {
            beginStoreShare(path: path)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
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
                }
                .frame(width: max(cardWidth - 8, 1), height: 60)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Text(model.registeredVideoDisplayName(for: path))
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.up.on.square")
                        .font(.system(size: 10, weight: .semibold))
                    Text(model.localizedString("Storeに共有"))
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundColor(.secondary)
            }
            .padding(4)
            .frame(width: cardWidth, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
        )
    }
}
