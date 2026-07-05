import Foundation
import XCTest
@testable import LiveWallpaper

final class LockScreenSyncServiceTests: XCTestCase {
    private let tahoeID = "4C108785-A7BA-422E-9C79-B0129F1D5550"
    private let sequoiaID = "6D6834A4-2F0F-479A-B053-7D4DC5CB8EB7"

    override func setUpWithError() throws {
        try super.setUpWithError()
        clearLockScreenDefaults()
    }

    override func tearDownWithError() throws {
        clearLockScreenDefaults()
        try super.tearDownWithError()
    }

    func testSyncBorrowsPreferredDownloadedAerialAndPatchesIndex() async throws {
        let fixture = try makeFixture(downloadedIDs: [sequoiaID, tahoeID])
        let sourceVideoURL = try writeFakeVideo(named: "source.mov", contents: "live-video")
        let service = makeService(fixture)

        let borrowed = try await service.sync(videoURL: sourceVideoURL)

        XCTAssertEqual(borrowed.id, tahoeID)
        XCTAssertEqual(borrowed.name, "Tahoe Day")
        XCTAssertEqual(try String(contentsOf: fixture.videoURL(tahoeID)), "live-video")
        XCTAssertEqual(try String(contentsOf: fixture.backupURL(tahoeID)), "original-\(tahoeID)")

        let store = try wallpaperStore(at: fixture.storeURL)
        let allSpacesAndDisplays = try XCTUnwrap(store["AllSpacesAndDisplays"] as? [String: Any])
        try assertLinkedAerialState(allSpacesAndDisplays, assetID: tahoeID)

        let systemDefault = try XCTUnwrap(store["SystemDefault"] as? [String: Any])
        try assertLinkedAerialState(systemDefault, assetID: tahoeID)
        try assertAllWallpaperStatesAreLinkedAerial(in: store, assetID: tahoeID)
        XCTAssertTrue(fixture.storeBackupExists)
    }

    func testSyncCreatesLeaseAndRestoreClearsIt() async throws {
        let fixture = try makeFixture(downloadedIDs: [tahoeID])
        let sourceVideoURL = try writeFakeVideo(named: "source.mov", contents: "live-video")
        let service = makeService(fixture)

        _ = try await service.sync(videoURL: sourceVideoURL)

        XCTAssertEqual(service.activeLease?.assetID, tahoeID)
        XCTAssertEqual(service.activeLease?.assetName, "Tahoe Day")

        try service.restoreOriginalAerialAndWallpaperStore()

        XCTAssertNil(service.activeLease)
        XCTAssertFalse(service.hasActiveLease)
    }

    func testRestoreIsIdempotentWhenLeaseBackupsAreMissing() throws {
        let fixture = try makeFixture(downloadedIDs: [tahoeID])
        UserDefaults.standard.set(tahoeID, forKey: "lockScreenBorrowedAerialID")
        let service = makeService(fixture)

        XCTAssertNoThrow(try service.restoreOriginalAerialAndWallpaperStore())
        XCTAssertNil(service.activeLease)
    }

    func testSyncReusesExistingAerialChoiceAsTemplate() async throws {
        let fixture = try makeFixture(downloadedIDs: [tahoeID], includesAerialTemplate: true)
        let sourceVideoURL = try writeFakeVideo(named: "source.mov", contents: "live-video")
        let service = makeService(fixture)

        _ = try await service.sync(videoURL: sourceVideoURL)

        let store = try wallpaperStore(at: fixture.storeURL)
        let systemDefault = try XCTUnwrap(store["SystemDefault"] as? [String: Any])
        let linked = try XCTUnwrap(systemDefault["Linked"] as? [String: Any])
        let content = try XCTUnwrap(linked["Content"] as? [String: Any])
        let choices = try XCTUnwrap(content["Choices"] as? [[String: Any]])
        XCTAssertEqual(choices.first?["TemplateMarker"] as? String, "preserved")
    }

