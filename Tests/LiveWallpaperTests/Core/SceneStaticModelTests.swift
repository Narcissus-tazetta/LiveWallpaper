@testable import LiveWallpaper
import XCTest

final class SceneStaticModelTests: XCTestCase {
    private func data<T>(_ values: [T]) -> Data {
        values.withUnsafeBytes { Data($0) }
    }

    /// Position and normal only: six floats a vertex.
    private func model(indices: [UInt32]) -> SceneStaticModel {
        let components: UInt32 = 0b00011
        let vertices: [Float] = [0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 1]
        return SceneStaticModel(material: 0, components: components, vertices: data(vertices), indices: data(indices))
    }

    private func layer(_ model: SceneStaticModel) -> SceneLayer {
        var layer = SceneLayer(name: "Sphere", imageFile: "")
        layer.kind = .model
        layer.model = model
        return layer
    }

    func testAModelLayerSurvivesEncodingAndGivesItsShape() throws {
        let original = layer(model(indices: [0, 1, 2]))
        let decoded = try JSONDecoder().decode(SceneLayer.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded.kind, .model)
        let shape = try XCTUnwrap(decoded.model).shape
        XCTAssertEqual(shape.vertices.count, 18)
        XCTAssertEqual(shape.vertices[5], 1)
        XCTAssertEqual(shape.indices, [0, 1, 2])
        XCTAssertEqual(shape.stride, 6)
    }

    func testATriangleOutsideTheVerticesIsRefused() throws {
        let encoded = try JSONEncoder().encode(layer(model(indices: [0, 1, 3])))
        XCTAssertThrowsError(try JSONDecoder().decode(SceneLayer.self, from: encoded))
    }

    func testIndicesThatAreNotWholeTrianglesAreRefused() throws {
        let encoded = try JSONEncoder().encode(layer(model(indices: [0, 1])))
        XCTAssertThrowsError(try JSONDecoder().decode(SceneLayer.self, from: encoded))
    }
}
