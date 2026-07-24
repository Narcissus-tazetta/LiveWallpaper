import SwiftUI

extension SettingsView {
    /// 一覧から編集対象を選ぶ。トリム編集に未保存の変更があるときは、
    /// `requestSelectVideo` が確認を挟むので、確定するまでフィット側の選択も
    /// 動かさない(片方だけ切り替わって表示が食い違うのを防ぐ)。
    func selectEditorVideo(path: String) {
        guard wallpaperEditor.requestSelectVideo(path: path) else {
            return
        }
        fitEditor.selectVideo(path: path)
    }

    var wallpaperFitLibraryPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(model.localizedString("壁紙一覧"), systemImage: "square.grid.2x2")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                Text("\(model.allRegisteredVideoPaths.count) \(model.localizedString("本"))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if model.allRegisteredVideoPaths.isEmpty {
                Text(model.localizedString("まず壁紙を追加すると、ここで配置を調整できます"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                // ハイライトは「いま前面にある編集タブ」の選択に合わせる。
                // トリム編集は未保存の確認を挟むため、確定するまで選択が
                // 動かないことがあり、フィット側の選択とは一致しない。
                let selectedPath = editorSubMode == .trim
                    ? wallpaperEditor.resolvedVideoPath()
                    : fitEditor.resolvedVideoPath()
                GeometryReader { proxy in
                    let layout = wallpaperGridLayout(for: proxy.size.width)
                    ScrollView {
                        LazyVGrid(
                            columns: layout.0,
                            alignment: .leading,
                            spacing: wallpaperGridRowSpacing
                        ) {
                            ForEach(model.allRegisteredVideoPaths, id: \.self) { path in
                                wallpaperCard(
                                    path: path,
                                    cardWidth: layout.1,
                                    switchToWallpaperTabOnSelect: false,
                                    isSelected: selectedPath == path,
                                    onSelect: {
                                        selectEditorVideo(path: path)
                                    }
                                )
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                    }
                }
                .frame(minHeight: wallpaperLibraryGridMinHeight, maxHeight: 360)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.08))
        )
    }
}