    func testSyncFallsBackToDownloadedSequoiaWhenTahoeIsMissing() async throws {
        let fixture = try makeFixture(downloadedIDs: [sequoiaID])
        let sourceVideoURL = try writeFakeVideo(named: "source.mov", contents: "live-video")
        let service = makeService(fixture)

        let borrowed = try await service.sync(videoURL: sourceVideoURL)

        XCTAssertEqual(borrowed.id, sequoiaID)
        XCTAssertEqual(try String(contentsOf: fixture.videoURL(sequoiaID)), "live-video")
    }

    func testSyncThrowsWhenNoAerialIsDownloaded() async throws {
        let fixture = try makeFixture(downloadedIDs: [])
        let sourceVideoURL = try writeFakeVideo(named: "source.mov", contents: "live-video")
        let service = makeService(fixture)

        do {
            _ = try await service.sync(videoURL: sourceVideoURL)
            XCTFail("Expected noDownloadedAerials")
        } catch LockScreenSyncError.noDownloadedAerials {
        }
    }

    func testSyncRollsBackVideoWhenWallpaperStoreVerificationFails() async throws {
        let fixture = try makeFixture(downloadedIDs: [tahoeID], includesWallpaperStates: false)
        let sourceVideoURL = try writeFakeVideo(named: "source.mov", contents: "live-video")
        let service = makeService(fixture)

        do {
            _ = try await service.sync(videoURL: sourceVideoURL)
            XCTFail("Expected wallpaperStoreVerificationFailed")
        } catch LockScreenSyncError.wallpaperStoreVerificationFailed {
            XCTAssertEqual(try String(contentsOf: fixture.videoURL(tahoeID)), "original-\(tahoeID)")
        }
    }

    func testReloadProcessNamesDoNotKillWallpaperSettingsExtension() throws {
        let fixture = try makeFixture(downloadedIDs: [tahoeID])
        let service = makeService(fixture)

        XCTAssertEqual(service.reloadProcessNames, ["WallpaperAgent", "WallpaperAerialsExtension"])
        XCTAssertFalse(service.reloadProcessNames.contains("Wallpaper"))
    }

    func testUnlockResetKillsOnlyAerialExtension() throws {
        let fixture = try makeFixture(downloadedIDs: [tahoeID])
        var killedProcesses: [String] = []
        let service = makeService(fixture, shouldRestartWallpaperServices: true) { processName in
            killedProcesses.append(processName)
        }

        service.resetAerialExtensionAfterUnlock()

        XCTAssertEqual(service.unlockResetProcessNamesForTesting, ["WallpaperAerialsExtension"])
        XCTAssertEqual(killedProcesses, ["WallpaperAerialsExtension"])
        XCTAssertFalse(killedProcesses.contains("Wallpaper"))
        XCTAssertFalse(killedProcesses.contains("WallpaperAgent"))
    }

    func testUnlockResetDoesNothingWhenRestartIsDisabled() throws {
        let fixture = try makeFixture(downloadedIDs: [tahoeID])
        var killedProcesses: [String] = []
        let service = makeService(fixture, shouldRestartWallpaperServices: false) { processName in
            killedProcesses.append(processName)
        }

        service.resetAerialExtensionAfterUnlock()

        XCTAssertTrue(killedProcesses.isEmpty)
    }

    func testInvalidMovIsRejectedBeforeApplyingWallpaperStore() async throws {
        let fixture = try makeFixture(downloadedIDs: [tahoeID])
        let originalStoreData = try Data(contentsOf: fixture.storeURL)
        let sourceVideoURL = try writeFakeVideo(named: "source.mov", contents: "not-a-real-movie")
        let service = makeService(fixture, shouldValidatePreparedVideo: true)

        do {
            _ = try await service.sync(videoURL: sourceVideoURL)
            XCTFail("Expected invalidVideo")
        } catch LockScreenSyncError.invalidVideo {
            XCTAssertEqual(try Data(contentsOf: fixture.storeURL), originalStoreData)
        }
    }

    func testRestoreOriginalAerialAndWallpaperStoreRestoresBackups() async throws {
        let fixture = try makeFixture(downloadedIDs: [tahoeID])
        let originalStoreData = try Data(contentsOf: fixture.storeURL)
        let sourceVideoURL = try writeFakeVideo(named: "source.mov", contents: "live-video")
        let service = makeService(fixture)

        _ = try await service.sync(videoURL: sourceVideoURL)
        try service.restoreOriginalAerialAndWallpaperStore()

        XCTAssertEqual(try String(contentsOf: fixture.videoURL(tahoeID)), "original-\(tahoeID)")
        XCTAssertEqual(try Data(contentsOf: fixture.storeURL), originalStoreData)
    }

