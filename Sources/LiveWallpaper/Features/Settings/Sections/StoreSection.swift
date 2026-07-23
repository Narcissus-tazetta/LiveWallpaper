import SwiftUI

extension SettingsView {
    var storeTabContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(model.localizedString("Store"), systemImage: "square.grid.2x2.fill")
                    .font(.system(size: 13, weight: .semibold))

                Picker("", selection: $storeTabMode) {
                    Text(model.localizedString("みんなの投稿")).tag(StoreTabMode.browse)
                    Text(model.localizedString("自分の投稿")).tag(StoreTabMode.mine)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)

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
                        switch storeTabMode {
                        case .browse:
                            await storeCatalog.reload()
                        case .mine:
                            await storeMySubmissions.refreshAll()
                        }
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(storeTabMode == .browse ? storeCatalog.isLoading : storeMySubmissions.isRefreshing)
            }

            switch storeTabMode {
            case .browse:
                storeBrowseContent
            case .mine:
                storeMySubmissionsList
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
        .onChange(of: storeTabMode) { mode in
            guard mode == .mine else {
                return
            }
            Task {
                await storeMySubmissions.refreshAll()
            }
        }
    }

    private var storeBrowseContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SearchField(
                    placeholder: model.localizedString("タイトルで検索"),
                    text: Binding(
                        get: { storeCatalog.searchQuery },
                        set: { storeCatalog.setSearchQuery($0) }
                    ),
                    isFocused: $isStoreSearchFocused,
                    isSearching: storeCatalog.isSearching
                )
                .frame(maxWidth: 260)
                .background(
                    Button("") { isStoreSearchFocused = true }
                        .keyboardShortcut("f", modifiers: .command)
                        .hidden()
                )

                Picker(
                    "",
                    selection: Binding(
                        get: { storeCatalog.sortOption },
                        set: { storeCatalog.setSortOption($0) }
                    )
                ) {
                    Text(model.localizedString("新着順")).tag(StoreSortOption.newest)
                    Text(model.localizedString("人気順")).tag(StoreSortOption.popular)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 160)

                Spacer(minLength: 0)
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
                    SearchEmptyState(
                        isSearchActive: !storeCatalog.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty,
                        noContentText: model.localizedString("まだ公開されている壁紙がありません"),
                        noMatchText: model.localizedString("検索条件に一致する壁紙がありません"),
                        clearButtonTitle: model.localizedString("検索をクリア"),
                        onClearSearch: { storeCatalog.setSearchQuery(""); isStoreSearchFocused = true }
                    )
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
    }
}
