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

private final class ExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession

    init(_ session: AVAssetExportSession) {
        self.session = session
    }
}

final class LockScreenSyncService {
    private let fileManager: FileManager
    private let injectedAerialsBaseURL: URL?
    private let injectedWallpaperStoreURL: URL?
    private let injectedAerialBackupDirectoryURL: URL?
    private let shouldRestartWallpaperServices: Bool
    private let shouldValidatePreparedVideo: Bool
    private let processKiller: (String) -> Void

    private let assetURLKey = "url-4K-SDR-240FPS"
    private let preferredBorrowedAerialIDs = [
        "4C108785-A7BA-422E-9C79-B0129F1D5550",
        "6D6834A4-2F0F-479A-B053-7D4DC5CB8EB7"
    ]
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
        self.injectedAerialsBaseURL = aerialsBaseURL
        self.injectedWallpaperStoreURL = wallpaperStoreURL
        self.injectedAerialBackupDirectoryURL = aerialBackupDirectoryURL
        self.shouldRestartWallpaperServices = shouldRestartWallpaperServices
        self.shouldValidatePreparedVideo = shouldValidatePreparedVideo
        self.processKiller = processKiller
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
        guard isSupported || injectedAerialsBaseURL != nil else {
            throw LockScreenSyncError.unsupportedOS
        }

        let paths = try resolvePaths()
        try prepareAerialsDirectories(paths)
        let borrowedAsset = try detectBorrowableAerial(in: paths)
        try backupOriginalAerialIfNeeded(borrowedAsset)

        let temporaryVideoURL = paths.videosDirectory
            .appendingPathComponent(".\(borrowedAsset.id).\(UUID().uuidString)")
            .appendingPathExtension("mov")
        try await prepareVideo(from: videoURL, to: temporaryVideoURL)