    private struct Fixture {
        let rootURL: URL
        let storeURL: URL
        let backupDirectoryURL: URL

        func videoURL(_ id: String) -> URL {
            rootURL.appendingPathComponent("videos/\(id).mov")
        }

        func backupURL(_ id: String) -> URL {
            backupDirectoryURL.appendingPathComponent("\(id).mov")
        }

        var storeBackupExists: Bool {
            FileManager.default.fileExists(
                atPath: storeURL.deletingLastPathComponent()
                    .appendingPathComponent("Index.plist.livewallpaper.bak").path
            )
        }
    }

    private func makeFixture(
        downloadedIDs: [String],
        storeType: String = "individual",
        includesAerialTemplate: Bool = false,
        includesWallpaperStates: Bool = true
    ) throws -> Fixture {
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveWallpaperLockScreenSyncTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let rootURL = baseURL.appendingPathComponent("aerials", isDirectory: true)
        let backupDirectoryURL = baseURL.appendingPathComponent("AerialBackups", isDirectory: true)
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("manifest", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("videos", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: backupDirectoryURL,
            withIntermediateDirectories: true
        )

        let manifest: [String: Any] = [
            "assets": [
                [
                    "id": tahoeID,
                    "accessibilityLabel": "Tahoe Day",
                    "preferredOrder": 1
                ],
                [
                    "id": sequoiaID,
                    "accessibilityLabel": "Sequoia Sunrise",
                    "preferredOrder": 2
                ]
            ]
        ]
        let manifestData = try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.prettyPrinted]
        )
        try manifestData.write(to: rootURL.appendingPathComponent("manifest/entries.json"))

        for id in downloadedIDs {
            try "original-\(id)".write(
                to: rootURL.appendingPathComponent("videos/\(id).mov"),
                atomically: true,
                encoding: .utf8
            )
        }

