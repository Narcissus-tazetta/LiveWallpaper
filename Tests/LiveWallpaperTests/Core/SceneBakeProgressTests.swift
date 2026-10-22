import Combine
import XCTest

@testable import LiveWallpaper

@MainActor
final class SceneBakeProgressTests: XCTestCase {
    /// Progress changes about once a second while a scene is baked; if the model published
    /// them, the whole settings window would be evaluated each time.
    func testBakeProgressDoesNotPublishFromTheModel() {
        let model = WallpaperModel()
        var modelChanges = 0
        var progressChanges = 0
        let modelSubscription = model.objectWillChange.sink { modelChanges += 1 }
        let progressSubscription = model.sceneBakeProgressStore.objectWillChange.sink { progressChanges += 1 }

        model.sceneBakeProgress["scene.mp4"] = 0.5

        XCTAssertEqual(model.sceneBakeProgress["scene.mp4"], 0.5)
        XCTAssertEqual(modelChanges, 0)
        XCTAssertEqual(progressChanges, 1)
        modelSubscription.cancel()
        progressSubscription.cancel()
    }
}
