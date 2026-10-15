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
    case exportFailed(String)
    case invalidVideo(String)
    case wallpaperStoreUnavailable
    case backupUnavailable
    case borrowedAerialUnavailable
    case wallpaperStoreVerificationFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedOS:
            return NSLocalizedString("ロック画面動画同期は macOS 26 以降で利用できます。", comment: "")
        case .applicationSupportUnavailable:
            return NSLocalizedString("Application Support フォルダを取得できませんでした。", comment: "")
        case let .aerialsDirectoryMissing(url):
            return String(format: NSLocalizedString("macOS の Aerial ディレクトリが見つかりません: %@", comment: ""), url.path)
        case let .manifestMissing(url):
            return String(format: NSLocalizedString("macOS の Aerial manifest が見つかりません: %@", comment: ""), url.path)
        case let .invalidManifest(url):
            return String(format: NSLocalizedString("macOS の Aerial manifest を読み込めませんでした: %@", comment: ""), url.path)
        case .noDownloadedAerials:
            return NSLocalizedString("ダウンロード済みのダイナミック壁紙が見つかりません。システム設定で Apple のダイナミック壁紙を1つダウンロードしてください。", comment: "")
        case let .exportFailed(message):
            return message
        case let .invalidVideo(message):
            return message
        case .wallpaperStoreUnavailable:
            return NSLocalizedString("macOS の壁紙設定ファイルを取得できませんでした。", comment: "")
        case .backupUnavailable:
            return NSLocalizedString("復元できる LiveWallpaper のバックアップが見つかりませんでした。", comment: "")
        case .borrowedAerialUnavailable:
            return NSLocalizedString("復元対象の Aerial バックアップが見つかりませんでした。", comment: "")
        case .wallpaperStoreVerificationFailed:
            return NSLocalizedString("macOS の壁紙設定に Aerial を正しく適用できませんでした。", comment: "")
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

struct LockScreenEncodeProgress: Equatable {
    var fraction: Double
    /// nil until enough has been encoded to estimate it.
    var remainingSeconds: Double?
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
    /// The wallpaper store backup taken just before this borrow began, in the store's
    /// folder. Leases from older versions have none.
    var storeBackupFileName: String?
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
    private let leaseDefaultsKey = "lockScreenSyncLease"
    private let legacyBorrowedAerialIDKey = "lockScreenBorrowedAerialID"
    private let legacyBorrowedAerialNameKey = "lockScreenBorrowedAerialName"

