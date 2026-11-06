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
        let base = withoutMediaExtension(collapsed)
        return base.isEmpty ? "Wallpaper" : base
    }

    /// Display names default to the file name, and the export adds its own extension,
    /// which otherwise gave files such as "clip.mp4.mp4" and "clip.mp4.lwpkg".
    private static func withoutMediaExtension(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        guard mediaExtensions.contains(ext) else { return name }
        return (name as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let mediaExtensions: Set<String> = [
        "mp4", "mov", "m4v", "webm", "gif", "png", "apng", "jpg", "jpeg", "heic", "webp", "lwpkg"
    ]
}
