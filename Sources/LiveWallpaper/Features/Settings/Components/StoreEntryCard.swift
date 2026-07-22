import SwiftUI

extension SettingsView {
    func storeEntryCard(entry: StoreEntry, cardWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(height: cardWidth * 9 / 16)
                Image(systemName: "film.stack")
                    .font(.system(size: 22))
                    .foregroundColor(.secondary)
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
        .onAppear {
            Task {
                await storeCatalog.loadMoreIfNeeded(currentEntry: entry)
            }
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
