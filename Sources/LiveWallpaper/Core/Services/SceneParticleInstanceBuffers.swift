import Metal

struct SceneParticleInstanceBuffers {
    private var buffers: [MTLBuffer] = []
    private var next = 0

    mutating func beginFrame() {
        next = 0
    }

    mutating func removeAll() {
        buffers.removeAll()
        next = 0
    }

    mutating func upload(
        _ instances: [SceneParticleSimulator.Instance],
        device: MTLDevice
    ) throws -> MTLBuffer {
        let length = instances.count * MemoryLayout<SceneParticleSimulator.Instance>.stride
        if next == buffers.count || buffers[next].length < length {
            let capacity = next < buffers.count ? max(length, buffers[next].length * 2) : length
            guard let buffer = device.makeBuffer(length: capacity, options: .storageModeShared)
            else {
                throw SceneRenderer.RendererError.bufferAllocationFailed
            }
            if next == buffers.count {
                buffers.append(buffer)
            } else {
                buffers[next] = buffer
            }
        }
        let buffer = buffers[next]
        // Every draw needs its own bytes until the GPU has consumed the whole frame,
        // including draws for children and other layers in the same encoder.
        next += 1
        instances.withUnsafeBytes { bytes in
            buffer.contents().copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
        return buffer
    }
}
