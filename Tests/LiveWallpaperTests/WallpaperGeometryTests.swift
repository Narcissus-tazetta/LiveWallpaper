import CoreGraphics
import XCTest
@testable import LiveWallpaper

final class WallpaperGeometryTests: XCTestCase {
    private let container = CGSize(width: 1600, height: 900)

    func testFitModeLetterboxesTallVideoInWideContainer() {
        let geometry = WallpaperGeometry.resolve(
            containerSize: container,
            videoAspectRatio: 9.0 / 16.0,
            fitMode: .fit,
            zoom: 1.0,
            offsetX: 0,
            offsetY: 0
        )

        XCTAssertEqual(geometry.renderedSize.height, 900, accuracy: 0.5)
        XCTAssertEqual(geometry.renderedSize.width, 900 * 9.0 / 16.0, accuracy: 0.5)
        XCTAssertEqual(geometry.translation, .zero)
        XCTAssertEqual(geometry.maxPan, .zero)
    }

    func testFillModeCoversContainerWithTallVideo() {
        let geometry = WallpaperGeometry.resolve(
            containerSize: container,
            videoAspectRatio: 9.0 / 16.0,
            fitMode: .fill,
            zoom: 1.0,
            offsetX: 0,
            offsetY: 0
        )

        XCTAssertGreaterThanOrEqual(geometry.renderedSize.width, container.width)
        XCTAssertGreaterThanOrEqual(geometry.renderedSize.height, container.height)
        // 幅は一致し、縦方向にはみ出す
        XCTAssertEqual(geometry.renderedSize.width, 1600, accuracy: 0.5)
        XCTAssertGreaterThan(geometry.maxPan.height, 0)
        XCTAssertEqual(geometry.maxPan.width, 0, accuracy: 0.5)
    }

    func testFillModeMatchingAspectHasNoPanAtZoomOne() {
        let geometry = WallpaperGeometry.resolve(
            containerSize: container,
            videoAspectRatio: 16.0 / 9.0,
            fitMode: .fill,
            zoom: 1.0,
            offsetX: 1.0,
            offsetY: -1.0
        )

        XCTAssertEqual(geometry.maxPan, .zero)
        XCTAssertEqual(geometry.translation, .zero)
    }

    func testZoomScalesRenderedSizeAndMaxPan() {
        let geometry = WallpaperGeometry.resolve(
            containerSize: container,
            videoAspectRatio: 16.0 / 9.0,
            fitMode: .fill,
            zoom: 2.0,
            offsetX: 0,
            offsetY: 0
        )

        XCTAssertEqual(geometry.renderedSize.width, 3200, accuracy: 0.5)
        XCTAssertEqual(geometry.renderedSize.height, 1800, accuracy: 0.5)
        XCTAssertEqual(geometry.maxPan.width, 800, accuracy: 0.5)
        XCTAssertEqual(geometry.maxPan.height, 450, accuracy: 0.5)
    }

    func testOffsetTranslationIsProportionalToMaxPan() {
        let geometry = WallpaperGeometry.resolve(
            containerSize: container,
            videoAspectRatio: 16.0 / 9.0,
            fitMode: .fill,
            zoom: 2.0,
            offsetX: 0.5,
            offsetY: -1.0
        )

        XCTAssertEqual(geometry.translation.width, 400, accuracy: 0.5)
        XCTAssertEqual(geometry.translation.height, -450, accuracy: 0.5)
    }

    func testOffsetBeyondRangeIsClampedBeforeTranslation() {
        let geometry = WallpaperGeometry.resolve(
            containerSize: container,
            videoAspectRatio: 16.0 / 9.0,
            fitMode: .fill,
            zoom: 2.0,
            offsetX: 5.0,
            offsetY: -5.0
        )

        XCTAssertEqual(geometry.translation.width, geometry.maxPan.width, accuracy: 0.5)
        XCTAssertEqual(geometry.translation.height, -geometry.maxPan.height, accuracy: 0.5)
    }

    func testZoomBelowOneIsTreatedAsOne() {
        let geometry = WallpaperGeometry.resolve(
            containerSize: container,
            videoAspectRatio: 16.0 / 9.0,
            fitMode: .fill,
            zoom: 0.5,
            offsetX: 0,
            offsetY: 0
        )

        XCTAssertEqual(geometry.renderedSize.width, 1600, accuracy: 0.5)
        XCTAssertEqual(geometry.renderedSize.height, 900, accuracy: 0.5)
    }

    func testClampOffset() {
        XCTAssertEqual(WallpaperGeometry.clampOffset(0.3), 0.3)
        XCTAssertEqual(WallpaperGeometry.clampOffset(1.5), 1.0)
        XCTAssertEqual(WallpaperGeometry.clampOffset(-1.5), -1.0)
    }

    func testClampZoomUsesSharedRange() {
        XCTAssertEqual(
            WallpaperGeometry.clampZoom(0.2),
            WallpaperGeometry.zoomRange.lowerBound
        )
        XCTAssertEqual(
            WallpaperGeometry.clampZoom(99),
            WallpaperGeometry.zoomRange.upperBound
        )
        XCTAssertEqual(WallpaperGeometry.clampZoom(2.0), 2.0)
    }

    func testDegenerateContainerDoesNotProduceInvalidGeometry() {
        let geometry = WallpaperGeometry.resolve(
            containerSize: .zero,
            videoAspectRatio: 16.0 / 9.0,
            fitMode: .fill,
            zoom: 1.0,
            offsetX: 0,
            offsetY: 0
        )

        XCTAssertGreaterThan(geometry.renderedSize.width, 0)
        XCTAssertGreaterThan(geometry.renderedSize.height, 0)
        XCTAssertGreaterThanOrEqual(geometry.maxPan.width, 0)
        XCTAssertGreaterThanOrEqual(geometry.maxPan.height, 0)
    }
}
