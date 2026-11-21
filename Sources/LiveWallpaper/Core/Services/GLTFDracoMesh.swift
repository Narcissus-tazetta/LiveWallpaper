import DracoBridge
import Foundation

final class GLTFDracoMesh {
    private let mesh: OpaquePointer

    var pointCount: Int {
        Int(lwp_draco_point_count(mesh))
    }

    var indexCount: Int {
        Int(lwp_draco_face_count(mesh)) * 3
    }

    init(data: Data, vertexLimit: Int, indexLimit: Int) throws {
        guard let mesh = data.withUnsafeBytes({ lwp_draco_decode($0.baseAddress, $0.count) }) else {
            throw GLTFAsset.ReadError(detail: "invalid Draco mesh")
        }
        guard (1 ... vertexLimit).contains(Int(lwp_draco_point_count(mesh))),
              (1 ... indexLimit / 3).contains(Int(lwp_draco_face_count(mesh)))
        else {
            lwp_draco_destroy(mesh)
            throw GLTFAsset.ReadError(detail: "Draco mesh exceeds the geometry limits or is empty")
        }
        self.mesh = mesh
    }

    deinit {
        lwp_draco_destroy(mesh)
    }

    func attribute(id: UInt32, type: Int, components: Int, componentSize: Int) throws -> Data {
        let length = pointCount * components * componentSize
        let output = UnsafeMutableRawPointer.allocate(byteCount: length, alignment: componentSize)
        guard lwp_draco_attribute(mesh, id, Int32(type), Int32(components), output) != 0 else {
            output.deallocate()
            throw GLTFAsset
                .ReadError(
                    detail: "Draco attribute \(id) is missing or does not match its accessor"
                )
        }
        return Data(bytesNoCopy: output, count: length, deallocator: .custom { pointer, _ in
            pointer.deallocate()
        })
    }

    func indices() -> [UInt32] {
        [UInt32](unsafeUninitializedCapacity: indexCount) { result, count in
            lwp_draco_indices(mesh, result.baseAddress)
            count = result.count
        }
    }
}
