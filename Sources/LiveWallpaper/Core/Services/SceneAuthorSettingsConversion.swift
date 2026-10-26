import AppKit
import Foundation

@MainActor
enum SceneAuthorSettingsConversion {
    struct ConversionError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct Request: Encodable {
        var sourceDirectory: String?
        var itemID: String?
        var values: [String: WebPropertyValue]
    }

    static func apply(
        sourceDirectory: String?, itemID: String?, values: [String: WebPropertyValue],
        install: (URL) async throws -> Void
    ) async throws {
        let id = UUID().uuidString
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("we-import/AuthorSettings", isDirectory: true)
        let folder = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            // A timed-out conversion still owns its output until it replies.
            if !FileManager.default.fileExists(atPath: folder.appendingPathComponent("accepted").path)
                || FileManager.default.fileExists(atPath: folder.appendingPathComponent("response.json").path) {
                do { try FileManager.default.removeItem(at: folder) }
                catch { AppLog.persistence.error("author settings cleanup failed: \(error.localizedDescription, privacy: .public)") }
            }
        }
        let request = Request(sourceDirectory: sourceDirectory, itemID: itemID, values: values)
        try JSONEncoder().encode(request).write(to: folder.appendingPathComponent("request.json"), options: .atomic)
        if !providerIsRunning() {
            let application = URL(fileURLWithPath: "/Applications/we-import.app")
            guard FileManager.default.fileExists(atPath: application.path) else {
                throw ConversionError(message: "壁紙の取り込み元アプリが見つかりません。取り込み元アプリを起動してください。")
            }
            _ = try await NSWorkspace.shared.openApplication(at: application, configuration: .init())
        }
        let started = ProcessInfo.processInfo.systemUptime
        while true {
            try Task.checkCancellation()
            let response = folder.appendingPathComponent("response.json")
            if FileManager.default.fileExists(atPath: response.path) {
                let result = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: response))
                if let message = result["error"] { throw ConversionError(message: message) }
                try await install(folder.appendingPathComponent("result.scene"))
                return
            }
            let accepted = FileManager.default.fileExists(atPath: folder.appendingPathComponent("accepted").path)
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            if !accepted, elapsed > 10 {
                throw ConversionError(message: "取り込み元アプリから応答がありません。最新版に更新して起動し直してください。")
            }
            if accepted, !providerIsRunning() {
                throw ConversionError(message: "再変換中に取り込み元アプリが終了しました。もう一度実行してください。")
            }
            if elapsed > 180 {
                throw ConversionError(message: "作品の設定の反映が時間内に完了しませんでした。取り込み元アプリを確認してください。")
            }
            if !accepted {
                DistributedNotificationCenter.default().postNotificationName(
                    .init("com.livewallpaper.configureScene"), object: id, deliverImmediately: true
                )
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private static func providerIsRunning() -> Bool {
        let manifest = ExternalWallpaperProviderMonitor.directoryURL.appendingPathComponent("we-import.json")
        guard let data = try? Data(contentsOf: manifest),
              let provider = try? JSONDecoder().decode(ExternalWallpaperManifest.self, from: data) else { return false }
        return kill(provider.processIdentifier, 0) == 0 || errno == EPERM
    }
}
