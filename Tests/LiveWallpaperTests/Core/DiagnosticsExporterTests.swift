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
        for name in ["system.txt", "state.txt", "settings.json", "log.txt", "session-log.txt"] {
            contents[name] = try String(
                contentsOf: root.appendingPathComponent(name),
                encoding: .utf8
            )
        }

        for (name, text) in contents {
            XCTAssertFalse(text.contains(NSHomeDirectory()), "\(name) leaks the home path")
        }
        XCTAssertTrue(try XCTUnwrap(contents["system.txt"]?.contains("macOS:")))
        XCTAssertTrue(try XCTUnwrap(contents["state.txt"]?
                .contains("Current video: ~/Movies/missing.mp4")))
        XCTAssertTrue(
            try XCTUnwrap(contents["state.txt"]?.contains("failed to read")),
            "a broken video is reported, not fatal"
        )
        XCTAssertNoThrow(try JSONSerialization
            .jsonObject(with: Data(XCTUnwrap(contents["settings.json"]?.utf8))))
        XCTAssertTrue(try XCTUnwrap(contents["log.txt"]?.contains("diagnostics test marker ~")))
    }

    func testCrashReportsKeepTheStackButDropDeviceIdentifiers() throws {
        let header = #"{"app_name":"LiveWallpaper","bug_type":"309","incident_id":"11111111-1111-1111-1111-111111111111"}"#
        let body = """
        {
          "crashReporterKey" : "22222222-2222-2222-2222-222222222222",
          "bootSessionUUID" : "33333333-3333-3333-3333-333333333333",
          "sleepWakeUUID" : "44444444-4444-4444-4444-444444444444",
          "incident" : "11111111-1111-1111-1111-111111111111",
          "storeInfo" : {"deviceIdentifierForVendor" : "55555555-5555-5555-5555-555555555555", "thirdParty" : true},
          "procPath" : "\(
              NSHomeDirectory()
          )/Applications/LiveWallpaper.app/Contents/MacOS/LiveWallpaper",
          "exception" : {"type" : "EXC_BAD_ACCESS", "signal" : "SIGSEGV"},
          "threads" : [{"triggered" : true, "frames" : [{"symbol" : "objc_release", "imageIndex" : 0}]}]
        }
        """
        let dir = workDir.appendingPathComponent("DiagnosticReports")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (header + "\n" + body).write(
            to: dir.appendingPathComponent("LiveWallpaper-2026-11-01-101010.ips"), atomically: true,
            encoding: .utf8
        )
        try "{}\n{}".write(
            to: dir.appendingPathComponent("OtherApp-2026-11-01-101010.ips"), atomically: true,
            encoding: .utf8
        )
        try "not json".write(
            to: dir.appendingPathComponent("ExcUserFault_LiveWallpaper-2026-11-01-090000.ips"),
            atomically: true, encoding: .utf8
        )

        let reports = try DiagnosticsExporter.recentCrashReports(in: [dir])

        XCTAssertEqual(
            Set(reports.map(\.0)),
            [
                "LiveWallpaper-2026-11-01-101010.ips",
                "ExcUserFault_LiveWallpaper-2026-11-01-090000.ips.txt"
            ]
        )
        let report = try XCTUnwrap(reports.first { $0.0.hasSuffix(".ips") }?.1)
        for id in ["1111", "2222", "3333", "4444", "5555"] {
            XCTAssertFalse(report.contains(id + "-"), "identifier \(id) survived")
        }
        XCTAssertTrue(report.contains("objc_release"))
        XCTAssertTrue(report.contains("SIGSEGV"))
        XCTAssertTrue(report.contains("\"thirdParty\" : true"))
        XCTAssertTrue(DiagnosticsExporter.redactingHome(report)
            .contains("~/Applications/LiveWallpaper.app"))
        let lines = report.split(separator: "\n", maxSplits: 1)
        XCTAssertNoThrow(
            try JSONSerialization.jsonObject(with: Data(lines[0].utf8)),
            "header stays one line"
        )
        let unparsable = try XCTUnwrap(reports.first { $0.0.hasSuffix(".txt") }?.1)
        XCTAssertFalse(
            unparsable.contains("not json"),
            "a report that cannot be redacted is not copied"
        )
    }

    func testRunsWithoutAQuitAreMarked() {
        let lines = SessionLog.annotatingUnfinishedRuns([
            "t1 === launch version=1 ===",
            "t2 screen locked",
            "t3 === launch version=1 ===",
            "t4 === quit ===",
            "t5 === launch version=1 ==="
        ])
        XCTAssertEqual(lines.filter { $0.hasPrefix("---") }.count, 1)
        XCTAssertEqual(lines[2].hasPrefix("---"), true, "the mark follows the run that crashed")
    }
}
