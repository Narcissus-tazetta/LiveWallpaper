import Foundation

/// issue #20 のStoreブラウズ/ダウンロードフロー。カタログはWorkerの GET /catalog から
/// 取得するだけで、ダウンロードした .lwpkg のインポートは既存の PackageImporter を
/// そのまま使う(マニフェストの edit フィールドが後方互換なので変更不要)。
@MainActor
final class StoreCatalogController: ObservableObject {
    @Published var entries: [StoreEntry] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var downloadingEntryID: String?
    /// 0...1 while `downloadingEntryID` downloads.
    @Published var downloadProgress: Double?
    /// The entry a shared Store link asked to show, above the catalog.
    @Published var linkedEntry: StoreEntry?
    @Published var downloadResultMessage: String?
    @Published var reportResultMessage: String?
    @Published var reportedEntryIDs: Set<String> = []
    @Published private(set) var searchQuery: String = ""
    @Published private(set) var sortOption: StoreSortOption = .newest
    /// 検索デバウンス待ち〜再検索完了までを表す、ページング読み込み(isLoading)とは
    /// 独立したフラグ。既存の entries は reload() 完了まで書き換わらないため一覧の
    /// ちらつきは元々発生していないが、「検索中」であることをフィールド脇の小さい
    /// インジケータでユーザーに伝えるために使う。
    @Published private(set) var isSearching: Bool = false

    private var nextCursor: String?
    private var hasLoadedOnce: Bool = false
    private var searchDebounceTask: Task<Void, Never>?
    private var requestGeneration: UInt64 = 0
    private let session: URLSession
    private let fileManager: FileManager
    private let endpointURL: URL
    private let packageImporter: PackageImporter

    init(
        session: URLSession = .shared,
        fileManager: FileManager = .default,
        baseURL: URL? = nil,
        packageImporter: PackageImporter? = nil
    ) {
        self.session = session
        self.fileManager = fileManager
        endpointURL = baseURL ?? StoreClient.baseURL
        self.packageImporter = packageImporter ?? PackageImporter(limits: .store)
    }

    func loadIfNeeded() async {
        guard !hasLoadedOnce else {
            return
        }
        await reload()
    }