        do {
            try replaceItem(at: borrowedAsset.videoURL, with: temporaryVideoURL)
            try applyWallpaperSelection(assetID: borrowedAsset.id)
            saveLease(for: borrowedAsset)
            restartWallpaperServices()
            return borrowedAsset
        } catch {
            try? restoreOriginalAerial(assetID: borrowedAsset.id)
            throw error
        }
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
                let paths = try resolvePaths()
                let asset = try detectBorrowableAerial(in: paths)
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
           let lease = try? JSONDecoder().decode(LockScreenSyncLease.self, from: data) {
            return lease
        }
        if let legacyID = UserDefaults.standard.string(forKey: legacyBorrowedAerialIDKey) {
            let legacyName = UserDefaults.standard.string(forKey: legacyBorrowedAerialNameKey)
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
        guard let indexURL = wallpaperStoreIndexURL else {
            throw LockScreenSyncError.wallpaperStoreUnavailable
        }
        guard let backupURL = latestWallpaperStoreBackup(for: indexURL) else {
            throw LockScreenSyncError.backupUnavailable
        }
        if fileManager.fileExists(atPath: indexURL.path) {
            try fileManager.removeItem(at: indexURL)
        }
        try fileManager.copyItem(at: backupURL, to: indexURL)
        restartWallpaperServices()
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

    private struct AerialsPaths {
        let baseURL: URL
        let videosDirectory: URL
        let entriesURL: URL
    }

    private struct ManifestAsset {
        let id: String
        let name: String
        let preferredOrder: Int
    }

    private func saveLease(for asset: BorrowedAerialAsset) {
        let lease = LockScreenSyncLease(
            assetID: asset.id,
            assetName: asset.name,
            createdAt: Date(),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
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
        guard let appSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        return appSupportURL
            .appendingPathComponent("com.apple.wallpaper", isDirectory: true)
            .appendingPathComponent("Store", isDirectory: true)
            .appendingPathComponent("Index.plist")
    }

    private func resolvePaths() throws -> AerialsPaths {
        let baseURL: URL
        if let injectedAerialsBaseURL {
            baseURL = injectedAerialsBaseURL
        } else {
            guard let appSupportURL = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                throw LockScreenSyncError.applicationSupportUnavailable
            }
            baseURL = appSupportURL
                .appendingPathComponent("com.apple.wallpaper", isDirectory: true)
                .appendingPathComponent("aerials", isDirectory: true)
        }

        return AerialsPaths(
            baseURL: baseURL,
            videosDirectory: baseURL.appendingPathComponent("videos", isDirectory: true),
            entriesURL: baseURL
                .appendingPathComponent("manifest", isDirectory: true)
                .appendingPathComponent("entries.json")
        )
    }

    private func prepareAerialsDirectories(_ paths: AerialsPaths) throws {
        guard fileManager.fileExists(atPath: paths.baseURL.path) else {
            throw LockScreenSyncError.aerialsDirectoryMissing(paths.baseURL)
        }
        guard fileManager.fileExists(atPath: paths.entriesURL.path) else {
            throw LockScreenSyncError.manifestMissing(paths.entriesURL)
        }
        try fileManager.createDirectory(
            at: paths.videosDirectory,
            withIntermediateDirectories: true
        )
    }

    private func detectBorrowableAerial(in paths: AerialsPaths) throws -> BorrowedAerialAsset {
        let manifestAssets = try loadManifestAssets(paths.entriesURL)
        let downloadedIDs = try downloadedAerialIDs(in: paths.videosDirectory)
        let candidates = manifestAssets
            .filter { downloadedIDs.contains($0.id) }
            .map { asset in
                BorrowedAerialAsset(
                    id: asset.id,
                    name: asset.name,
                    videoURL: paths.videosDirectory
                        .appendingPathComponent(asset.id)
                        .appendingPathExtension("mov")
                )
            }

        guard !candidates.isEmpty else {
            throw LockScreenSyncError.noDownloadedAerials
        }

        for preferredID in preferredBorrowedAerialIDs {
            if let candidate = candidates.first(where: { $0.id == preferredID }) {
                return candidate
            }
        }

        return candidates.sorted { lhs, rhs in
            let leftOrder = manifestAssets.first(where: { $0.id == lhs.id })?.preferredOrder ?? Int.max
            let rightOrder = manifestAssets.first(where: { $0.id == rhs.id })?.preferredOrder ?? Int.max
            return leftOrder < rightOrder
        }.first!
    }

    private func loadManifestAssets(_ entriesURL: URL) throws -> [ManifestAsset] {
        let data = try Data(contentsOf: entriesURL)
        guard let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawAssets = manifest["assets"] as? [[String: Any]]
        else {
            throw LockScreenSyncError.invalidManifest(entriesURL)
        }

        return rawAssets.compactMap { rawAsset in
            guard let id = rawAsset["id"] as? String else {
                return nil
            }
            let name = (rawAsset["accessibilityLabel"] as? String)
                ?? (rawAsset["localizedNameKey"] as? String)
                ?? id
            let preferredOrder = rawAsset["preferredOrder"] as? Int ?? Int.max
            return ManifestAsset(id: id, name: name, preferredOrder: preferredOrder)
        }
    }

    private func downloadedAerialIDs(in videosDirectory: URL) throws -> Set<String> {
        let urls = try fileManager.contentsOfDirectory(
            at: videosDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return Set(
            urls
                .filter { $0.pathExtension.lowercased() == "mov" }
                .map { $0.deletingPathExtension().lastPathComponent }
        )
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
        let paths = try resolvePaths()
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
            return injectedAerialBackupDirectoryURL
                .appendingPathComponent(assetID)
                .appendingPathExtension("mov")
        }
        guard let appSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw LockScreenSyncError.applicationSupportUnavailable
        }
        return appSupportURL
            .appendingPathComponent("LiveWallpaper", isDirectory: true)
            .appendingPathComponent("AerialBackups", isDirectory: true)
            .appendingPathComponent(assetID)
            .appendingPathExtension("mov")
    }

