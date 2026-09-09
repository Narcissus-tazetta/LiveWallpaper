import AppKit
@preconcurrency import AVFoundation
import Foundation

enum LockScreenSyncError: LocalizedError {
    case unsupportedOS
    case applicationSupportUnavailable
    case aerialsDirectoryMissing(URL)
    case manifestMissing(URL)
    case invalidManifest(URL)
    case noDownloadedAerials
    case exportSessionUnavailable
    case exportFailed(String)
    case invalidVideo(String)
    case wallpaperStoreUnavailable
    case backupUnavailable
    case borrowedAerialUnavailable
    case wallpaperStoreVerificationFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedOS:
            return "ロック画面動画同期は macOS 26 以降で利用できます。"
        case .applicationSupportUnavailable:
            return "Application Support フォルダを取得できませんでした。"
        case let .aerialsDirectoryMissing(url):
            return "macOS の Aerial ディレクトリが見つかりません: \(url.path)"
        case let .manifestMissing(url):
            return "macOS の Aerial manifest が見つかりません: \(url.path)"
        case let .invalidManifest(url):
            return "macOS の Aerial manifest を読み込めませんでした: \(url.path)"
        case .noDownloadedAerials:
            return "ダウンロード済みのダイナミック壁紙が見つかりません。System Settings で Apple のダイナミック壁紙を1つダウンロードしてください。"
        case .exportSessionUnavailable:
            return "動画をロック画面用 mov に変換できませんでした。"
        case let .exportFailed(message):
            return message
        case let .invalidVideo(message):
            return message
        case .wallpaperStoreUnavailable:
            return "macOS の壁紙設定ファイルを取得できませんでした。"
        case .backupUnavailable:
            return "復元できる LiveWallpaper のバックアップが見つかりませんでした。"
        case .borrowedAerialUnavailable:
            return "復元対象の Aerial バックアップが見つかりませんでした。"
        case .wallpaperStoreVerificationFailed:
            return "macOS の壁紙設定に Aerial を正しく適用できませんでした。"
        }
    }
}

enum LockScreenSyncStatus: Equatable {
    case disabled
    case unsupported
    case idle
    case syncing
    case borrowed(String)
    case recovering
    case removing
    case restoring
    case restored
    case recovered
    case noAerialDownloaded
    case failed(String)
}

struct BorrowedAerialAsset: Equatable {
    let id: String
    let name: String
    let videoURL: URL
}

struct LockScreenSyncLease: Codable, Equatable {
    let assetID: String
    let assetName: String
    let createdAt: Date
    let appVersion: String
}

/// ロック画面(Aerial)動画の同期。実処理は3つの協調オブジェクトに分かれる:
/// - [[LockScreenSyncService+AerialManifest]] の `AerialManifestResolver`: Aerial
///   ディレクトリ/manifest の探索と、借用可能なアセットの選定。
/// - [[LockScreenSyncService+VideoExport]] の `AerialVideoExporter`: 動画の
///   mov 変換・検証。
/// - [[LockScreenSyncService+WallpaperStorePatcher]] の `WallpaperStorePatcher`:
///   macOS の壁紙設定 plist(Store/Index.plist)への書き込み・検証(純粋関数)。
///
/// このクラス自身は、上記3つを束ねてバックアップ・リース管理・ファイル入出力を担う。
final class LockScreenSyncService {
    private let fileManager: FileManager
    private let injectedAerialsBaseURL: URL?
    private let injectedWallpaperStoreURL: URL?
    private let injectedAerialBackupDirectoryURL: URL?
    private let shouldRestartWallpaperServices: Bool
    private let processKiller: (String) -> Void

    private let manifestResolver: AerialManifestResolver
    private let videoExporter: AerialVideoExporter
    private let operationLock = NSLock()
    private var currentSyncOperationID: UUID?

    private let wallpaperServiceProcessNames = [
        "WallpaperAgent",
        "WallpaperAerialsExtension"
    ]
    private let unlockResetProcessNames = [
        "WallpaperAerialsExtension"
    ]
    private let leaseDefaultsKey = "lockScreenSyncLease"
    private let legacyBorrowedAerialIDKey = "lockScreenBorrowedAerialID"
    private let legacyBorrowedAerialNameKey = "lockScreenBorrowedAerialName"

