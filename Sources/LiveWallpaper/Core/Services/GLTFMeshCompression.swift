import Foundation
import MeshOptimizer

struct GLTFMeshCompression: Decodable {
    enum Mode: String, Decodable {
        case attributes = "ATTRIBUTES"
        case triangles = "TRIANGLES"
        case indices = "INDICES"
    }

    enum Filter: String, Decodable {
        case none = "NONE"
        case octahedral = "OCTAHEDRAL"
        case quaternion = "QUATERNION"
        case exponential = "EXPONENTIAL"
        case color = "COLOR"

        func accepts(stride: Int) -> Bool {
            switch self {
            case .none: true
            case .octahedral, .color: stride == 4 || stride == 8
            case .quaternion: stride == 8
            case .exponential: stride.isMultiple(of: 4)
            }
        }
    }

    let buffer: Int
    let byteOffset: Int?
    let byteLength: Int
    let byteStride: Int
    let count: Int
    let mode: Mode
    let filter: Filter?

    func decode(_ source: Data, length: Int, stride: Int?) throws -> Data {
        let filter = filter ?? .none
        guard (1 ... 256).contains(byteStride), count >= 1,
              length > 0, length.isMultiple(of: byteStride), count == length / byteStride,
              stride == nil || stride == byteStride,
              filter.accepts(stride: byteStride), !source.isEmpty
        else { throw GLTFAsset.ReadError(detail: "invalid meshopt buffer layout") }

        switch mode {
        case .attributes:
            guard byteStride.isMultiple(of: 4) else {
                throw GLTFAsset.ReadError(detail: "invalid meshopt attribute stride")
            }
        case .triangles, .indices:
            guard byteStride == 2 || byteStride == 4, filter == .none,
                  mode != .triangles || count.isMultiple(of: 3)
            else { throw GLTFAsset.ReadError(detail: "invalid meshopt index layout") }
        }

        // The native index decoder and filters use typed writes even for tiny buffers.
        let output = UnsafeMutableRawPointer.allocate(byteCount: length, alignment: 16)
        let result = source.withUnsafeBytes { sourceBytes in
            let input = sourceBytes.bindMemory(to: UInt8.self).baseAddress!
            return switch mode {
            case .attributes: meshopt_decodeVertexBuffer(
                    output,
                    count,
                    byteStride,
                    input,
                    source.count
                )
            case .triangles: meshopt_decodeIndexBuffer(
                    output,
                    count,
                    byteStride,
                    input,
                    source.count
                )
            case .indices: meshopt_decodeIndexSequence(
                    output,
                    count,
                    byteStride,
                    input,
                    source.count
                )
            }
        }
        guard result == 0 else {
            output.deallocate()
            throw GLTFAsset.ReadError(detail: "invalid meshopt bitstream (decoder code \(result))")
        }
        switch filter {
        case .none: break
        case .octahedral: meshopt_decodeFilterOct(output, count, byteStride)
        case .quaternion: meshopt_decodeFilterQuat(output, count, byteStride)
        case .exponential: meshopt_decodeFilterExp(output, count, byteStride)
        case .color: meshopt_decodeFilterColor(output, count, byteStride)
        }
        return Data(bytesNoCopy: output, count: length, deallocator: .custom { pointer, _ in
            pointer.deallocate()
        })
    }
}
