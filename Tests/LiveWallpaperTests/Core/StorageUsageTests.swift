import Foundation
@testable import LiveWallpaper
import XCTest

final class StorageUsageTests: XCTestCase {
    private let fileManager = FileManager.default

    func testEstimatedBakeBytesAccuracy() {
        // Rainlink 4K 60fps 60s test
        let w = 3840
        let h = 2160
        let s = 60

        let maxEst = StorageUsage.estimatedBakeBytes(
            width: w,
            height: h,
            loopSeconds: s,
            quality: .maximum
        )
        let highEst = StorageUsage.estimatedBakeBytes(
            width: w,
            height: h,
            loopSeconds: s,
            quality: .high
        )
        let stdEst = StorageUsage.estimatedBakeBytes(
            width: w,
            height: h,
            loopSeconds: s,
            quality: .standard
        )

        // Measured actuals:
        // 1.0: 4,503,686,704 bytes
        // 0.9: 883,364,316 bytes
        // 0.8: 282,786,850 bytes
        let actualMax: Double = 4_503_686_704
        let actualHigh: Double = 883_364_316
        let actualStd: Double = 282_786_850

        let maxError = abs(Double(maxEst) - actualMax) / actualMax
        let highError = abs(Double(highEst) - actualHigh) / actualHigh
        let stdError = abs(Double(stdEst) - actualStd) / actualStd

        XCTAssertLessThan(
            maxError,
            0.05,
            "Estimate for maximum quality must be within 5% (got \(maxError * 100)%)"
        )
        XCTAssertLessThan(
            highError,
            0.05,
            "Estimate for high quality must be within 5% (got \(highError * 100)%)"
        )
        XCTAssertLessThan(
            stdError,
            0.05,
            "Estimate for standard quality must be within 5% (got \(stdError * 100)%)"
        )
    }

    func testCheckBakeCapacity() {
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        var doc = SceneDocument(canvasWidth: 1920, canvasHeight: 1080, layers: [])
        doc.loopSeconds = 10

        let result = StorageUsage.checkBakeCapacity(
            outputURL: tempDir,
            document: doc,
            quality: .high
        )
        XCTAssertGreaterThan(result.requiredBytes, StorageUsage.bakeHeadroomBytes)
        // System disk should normally have capacity in test environment
        XCTAssertGreaterThan(result.availableBytes, 0)

        // Simulated small disk capacity -> must return isSufficient = false
        let lowCapacity = StorageUsage.checkBakeCapacity(
            outputURL: tempDir,
            document: doc,
            quality: .high,
            availableDiskSpace: 1024
        )
        XCTAssertFalse(lowCapacity.isSufficient)
    }

    func testEstimatedBakeBytesOverflowSafety() {
        // Int.max loop seconds must not trap / fatalError
        let bytes = StorageUsage.estimatedBakeBytes(
            width: 3840,
            height: 2160,
            loopSeconds: Int.max,
            quality: .maximum
        )
        XCTAssertGreaterThan(bytes, 0)
        XCTAssertLessThanOrEqual(bytes, Int64.max - StorageUsage.bakeHeadroomBytes)

        // Negative dimensions or loopSeconds must clamp safely without crashing
        let zeroBytes = StorageUsage.estimatedBakeBytes(
            width: -100,
            height: -100,
            loopSeconds: -50,
            quality: .standard
        )
        XCTAssertGreaterThanOrEqual(zeroBytes, 0)
    }

