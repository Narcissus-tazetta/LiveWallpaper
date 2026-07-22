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

    private var nextCursor: String?
    private var hasLoadedOnce: Bool = false
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
        struct ReportBody: Encodable {
            let entryId: String
            let reason: String
        }
        var request = URLRequest(url: StoreClient.baseURL.appendingPathComponent("report"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try? JSONEncoder().encode(ReportBody(entryId: entry.id, reason: reason))
        _ = try? await session.data(for: request)
    }
}
