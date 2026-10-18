import Foundation

enum WebPropertyValue: Codable, Equatable, Hashable {
    case bool(Bool), number(Double), string(String), null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() {
            self = .null
        } else if let boolean = try? value.decode(Bool.self) {
            self = .bool(boolean)
        } else if let number = try? value.decode(Double.self),
                  number.isFinite
        {
            self = .number(number)
        } else { self = try .string(value.decode(String.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case let .bool(item): try value.encode(item)
        case let .number(item): try value.encode(item)
        case let .string(item): try value.encode(item)
        case .null: try value.encodeNil()
        }
    }

    var string: String {
        if case let .string(value) = self { return value }; return ""
    }

    var number: Double {
        if case let .number(value) = self { return value }; return 0
    }

    var bool: Bool {
        if case let .bool(value) = self { return value }; return false
    }
}

struct LocalWebProperty: Codable, Identifiable, Equatable {
    struct Option: Codable, Equatable {
        var label: [String: String]
        var value: WebPropertyValue
    }

    var id: String
    var kind: String
    var label: [String: String]
    var value: WebPropertyValue
    var minimum: Double?
    var maximum: Double?
    var step: Double?
    var options: [Option]?
    var condition: String?

    static func text(_ translations: [String: String], locale: Locale) -> String {
        let language = locale.language.languageCode?.identifier ?? "en"
        let script = locale.language.script?.identifier
        let scriptKey = script.map { language + "-" + $0 } ?? language
        return translations[locale.identifier] ?? translations[scriptKey] ?? translations[language]
            ?? translations["en"] ?? translations["default"] ?? ""
    }
}

struct LocalWebSettings: Codable, Equatable {
    var values: [String: WebPropertyValue] = [:]
    var audioReactiveEnabled = false
    var mediaEnabled = false

    static func load(id: UUID) throws -> Self {
        guard let data = UserDefaults.standard.data(forKey: key(id)) else { return Self() }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    func save(id: UUID) throws {
        try UserDefaults.standard.set(JSONEncoder().encode(self), forKey: Self.key(id))
    }

    private static func key(_ id: UUID) -> String {
        "localWebSettings.\(id.uuidString)"
    }
}

/// Conditions are data, not executable JavaScript from an external package.
struct LocalWebPropertyCondition {
    private var tokens: [String]
    private var index = 0
    private let values: [String: WebPropertyValue]

    static func evaluate(_ expression: String, values: [String: WebPropertyValue]) -> Bool? {
        let pattern =
            #/\s*([A-Za-z_$][\w$]*(?:\.value)?|===|!==|==|!=|>=|<=|&&|\|\||[()!<>]|-?\d+(?:\.\d+)?|'(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*")/#
        var end = expression.startIndex
        var tokens: [String] = []
        for match in expression.matches(of: pattern) {
            guard match.range.lowerBound == end else { return nil }
            end = match.range.upperBound
            tokens.append(String(match.output.1))
        }
        guard expression[end...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        var parser = Self(tokens: tokens, values: values)
        guard let value = parser.or(), parser.index == tokens.count else { return nil }
        return value
    }

    private mutating func take(_ token: String) -> Bool {
        guard index < tokens.count, tokens[index] == token else { return false }
        index += 1
        return true
    }

    private mutating func or() -> Bool? {
        guard var value = and() else { return nil }
        while take("||") {
            guard let right = and() else { return nil }
            value = value || right
        }
        return value
    }

    private mutating func and() -> Bool? {
        guard var value = comparison() else { return nil }
        while take("&&") {
            guard let right = comparison() else { return nil }
            value = value && right
        }
        return value
    }

    private mutating func comparison() -> Bool? {
        guard let left = unary() else { return nil }
        guard index < tokens.count,
              ["==", "===", "!=", "!==", ">", "<", ">=", "<="].contains(tokens[index])
        else {
            return Self.truth(left)
        }
        let operation = tokens[index]
        index += 1
        guard let right = unary() else { return nil }
        return Self.compare(left, right, operation: operation)
    }

    private mutating func unary() -> WebPropertyValue? {
        if take("!") { return unary().map { .bool(!Self.truth($0)) } }
        if take("(") {
            guard let value = or(), take(")") else { return nil }
            return .bool(value)
        }
        return operand()
    }

    private static func compare(
        _ left: WebPropertyValue,
        _ right: WebPropertyValue,
        operation: String
    ) -> Bool {
        switch operation {
        case "===": return left == right
        case "!==": return left != right
        case "==": return equal(left, right)
        case "!=": return !equal(left, right)
        default:
            if case let .string(a) = left, case let .string(b) = right {
                switch operation {
                case ">": return a > b
                case "<": return a < b
                case ">=": return a >= b
                default: return a <= b
                }
            }
            guard let a = numeric(left), let b = numeric(right) else { return false }
            switch operation {
            case ">": return a > b
            case "<": return a < b
            case ">=": return a >= b
            default: return a <= b
            }
        }
    }

    private static func numeric(_ value: WebPropertyValue) -> Double? {
        switch value {
        case let .bool(value): return value ? 1 : 0
        case let .number(value): return value
        case let .string(value):
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? 0 : Double(text)
        case .null: return 0
        }
    }

    private static func equal(_ left: WebPropertyValue, _ right: WebPropertyValue) -> Bool {
        if left == right { return true }
        if case .string = left, case .string = right { return false }
        if left == .null || right == .null { return false }
        guard let a = numeric(left), let b = numeric(right) else { return false }
        return a == b
    }

    private static func truth(_ value: WebPropertyValue) -> Bool {
        switch value {
        case let .bool(value): return value
        case let .number(value): return value != 0
        case let .string(value): return !value.isEmpty
        case .null: return false
        }
    }

    private mutating func operand() -> WebPropertyValue? {
        guard index < tokens.count else { return nil }
        let token = tokens[index]
        index += 1
        if token == "true" { return .bool(true) }
        if token == "false" { return .bool(false) }
        if token == "null" { return .null }
        if let number = Double(token) { return .number(number) }
        if token.hasPrefix("'") || token.hasPrefix("\"") {
            return .string(String(token.dropFirst().dropLast()).replacingOccurrences(
                of: "\\'",
                with: "'"
            ).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(
                of: "\\\\",
                with: "\\"
            ))
        }
        if token.hasSuffix(".value") { return values[String(token.dropLast(6))] }
        return values[token]
    }
}
