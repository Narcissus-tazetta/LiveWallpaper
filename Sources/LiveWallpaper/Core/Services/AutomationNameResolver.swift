import Foundation

enum AutomationNameMatch<ID: Equatable>: Equatable {
    case unique(ID)
    case notFound
    /// 同じ優先度で複数が当たった。誤った壁紙へ切り替えるより何もしない方が安全。
    case ambiguous([String])
}

/// URL スキームの `name=` を登録済みの表示名へ解決する。
///
/// 完全一致 → 前方一致の順に探し、各段階で1件に絞れたときだけ採用する。
/// 大文字小文字と全角/半角は区別しない(ショートカット.app で手入力されるため)。
enum AutomationNameResolver {
    static func resolve<ID: Equatable>(
        _ query: String,
        among candidates: [(id: ID, name: String)]
    ) -> AutomationNameMatch<ID> {
        let needle = normalize(query)
        guard !needle.isEmpty else {
            return .notFound
        }
        let normalized = candidates.map { (id: $0.id, name: $0.name, key: normalize($0.name)) }

        let exact = normalized.filter { $0.key == needle }
        if let match = single(exact) {
            return match
        }
        let prefixed = normalized.filter { $0.key.hasPrefix(needle) }
        if let match = single(prefixed) {
            return match
        }
        return .notFound
    }

    private static func single<ID: Equatable>(
        _ matches: [(id: ID, name: String, key: String)]
    ) -> AutomationNameMatch<ID>? {
        guard let first = matches.first else {
            return nil
        }
        // 同じ対象に複数の名前(別名)がある場合は、どれに当たっても曖昧ではない。
        if matches.allSatisfy({ $0.id == first.id }) {
            return .unique(first.id)
        }
        return .ambiguous(matches.map(\.name))
    }

    private static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
    }
}
