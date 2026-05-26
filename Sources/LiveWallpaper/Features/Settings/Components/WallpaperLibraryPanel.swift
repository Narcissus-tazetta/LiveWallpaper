import SwiftUI

extension SettingsView {
    var wallpaperLibraryPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(model.localizedString("壁紙一覧"), systemImage: "square.grid.2x2")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                Text("\(model.allRegisteredVideoPaths.count) \(model.localizedString("本"))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 12) {
                Text(
                    model.currentVideoPath.map { model.registeredVideoDisplayName(
                        for: $0
                    ) } ?? model.localizedString("(選択なし)")
                )
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    Button(model.localizedString("壁紙を共有")) {
                        isWallpaperShareSheetPresented = true
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.allRegisteredVideoPaths.isEmpty)

                    Button(model.localizedString("動画を追加")) {
                        NotificationCenter.default.post(name: .chooseVideo, object: nil)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            if model.allRegisteredVideoPaths.isEmpty {
                Text(model.localizedString("1. 「動画を追加」を押して動画を選ぶ\n2. 選んだ動画がそのまま壁紙として再生されます"))
                    .font(.caption)
                    .foregroundColor(.secondary)
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
                                wallpaperCard(
                                    path: path,
                                    cardWidth: layout.1,
                                    canDragToPlaylist: true
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
