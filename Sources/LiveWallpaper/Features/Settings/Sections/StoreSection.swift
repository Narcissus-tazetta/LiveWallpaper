import SwiftUI

extension SettingsView {
    var storeTabContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(model.localizedString("Store"), systemImage: "square.grid.2x2.fill")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                if let message = storeCatalog.reportResultMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if let message = storeCatalog.downloadResultMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Button {
                    isStoreSharePickerPresented = true
                } label: {
                    Label(model.localizedString("動画を共有"), systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .disabled(model.allRegisteredVideoPaths.isEmpty)

                Button {
                    Task {
                        await storeCatalog.reload()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(storeCatalog.isLoading)
            }

            if let errorMessage = storeCatalog.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            if storeCatalog.entries.isEmpty {
                if storeCatalog.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 40)
                } else {
                    Text(model.localizedString("まだ公開されている壁紙がありません"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                GeometryReader { proxy in
                    let layout = wallpaperGridLayout(for: proxy.size.width)
                    ScrollView {
                        LazyVGrid(
                            columns: layout.0,
                            alignment: .leading,
                            spacing: wallpaperGridRowSpacing
                        ) {
                            ForEach(storeCatalog.entries) { entry in
                                storeEntryCard(entry: entry, cardWidth: layout.1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                    }
                }
                .frame(minHeight: 320, maxHeight: 560)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.08))
        )
        .task {
            await storeCatalog.loadIfNeeded()
        }
    }
}