    init(
        fileManager: FileManager = .default,
        aerialsBaseURL: URL? = nil,
        wallpaperStoreURL: URL? = nil,
        aerialBackupDirectoryURL: URL? = nil,
        shouldRestartWallpaperServices: Bool = true,
        encodesVideo: Bool = true,
        videoCacheDirectoryURL: URL? = LockScreenSyncService.defaultVideoCacheDirectoryURL,
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
            encodesVideo: encodesVideo,
            cacheDirectory: videoCacheDirectoryURL
        )
    }

    static var defaultVideoCacheDirectoryURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("LiveWallpaper/LockScreenVideoCache", isDirectory: true)
    }

    var isSupported: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
    }

    var reloadProcessNames: [String] {
        wallpaperServiceProcessNames
    }

    /// `start` is the source time the lock screen video begins at; nil picks it
    /// automatically. `progress` gets the fraction of the video encoded so far, from a
    /// background thread.
    func sync(
        videoURL: URL,
        start: Double? = nil,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> BorrowedAerialAsset {
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
        try await videoExporter.prepareVideo(
            from: videoURL, to: temporaryVideoURL, start: start, progress: progress
        )
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
            do {
                try restoreOriginalAerial(assetID: borrowedAsset.id)
            } catch let rollbackError {
                AppLog.lockScreenSync.error(
                    "rollback of aerial \(borrowedAsset.id, privacy: .public) failed error=\(rollbackError.localizedDescription, privacy: .public)"
                )
            }
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
            // A sync within the same borrow (a new video) backs up a store this app
            // already patched; restoring must go to the one from before the borrow.
            let existingBackup = activeLease?.storeBackupFileName
            try replaceItem(at: asset.videoURL, with: temporaryVideoURL)
            let backupURL = try applyWallpaperSelection(assetID: asset.id)
            let kept = existingBackup ?? backupURL?.lastPathComponent
            saveLease(for: asset, storeBackupFileName: kept)
            pruneWallpaperStoreBackups(keeping: kept)
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
        let leaseBackup = activeLease?.storeBackupFileName
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
            try restoreWallpaperStoreBackup(restartServices: true, preferredBackupFileName: leaseBackup)
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
                appVersion: "legacy",
                storeBackupFileName: nil
            )
        }
        return nil
    }

    var hasActiveLease: Bool {
        activeLease != nil
    }

    func restoreWallpaperStoreBackup() throws {
        try restoreWallpaperStoreBackup(restartServices: true, preferredBackupFileName: activeLease?.storeBackupFileName)
    }

    /// `preferredBackupFileName` is the backup from before the current borrow. Without
    /// one (a lease from an older version) the old guess applies, which can be an
    /// older wallpaper than the one replaced.
    private func restoreWallpaperStoreBackup(restartServices: Bool, preferredBackupFileName: String?) throws {
        guard let indexURL = wallpaperStoreIndexURL else {
            throw LockScreenSyncError.wallpaperStoreUnavailable
        }
        let preferred = preferredBackupFileName.map {
            indexURL.deletingLastPathComponent().appendingPathComponent($0)
        }.flatMap { fileManager.fileExists(atPath: $0.path) ? $0 : nil }
        guard let backupURL = preferred ?? latestWallpaperStoreBackup(for: indexURL) else {
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
        // Only once the store is back: a failed restore still needs its backup. A lease
        // still active here (the Aerial video could not be put back) will be retried,
        // and the retry must return to the same backup.
        pruneWallpaperStoreBackups(keeping: activeLease?.storeBackupFileName)
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

    private func saveLease(for asset: BorrowedAerialAsset, storeBackupFileName: String?) {
        let lease = LockScreenSyncLease(
            assetID: asset.id,
            assetName: asset.name,
            createdAt: Date(),
            appVersion: Bundle.main
                .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? "unknown",
            storeBackupFileName: storeBackupFileName
        )
        do {
            try UserDefaults.standard.set(JSONEncoder().encode(lease), forKey: leaseDefaultsKey)
        } catch {
            AppLog.lockScreenSync.error("saving lease failed error=\(error.localizedDescription, privacy: .public)")
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

    /// Returns the backup taken before patching, nil when there was no store.
    @discardableResult
    private func applyWallpaperSelection(assetID: String) throws -> URL? {
        guard let indexURL = wallpaperStoreIndexURL,
              fileManager.fileExists(atPath: indexURL.path)
        else {
            return nil
        }

        let data = try Data(contentsOf: indexURL)
        guard
            var store = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any]
        else {
            return nil
        }

        let transactionBackupURL = try backupWallpaperStore(indexURL)
        try WallpaperStorePatcher.applySelection(assetID: assetID, to: &store)
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
            do {
                try restoreWallpaperStore(from: transactionBackupURL, to: indexURL)
            } catch let rollbackError {
                AppLog.lockScreenSync.error(
                    "rollback of wallpaper store failed error=\(rollbackError.localizedDescription, privacy: .public)"
                )
            }
            throw error
        }
        return transactionBackupURL
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

    private func backupWallpaperStore(_ url: URL) throws -> URL {
        guard fileManager.fileExists(atPath: url.path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
        }
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

    /// The newest timestamped backup. The permanent one that older versions made once
    /// holds a wallpaper from long ago, so it is only a last resort.
    private func latestWallpaperStoreBackup(for indexURL: URL) -> URL? {
        if let newest = timestampedWallpaperStoreBackups(for: indexURL).first {
            return newest
        }
        let legacy = legacyWallpaperStoreBackup(for: indexURL)
        return fileManager.fileExists(atPath: legacy.path) ? legacy : nil
    }

    private func legacyWallpaperStoreBackup(for indexURL: URL) -> URL {
        indexURL.deletingLastPathComponent()
            .appendingPathComponent("\(indexURL.lastPathComponent).livewallpaper.bak")
    }

    /// Newest first. Ordered by the timestamp in the name: the files are copies, which
    /// keep the store's own modification date.
    private func timestampedWallpaperStoreBackups(for indexURL: URL) -> [URL] {
        let prefix = "\(indexURL.lastPathComponent).livewallpaper."
        let legacyName = legacyWallpaperStoreBackup(for: indexURL).lastPathComponent
        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(atPath: indexURL.deletingLastPathComponent().path)
        } catch {
            AppLog.lockScreenSync.error("listing store backups failed error=\(error.localizedDescription, privacy: .public)")
            return []
        }
        return names
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".bak") && $0 != legacyName }
            .sorted(by: >)
            .map { indexURL.deletingLastPathComponent().appendingPathComponent($0) }
    }

    /// Keeps the backup the current borrow returns to and the newest few; removes the
    /// rest, including the permanent backup older versions made.
    private func pruneWallpaperStoreBackups(keeping kept: String?) {
        guard let indexURL = wallpaperStoreIndexURL else {
            return
        }
        let backups = timestampedWallpaperStoreBackups(for: indexURL)
        var doomed = backups.dropFirst(Self.keptStoreBackupCount).filter { $0.lastPathComponent != kept }
        let legacy = legacyWallpaperStoreBackup(for: indexURL)
        if fileManager.fileExists(atPath: legacy.path) {
            doomed.append(legacy)
        }
        for url in doomed {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                AppLog.lockScreenSync.error(
                    "removing store backup \(url.lastPathComponent, privacy: .public) failed error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private static let keptStoreBackupCount = 3

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
        do {
            try process.run()
        } catch {
            AppLog.lockScreenSync.error(
                "killall \(processName, privacy: .public) failed error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
