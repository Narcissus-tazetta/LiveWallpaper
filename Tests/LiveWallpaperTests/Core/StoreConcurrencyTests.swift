import Foundation
@testable import LiveWallpaper
import XCTest

private final class ControlledStoreProtocol: URLProtocol {
    @MainActor static var onRequest: ((ControlledStoreProtocol) -> Void)?

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Task { @MainActor in
            guard let handler = Self.onRequest else {
                fail()
                return
            }
            handler(self)
        }
    }

    override func stopLoading() {}

    func fail() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    func respond(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor
final class StoreConcurrencyTests: XCTestCase {
    private var session: URLSession!
    private var defaults: UserDefaults!
    private var defaultsName: String!

    override func setUpWithError() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ControlledStoreProtocol.self]
        session = URLSession(configuration: configuration)
        defaultsName = "StoreConcurrencyTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsName)
    }

    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        ControlledStoreProtocol.onRequest = nil
        defaults.removePersistentDomain(forName: defaultsName)
    }

    func testConcurrentDownloadDoesNotReplaceActiveProgressAndCanRetryAfterFailure() async throws {
        let controller = StoreCatalogController(session: session)
        let model = WallpaperModel()
        defer {
            model.stopAllPlayers()
            model.stopAllDedicatedPlayers()
        }
        let started = expectation(description: "first download started")
        var firstRequest: ControlledStoreProtocol?
        var secondRequests = 0
        ControlledStoreProtocol.onRequest = { request in
            if request.request.url?.lastPathComponent == "a" {
                firstRequest = request
                started.fulfill()
            } else {
                secondRequests += 1
                request.fail()
            }
        }
        let first = Task { await controller.download(entry: entry("a"), into: model) }
        await fulfillment(of: [started], timeout: 2)
        await controller.download(entry: entry("b"), into: model)
        XCTAssertEqual(secondRequests, 0)
        XCTAssertEqual(controller.downloadingEntryID, "a")
        XCTAssertNotNil(controller.downloadProgress)
        try XCTUnwrap(firstRequest).fail()
        await first.value
        XCTAssertNil(controller.downloadingEntryID)
        XCTAssertNil(controller.downloadProgress)
        XCTAssertNotNil(controller.downloadResultMessage)

        await controller.download(entry: entry("b"), into: model)
        XCTAssertEqual(secondRequests, 1)
        XCTAssertNil(controller.downloadingEntryID)
    }

    func testRefreshUpdatesOriginalSubmissionAfterAnotherIsInserted() async throws {
        let controller = StoreMySubmissionsController(defaults: defaults, session: session)
        record("a", in: controller)
        let started = expectation(description: "status request started")
        var pending: ControlledStoreProtocol?
        ControlledStoreProtocol.onRequest = { request in
            pending = request
            started.fulfill()
        }
        let refresh = Task { await controller.refreshAll() }
        await fulfillment(of: [started], timeout: 2)
        record("b", in: controller)
        try XCTUnwrap(pending).respond(status("a", value: "published"))
        await refresh.value
        XCTAssertEqual(
            controller.submissions.first(where: { $0.id == "a" })?.lastKnownStatus,
            "published"
        )
        XCTAssertEqual(
            controller.submissions.first(where: { $0.id == "b" })?.lastKnownStatus,
            "requested"
        )
        XCTAssertFalse(controller.isRefreshing)
        let restored = StoreMySubmissionsController(defaults: defaults, session: session)
        XCTAssertEqual(restored.submissions, controller.submissions)
    }

    func testRefreshDoesNotRestoreSubmissionRemovedWhileWaiting() async throws {
        let controller = StoreMySubmissionsController(defaults: defaults, session: session)
        record("a", in: controller)
        let started = expectation(description: "status request started")
        var pending: ControlledStoreProtocol?
        ControlledStoreProtocol.onRequest = { request in
            pending = request
            started.fulfill()
        }
        let refresh = Task { await controller.refreshAll() }
        await fulfillment(of: [started], timeout: 2)
        controller.remove(id: "a")
        try XCTUnwrap(pending).respond(status("a", value: "published"))
        await refresh.value
        XCTAssertTrue(controller.submissions.isEmpty)
        XCTAssertFalse(controller.isRefreshing)
        XCTAssertTrue(StoreMySubmissionsController(defaults: defaults, session: session)
            .submissions.isEmpty)
    }

    func testRepeatedRefreshDoesNotStartAnotherStatusRequest() async throws {
        let controller = StoreMySubmissionsController(defaults: defaults, session: session)
        record("a", in: controller)
        let started = expectation(description: "status request started")
        var pending: ControlledStoreProtocol?
        var requestCount = 0
        ControlledStoreProtocol.onRequest = { request in
            requestCount += 1
            pending = request
            started.fulfill()
        }
        let refresh = Task { await controller.refreshAll() }
        await fulfillment(of: [started], timeout: 2)
        await controller.refreshAll()
        XCTAssertEqual(requestCount, 1)
        XCTAssertTrue(controller.isRefreshing)
        try XCTUnwrap(pending).respond(status("a", value: "published"))
        await refresh.value
        XCTAssertFalse(controller.isRefreshing)
    }

    func testRefreshCompletionDoesNotClearBusyStateOfPendingWithdrawal() async throws {
        let controller = StoreMySubmissionsController(defaults: defaults, session: session)
        record("a", in: controller)
        let statusStarted = expectation(description: "status request started")
        let withdrawalStarted = expectation(description: "withdrawal request started")
        var statusRequest: ControlledStoreProtocol?
        var withdrawalRequest: ControlledStoreProtocol?
        ControlledStoreProtocol.onRequest = { request in
            if request.request.httpMethod == "DELETE" {
                withdrawalRequest = request
                withdrawalStarted.fulfill()
            } else {
                statusRequest = request
                statusStarted.fulfill()
            }
        }
        let refresh = Task { await controller.refreshAll() }
        await fulfillment(of: [statusStarted], timeout: 2)
        let withdraw = Task { await controller.withdraw(id: "a") }
        await fulfillment(of: [withdrawalStarted], timeout: 2)
        await controller.withdraw(id: "a")
        try XCTUnwrap(statusRequest).respond(status("a", value: "published"))
        await refresh.value
        XCTAssertTrue(controller.isRefreshing)
        try XCTUnwrap(withdrawalRequest).respond([:])
        await withdraw.value
        XCTAssertTrue(controller.submissions.isEmpty)
        XCTAssertFalse(controller.isRefreshing)
    }

    func testWithdrawalBeforeStatusResponseDoesNotRestoreRemovedSubmission() async throws {
        let controller = StoreMySubmissionsController(defaults: defaults, session: session)
        record("a", in: controller)
        let started = expectation(description: "status request started")
        var pending: ControlledStoreProtocol?
        ControlledStoreProtocol.onRequest = { request in
            if request.request.httpMethod == "DELETE" {
                do { try request.respond([:]) }
                catch { XCTFail("Could not encode withdrawal response: \(error)") }
            } else {
                pending = request
                started.fulfill()
            }
        }
        let refresh = Task { await controller.refreshAll() }
        await fulfillment(of: [started], timeout: 2)
        await controller.withdraw(id: "a")
        XCTAssertTrue(controller.submissions.isEmpty)
        XCTAssertTrue(controller.isRefreshing)
        try XCTUnwrap(pending).respond(status("a", value: "published"))
        await refresh.value
        XCTAssertTrue(controller.submissions.isEmpty)
        XCTAssertFalse(controller.isRefreshing)
    }

    func testPartialRefreshFailureIsVisibleAndKeepsSuccessfulStatuses() async {
        let controller = StoreMySubmissionsController(defaults: defaults, session: session)
        record("b", in: controller)
        record("a", in: controller)
        ControlledStoreProtocol.onRequest = { request in
            if request.request.url?.path.contains("/a/") == true {
                request.fail()
            } else {
                do { try request.respond(self.status("b", value: "published")) }
                catch { XCTFail("Could not encode status response: \(error)") }
            }
        }
        await controller.refreshAll()
        XCTAssertEqual(
            controller.submissions.first(where: { $0.id == "a" })?.lastKnownStatus,
            "requested"
        )
        XCTAssertEqual(
            controller.submissions.first(where: { $0.id == "b" })?.lastKnownStatus,
            "published"
        )
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertFalse(controller.isRefreshing)
    }

    private func record(_ id: String, in controller: StoreMySubmissionsController) {
        controller.record(
            id: id,
            title: id,
            createdAt: "2026-11-07T00:00:00Z",
            withdrawToken: "test-token"
        )
    }

    private func status(_ id: String, value: String) -> [String: Any] {
        [
            "id": id,
            "title": id,
            "author": "test",
            "status": value,
            "createdAt": "2026-11-07T00:00:00Z"
        ]
    }

    private func entry(_ id: String) -> StoreEntry {
        StoreEntry(
            id: id, title: id, author: "test", description: nil,
            sha256: String(repeating: "0", count: 64), sizeBytes: 1,
            durationSeconds: nil, hasAudio: nil, license: nil,
            createdAt: "2026-11-07T00:00:00Z", downloadCount: 0,
            downloadURL: "https://store-test.invalid/\(id)", thumbnailURL: nil
        )
    }
}
