import Foundation

enum AutomationNameMatch<ID: Equatable>: Equatable {
    case unique(ID)
    case notFound
    /// Several items matched at the same priority; doing nothing beats switching to the wrong one.
    case ambiguous([String])
}

/// Resolves the URL scheme's `name=` against registered display names.
///
/// Exact match first, then prefix match; a stage wins only if it narrows to one
/// target. Case and full/half width are ignored because names are typed by hand
/// in Shortcuts.
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
        // Several names (aliases) for the same target are not ambiguous.
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
