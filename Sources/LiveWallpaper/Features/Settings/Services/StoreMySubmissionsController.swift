import Foundation

/// この端末からStoreに投稿したエントリのローカル記録と、審査状況(requested/
/// published/rejected)の追跡を担当する。サーバー側は投稿者アカウントの概念を
/// 持たないため、「自分の投稿」はこの端末のUserDefaultsに覚えたidのリストを
/// GET /entries/:id/status で都度引き直すだけの、ベストエフォートな仕組み。
/// アプリの再インストールや端末変更をまたいでは追跡できない。
@MainActor
final class StoreMySubmissionsController: ObservableObject {
    @Published private(set) var submissions: [StoreMySubmission] = []
    @Published var isRefreshing: Bool = false
    @Published var errorMessage: String?

    private let defaults: UserDefaults
    private let session: URLSession
    private static let storageKey = "store.mySubmissions"

    init(defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.defaults = defaults
        self.session = session
        submissions = Self.load(from: defaults)
    }

    /// Store投稿が成功した直後に呼ぶ。同じidの既存レコードがあれば先頭に上書き
    /// (再投稿はしない設計だが、将来的な再送信に備えて重複させない)。
    func record(id: String, title: String, createdAt: String) {
        submissions.removeAll { $0.id == id }
        submissions.insert(
            StoreMySubmission(id: id, title: title, createdAt: createdAt, lastKnownStatus: "requested"),
            at: 0
        )
        persist()
    }

    func remove(id: String) {
        submissions.removeAll { $0.id == id }
        persist()
    }

    /// 全投稿のステータスを順番に問い合わせる。件数は個人の投稿数程度で多くならない
    /// 想定のため、並列化はせず単純に直列で行う。1件が404(運営がpurgeした等)でも
    /// 他の問い合わせは継続する。
    func refreshAll() async {
        guard !submissions.isEmpty else {
            return
        }
        isRefreshing = true
        errorMessage = nil
        defer { isRefreshing = false }

        var anySucceeded = false
        for index in submissions.indices {
            if let status = try? await fetchStatus(id: submissions[index].id) {
                submissions[index].lastKnownStatus = status
                anySucceeded = true
            }
        }
        if !anySucceeded {
            errorMessage = Self.localized("ステータスの取得に失敗しました。しばらくしてから再度お試しください")
        }
        persist()
    }

    private func fetchStatus(id: String) async throws -> String {
        let url = StoreClient.baseURL.appendingPathComponent("entries/\(id)/status")
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw StoreClientError.invalidResponse
        }
        return try JSONDecoder().decode(StoreEntryStatusResponse.self, from: data).status
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(submissions) else {
            return
        }
        defaults.set(data, forKey: Self.storageKey)
    }

    private static func load(from defaults: UserDefaults) -> [StoreMySubmission] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([StoreMySubmission].self, from: data)
        else {
            return []
        }
        return decoded
    }

    private static func localized(_ key: String) -> String {
        let raw = UserDefaults.standard.string(forKey: "appLanguage") ?? AppLanguage.automatic.rawValue
        let language = AppLanguage(rawValue: raw) ?? .automatic
        return AppLocalization.localizedString(key, languageCode: language.effectiveLanguageCode)
    }
}
