import AppKit
import Foundation

struct WallpaperReconversionStatus: Decodable {
    let requestID: String
    let total: Int
    let completed: Int
    let currentTitle: String
    let updatedIDs: [String]
    let failures: [String]
    let isFinished: Bool
    let backupPath: String
}

@MainActor
final class WallpaperReconversionController: NSObject, ObservableObject {
    static let shared = WallpaperReconversionController()
    @Published private(set) var isRunning = false
    @Published private(set) var status: WallpaperReconversionStatus?
    @Published private(set) var errorKey: String?
    @Published private(set) var copyFailures: [String] = []
    private var requestID: String?
    private var receivedReply = false
    private var launchTask: Task<Void, Never>?
    private var providerExit: DispatchSourceProcess?
    private var completion: ((WallpaperReconversionStatus) async -> [String])?

    override init() {
        super.init()
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(receive(_:)),
            name: .init("com.livewallpaper.reconversionProgress"), object: nil
        )
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
        launchTask?.cancel()
        providerExit?.cancel()
    }

    func start(itemIDs: [String], completion: @escaping (WallpaperReconversionStatus) async -> [String]) {
        guard !isRunning else { return }
        isRunning = true
        status = nil
        errorKey = nil
        copyFailures = []
        receivedReply = false
        let id = UUID().uuidString
        requestID = id
        self.completion = completion
        launchTask = Task {
            if providerPID() == nil {
                let application = URL(fileURLWithPath: "/Applications/we-import.app")
                guard FileManager.default.fileExists(atPath: application.path) else {
                    fail("壁紙の取り込み元アプリが見つかりません。取り込み元アプリを起動してください。")
                    return
                }
                do {
                    _ = try await NSWorkspace.shared.openApplication(at: application, configuration: .init())
                } catch {
                    AppLog.externalWallpapers.error("cannot launch provider: \(error.localizedDescription, privacy: .public)")
                    fail("壁紙の取り込み元アプリを起動できませんでした。")
                    return
                }
            }
            for _ in 0..<20 {
                guard !Task.isCancelled, !receivedReply else { return }
                DistributedNotificationCenter.default().postNotificationName(
                    .init("com.livewallpaper.reconvertAll"), object: id,
                    userInfo: ["itemIDs": itemIDs], deliverImmediately: true
                )
                do { try await Task.sleep(nanoseconds: 500_000_000) }
                catch is CancellationError { return }
                catch { preconditionFailure("Unexpected sleep error: \(error)") }
            }
            if !receivedReply {
                fail("取り込み元アプリから応答がありません。最新版に更新して起動し直してください。")
            }
        }
    }

    private func fail(_ key: String) {
        errorKey = key
        isRunning = false
        providerExit?.cancel()
        providerExit = nil
    }

    private func providerPID() -> pid_t? {
        let url = ExternalWallpaperProviderMonitor.directoryURL.appendingPathComponent("we-import.json")
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(ExternalWallpaperManifest.self, from: data),
              kill(manifest.processIdentifier, 0) == 0 else { return nil }
        return manifest.processIdentifier
    }

    @objc private func receive(_ notification: Notification) {
        guard let text = notification.userInfo?["status"] as? String else { return }
        do {
            let value = try JSONDecoder().decode(WallpaperReconversionStatus.self, from: Data(text.utf8))
            guard value.requestID == requestID, isRunning else { return }
            receivedReply = true
            status = value
            if providerExit == nil, let pid = providerPID() {
                let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
                source.setEventHandler { [weak self] in
                    self?.fail("再変換中に取り込み元アプリが終了しました。もう一度実行してください。")
                }
                providerExit = source
                source.resume()
            }
            if value.isFinished {
                providerExit?.cancel()
                providerExit = nil
                // A final reply can be retried by the provider while library copies are updating.
                requestID = nil
                Task {
                    copyFailures = await completion?(value) ?? []
                    isRunning = false
                    completion = nil
                }
            }
        } catch {
            AppLog.externalWallpapers.error("invalid reconversion status: \(error.localizedDescription, privacy: .public)")
            fail("再変換の進捗を読み取れませんでした。")
        }
    }
}
