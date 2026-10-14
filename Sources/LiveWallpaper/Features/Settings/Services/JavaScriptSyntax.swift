import Foundation

enum JavaScriptSyntax {
    enum Kind { case keyword, literal, number, string, comment, function, property, regex }
    struct Token {
        let range: NSRange
        let kind: Kind
    }
    private static let keywords: Set<String> = [
        "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default",
        "delete", "do", "else", "export", "extends", "finally", "for", "function", "if", "import", "in",
        "instanceof", "let", "new", "of", "return", "static", "super", "switch", "this", "throw", "try",
        "typeof", "var", "void", "while", "with", "yield"
    ]
    private static let literals: Set<String> = ["true", "false", "null", "undefined", "NaN", "Infinity"]

    static func tokens(in source: String) -> [Token] {
        // Drafts can exceed the runtime source limit; keep coloring bounded while the user edits them.
        let text = Array(source.utf16.prefix(131072))
        var result: [Token] = []
        var index = 0
        var expectsExpression = true
        var afterDot = false
        func append(_ start: Int, _ kind: Kind) {
            result.append(Token(range: NSRange(location: start, length: index - start), kind: kind))
        }
        func isWord(_ c: UInt16) -> Bool {
            c == 36 || c == 95 || (65 ... 90).contains(c) || (97 ... 122).contains(c) || c >= 128
        }
        func isDigit(_ c: UInt16) -> Bool { (48 ... 57).contains(c) }
        while index < text.count {
            let start = index
            let c = text[index]
            let next: UInt16? = index + 1 < text.count ? text[index + 1] : nil
            if c == 47, next == 47 {
                index += 2
                while index < text.count, text[index] != 10, text[index] != 13 { index += 1 }
                append(start, .comment)
            } else if c == 47, next == 42 {
                index += 2
                while index < text.count {
                    if text[index] == 42, index + 1 < text.count, text[index + 1] == 47 { index += 2; break }
                    index += 1
                }
                append(start, .comment)
            } else if c == 34 || c == 39 || c == 96 {
                index += 1
                while index < text.count {
                    if text[index] == 92 { index = min(index + 2, text.count); continue }
                    if text[index] == c { index += 1; break }
                    if c != 96, text[index] == 10 || text[index] == 13 { break }
                    index += 1
                }
                append(start, .string)
                expectsExpression = false
                afterDot = false
            } else if c == 47, expectsExpression {
                index += 1
                var inClass = false
                while index < text.count, text[index] != 10, text[index] != 13 {
                    let value = text[index]
                    if value == 92 { index = min(index + 2, text.count); continue }
                    if value == 91 { inClass = true }
                    if value == 93 { inClass = false }
                    index += 1
                    if value == 47, !inClass { break }
                }
                while index < text.count, isWord(text[index]) { index += 1 }
                append(start, .regex)
                expectsExpression = false
                afterDot = false
            } else if isDigit(c) || (c == 46 && next.map(isDigit) == true) {
                index += 1
                while index < text.count {
                    let value = text[index]
                    if isDigit(value) || (65 ... 70).contains(value) || (97 ... 102).contains(value)
                        || [46, 95, 120, 88, 111, 79, 98, 66, 110].contains(value) {
                        index += 1
                    } else if (value == 43 || value == 45), index > start,
                              text[index - 1] == 101 || text[index - 1] == 69 {
                        index += 1
                    } else { break }
                }
                append(start, .number)
                expectsExpression = false
                afterDot = false
            } else if isWord(c) {
                index += 1
                while index < text.count, isWord(text[index]) || isDigit(text[index]) { index += 1 }
                let word = String(decoding: text[start..<index], as: UTF16.self)
                var ahead = index
                while ahead < text.count, [9, 10, 13, 32].contains(text[ahead]) { ahead += 1 }
                if keywords.contains(word) {
                    append(start, .keyword)
                } else if literals.contains(word) {
                    append(start, .literal)
                } else if ahead < text.count, text[ahead] == 40 {
                    append(start, .function)
                } else if afterDot || (ahead < text.count && text[ahead] == 58) {
                    append(start, .property)
                }
                expectsExpression = ["return", "throw", "yield", "delete", "typeof", "void", "new", "case"].contains(word)
                afterDot = false
            } else {
                index += 1
                if [9, 10, 13, 32].contains(c) { continue }
                afterDot = c == 46
                expectsExpression = ![41, 93, 125, 46].contains(c)
            }
        }
        return result
    }
}