        let storeURL = try makeWallpaperStoreIndex(
            in: baseURL,
            type: storeType,
            includesAerialTemplate: includesAerialTemplate,
            includesWallpaperStates: includesWallpaperStates
        )
        return Fixture(
            rootURL: rootURL,
            storeURL: storeURL,
            backupDirectoryURL: backupDirectoryURL
        )
    }

    private func makeService(
        _ fixture: Fixture,
        shouldRestartWallpaperServices: Bool = false,
        shouldValidatePreparedVideo: Bool = false,
        processKiller: @escaping (String) -> Void = { _ in }
    ) -> LockScreenSyncService {
        LockScreenSyncService(
            aerialsBaseURL: fixture.rootURL,
            wallpaperStoreURL: fixture.storeURL,
            aerialBackupDirectoryURL: fixture.backupDirectoryURL,
            shouldRestartWallpaperServices: shouldRestartWallpaperServices,
            shouldValidatePreparedVideo: shouldValidatePreparedVideo,
            processKiller: processKiller
        )
    }

    private func makeWallpaperStoreIndex(
        in baseURL: URL,
        type: String,
        includesAerialTemplate: Bool,
        includesWallpaperStates: Bool
    ) throws -> URL {
        let storeURL = baseURL.appendingPathComponent("Store/Index.plist")
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let defaultChoice: [String: Any] = [
            "Provider": "default",
            "Files": [],
            "Configuration": Data()
        ]
        let aerialTemplateChoice: [String: Any] = [
            "Provider": "com.apple.wallpaper.choice.aerials",
            "Files": [],
            "Configuration": try PropertyListSerialization.data(
                fromPropertyList: ["assetID": sequoiaID],
                format: .binary,
                options: 0
            ),
            "TemplateMarker": "preserved"
        ]
        let surface: [String: Any] = [
            "LastSet": Date(),
            "LastUse": Date(),
            "Content": [
                "Choices": [
                    includesAerialTemplate ? aerialTemplateChoice : defaultChoice
                ]
            ]
        ]
        let surfaceKey = type == "linked" ? "Linked" : "Idle"
        let store: [String: Any] = includesWallpaperStates ? [
            "AllSpacesAndDisplays": [
                "Type": type,
                surfaceKey: [
                    "LastSet": Date(),
                    "LastUse": Date(),
                    "Content": [
                        "Choices": [
                            [
                                "Provider": "com.apple.wallpaper.choice.image",
                                "Files": [],
                                "Configuration": Data()
                            ]
                        ]
                    ]
                ]
            ],
            "SystemDefault": [
                "Type": type,
                surfaceKey: surface
            ],
            "Displays": [
                "display": [
                    "Type": type,
                    surfaceKey: surface
                ]
            ],
            "Spaces": [
                "space": [
                    "Default": [
                        "Type": type,
                        surfaceKey: surface
                    ],
                    "Displays": [
                        "display": [
                            "Type": type,
                            surfaceKey: surface
                        ]
                    ]
                ]
            ]
        ] : [:]
        let data = try PropertyListSerialization.data(
            fromPropertyList: store,
            format: .binary,
            options: 0
        )
        try data.write(to: storeURL)
        return storeURL
    }

    private func writeFakeVideo(named name: String, contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveWallpaperLockScreenSyncTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func wallpaperStore(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        return try XCTUnwrap(plist as? [String: Any])
    }

    private func assertAllWallpaperStatesAreLinkedAerial(
        in store: [String: Any],
        assetID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        if let state = store["AllSpacesAndDisplays"] as? [String: Any] {
            try assertLinkedAerialState(state, assetID: assetID, file: file, line: line)
        }
        if let state = store["SystemDefault"] as? [String: Any] {
            try assertLinkedAerialState(state, assetID: assetID, file: file, line: line)
        }
        if let displays = store["Displays"] as? [String: Any] {
            for value in displays.values {
                let state = try XCTUnwrap(value as? [String: Any], file: file, line: line)
                try assertLinkedAerialState(state, assetID: assetID, file: file, line: line)
            }
        }
        if let spaces = store["Spaces"] as? [String: Any] {
            for value in spaces.values {
                let space = try XCTUnwrap(value as? [String: Any], file: file, line: line)
                if let defaultState = space["Default"] as? [String: Any] {
                    try assertLinkedAerialState(defaultState, assetID: assetID, file: file, line: line)
                }
                if let displays = space["Displays"] as? [String: Any] {
                    for displayValue in displays.values {
                        let state = try XCTUnwrap(displayValue as? [String: Any], file: file, line: line)
                        try assertLinkedAerialState(state, assetID: assetID, file: file, line: line)
                    }
                }
            }
        }
    }

    private func assertLinkedAerialState(
        _ state: [String: Any],
        assetID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(state["Type"] as? String, "linked", file: file, line: line)
        XCTAssertNil(state["Idle"], file: file, line: line)
        XCTAssertNil(state["Desktop"], file: file, line: line)
        let surfaceState = try XCTUnwrap(state["Linked"] as? [String: Any], file: file, line: line)
        let content = try XCTUnwrap(surfaceState["Content"] as? [String: Any], file: file, line: line)
        let choices = try XCTUnwrap(content["Choices"] as? [[String: Any]], file: file, line: line)
        XCTAssertEqual(
            choices.first?["Provider"] as? String,
            "com.apple.wallpaper.choice.aerials",
            file: file,
            line: line
        )
        let configuration = try XCTUnwrap(
            choices.first?["Configuration"] as? Data,
            file: file,
            line: line
        )
        let configurationPlist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: configuration, options: [], format: nil)
                as? [String: String],
            file: file,
            line: line
        )
        XCTAssertEqual(configurationPlist["assetID"], assetID, file: file, line: line)
    }

    private func clearLockScreenDefaults() {
        UserDefaults.standard.removeObject(forKey: "lockScreenSyncLease")
        UserDefaults.standard.removeObject(forKey: "lockScreenBorrowedAerialID")
        UserDefaults.standard.removeObject(forKey: "lockScreenBorrowedAerialName")
        UserDefaults.standard.removeObject(forKey: "lockScreenSyncEnabled")
    }
}
