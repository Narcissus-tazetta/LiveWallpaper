import CoreFoundation
import Foundation

/// The update(context) argument as a tagged value tree that Bridge.c turns straight
/// into JavaScript values, instead of JSON text the script engine has to parse.
/// Tags: 0 null, 1 false, 2 true, 3 float64, 4 string, 5 array, 6 object; strings,
/// arrays and objects carry a u32 count, object keys a u32 length.
struct SceneScriptInput {
    private(set) var bytes: [UInt8] = []

    struct InvalidValue: Error, LocalizedError {
        var errorDescription: String?
    }

    mutating func null() { bytes.append(0) }

    mutating func bool(_ value: Bool) { bytes.append(value ? 2 : 1) }

    /// JSON has no NaN or infinity, and scripts were never given one.
    mutating func number(_ value: Double) throws {
        guard value.isFinite else { throw InvalidValue(errorDescription: "Invalid number value (\(value)) in script input") }
        bytes.append(3)
        withUnsafeBytes(of: value.bitPattern.littleEndian) { bytes.append(contentsOf: $0) }
    }

    /// JSONSerialization wrote a Float widened to Double, so scripts got that value.
    mutating func number(_ value: Float) throws {
        try number(Double(value))
    }

    mutating func string(_ value: String) {
        bytes.append(4)
        appendText(value)
    }

    /// Returns where the count goes, for `end(_:count:)`.
    mutating func beginArray() -> Int { begin(5) }

    mutating func beginObject() -> Int { begin(6) }

    mutating func key(_ name: String) { appendText(name) }

    mutating func end(_ position: Int, count: Int) {
        withUnsafeBytes(of: UInt32(count).littleEndian) { bytes.replaceSubrange(position ..< position + 4, with: $0) }
    }

    mutating func append(_ other: SceneScriptInput) { bytes.append(contentsOf: other.bytes) }

    /// Any value JSONSerialization would write.
    mutating func value(_ value: Any) throws {
        switch value {
        case is NSNull:
            null()
        case let text as String:
            string(text)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                bool(number.boolValue)
            } else if CFNumberGetType(number) == .float32Type || CFNumberGetType(number) == .floatType {
                try self.number(number.floatValue)
            } else {
                try self.number(number.doubleValue)
            }
        case let object as [String: Any]:
            let position = beginObject()
            for (name, item) in object {
                key(name)
                try self.value(item)
            }
            end(position, count: object.count)
        case let array as [Any]:
            let position = beginArray()
            for item in array { try self.value(item) }
            end(position, count: array.count)
        default:
            throw InvalidValue(errorDescription: "Invalid type in script input: \(type(of: value))")
        }
    }

    private mutating func begin(_ tag: UInt8) -> Int {
        bytes.append(tag)
        bytes.append(contentsOf: [0, 0, 0, 0])
        return bytes.count - 4
    }

    private mutating func appendText(_ text: String) {
        var text = text
        text.withUTF8 { utf8 in
            withUnsafeBytes(of: UInt32(utf8.count).littleEndian) { bytes.append(contentsOf: $0) }
            bytes.append(contentsOf: utf8)
        }
    }
}
