import SwiftUI

extension SettingsView {
    func storeEntryCard(entry: StoreEntry, cardWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(height: cardWidth * 9 / 16)
                if let image = remoteThumbnailCache.image(for: entry) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(height: cardWidth * 9 / 16)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    Image(systemName: "film.stack")
                        .font(.system(size: 22))
                        .foregroundColor(.secondary)
                }
            }

            Text(entry.title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)

            Text(entry.author)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)

            HStack(spacing: 6) {
                if let duration = entry.durationSeconds {
                    Text(storeEntryDurationText(duration))
                }
                Text(storeEntrySizeText(entry.sizeBytes))
                if entry.hasAudio == true {
                    Image(systemName: "speaker.wave.2.fill")
                }
            }
            .font(.caption2)
            .foregroundColor(.secondary)

            if storeCatalog.downloadingEntryID == entry.id {
                ProgressView().controlSize(.small)
            } else {
                Button(model.localizedString("追加")) {
                    Task {
                        await storeCatalog.download(entry: entry, into: model)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .frame(width: cardWidth, alignment: .leading)
        // LazyVGrid内でcontextMenuにid()を付けないと、スクロール後にAppKit側が
        // 別セルのメニュー(と閉じたクロージャが捕えたentry)を使い回すことがあり、
        // 右クリックしたカードと違うentryが通報される不具合につながる。
        .id(entry.id)
        .contextMenu {
            if storeCatalog.reportedEntryIDs.contains(entry.id) {
                Text(model.localizedString("通報済み"))
            } else {
                Button(model.localizedString("この動画を通報")) {
                    storeReportTargetEntry = entry
                }
            }
        }
        .onAppear {
            remoteThumbnailCache.setVisible(entryID: entry.id, isVisible: true)
            Task {
                await storeCatalog.loadMoreIfNeeded(currentEntry: entry)
            }
        }
        .onDisappear {
            remoteThumbnailCache.setVisible(entryID: entry.id, isVisible: false)
        }
    }

    private func storeEntryDurationText(_ seconds: Double) -> String {
        let total = max(Int(seconds.rounded()), 0)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func storeEntrySizeText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