    @MainActor
    func testInsufficientDiskSpacePreventsBakeAndNotifiesUser() async throws {
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        let model = WallpaperModel()
        // Intentional enormous duration so estimated bake size exceeds available disk space
        var doc = SceneDocument(canvasWidth: 3840, canvasHeight: 2160, layers: [])
        doc.cameraShake = SceneCameraShake(speed: 1, amplitude: 1, roughness: 1)
        doc.loopSeconds = 100_000_000

        let videoURL = tempDir.appendingPathComponent("wallpaper-overflow.mp4")
        let videoPath = videoURL.path

        var notificationFired = false
        var notifiedError: String?
        let observer = NotificationCenter.default.addObserver(
            forName: .sceneBakeDidFail,
            object: videoPath,
            queue: .main
        ) { note in
            notificationFired = true
            notifiedError = note.userInfo?["error"] as? String
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        model.currentVideoPath = videoPath
        model.sceneDocumentsByPath[videoPath] = doc
        model.scheduleSceneBake(path: videoPath)
        model.bakeSceneNowIfPending(path: videoPath)

        // Wait for asynchronous bake task to fail preflight
        try await Task.sleep(nanoseconds: 200_000_000)

        // 1. Bake did NOT start or write output
        XCTAssertFalse(model.scenesBakeRunning.contains(videoPath))
        XCTAssertNil(model.sceneBakeProgress[videoPath])
        XCTAssertFalse(fileManager.fileExists(atPath: videoPath))

        // 2. Reason is recorded and notified to user
        XCTAssertNotNil(model.sceneBakeFailures[videoPath])
        XCTAssertNotNil(model.sceneErrorMessage)
        XCTAssertTrue(model.sceneErrorMessage?.contains("空き容量が不足しているため") == true)
        XCTAssertTrue(notificationFired)
        XCTAssertEqual(notifiedError, model.sceneBakeFailures[videoPath])
    }

    @MainActor
    func testAllReferencedVideoPathsProtectsAllSubsystems() {
        let model = WallpaperModel()
        model.screenSaverVideoPath = "/path/to/screensaver.mp4"
        model.videoBySpaceUUID["space-1"] = "/path/to/space.mp4"
        let rule = ScheduleRule(
            id: UUID(),
            name: "Test",
            target: .video("/path/to/scheduled.mp4")
        )
        model.scheduleRules = [rule]
        model.focusModeAssignments["work"] = .video("/path/to/focus.mp4")

        let referenced = model.allReferencedVideoPaths()
        XCTAssertTrue(referenced.contains("/path/to/screensaver.mp4"))
        XCTAssertTrue(referenced.contains("/path/to/space.mp4"))
        XCTAssertTrue(referenced.contains("/path/to/scheduled.mp4"))
        XCTAssertTrue(referenced.contains("/path/to/focus.mp4"))
    }

    func testFindOrphanVideosAndCleanup() throws {
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let videosDir = tempDir.appendingPathComponent("Videos")
        try fileManager.createDirectory(at: videosDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        let now = Date()
        let tenDaysAgo = now.addingTimeInterval(-10 * 86400)
        let twoDaysAgo = now.addingTimeInterval(-2 * 86400)

        // Referenced video A
        let videoA = videosDir.appendingPathComponent("wallpaper-A.mp4")
        let previewA = videosDir.appendingPathComponent("wallpaper-A.preview.jpg")
        let sceneA = videosDir.appendingPathComponent("wallpaper-A.scene")
        try Data("vidA".utf8).write(to: videoA)
        try Data("prevA".utf8).write(to: previewA)
        try fileManager.createDirectory(at: sceneA, withIntermediateDirectories: true)
        try Data("sceneA".utf8).write(to: sceneA.appendingPathComponent("scene.json"))

        // Orphan video B (10 days old)
        let videoB = videosDir.appendingPathComponent("wallpaper-B.mp4")
        let previewB = videosDir.appendingPathComponent("wallpaper-B.preview.jpg")
        let sceneB = videosDir.appendingPathComponent("wallpaper-B.scene")
        try Data("vidB".utf8).write(to: videoB)
        try Data("prevB".utf8).write(to: previewB)
        try fileManager.createDirectory(at: sceneB, withIntermediateDirectories: true)
        try Data("sceneB".utf8).write(to: sceneB.appendingPathComponent("scene.json"))
        try fileManager.setAttributes([.modificationDate: tenDaysAgo], ofItemAtPath: videoB.path)
        try fileManager.setAttributes([.modificationDate: tenDaysAgo], ofItemAtPath: previewB.path)
        try fileManager.setAttributes([.modificationDate: tenDaysAgo], ofItemAtPath: sceneB.path)

        // Orphan video C (2 days old)
        let videoC = videosDir.appendingPathComponent("wallpaper-C.mp4")
        try Data("vidC".utf8).write(to: videoC)
        try fileManager.setAttributes([.modificationDate: twoDaysAgo], ofItemAtPath: videoC.path)

        // Temporary file (should be ignored by orphan finder)
        let tempFile = videosDir.appendingPathComponent(".scene-1234.tmp.mp4")
        try Data("temp".utf8).write(to: tempFile)

        let referencedPaths: Set<String> = [videoA.path]

        // Check olderThanDays: 7
        let oldOrphans = StorageUsage.findOrphanVideos(
            in: videosDir,
            referencedVideoPaths: referencedPaths,
            now: now,
            olderThanDays: 7
        )
        XCTAssertEqual(oldOrphans.count, 1)
        XCTAssertEqual(oldOrphans.first?.stem, "wallpaper-B")
        XCTAssertEqual(oldOrphans.first?.files.count, 3)

        // Check all orphans
        let allOrphans = StorageUsage.findOrphanVideos(
            in: videosDir,
            referencedVideoPaths: referencedPaths,
            now: now,
            olderThanDays: nil
        )
        XCTAssertEqual(allOrphans.count, 2)
        XCTAssertEqual(Set(allOrphans.map(\.stem)), Set(["wallpaper-B", "wallpaper-C"]))

        // Delete old orphans
        let freed = try StorageUsage.deleteOrphans(oldOrphans)
        XCTAssertGreaterThan(freed, 0)
        XCTAssertFalse(fileManager.fileExists(atPath: videoB.path))
        XCTAssertFalse(fileManager.fileExists(atPath: previewB.path))
        XCTAssertFalse(fileManager.fileExists(atPath: sceneB.path))
        XCTAssertTrue(fileManager.fileExists(atPath: videoA.path))
        XCTAssertTrue(fileManager.fileExists(atPath: videoC.path))
    }

    func testAVideoNamedAnywhereInPreferencesIsNeverAnOrphan() throws {
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let videosDir = tempDir.appendingPathComponent("Videos")
        try fileManager.createDirectory(at: videosDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        let old = Date().addingTimeInterval(-30 * 86400)
        for name in ["wallpaper-KEPT.mp4", "wallpaper-GONE.mp4"] {
            let url = videosDir.appendingPathComponent(name)
            try Data("v".utf8).write(to: url)
            try fileManager.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }

        let orphans = StorageUsage.findOrphanVideos(
            in: videosDir,
            referencedVideoPaths: [],
            protectedText: "{ someFutureKey = \"/x/wallpaper-KEPT.mp4\"; }",
            olderThanDays: 7
        )
        XCTAssertEqual(orphans.map(\.stem), ["wallpaper-GONE"])
    }

    func testFindExpiredAuthorSettingsBackups() throws {
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let backupsDir = tempDir.appendingPathComponent("AuthorSettingsBackups")
        try fileManager.createDirectory(at: backupsDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        let now = Date()
        let dates = [
            now.addingTimeInterval(-1 * 86400),
            now.addingTimeInterval(-5 * 86400),
            now.addingTimeInterval(-10 * 86400),
            now.addingTimeInterval(-20 * 86400),
            now.addingTimeInterval(-40 * 86400) // > 30 days
        ]

        var createdDirs: [URL] = []
        for (i, date) in dates.enumerated() {
            let dir = backupsDir.appendingPathComponent("backup-\(i)")
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("dummy".utf8).write(to: dir.appendingPathComponent("wallpaper.mp4"))
            try fileManager.setAttributes([.modificationDate: date], ofItemAtPath: dir.path)
            createdDirs.append(dir)
        }

        let expired = StorageUsage.findExpiredAuthorSettingsBackups(
            in: backupsDir,
            keepLatestCount: 3,
            maxAgeDays: 30,
            now: now
        )

        // Out of 5 backups:
        // Top 3 (index 0, 1, 2) kept
        // Index 3 is 20 days old (< 30 days) -> kept
        // Index 4 is 40 days old (> 30 days) -> expired!
        XCTAssertEqual(expired.count, 1)
        XCTAssertEqual(expired.first?.url.lastPathComponent, "backup-4")

        try StorageUsage.deleteBackups(expired)
        XCTAssertFalse(fileManager.fileExists(atPath: createdDirs[4].path))
        XCTAssertTrue(fileManager.fileExists(atPath: createdDirs[0].path))
        XCTAssertTrue(fileManager.fileExists(atPath: createdDirs[3].path))
    }
}
