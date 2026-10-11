import Foundation

extension UserDefaults {
    /// Decodes a JSON blob stored under `key`, or returns nil when the key is absent.
    ///
    /// When the blob exists but cannot be decoded, the next save would overwrite it with the
    /// in-memory defaults and the user's data would be gone for good. The raw bytes are copied
    /// to `<key>.unreadable` first so they can still be recovered by hand (e.g. after a downgrade).
    func decodedJSON<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = data(forKey: key) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            let backupKey = key + ".unreadable"
            set(data, forKey: backupKey)
            AppLog.persistence.error(
                "decode failed key=\(key, privacy: .public) bytes=\(data.count, privacy: .public) backup=\(backupKey, privacy: .public) error=\(Self.decodeFailureKind(error), privacy: .public)"
            )
            return nil
        }
    }

    /// Coding paths of path-keyed dictionaries contain file paths (and so the user name),
    /// and the log ends up in exported diagnostics, so only the failure kind is logged.
    private static func decodeFailureKind(_ error: Error) -> String {
        switch error as? DecodingError {
        case .typeMismatch: "typeMismatch"
        case .valueNotFound: "valueNotFound"
        case .keyNotFound: "keyNotFound"
        case .dataCorrupted: "dataCorrupted"
        case nil: String(describing: type(of: error))
        @unknown default: "unknown"
        }
    }
}
