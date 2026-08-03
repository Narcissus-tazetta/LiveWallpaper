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
    func record(id: String, title: String, createdAt: String, withdrawToken: String) {
        submissions.removeAll { $0.id == id }
        submissions.insert(
            StoreMySubmission(
                id: id,
                title: title,
                createdAt: createdAt,
                lastKnownStatus: "requested",
                withdrawToken: withdrawToken
            ),
            at: 0
        )
        persist()
    }

    /// ローカルの一覧から消すだけで、サーバー側の投稿には触れない。withdrawTokenを
    /// 持たない古い記録(この機能を追加する前に送信したもの)向けのフォールバック。
    func remove(id: String) {
        submissions.removeAll { $0.id == id }
        persist()
    }

    /// サーバー側に自己サービスの取り下げ(DELETE /entries/:id/withdraw)を要求し、
    /// 成功した場合のみローカルの一覧からも消す。withdrawTokenを持たない記録は
    /// サーバー側で取り下げようがないため、呼び出し側(UI)でボタンを出し分ける。
    func withdraw(id: String) async {
        guard let submission = submissions.first(where: { $0.id == id }),
              let token = submission.withdrawToken
        else {
            errorMessage = Self.localized("この投稿は取り下げに対応していません。リストから削除のみ行えます")
            return
        }
        isRefreshing = true
        errorMessage = nil
        defer { isRefreshing = false }
        do {
            try await performWithdraw(id: id, token: token)
            remove(id: id)
        } catch {
            errorMessage = Self.localized("取り下げに失敗しました。もう一度お試しください")
        }
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

    private func performWithdraw(id: String, token: String) async throws {
        struct WithdrawRequestBody: Encodable {
            let token: String
        }
        var request = URLRequest(url: StoreClient.baseURL.appendingPathComponent("entries/\(id)/withdraw"))
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(WithdrawRequestBody(token: token))
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw StoreClientError.invalidResponse
        }
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
        let raw = UserDefaults.standard.string(forKey: PrefsKey.appLanguage) ?? AppLanguage.automatic.rawValue
        let language = AppLanguage(rawValue: raw) ?? .automatic
        return AppLocalization.localizedString(key, languageCode: language.effectiveLanguageCode)
    }
}