    private func prepareVideo(from sourceURL: URL, to destinationURL: URL) async throws {
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        if sourceURL.pathExtension.lowercased() == "mov" {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            try await validatePreparedVideo(at: destinationURL)
            return
        }

        let asset = AVURLAsset(url: sourceURL)
        do {
            try await exportVideo(asset, to: destinationURL, presetName: AVAssetExportPresetPassthrough)
        } catch {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try? fileManager.removeItem(at: destinationURL)
            }
            try await exportVideo(asset, to: destinationURL, presetName: AVAssetExportPresetHighestQuality)
        }
        try await validatePreparedVideo(at: destinationURL)
    }

    private func exportVideo(
        _ asset: AVURLAsset,
        to destinationURL: URL,
        presetName: String
    ) async throws {
        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: presetName
        ) else {
            throw LockScreenSyncError.exportSessionUnavailable
        }
        exportSession.outputURL = destinationURL
        exportSession.outputFileType = .mov
        exportSession.shouldOptimizeForNetworkUse = false

        let exportSessionBox = ExportSessionBox(exportSession)
        try await withCheckedThrowingContinuation { continuation in
            exportSessionBox.session.exportAsynchronously {
                switch exportSessionBox.session.status {
                case .completed:
                    continuation.resume()
                case .failed, .cancelled:
                    let message = exportSessionBox.session.error?.localizedDescription
                        ?? "動画の mov 変換に失敗しました。"
                    continuation.resume(throwing: LockScreenSyncError.exportFailed(message))
                default:
                    continuation.resume(
                        throwing: LockScreenSyncError.exportFailed("動画の mov 変換が完了しませんでした。")
                    )
                }
            }
        }
    }

    private func validatePreparedVideo(at url: URL) async throws {
        guard shouldValidatePreparedVideo else {
            return
        }
        let asset = AVURLAsset(url: url)
        let duration: CMTime
        let isPlayable: Bool
        let videoTracks: [AVAssetTrack]
        do {
            duration = try await asset.load(.duration)
            isPlayable = try await asset.load(.isPlayable)
            videoTracks = try await asset.loadTracks(withMediaType: .video)
        } catch {
            throw LockScreenSyncError.invalidVideo("ロック画面用の動画を読み込めませんでした: \(error.localizedDescription)")
        }

        guard isPlayable else {
            throw LockScreenSyncError.invalidVideo("ロック画面用の動画を再生可能として読み込めませんでした。")
        }
        guard duration.seconds.isFinite, duration.seconds >= 1.0 else {
            throw LockScreenSyncError.invalidVideo("ロック画面用の動画が短すぎるか、長さを読み取れませんでした。")
        }
        guard !videoTracks.isEmpty else {
            throw LockScreenSyncError.invalidVideo("ロック画面用の動画に映像トラックがありません。")
        }
    }

    private func applyWallpaperSelection(assetID: String) throws {
        guard let indexURL = wallpaperStoreIndexURL,
              fileManager.fileExists(atPath: indexURL.path)
        else {
            return
        }

        let data = try Data(contentsOf: indexURL)
        guard var store = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any] else {
            return
        }

        try backupWallpaperStore(indexURL)
        let choice = aerialChoice(assetID: assetID, template: findAerialChoice(in: store))
        applyLinkedWallpaperChoice(choice, to: &store)
        let outputData = try PropertyListSerialization.data(
            fromPropertyList: store,
            format: .binary,
            options: 0
        )
        try writeAtomically(outputData, to: indexURL)
        try verifyLinkedWallpaperSelection(assetID: assetID, at: indexURL)
    }

    private func aerialChoice(assetID: String, template: [String: Any]?) -> [String: Any] {
        var choice = template ?? [
            "Provider": "com.apple.wallpaper.choice.aerials",
            "Files": [],
            "Configuration": Data()
        ]
        choice["Provider"] = "com.apple.wallpaper.choice.aerials"
        if choice["Files"] == nil {
            choice["Files"] = []
        }
        choice["Configuration"] = aerialConfigurationData(assetID: assetID)
        return choice
    }

    private func aerialConfigurationData(assetID: String) -> Data {
        (
            try? PropertyListSerialization.data(
                fromPropertyList: ["assetID": assetID],
                format: .binary,
                options: 0
            )
        ) ?? Data()
    }

    private func findAerialChoice(in object: Any) -> [String: Any]? {
        if let dictionary = object as? [String: Any] {
            if dictionary["Provider"] as? String == "com.apple.wallpaper.choice.aerials" {
                return dictionary
            }
            for value in dictionary.values {
                if let choice = findAerialChoice(in: value) {
                    return choice
                }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let choice = findAerialChoice(in: value) {
                    return choice
                }
            }
        }
        return nil
    }

    private func applyLinkedWallpaperChoice(_ choice: [String: Any], to store: inout [String: Any]) {
        if var allSpacesAndDisplays = store["AllSpacesAndDisplays"] as? [String: Any] {
            patchStateAsLinked(&allSpacesAndDisplays, choice: choice)
            store["AllSpacesAndDisplays"] = allSpacesAndDisplays
        }
        if var systemDefault = store["SystemDefault"] as? [String: Any] {
            patchStateAsLinked(&systemDefault, choice: choice)
            store["SystemDefault"] = systemDefault
        }
        if var displays = store["Displays"] as? [String: Any] {
            for key in displays.keys {
                guard var state = displays[key] as? [String: Any] else {
                    continue
                }
                patchStateAsLinked(&state, choice: choice)
                displays[key] = state
            }
            store["Displays"] = displays
        }
        if var spaces = store["Spaces"] as? [String: Any] {
            updateSpaces(&spaces, choice: choice)
            store["Spaces"] = spaces
        }
    }

    private func updateSpaces(_ spaces: inout [String: Any], choice: [String: Any]) {
        for spaceKey in spaces.keys {
            guard var space = spaces[spaceKey] as? [String: Any] else {
                continue
            }
            if var defaultState = space["Default"] as? [String: Any] {
                patchStateAsLinked(&defaultState, choice: choice)
                space["Default"] = defaultState
            }
            if var displays = space["Displays"] as? [String: Any] {
                for displayKey in displays.keys {
                    guard var state = displays[displayKey] as? [String: Any] else {
                        continue
                    }
                    patchStateAsLinked(&state, choice: choice)
                    displays[displayKey] = state
                }
                space["Displays"] = displays
            }
            spaces[spaceKey] = space
        }
    }

    private func patchStateAsLinked(_ state: inout [String: Any], choice: [String: Any]) {
        var linkedSurface = state["Linked"] as? [String: Any]
            ?? state["Idle"] as? [String: Any]
            ?? state["Desktop"] as? [String: Any]
            ?? [:]

        patchSurface(&linkedSurface, choice: choice)
        state["Type"] = "linked"
        state["Linked"] = linkedSurface
        state.removeValue(forKey: "Idle")
        state.removeValue(forKey: "Desktop")
    }

    private func patchSurface(_ surface: inout [String: Any], choice: [String: Any]) {
        var content = surface["Content"] as? [String: Any] ?? [:]
        var choices = content["Choices"] as? [[String: Any]] ?? []
        if choices.isEmpty {
            choices = [choice]
        } else {
            choices[0] = choice
        }
        content["Choices"] = choices
        surface["Content"] = content
        surface["LastSet"] = Date()
        surface["LastUse"] = Date()
    }

    private func verifyLinkedWallpaperSelection(assetID: String, at indexURL: URL) throws {
        let data = try Data(contentsOf: indexURL)
        guard let store = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any] else {
            throw LockScreenSyncError.wallpaperStoreVerificationFailed
        }

        var verifiedStateCount = 0
        if !verifyState(store["AllSpacesAndDisplays"], assetID: assetID, count: &verifiedStateCount) {
            throw LockScreenSyncError.wallpaperStoreVerificationFailed
        }
        if !verifyState(store["SystemDefault"], assetID: assetID, count: &verifiedStateCount) {
            throw LockScreenSyncError.wallpaperStoreVerificationFailed
        }
        if let displays = store["Displays"] as? [String: Any] {
            for state in displays.values where !verifyState(state, assetID: assetID, count: &verifiedStateCount) {
                throw LockScreenSyncError.wallpaperStoreVerificationFailed
            }
        }
        if let spaces = store["Spaces"] as? [String: Any] {
            for spaceValue in spaces.values {
                guard let space = spaceValue as? [String: Any] else {
                    continue
                }
                if !verifyState(space["Default"], assetID: assetID, count: &verifiedStateCount) {
                    throw LockScreenSyncError.wallpaperStoreVerificationFailed
                }
                if let displays = space["Displays"] as? [String: Any] {
                    for state in displays.values where !verifyState(state, assetID: assetID, count: &verifiedStateCount) {
                        throw LockScreenSyncError.wallpaperStoreVerificationFailed
                    }
                }
            }
        }

        guard verifiedStateCount > 0 else {
            throw LockScreenSyncError.wallpaperStoreVerificationFailed
        }
    }

    private func verifyState(_ value: Any?, assetID: String, count: inout Int) -> Bool {
        guard let state = value as? [String: Any] else {
            return true
        }
        guard state["Type"] as? String == "linked",
              state["Idle"] == nil,
              state["Desktop"] == nil,
              let linked = state["Linked"] as? [String: Any],
              linkedChoiceAssetID(linked) == assetID
        else {
            return false
        }
        count += 1
        return true
    }

    private func linkedChoiceAssetID(_ surface: [String: Any]) -> String? {
        guard let content = surface["Content"] as? [String: Any],
              let choices = content["Choices"] as? [[String: Any]],
              let choice = choices.first,
              choice["Provider"] as? String == "com.apple.wallpaper.choice.aerials",
              let configuration = choice["Configuration"] as? Data,
              let configurationPlist = try? PropertyListSerialization.propertyList(
                from: configuration,
                options: [],
                format: nil
              ) as? [String: Any]
        else {
            return nil
        }
        return configurationPlist["assetID"] as? String
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

    private func backupWallpaperStore(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            return
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
        let backups = (try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return backups
            .filter { url in
                url.lastPathComponent.hasPrefix(prefix)
                    && url.lastPathComponent.hasSuffix(suffix)
            }
            .max { lhs, rhs in
                let leftValues = try? lhs.resourceValues(forKeys: [.contentModificationDateKey])
                let rightValues = try? rhs.resourceValues(forKeys: [.contentModificationDateKey])
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
