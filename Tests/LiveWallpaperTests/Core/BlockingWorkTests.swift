@testable import LiveWallpaper
import XCTest

final class BlockingWorkTests: XCTestCase {
    func testAFailingCommandReportsItsStatusAndStandardError() async throws {
        do {
            try await ProcessRunner.run(
                "/bin/sh",
                arguments: ["-c", "echo first >&2; echo why it failed >&2; exit 3"]
            )
            XCTFail("expected failure")
        } catch let failure as ProcessRunner.Failure {
            XCTAssertEqual(failure.status, 3)
            XCTAssertEqual(failure.standardError, "first\nwhy it failed")
        }
    }

    /// More than a pipe buffer of stderr must not deadlock the wait for exit.
    func testLargeStandardErrorDoesNotBlockAndKeepsTheTail() async throws {
        let script = "i=0; while [ $i -lt 20000 ]; do echo line$i >&2; i=$((i+1)); done; exit 1"
        do {
            try await ProcessRunner.run("/bin/sh", arguments: ["-c", script])
            XCTFail("expected failure")
        } catch let failure as ProcessRunner.Failure {
            XCTAssertTrue(failure.standardError.hasSuffix("line19999"))
            XCTAssertLessThanOrEqual(
                failure.standardError.utf8.count,
                ProcessRunner.keptStandardErrorBytes
            )
        }
    }

    func testSuccessReturnsNormally() async throws {
        try await ProcessRunner.run("/usr/bin/true", arguments: [])
    }

    func testWorkRunsOffTheMainThread() async throws {
        let onMain = try await BlockingWork.run { Thread.isMainThread }
        XCTAssertFalse(onMain)
    }

    func testWebOriginTreatsDefaultPortsAsEqual() throws {
        let explicit =
            try XCTUnwrap(WebOrigin(url: XCTUnwrap(URL(string: "http://127.0.0.1:80/a"))))
        let implicit = try XCTUnwrap(WebOrigin(url: XCTUnwrap(URL(string: "HTTP://127.0.0.1/b"))))
        XCTAssertEqual(explicit, implicit)
        let otherPort =
            try XCTUnwrap(WebOrigin(url: XCTUnwrap(URL(string: "http://127.0.0.1:8080/"))))
        XCTAssertNotEqual(explicit, otherPort)
        XCTAssertNil(try WebOrigin(url: XCTUnwrap(URL(string: "about:blank"))))
    }
}
