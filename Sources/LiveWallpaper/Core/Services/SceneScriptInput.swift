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

    mutating func null() {
        bytes.append(0)
    }

    mutating func bool(_ value: Bool) {
        bytes.append(value ? 2 : 1)
    }

    /// JSON has no NaN or infinity, and scripts were never given one.
    mutating func number(_ value: Double) throws {
        guard value.isFinite
        else {
            throw InvalidValue(errorDescription: "Invalid number value (\(value)) in script input")
        }
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
    mutating func beginArray() -> Int {
        begin(5)
    }

    mutating func beginObject() -> Int {
        begin(6)
    }

    mutating func key(_ name: String) {
        appendText(name)
    }

    mutating func end(_ position: Int, count: Int) {
        withUnsafeBytes(of: UInt32(count).littleEndian) { bytes.replaceSubrange(
            position ..< position + 4,
            with: $0
        ) }
    }

    mutating func append(_ other: SceneScriptInput) {
        bytes.append(contentsOf: other.bytes)
    }

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
            } else if CFNumberGetType(number) == .float32Type || CFNumberGetType(number) ==
                .floatType
            {
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
            for item in array {
                try self.value(item)
            }
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

/// Reads the tagged tree Bridge.c writes for an update(context) result into the
/// values JSONSerialization makes from the same result's JSON text: NSNull, CFBoolean,
/// Int64 or Double NSNumbers, String, [Any] and [String: Any].
/// Tags: 0 null, 1 false, 2 true, 3 int64, 4 float64, 5 string, 6 array, 7 object;
/// strings, arrays and objects carry a u32 count, object keys a u32 length.
enum SceneScriptOutputReader {
    static let magic: UInt8 = 0xFF

    static func read(_ bytes: UnsafeRawBufferPointer) -> Any {
        var offset = 1
        return value(bytes, &offset)
    }

    private static func value(_ bytes: UnsafeRawBufferPointer, _ offset: inout Int) -> Any {
        let tag = bytes[offset]
        offset += 1
        switch tag {
        case 0:
            return NSNull()
        case 1, 2:
            return NSNumber(value: tag == 2)
        case 3:
            return NSNumber(value: Int64(littleEndian: load(bytes, &offset)))
        case 4:
            return NSNumber(value: Double(bitPattern: UInt64(littleEndian: load(bytes, &offset))))
        case 5:
            return text(bytes, &offset)
        case 6:
            let count = Int(UInt32(littleEndian: load(bytes, &offset)))
            var array: [Any] = []
            array.reserveCapacity(count)
            for _ in 0 ..< count {
                array.append(value(bytes, &offset))
            }
            return array
        default:
            let count = Int(UInt32(littleEndian: load(bytes, &offset)))
            var object: [String: Any] = Dictionary(minimumCapacity: count)
            for _ in 0 ..< count {
                let key = text(bytes, &offset)
                object[key] = value(bytes, &offset)
            }
            return object
        }
    }

    private static func load<T: FixedWidthInteger>(
        _ bytes: UnsafeRawBufferPointer,
        _ offset: inout Int
    ) -> T {
        defer { offset += MemoryLayout<T>.size }
        return bytes.loadUnaligned(fromByteOffset: offset, as: T.self)
    }

    private static func text(_ bytes: UnsafeRawBufferPointer, _ offset: inout Int) -> String {
        let length = Int(UInt32(littleEndian: load(bytes, &offset)))
        defer { offset += length }
        return String(
            decoding: UnsafeRawBufferPointer(rebasing: bytes[offset ..< offset + length]),
            as: UTF8.self
        )
    }
}

/// Decodes a script's checked output values (as SceneScriptOutputReader or
/// JSONSerialization makes them) the way JSONDecoder decodes their JSON text, without
/// writing and parsing that text. Float is left out: JSONDecoder rounds the decimal
/// text to Float, which differs from rounding the Double in rare cases.
struct SceneScriptValueDecoder: Decoder {
    let value: Any
    var codingPath: [CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] {
        [:]
    }

    static func decode<T: Decodable>(_: T.Type, from value: Any) throws -> T {
        try T(from: SceneScriptValueDecoder(value: value))
    }

    func container<Key: CodingKey>(keyedBy _: Key.Type) throws -> KeyedDecodingContainer<Key> {
        guard let object = value as? [String: Any] else { throw mismatch(
            [String: Any].self,
            codingPath
        ) }
        return KeyedDecodingContainer(Keyed<Key>(object: object, codingPath: codingPath))
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        throw DecodingError.typeMismatch(
            [Any].self,
            .init(
                codingPath: codingPath,
                debugDescription: "Arrays are not decoded from script values"
            )
        )
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        Single(
            value: value,
            codingPath: codingPath
        )
    }

    fileprivate static func number(
        _ value: Any,
        _ type: Any.Type,
        _ path: [CodingKey]
    ) throws -> NSNumber {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { throw mismatch(
            type,
            path
        ) }
        return number
    }

    /// The caller has matched `type` already; this only spells the conversion without `as!`.
    private static func typed<T>(_ value: Any, _ type: T.Type, _ path: [CodingKey]) throws -> T {
        guard let typed = value as? T else {
            throw mismatch(type, path)
        }
        return typed
    }

    fileprivate static func decodeValue<T: Decodable>(
        _ type: T.Type,
        _ value: Any,
        _ path: [CodingKey]
    ) throws -> T {
        switch type {
        case is Bool.Type:
            guard let number = value as? NSNumber,
                  CFGetTypeID(number) == CFBooleanGetTypeID()
            else { throw mismatch(
                type,
                path
            ) }
            return try typed(number.boolValue, type, path)
        case is Double.Type:
            return try typed(number(value, type, path).doubleValue, type, path)
        case is Int.Type:
            let number = try number(value, type, path)
            let integer = CFNumberIsFloatType(number) ? Int(exactly: number.doubleValue) :
                Int(exactly: number.int64Value)
            guard let integer else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: path,
                    debugDescription: "Number \(number) does not fit in Int."
                ))
            }
            return try typed(integer, type, path)
        case is String.Type:
            guard let text = value as? String else { throw mismatch(type, path) }
            return try typed(text, type, path)
        case is Float.Type:
            throw DecodingError.typeMismatch(
                type,
                .init(codingPath: path, debugDescription: "Float is decoded from JSON text")
            )
        default:
            return try T(from: SceneScriptValueDecoder(value: value, codingPath: path))
        }
    }

    private struct Keyed<Key: CodingKey>: KeyedDecodingContainerProtocol {
        let object: [String: Any]
        let codingPath: [CodingKey]
        var allKeys: [Key] {
            object.keys.compactMap(Key.init(stringValue:))
        }

        func contains(_ key: Key) -> Bool {
            object[key.stringValue] != nil
        }

        func decodeNil(forKey key: Key) throws -> Bool {
            object[key.stringValue] is NSNull
        }

        func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
            guard let value = object[key.stringValue] else {
                throw DecodingError.keyNotFound(
                    key,
                    .init(
                        codingPath: codingPath,
                        debugDescription: "No value for \(key.stringValue)."
                    )
                )
            }
            return try decodeValue(type, value, codingPath + [key])
        }

        func decodeIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
            guard let value = object[key.stringValue], !(value is NSNull) else { return nil }
            return try decodeValue(type, value, codingPath + [key])
        }

        func nestedContainer<NestedKey: CodingKey>(
            keyedBy type: NestedKey.Type,
            forKey key: Key
        ) throws -> KeyedDecodingContainer<NestedKey> {
            try SceneScriptValueDecoder(
                value: object[key.stringValue] as Any,
                codingPath: codingPath + [key]
            ).container(keyedBy: type)
        }

        func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
            try SceneScriptValueDecoder(
                value: object[key.stringValue] as Any,
                codingPath: codingPath + [key]
            ).unkeyedContainer()
        }

        func superDecoder() throws -> Decoder {
            SceneScriptValueDecoder(
                value: object,
                codingPath: codingPath
            )
        }

        func superDecoder(forKey key: Key) throws -> Decoder {
            SceneScriptValueDecoder(
                value: object[key.stringValue] ?? NSNull(),
                codingPath: codingPath + [key]
            )
        }
    }

    private struct Single: SingleValueDecodingContainer {
        let value: Any
        let codingPath: [CodingKey]

        func decodeNil() -> Bool {
            value is NSNull
        }

        func decode<T: Decodable>(_ type: T.Type) throws -> T {
            try decodeValue(
                type,
                value,
                codingPath
            )
        }
    }
}

private func mismatch(_ type: Any.Type, _ path: [CodingKey]) -> DecodingError {
    DecodingError.typeMismatch(
        type,
        .init(
            codingPath: path,
            debugDescription: "Expected to decode \(type) but found another value."
        )
    )
}
