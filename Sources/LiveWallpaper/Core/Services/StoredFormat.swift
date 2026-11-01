import Foundation

/// The version of a JSON file the app writes for itself (scene.json, preset.json).
///
/// Decoders here skip what they do not know (unknown layers, links and effects are
/// dropped, not rejected), so an older app reading a newer file would succeed and then
/// save it back without the parts it skipped. A file from a newer format is therefore
/// refused before decoding, and left on disk untouched.
struct StoredFormat {
    /// Turns the JSON of version `from` into version `from + 1`.
    struct Step {
        /// Only the number is added; the shape is the same, so the file is not re-parsed.
        let stampOnly: Bool
        let apply: (inout [String: Any]) throws -> Void

        static let stamp = Step(stampOnly: true) { _ in }
    }

    struct NewerVersionError: LocalizedError {
        let found: Int
        let supported: Int

        var errorDescription: String? {
            NSLocalizedString(
                "新しい版のLiveWallpaperで作られたため、この版では開けません。LiveWallpaperを更新してください。", comment: ""
            )
        }
    }

    struct InvalidVersionError: LocalizedError {
        var errorDescription: String? {
            "formatVersion must be a non-negative integer"
        }
    }

    /// What `prepare` made of a file.
    struct Prepared {
        let data: Data
        let storedVersion: Int
        /// The shape changed, so the stored file is worth keeping a copy of before it is overwritten.
        let reshaped: Bool
    }

    static let versionKey = "formatVersion"

    /// `steps[n]` upgrades version n to n + 1; a file without a number is version 0.
    let steps: [Step]

    var current: Int { steps.count }

    func prepare(_ data: Data) throws -> Prepared {
        let stored = try Self.storedVersion(of: data)
        guard stored <= current else {
            throw NewerVersionError(found: stored, supported: current)
        }
        let pending = steps[stored...]
        guard pending.contains(where: { !$0.stampOnly }) else {
            return Prepared(data: data, storedVersion: stored, reshaped: false)
        }
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Top level must be an object"))
        }
        for step in pending {
            try step.apply(&object)
        }
        object[Self.versionKey] = current
        return Prepared(data: try JSONSerialization.data(withJSONObject: object), storedVersion: stored, reshaped: true)
    }

    func encode<Value: Encodable>(_ value: Value, using encoder: JSONEncoder) throws -> Data {
        try encoder.encode(Versioned(value: value, version: current))
    }

    /// The version only, which a newer file may carry next to a shape this app cannot decode.
    static func storedVersion(of data: Data) throws -> Int {
        struct Header: Decodable {
            var formatVersion: Int?
        }
        let version = try JSONDecoder().decode(Header.self, from: data).formatVersion ?? 0
        guard version >= 0 else {
            throw InvalidVersionError()
        }
        return version
    }

    private struct Versioned<Value: Encodable>: Encodable {
        struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }

            init(stringValue: String) {
                self.stringValue = stringValue
            }

            init?(intValue _: Int) {
                nil
            }
        }

        let value: Value
        let version: Int

        func encode(to encoder: Encoder) throws {
            try value.encode(to: encoder)
            var container = encoder.container(keyedBy: Key.self)
            try container.encode(version, forKey: Key(stringValue: StoredFormat.versionKey))
        }
    }
}

extension StoredFormat {
    static let scene = StoredFormat(steps: [.stamp])
    static let scenePreset = StoredFormat(steps: [.stamp])
}
