import SwiftUI

extension SettingsView {
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
                let selectedPath = resolvedFitEditorVideoPath()
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
                                        selectFitEditorVideo(path: path)
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