    init(
        fileManager: FileManager = .default,
        aerialsBaseURL: URL? = nil,
        wallpaperStoreURL: URL? = nil,
        aerialBackupDirectoryURL: URL? = nil,
        shouldRestartWallpaperServices: Bool = true,
        shouldValidatePreparedVideo: Bool = true,
        processKiller: @escaping (String) -> Void = LockScreenSyncService.killProcess(named:)
    ) {
        self.fileManager = fileManager
        injectedAerialsBaseURL = aerialsBaseURL
        injectedWallpaperStoreURL = wallpaperStoreURL
        injectedAerialBackupDirectoryURL = aerialBackupDirectoryURL
        self.shouldRestartWallpaperServices = shouldRestartWallpaperServices
        self.processKiller = processKiller
        manifestResolver = AerialManifestResolver(
            fileManager: fileManager,
            aerialsBaseURL: aerialsBaseURL
        )
        videoExporter = AerialVideoExporter(
            fileManager: fileManager,
            shouldValidatePreparedVideo: shouldValidatePreparedVideo
        )
    }

    var isSupported: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
    }

    var reloadProcessNames: [String] {
        wallpaperServiceProcessNames
    }

    var unlockResetProcessNamesForTesting: [String] {
        unlockResetProcessNames
    }

    func sync(videoURL: URL) async throws -> BorrowedAerialAsset {
        let operationID = beginSyncOperation()
        defer { finishSyncOperation(operationID) }
        guard isSupported || injectedAerialsBaseURL != nil else {
            throw LockScreenSyncError.unsupportedOS
        }

        let paths = try manifestResolver.resolvePaths()
        try manifestResolver.prepareAerialsDirectories(paths)
        let borrowedAsset = try manifestResolver.detectBorrowableAerial(in: paths)
        try backupOriginalAerialIfNeeded(borrowedAsset)

        let temporaryVideoURL = paths.videosDirectory
            .appendingPathComponent(".\(borrowedAsset.id).\(UUID().uuidString)")
            .appendingPathExtension("mov")
        try await videoExporter.prepareVideo(from: videoURL, to: temporaryVideoURL)
        try Task.checkCancellation()

        do {
            try commitSyncOperation(
                operationID,
                asset: borrowedAsset,
                temporaryVideoURL: temporaryVideoURL
            )
            return borrowedAsset
        } catch is CancellationError {
            try? fileManager.removeItem(at: temporaryVideoURL)
            throw CancellationError()
        } catch {
            try? restoreOriginalAerial(assetID: borrowedAsset.id)
            throw error
        }
    }

    func cancelPendingSync() {
        operationLock.lock()
        currentSyncOperationID = nil
        operationLock.unlock()
    }

    private func beginSyncOperation() -> UUID {
        let id = UUID()
        operationLock.lock()
        currentSyncOperationID = id
        operationLock.unlock()
        return id
    }

    private func finishSyncOperation(_ id: UUID) {
        operationLock.lock()
        if currentSyncOperationID == id {
            currentSyncOperationID = nil
        }
        operationLock.unlock()
    }

    /// キャンセル判定からリース保存までを1つの同期区間にする。
    /// cancelPendingSync()がこの間へ割り込んで「リースなし」と誤判定しない。
    private func commitSyncOperation(
        _ id: UUID,
        asset: BorrowedAerialAsset,
        temporaryVideoURL: URL
    ) throws {
        operationLock.lock()
        guard currentSyncOperationID == id else {
            operationLock.unlock()
            try? fileManager.removeItem(at: temporaryVideoURL)
            throw CancellationError()
        }
        do {
            try replaceItem(at: asset.videoURL, with: temporaryVideoURL)
            try applyWallpaperSelection(assetID: asset.id)
            saveLease(for: asset)
        } catch {
            operationLock.unlock()
            throw error
        }
        operationLock.unlock()

        // ロック解放後に呼ぶ。リースは永続化済みなので、プロセス kill を含む
        // この処理中に cancelPendingSync()(メインスレッド)がロック待ちしない。
        restartWallpaperServices()
    }

    func restoreOriginalAerialAndWallpaperStore() throws {
        var restoreErrors: [Error] = []
        if let lease = activeLease {
            do {
                try restoreOriginalAerialIfPossible(assetID: lease.assetID)
                clearLease()
            } catch {
                restoreErrors.append(error)
            }
        } else {
            do {
                let paths = try manifestResolver.resolvePaths()
                let asset = try manifestResolver.detectBorrowableAerial(in: paths)
                try restoreOriginalAerialIfPossible(assetID: asset.id)
            } catch {
                restoreErrors.append(error)
            }
        }

        do {
            try restoreWallpaperStoreBackup()
        } catch LockScreenSyncError.backupUnavailable {
        } catch {
            restoreErrors.append(error)
        }

        if let firstError = restoreErrors.first {
            throw firstError
        }
    }

    var activeLease: LockScreenSyncLease? {
        if let data = UserDefaults.standard.data(forKey: leaseDefaultsKey),
           let lease = try? JSONDecoder().decode(LockScreenSyncLease.self, from: data)
        {
            return lease
        }
        if let legacyID = UserDefaults.standard.string(forKey: legacyBorrowedAerialIDKey) {
            let legacyName =
                UserDefaults.standard.string(forKey: legacyBorrowedAerialNameKey)
                    ?? legacyID
            return LockScreenSyncLease(
                assetID: legacyID,
                assetName: legacyName,
                createdAt: .distantPast,
                appVersion: "legacy"
            )
        }
        return nil
    }

    var hasActiveLease: Bool {
        activeLease != nil
    }

    func restoreWallpaperStoreBackup() throws {
        try restoreWallpaperStoreBackup(restartServices: true)
    }

    private func restoreWallpaperStoreBackup(restartServices: Bool) throws {
        guard let indexURL = wallpaperStoreIndexURL else {
            throw LockScreenSyncError.wallpaperStoreUnavailable
        }
        guard let backupURL = latestWallpaperStoreBackup(for: indexURL) else {
            throw LockScreenSyncError.backupUnavailable
        }
        let temporaryURL = indexURL.deletingLastPathComponent()
            .appendingPathComponent(".\(indexURL.lastPathComponent).restore.\(UUID().uuidString)")
        try fileManager.copyItem(at: backupURL, to: temporaryURL)
        do {
            try replaceItem(at: indexURL, with: temporaryURL)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
        if restartServices {
            restartWallpaperServices()
        }
    }

    func openWallpaperSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.desktopscreeneffect"
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                return
            }
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    func resetAerialExtensionAfterUnlock() {
        guard shouldRestartWallpaperServices else {
            return
        }
        for processName in unlockResetProcessNames {
            processKiller(processName)
        }
    }

    private func saveLease(for asset: BorrowedAerialAsset) {
        let lease = LockScreenSyncLease(
            assetID: asset.id,
            assetName: asset.name,
            createdAt: Date(),
            appVersion: Bundle.main
                .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? "unknown"
        )
        if let data = try? JSONEncoder().encode(lease) {
            UserDefaults.standard.set(data, forKey: leaseDefaultsKey)
        }
        UserDefaults.standard.set(asset.id, forKey: legacyBorrowedAerialIDKey)
        UserDefaults.standard.set(asset.name, forKey: legacyBorrowedAerialNameKey)
    }

    private func clearLease() {
        UserDefaults.standard.removeObject(forKey: leaseDefaultsKey)
        UserDefaults.standard.removeObject(forKey: legacyBorrowedAerialIDKey)
        UserDefaults.standard.removeObject(forKey: legacyBorrowedAerialNameKey)
    }

    private var wallpaperStoreIndexURL: URL? {
        if let injectedWallpaperStoreURL {
            return injectedWallpaperStoreURL
        }
        if injectedAerialsBaseURL != nil {
            return nil
        }
        guard
            let appSupportURL = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        else {
            return nil
        }
        return
            appSupportURL
                .appendingPathComponent("com.apple.wallpaper", isDirectory: true)
                .appendingPathComponent("Store", isDirectory: true)
                .appendingPathComponent("Index.plist")
    }

    private func backupOriginalAerialIfNeeded(_ asset: BorrowedAerialAsset) throws {
        let backupURL = try backupURLForBorrowedAerial(assetID: asset.id)
        guard !fileManager.fileExists(atPath: backupURL.path) else {
            return
        }
        try fileManager.createDirectory(
            at: backupURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.copyItem(at: asset.videoURL, to: backupURL)
    }

    private func restoreOriginalAerial(assetID: String) throws {
        try restoreOriginalAerialIfPossible(assetID: assetID)
    }

    private func restoreOriginalAerialIfPossible(assetID: String) throws {
        let paths = try manifestResolver.resolvePaths()
        let backupURL = try backupURLForBorrowedAerial(assetID: assetID)
        guard fileManager.fileExists(atPath: backupURL.path) else {
            return
        }
        let targetURL = paths.videosDirectory
            .appendingPathComponent(assetID)
            .appendingPathExtension("mov")
        let temporaryURL = paths.videosDirectory
            .appendingPathComponent(".restore-\(assetID)-\(UUID().uuidString)")
            .appendingPathExtension("mov")
        try fileManager.copyItem(at: backupURL, to: temporaryURL)
        try replaceItem(at: targetURL, with: temporaryURL)
    }

    private func backupURLForBorrowedAerial(assetID: String) throws -> URL {
        if let injectedAerialBackupDirectoryURL {
            return
                injectedAerialBackupDirectoryURL
                    .appendingPathComponent(assetID)
                    .appendingPathExtension("mov")
        }
        guard
            let appSupportURL = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        else {
            throw LockScreenSyncError.applicationSupportUnavailable
        }
        return
            appSupportURL
                .appendingPathComponent("LiveWallpaper", isDirectory: true)
                .appendingPathComponent("AerialBackups", isDirectory: true)
                .appendingPathComponent(assetID)
                .appendingPathExtension("mov")
    }

    private func applyWallpaperSelection(assetID: String) throws {
        guard let indexURL = wallpaperStoreIndexURL,
              fileManager.fileExists(atPath: indexURL.path)
        else {
            return
        }

        let data = try Data(contentsOf: indexURL)
        guard
            var store = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any]
        else {
            return
        }

        let transactionBackupURL = try backupWallpaperStore(indexURL)
        WallpaperStorePatcher.applySelection(assetID: assetID, to: &store)
        let outputData = try PropertyListSerialization.data(
            fromPropertyList: store,
            format: .binary,
            options: 0
        )
        do {
            try writeAtomically(outputData, to: indexURL)
            try verifyLinkedWallpaperSelection(assetID: assetID, at: indexURL)
        } catch {
            // この同期の直前バックアップだけを戻し、古い壁紙状態への巻き戻しを防ぐ。
            try? restoreWallpaperStore(from: transactionBackupURL, to: indexURL)
            throw error
        }
    }

    private func verifyLinkedWallpaperSelection(assetID: String, at indexURL: URL) throws {
        let data = try Data(contentsOf: indexURL)
        guard
            let store = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any]
        else {
            throw LockScreenSyncError.wallpaperStoreVerificationFailed
        }
        guard WallpaperStorePatcher.verifySelection(assetID: assetID, in: store) else {
            throw LockScreenSyncError.wallpaperStoreVerificationFailed
        }
    }

    private func replaceItem(at targetURL: URL, with temporaryURL: URL) throws {
        if fileManager.fileExists(atPath: targetURL.path) {
            _ = try fileManager.replaceItemAt(targetURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: targetURL)
        }
    }

    private func backupFileIfNeeded(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        let backupURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).livewallpaper.bak")
        guard !fileManager.fileExists(atPath: backupURL.path) else {
            return
        }
        try fileManager.copyItem(at: url, to: backupURL)
    }

    private func backupWallpaperStore(_ url: URL) throws -> URL {
        guard fileManager.fileExists(atPath: url.path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        try backupFileIfNeeded(url)

        let timestamp = Self.backupTimestampFormatter.string(from: Date())
        var timestampedBackupURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).livewallpaper.\(timestamp).bak")
        if fileManager.fileExists(atPath: timestampedBackupURL.path) {
            timestampedBackupURL = url.deletingLastPathComponent()
                .appendingPathComponent(
                    "\(url.lastPathComponent).livewallpaper.\(timestamp).\(UUID().uuidString).bak"
                )
        }
        try fileManager.copyItem(at: url, to: timestampedBackupURL)
        return timestampedBackupURL
    }

    private func restoreWallpaperStore(from backupURL: URL, to indexURL: URL) throws {
        let temporaryURL = indexURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(indexURL.lastPathComponent).restore.\(UUID().uuidString).tmp"
            )
        try fileManager.copyItem(at: backupURL, to: temporaryURL)
        do {
            try replaceItem(at: indexURL, with: temporaryURL)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    private func latestWallpaperStoreBackup(for indexURL: URL) -> URL? {
        let stableBackupURL = indexURL.deletingLastPathComponent()
            .appendingPathComponent("\(indexURL.lastPathComponent).livewallpaper.bak")
        if fileManager.fileExists(atPath: stableBackupURL.path) {
            return stableBackupURL
        }

        let directoryURL = indexURL.deletingLastPathComponent()
        let prefix = "\(indexURL.lastPathComponent).livewallpaper."
        let suffix = ".bak"
        let backups =
            (try? fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []

        return
            backups
                .filter { url in
                    url.lastPathComponent.hasPrefix(prefix)
                        && url.lastPathComponent.hasSuffix(suffix)
                }
                .max { lhs, rhs in
                    let leftValues = try? lhs.resourceValues(forKeys: [.contentModificationDateKey])
                    let rightValues = try? rhs
                        .resourceValues(forKeys: [.contentModificationDateKey])
                    let leftDate = leftValues?.contentModificationDate ?? .distantPast
                    let rightDate = rightValues?.contentModificationDate ?? .distantPast
                    return leftDate < rightDate
                }
    }

    private static let backupTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter
    }()

    private func writeAtomically(_ data: Data, to url: URL) throws {
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporaryURL, options: .atomic)
        try replaceItem(at: url, with: temporaryURL)
    }

    private func restartWallpaperServices() {
        guard shouldRestartWallpaperServices else {
            return
        }
        for processName in wallpaperServiceProcessNames {
            processKiller(processName)
        }
    }

    private static func killProcess(named processName: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = [processName]
        try? process.run()
    }
}
