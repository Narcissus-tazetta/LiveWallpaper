import Foundation
@testable import LiveWallpaper
import XCTest

@MainActor
final class DiagnosticsExporterTests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticsExporterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    func testExportWritesEveryReportWithoutTheHomePath() async throws {
        AppLog.automation.notice("diagnostics test marker \(NSHomeDirectory(), privacy: .public)")
        let model = WallpaperModel()
        model.currentVideoPath = NSHomeDirectory() + "/Movies/missing.mp4"
        let zipURL = workDir.appendingPathComponent(DiagnosticsExporter.defaultFileName())

        try await DiagnosticsExporter.export(from: model, to: zipURL)

        let unpacked = workDir.appendingPathComponent("unpacked")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zipURL.path, unpacked.path]
        try ditto.run()
        ditto.waitUntilExit()
        XCTAssertEqual(ditto.terminationStatus, 0)

        let root = unpacked.appendingPathComponent(zipURL.deletingPathExtension().lastPathComponent)
        var contents: [String: String] = [:]
        for name in ["system.txt", "state.txt", "settings.json", "log.txt"] {
            contents[name] = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
        }

        for (name, text) in contents {
            XCTAssertFalse(text.contains(NSHomeDirectory()), "\(name) leaks the home path")
        }
        XCTAssertTrue(contents["system.txt"]!.contains("macOS:"))
        XCTAssertTrue(contents["state.txt"]!.contains("Current video: ~/Movies/missing.mp4"))
        XCTAssertTrue(contents["state.txt"]!.contains("failed to read"), "a broken video is reported, not fatal")
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(contents["settings.json"]!.utf8)))
        XCTAssertTrue(contents["log.txt"]!.contains("diagnostics test marker ~"))
    }
}
