@testable import LiveWallpaper
import XCTest

final class SceneMipHistoryTests: XCTestCase {
    func testMipLevelCountMatchesTheMeasuredFramebuffers() {
        XCTAssertEqual(SceneRenderer.mipLevelCount(width: 1280, height: 720), 7)
        XCTAssertEqual(SceneRenderer.mipLevelCount(width: 1600, height: 900), 7)
        XCTAssertEqual(SceneRenderer.mipLevelCount(width: 512, height: 512), 6)
        XCTAssertEqual(SceneRenderer.mipLevelCount(width: 640, height: 360), 6)
        XCTAssertEqual(SceneRenderer.mipLevelCount(width: 1024, height: 256), 5)
        XCTAssertEqual(SceneRenderer.mipLevelCount(width: 8, height: 8), 1)
    }
}
