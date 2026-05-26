import Foundation

enum ExportFileNameSanitizer {
    static func sanitizedExportFileName(_ rawValue: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let components = rawValue.components(separatedBy: invalidCharacters)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = components.replacingOccurrences(
            of: "  +",
            with: " ",
            options: .regularExpression
        )
        return collapsed.isEmpty ? "Wallpaper" : collapsed
    }
}
