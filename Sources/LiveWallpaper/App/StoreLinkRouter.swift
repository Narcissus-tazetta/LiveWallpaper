import Combine
import Foundation

/// Carries a Store link opened from outside (`livewallpaper://store?id=…`) to the settings
/// window, which may not exist yet when the link arrives: a @Published value is replayed to
/// a subscriber that appears later.
@MainActor
final class StoreLinkRouter: ObservableObject {
    static let shared = StoreLinkRouter()

    @Published var requestedEntryID: String?

    /// Store ids are what the Store's own routes accept.
    static func isValidEntryID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64
            && id.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_"
            }
    }
}