    /// 検索欄の入力ごとに即リロードすると打鍵のたびにリクエストが飛ぶため、
    /// 入力が止まって一定時間経ってから実際のリロードを行う。
    func setSearchQuery(_ query: String) {
        guard searchQuery != query else {
            return
        }
        searchQuery = query
        searchDebounceTask?.cancel()
        searchDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self, !Task.isCancelled else {
                return
            }
            isSearching = true
            await reload()
            isSearching = false
        }
    }

    func setSortOption(_ option: StoreSortOption) {
        guard sortOption != option else {
            return
        }
        sortOption = option
        searchDebounceTask?.cancel()
        // Taskの実行開始前に旧レスポンスが返る隙をなくす。
        requestGeneration &+= 1
        Task { [weak self] in await self?.reload() }
    }

    func reload() async {
        requestGeneration &+= 1
        let generation = requestGeneration
        hasLoadedOnce = true
        isLoading = true
        errorMessage = nil
        nextCursor = nil
        defer {
            if requestGeneration == generation {
                isLoading = false
            }
        }
        do {
            let page = try await fetchPage(cursor: nil)
            guard requestGeneration == generation else { return }
            entries = page.entries
            nextCursor = page.nextCursor
        } catch {
            guard requestGeneration == generation else { return }
            errorMessage = error.localizedDescription
        }
    }

    func loadMoreIfNeeded(currentEntry: StoreEntry) async {
        guard currentEntry.id == entries.last?.id, let cursor = nextCursor, !isLoading else {
            return
        }
        isLoading = true
        let generation = requestGeneration
        defer {
            if requestGeneration == generation {
                isLoading = false
            }
        }
        do {
            let page = try await fetchPage(cursor: cursor)
            guard requestGeneration == generation else { return }
            entries.append(contentsOf: page.entries)
            nextCursor = page.nextCursor
        } catch {
            guard requestGeneration == generation else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func fetchPage(cursor: String?) async throws -> StoreCatalogResponse {
        var components = URLComponents(
            url: endpointURL.appendingPathComponent("catalog"),
            resolvingAgainstBaseURL: false
        )!
        var queryItems = [URLQueryItem(name: "limit", value: "20")]
        if let cursor {
            queryItems.append(URLQueryItem(name: "cursor", value: cursor))
        }
        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespaces)
        if !trimmedQuery.isEmpty {
            queryItems.append(URLQueryItem(name: "q", value: trimmedQuery))
        }
        if sortOption == .popular {
            queryItems.append(URLQueryItem(name: "sort", value: sortOption.rawValue))
        }
        components.queryItems = queryItems

        let (data, response) = try await session.data(from: components.url!)
        guard let http = response as? HTTPURLResponse,
              (200 ..< 300).contains(http.statusCode)
        else {
            throw StoreClientError.invalidResponse
        }
        return try JSONDecoder().decode(StoreCatalogResponse.self, from: data)
    }

    func download(entry: StoreEntry, into model: WallpaperModel) async {
        downloadingEntryID = entry.id
        downloadProgress = 0
        downloadResultMessage = nil
        defer {
            downloadingEntryID = nil
            downloadProgress = nil
        }

        guard let url = URL(string: entry.downloadURL) else {
            downloadResultMessage = Self.localized("ダウンロードURLが不正です")
            return
        }

        let packageURL: URL
        do {
            packageURL = try await StoreDownloader.download(
                from: url,
                session: session,
                maxBytes: Int64(StoreClient.maxUploadBytes),
                expectedSHA256: entry.sha256
            ) { [weak self] fraction in
                Task { @MainActor in
                    guard self?.downloadingEntryID == entry.id else { return }
                    self?.downloadProgress = fraction
                }
            }
        } catch {
            AppLog.store.error(
                "download failed id=\(entry.id, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            downloadResultMessage = error.localizedDescription
            return
        }
        defer { BlockingWork.removeInBackground(packageURL) }

        switch await PackageImportFlow.importPackage(
            at: packageURL,
            model: model,
            importer: packageImporter,
            confirmsContents: false
        ) {
        case .imported:
            downloadResultMessage = model.localizedString("追加しました")
        case .cancelled:
            break
        case let .failed(message):
            downloadResultMessage = message
        }
    }

    func openLinkedEntry(id: String) async {
        downloadResultMessage = nil
        let url = endpointURL.appendingPathComponent("entries").appendingPathComponent(id)
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else {
                throw StoreClientError.invalidResponse
            }
            guard http.statusCode != 404 else {
                linkedEntry = nil
                downloadResultMessage = Self
                    .localized("この作品は見つかりませんでした。取り下げられた可能性があります")
                return
            }
            guard (200 ..< 300).contains(http.statusCode) else {
                throw StoreClientError.serverError(status: http.statusCode, message: nil)
            }
            linkedEntry = try JSONDecoder().decode(StoreEntry.self, from: data)
        } catch {
            AppLog.store.error(
                "linked entry failed id=\(id, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            downloadResultMessage = error.localizedDescription
        }
    }

    static func shareLink(for entry: StoreEntry) -> URL {
        StoreClient.baseURL.appendingPathComponent("w").appendingPathComponent(entry.id)
    }

    func report(entry: StoreEntry, reason: String) async {
        reportResultMessage = nil
        guard !reportedEntryIDs.contains(entry.id) else {
            return
        }
        struct ReportBody: Encodable {
            let entryId: String
            let reason: String
        }
        var request = URLRequest(url: endpointURL.appendingPathComponent("report"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        do {
            request.httpBody = try JSONEncoder().encode(ReportBody(
                entryId: entry.id,
                reason: reason
            ))
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200 ..< 300).contains(http.statusCode)
            else {
                throw StoreClientError.invalidResponse
            }
            _ = data
            reportedEntryIDs.insert(entry.id)
            reportResultMessage = Self.localized("通報しました。ご協力ありがとうございます")
        } catch {
            AppLog.store
                .error("report failed error=\(error.localizedDescription, privacy: .public)")
            reportResultMessage = Self.localized("通報に失敗しました。もう一度お試しください")
        }
    }

    private static func localized(_ key: String) -> String {
        let raw =
            UserDefaults.standard.string(forKey: PrefsKey.appLanguage) ?? AppLanguage.automatic
                .rawValue
        let language = AppLanguage(rawValue: raw) ?? .automatic
        return AppLocalization.localizedString(key, languageCode: language.effectiveLanguageCode)
    }
}
