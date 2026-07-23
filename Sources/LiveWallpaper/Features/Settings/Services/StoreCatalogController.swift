import CryptoKit
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
    private let session: URLSession
    private let fileManager: FileManager

    init(session: URLSession = .shared, fileManager: FileManager = .default) {
        self.session = session
        self.fileManager = fileManager
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
            self.isSearching = true
            await self.reload()
            self.isSearching = false
        }
    }

    func setSortOption(_ option: StoreSortOption) {
        guard sortOption != option else {
            return
        }
        sortOption = option
        searchDebounceTask?.cancel()
        Task { await reload() }
    }

    func reload() async {
        hasLoadedOnce = true
        isLoading = true
        errorMessage = nil
        nextCursor = nil
        defer { isLoading = false }
        do {
            let page = try await fetchPage(cursor: nil)
            entries = page.entries
            nextCursor = page.nextCursor
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadMoreIfNeeded(currentEntry: StoreEntry) async {
        guard currentEntry.id == entries.last?.id, let cursor = nextCursor, !isLoading else {
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await fetchPage(cursor: cursor)
            entries.append(contentsOf: page.entries)
            nextCursor = page.nextCursor
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func fetchPage(cursor: String?) async throws -> StoreCatalogResponse {
        var components = URLComponents(
            url: StoreClient.baseURL.appendingPathComponent("catalog"),
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
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw StoreClientError.invalidResponse
        }
        return try JSONDecoder().decode(StoreCatalogResponse.self, from: data)
    }

    func download(entry: StoreEntry, into model: WallpaperModel) async {
        downloadingEntryID = entry.id
        downloadResultMessage = nil
        defer { downloadingEntryID = nil }

        guard let url = URL(string: entry.downloadURL) else {
            downloadResultMessage = "invalid download URL"
            return
        }

        let tempFile = fileManager.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).lwpkg")

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw StoreClientError.invalidResponse
            }
            let actualSHA256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actualSHA256.caseInsensitiveCompare(entry.sha256) == .orderedSame else {
                throw StoreClientError.checksumMismatch
            }
            try data.write(to: tempFile)
            defer { try? fileManager.removeItem(at: tempFile) }

            try await PackageImporter().importPackage(from: tempFile, into: model)
            downloadResultMessage = model.localizedString("追加しました")
        } catch {
            downloadResultMessage = error.localizedDescription
        }
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
        var request = URLRequest(url: StoreClient.baseURL.appendingPathComponent("report"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try? JSONEncoder().encode(ReportBody(entryId: entry.id, reason: reason))
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw StoreClientError.invalidResponse
            }
            _ = data
            reportedEntryIDs.insert(entry.id)
            reportResultMessage = Self.localized("通報しました。ご協力ありがとうございます")
        } catch {
            reportResultMessage = Self.localized("通報に失敗しました。もう一度お試しください")
        }
    }

    private static func localized(_ key: String) -> String {
        let raw = UserDefaults.standard.string(forKey: "appLanguage") ?? AppLanguage.automatic.rawValue
        let language = AppLanguage(rawValue: raw) ?? .automatic
        return AppLocalization.localizedString(key, languageCode: language.effectiveLanguageCode)
    }
}
