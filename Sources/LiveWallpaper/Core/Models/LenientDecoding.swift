import Foundation

/// Scene and preset files are read leniently so one bad field never costs the user a whole
/// scene: a field that is missing or null takes its default (files written before it
/// existed), and a field that is present but unreadable (wrong type, an enum case from a
/// newer version) also takes its default, but is logged so the loss can be traced.
extension KeyedDecodingContainer {
    func decodeLenient<T: Decodable>(
        _ type: T.Type,
        forKey key: Key,
        default defaultValue: @autoclosure () -> T
    ) -> T {
        decodeLenientIfPresent(type, forKey: key) ?? defaultValue()
    }

    func decodeLenientIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        do {
            return try decodeIfPresent(type, forKey: key)
        } catch {
            LenientDecoding.report(error, path: codingPath + [key], type: type)
            return nil
        }
    }
}

enum LenientDecoding {
    /// Logs the field's path and the decoder's reason, never the value: scene files can hold
    /// text the user typed.
    static func report(_ error: Error, path: [CodingKey], type: Any.Type) {
        let field = path.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }
            .joined(separator: ".")
        AppLog.persistence.warning(
            "ignored unreadable field \(field, privacy: .public) (\(String(describing: type), privacy: .public)): \(reason(error), privacy: .public)"
        )
    }

    private static func reason(_ error: Error) -> String {
        guard let error = error as? DecodingError else {
            return error.localizedDescription
        }
        switch error {
        case let .typeMismatch(_, context), let .valueNotFound(_, context),
             let .keyNotFound(_, context), let .dataCorrupted(context):
            return context.debugDescription
        @unknown default:
            return String(describing: error)
        }
    }
}

/// Decodes an array element by element, dropping (and logging) the ones that cannot be read.
struct FailableDecodable<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        do {
            value = try Value(from: decoder)
        } catch {
            LenientDecoding.report(error, path: decoder.codingPath, type: Value.self)
            value = nil
        }
    }
}
