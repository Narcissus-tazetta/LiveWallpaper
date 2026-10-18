import CoreGraphics
@testable import LiveWallpaper
import Metal
import XCTest

final class SceneRenderGraphTests: XCTestCase {
    private let vertex = """
    #include <metal_stdlib>
    using namespace metal;
    struct V { float4 position [[position]]; };
    vertex V vertexMain(uint id [[vertex_id]]) {
        float2 p[] = {float2(-1,-1), float2(3,-1), float2(-1,3)};
        return {float4(p[id],0,1)};
    }
    """

    private func graph(
        fragment: String,
        uniforms: Data = Data(),
        updates: [SceneRenderGraph.UniformUpdate] = [],
        history: Bool = false
    ) -> SceneRenderGraph {
        var textures = [SceneRenderGraph.Texture(index: 0, source: "input")]
        if history { textures.append(.init(index: 1, source: "history")) }
        let draw = SceneRenderGraph.Draw(
            vertex: .init(source: vertex, entryPoint: "vertexMain"),
            fragment: .init(
                source: fragment,
                entryPoint: "fragmentMain",
                uniforms: uniforms,
                updates: updates
            ),
            vertices: Data(repeating: 0, count: 12), vertexStride: 4, vertexCount: 3,
            attributes: [], textures: textures
        )
        var targets = [SceneRenderGraph.Target(name: "work")]
        var passes = [SceneRenderGraph.Pass(operation: .draw, target: "work", draw: draw)]
        if history {
            targets.append(.init(name: "history"))
            passes.append(.init(operation: .copy, target: "history", source: "work"))
        }
        return .init(targets: targets, passes: passes, output: "work")
    }

    private func device() throws -> MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice()
        else { throw XCTSkip("Metal unavailable") }
        return device
    }

    private func input(_ device: MTLDevice, size: Int = 4) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: size,
            height: size,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let pixels: [UInt8] = Array(repeating: [64, 0, 0, 255], count: size * size).flatMap { $0 }
        pixels.withUnsafeBytes {
            texture.replace(
                region: MTLRegionMake2D(0, 0, size, size),
                mipmapLevel: 0,
                withBytes: $0.baseAddress!,
                bytesPerRow: size * 4
            )
        }
        return texture
    }

    private func render(
        _ renderer: SceneRenderGraphRenderer,
        device: MTLDevice,
        input: MTLTexture,
        time: Double = 0,
        values: [String: Double] = [:],
        audio: SceneAudioSpectrum? = nil
    ) throws -> [UInt8] {
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let result = try renderer.encode(
            input: input,
            images: [:],
            time: time,
            cursor: nil,
            values: values,
            audio: audio,
            commandBuffer: command
        )
        let length = result.width * result.height * 4
        let buffer = try XCTUnwrap(device.makeBuffer(length: length, options: .storageModeShared))
        let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
        blit.copy(
            from: result,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(),
            sourceSize: MTLSize(width: result.width, height: result.height, depth: 1),
            to: buffer,
            destinationOffset: 0,
            destinationBytesPerRow: result.width * 4,
            destinationBytesPerImage: length
        )
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        if let error = command.error { throw error }
        return Array(UnsafeBufferPointer(
            start: buffer.contents().assumingMemoryBound(to: UInt8.self),
            count: length
        ))
    }

    func testFeedbackCopyAndResizeReset() throws {
        let device = try device()
        let graph = graph(fragment: """
        #include <metal_stdlib>
        using namespace metal;
        fragment float4 fragmentMain(float4 p [[position]], texture2d<float> image [[texture(0)]], texture2d<float> history [[texture(1)]]) {
            return image.read(uint2(p.xy)) + history.read(uint2(p.xy)) * 0.5;
        }
        """, history: true)
        let renderer = try SceneRenderGraphRenderer(graph: graph, device: device)
        let texture = try input(device)
        let first = try render(renderer, device: device, input: texture)
        let second = try render(renderer, device: device, input: texture)
        let resized = try render(renderer, device: device, input: input(device, size: 8))
        for offset in stride(from: 0, to: first.count, by: 4) {
            XCTAssertEqual(first[offset], 64)
            XCTAssertEqual(second[offset], 96)
        }
        for offset in stride(from: 0, to: resized.count, by: 4) {
            XCTAssertEqual(resized[offset], 64)
        }
    }

    func testIndexedCommandsKeepTheMaximumMaskCoverage() throws {
        let device = try device()
        func uniforms(_ red: Float) -> Data {
            [red, 0, 0, 1].withUnsafeBytes { Data($0) }
        }
        var graph = graph(fragment: """
        #include <metal_stdlib>
        using namespace metal;
        fragment float4 fragmentMain(constant float4& color [[buffer(0)]]) { return color; }
        """, uniforms: uniforms(0))
        graph.passes[0].draw?.indices = [UInt16(0), 1, 2, 0, 1, 2].withUnsafeBytes { Data($0) }
        graph.passes[0].draw?.blend = .maximum
        graph.passes[0].draw?.commands = [
            .init(firstIndex: 0, indexCount: 3, fragmentUniforms: uniforms(0.75)),
            .init(firstIndex: 3, indexCount: 3, fragmentUniforms: uniforms(0.25))
        ]
        let renderer = try SceneRenderGraphRenderer(graph: graph, device: device)
        let pixels = try render(renderer, device: device, input: input(device))
        XCTAssertEqual(pixels[0], 191)
        graph.passes[0].draw?.commands?[1].firstIndex = 5
        XCTAssertThrowsError(try SceneRenderGraphRenderer(graph: graph, device: device))
    }

    func testTimeUniformUsesSeconds() throws {
        let device = try device()
        let graph = graph(fragment: """
        #include <metal_stdlib>
        using namespace metal;
        fragment float4 fragmentMain(constant float& time [[buffer(0)]]) { return float4(time,0,0,1); }
        """, uniforms: Data(repeating: 0, count: 16), updates: [.init(offset: 0, value: .time)])
        let renderer = try SceneRenderGraphRenderer(graph: graph, device: device)
        let pixels = try render(renderer, device: device, input: input(device), time: 0.25)
        XCTAssertEqual(pixels[0], 64)
    }

    /// 16 bands from the 64: each the mean of the four it covers, one per 16 bytes
    /// as std140 lays out a float array; silence without audio.
    func testAudioSpectrumUniformWritesBandsAtTheirStride() throws {
        let device = try device()
        let graph = graph(fragment: """
        #include <metal_stdlib>
        using namespace metal;
        struct Bands { float4 left[16]; };
        fragment float4 fragmentMain(constant Bands& u [[buffer(0)]]) { return float4(u.left[0].x, u.left[1].x, u.left[15].x, 1); }
        """, uniforms: Data(repeating: 0, count: 256), updates: [
            .init(offset: 0, value: .audioSpectrum, stride: 16, key: "left", components: 16)
        ])
        let renderer = try SceneRenderGraphRenderer(graph: graph, device: device)
        var left = [Float](repeating: 0, count: 64)
        left[0 ..< 4] = [0.2, 0.2, 0.2, 0.2]
        left[4 ..< 8] = [0, 0, 1, 1]
        left[60 ..< 64] = [1, 1, 1, 1]
        let loud = try render(renderer, device: device, input: input(device),
                              audio: SceneAudioSpectrum(left: left, right: Array(repeating: 0, count: 64)))
        XCTAssertEqual(Array(loud[0 ..< 3]), [51, 255, 255])
        let silent = try render(renderer, device: device, input: input(device))
        XCTAssertEqual(Array(silent[0 ..< 3]), [0, 0, 0])
    }

    func testAudioSpectrumUpdateOutsideItsBufferIsRejected() throws {
        let device = try device()
        let graph = graph(fragment: "", uniforms: Data(repeating: 0, count: 64), updates: [
            .init(offset: 0, value: .audioSpectrum, stride: 16, key: "left", components: 16)
        ])
        XCTAssertThrowsError(try SceneRenderGraphRenderer(graph: graph, device: device))
    }

    func testSamplingDrawAttachmentIsRejected() throws {
        let device = try device()
        var graph = graph(fragment: "")
        graph.passes[0].draw?.textures[0].source = "work"
        XCTAssertThrowsError(try SceneRenderGraphRenderer(graph: graph, device: device)) { error in
            XCTAssertTrue(error.localizedDescription.contains("samples its target"))
        }
    }

    func testPixelsOutsideGeometryRemainTransparent() throws {
        let device = try device()
        var graph = graph(fragment: """
        #include <metal_stdlib>
        using namespace metal;
        fragment float4 fragmentMain() { return float4(1,0,0,1); }
        """)
        graph.passes[0].draw?.vertex.source = """
        #include <metal_stdlib>
        using namespace metal;
        vertex float4 vertexMain(uint id [[vertex_id]]) { return float4(2+float(id),2,0,1); }
        """
        let renderer = try SceneRenderGraphRenderer(graph: graph, device: device)
        let pixels = try render(renderer, device: device, input: input(device))
        XCTAssertTrue(pixels.allSatisfy { $0 == 0 })
    }

    func testGraphRoundTripKeepsPackagedImagesAndPlaybackDependencies() throws {
        var layer = SceneLayer(name: "image", imageFile: "image.png")
        var graph = graph(
            fragment: "",
            uniforms: Data(repeating: 0, count: 16),
            updates: [.init(offset: 0, value: .cursor)]
        )
        graph.images = ["mask": "mask.png"]
        layer.renderGraph = graph
        let document = SceneDocument(canvasWidth: 64, canvasHeight: 64, layers: [layer])
        let restored = try JSONDecoder().decode(
            SceneDocument.self,
            from: SceneStore.encode(document)
        )
        XCTAssertEqual(restored.layers[0].renderGraph, graph)
        XCTAssertEqual(SceneStore.referencedFiles(of: restored), ["image.png", "mask.png"])
        XCTAssertTrue(restored.requiresRealTimePlayback)
        XCTAssertTrue(restored.layers[0].isAnimated)
        XCTAssertTrue(restored.usesCursor)
    }

    func testShaderEffectRunsAtItsPlaceAmongEffects() throws {
        _ = try device()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("scene.mp4")
        let bytes: [UInt8] = Array(repeating: [64, 0, 0, 255], count: 16).flatMap { $0 }
        let image = try XCTUnwrap(try CGImage(
            width: 4, height: 4, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 16,
            space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent
        ))
        let file = try SceneStore.writeImage(image, prefix: "layer", videoPath: video.path)
        var shader = SceneEffect(kind: .shader)
        shader.renderGraph = graph(fragment: """
        #include <metal_stdlib>
        using namespace metal;
        fragment float4 fragmentMain() { return float4(0,1,0,1); }
        """)
        var mask = SceneEffect(kind: .opacityMask)
        mask.values = ["alpha": 0.5]
        func render(_ effects: [SceneEffect]) throws -> [UInt8] {
            var layer = SceneLayer(name: "image", imageFile: file)
            layer.effects = effects
            let document = SceneDocument(canvasWidth: 16, canvasHeight: 16, layers: [layer])
            try SceneStore.save(document, videoPath: video.path)
            let restored = try XCTUnwrap(SceneStore.load(videoPath: video.path))
            XCTAssertEqual(restored.layers[0].effects.first { $0.kind == .shader }?.renderGraph, shader.renderGraph)
            let renderer = try SceneRenderer(document: restored, videoPath: video.path)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: 16, height: 16, mipmapped: false
            )
            descriptor.storageMode = .shared
            descriptor.usage = [.renderTarget, .shaderRead]
            let target = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))
            let command = try XCTUnwrap(renderer.commandQueue.makeCommandBuffer())
            try renderer.encode(into: target, commandBuffer: command, input: SceneFrameInput(time: 0, isRealTime: true))
            command.commit()
            command.waitUntilCompleted()
            if let error = command.error { throw error }
            var pixels = [UInt8](repeating: 0, count: 4)
            pixels.withUnsafeMutableBytes {
                target.getBytes($0.baseAddress!, bytesPerRow: 64, from: MTLRegionMake2D(8, 8, 1, 1), mipmapLevel: 0)
            }
            return pixels
        }
        // BGRA over the black canvas: the mask halves what the shader drew...
        XCTAssertEqual(Double(try render([shader, mask])[1]), 128, accuracy: 1)
        // ...and the shader replaces what the mask left.
        XCTAssertEqual(try render([mask, shader]), [0, 255, 0, 255])
        shader.isEnabled = false
        XCTAssertEqual(Double(try render([shader, mask])[2]), 32, accuracy: 1)
    }

    func testSceneRendererAppliesSavedGraph() throws {
        _ = try device()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("scene.mp4")
        let bytes: [UInt8] = Array(repeating: [64, 0, 0, 255], count: 16).flatMap { $0 }
        let image = try XCTUnwrap(try CGImage(
            width: 4, height: 4, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 16,
            space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent
        ))
        let file = try SceneStore.writeImage(image, prefix: "layer", videoPath: video.path)
        var layer = SceneLayer(name: "image", imageFile: file)
        layer.renderGraph = graph(fragment: """
        #include <metal_stdlib>
        using namespace metal;
        fragment float4 fragmentMain() { return float4(0,0.5,0,1); }
        """)
        let document = SceneDocument(canvasWidth: 16, canvasHeight: 16, layers: [layer])
        try SceneStore.save(document, videoPath: video.path)
        let restored = try XCTUnwrap(SceneStore.load(videoPath: video.path))
        let renderer = try SceneRenderer(document: restored, videoPath: video.path)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 16,
            height: 16,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead]
        let target = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))
        let command = try XCTUnwrap(renderer.commandQueue.makeCommandBuffer())
        try renderer.encode(into: target, commandBuffer: command, input: .rest)
        command.commit()
        command.waitUntilCompleted()
        if let error = command.error { throw error }
        var pixels = [UInt8](repeating: 0, count: 16 * 16 * 4)
        pixels.withUnsafeMutableBytes {
            target.getBytes(
                $0.baseAddress!,
                bytesPerRow: 64,
                from: MTLRegionMake2D(0, 0, 16, 16),
                mipmapLevel: 0
            )
        }
        XCTAssertEqual(Array(pixels[0 ..< 4]), [0, 128, 0, 255])
    }

    func testIndexedSkinningMovesGeometryAndOpacityOnGPU() throws {
        let device = try device()
        let identity: [Float] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
        let skeleton = SceneSkeleton(
            bones: (0 ..< 54)
                .map { .init(name: "bone\($0)", rest: .init(), inverseBind: identity) },
            clips: [.init(name: "move", framesPerSecond: 1, frameCount: 1, tracks: [
                .init(
                    bone: 53,
                    transforms: [.init(), .init(translation: [1, 0, 0])],
                    opacity: [1, 0.25]
                )
            ])], playback: [.init(clip: 0, loops: false)]
        )
        var vertices = Data()
        for point: [Float] in [[-0.9, -0.5], [-0.1, -0.5], [-0.5, 0.5]] {
            point.withUnsafeBytes { vertices.append(contentsOf: $0) }
            [UInt32(53), 0, 0, 0].withUnsafeBytes { vertices.append(contentsOf: $0) }
            [Float(1), 0, 0, 0].withUnsafeBytes { vertices.append(contentsOf: $0) }
        }
        let draw = SceneRenderGraph.Draw(
            vertex: .init(source: """
            #include <metal_stdlib>
            using namespace metal;
            struct Input { float2 p [[attribute(0)]]; uint4 bones [[attribute(1)]]; float4 weights [[attribute(2)]]; };
            struct Output { float4 p [[position]]; float opacity; };
            struct Uniforms { float4x4 bones[54]; float4 opacity[54]; };
            vertex Output skin(Input v [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
                float4 position = float4(0);
                float opacity = 0;
                for (uint i=0; i<4; ++i) {
                    position += (u.bones[v.bones[i]] * float4(v.p,0,1)) * v.weights[i];
                    opacity += u.opacity[v.bones[i]].x * v.weights[i];
                }
                return {position, opacity};
            }
            """, entryPoint: "skin", uniforms: Data(repeating: 0, count: 54 * 80), updates: [
                .init(offset: 0, value: .boneMatrices),
                .init(offset: 54 * 64, value: .boneOpacity)
            ]),
            fragment: .init(source: """
            #include <metal_stdlib>
            using namespace metal;
            struct Output { float4 p [[position]]; float opacity; };
            fragment float4 color(Output v [[stage_in]]) { return float4(0,v.opacity,0,v.opacity); }
            """, entryPoint: "color"),
            vertices: vertices, vertexStride: 40, vertexCount: 3,
            attributes: [
                .init(location: 0, offset: 0, format: .float2),
                .init(location: 1, offset: 8, format: .uint4),
                .init(location: 2, offset: 24, format: .float4)
            ],
            textures: [], skeleton: skeleton,
            indices: [UInt16(0), 1, 2].withUnsafeBytes { Data($0) }
        )
        let graph = SceneRenderGraph(targets: [.init(name: "output")], passes: [
            .init(operation: .draw, target: "output", draw: draw)
        ], output: "output")
        let restored = try JSONDecoder().decode(
            SceneRenderGraph.self,
            from: JSONEncoder().encode(graph)
        )
        let renderer = try SceneRenderGraphRenderer(graph: restored, device: device)
        let texture = try input(device, size: 32)
        let first = try render(renderer, device: device, input: texture)
        let last = try render(renderer, device: device, input: texture, time: 1)
        func pixel(_ pixels: [UInt8], x: Int) -> [UInt8] {
            Array(pixels[(16 * 32 + x) * 4 ..< (16 * 32 + x) * 4 + 4])
        }
        XCTAssertEqual(pixel(first, x: 8), [0, 255, 0, 255])
        XCTAssertEqual(pixel(first, x: 24), [0, 0, 0, 0])
        XCTAssertEqual(pixel(last, x: 8), [0, 0, 0, 0])
        XCTAssertEqual(pixel(last, x: 24), [0, 64, 0, 64])
        var overlapping = graph
        overlapping.passes[0].draw?.blend = .sourceOver
        try overlapping.passes[0].draw?.indices?.append(XCTUnwrap(draw.indices))
        let blended = try SceneRenderGraphRenderer(graph: overlapping, device: device)
        let combined = try render(blended, device: device, input: texture, time: 1)
        XCTAssertEqual(pixel(combined, x: 24), [0, 112, 0, 112])
        let id = UUID()
        var referenced = graph
        referenced.passes[0].draw?.skeleton = nil
        referenced.passes[0].draw?.skeletonID = id
        let registry = try SceneSkeletonRegistry([id: skeleton])
        let shared = try SceneRenderGraphRenderer(graph: referenced, device: device, rigs: registry)
        let sharedPixels = try render(shared, device: device, input: texture, time: 1)
        XCTAssertEqual(pixel(sharedPixels, x: 24), [0, 64, 0, 64])
        XCTAssertThrowsError(try SceneRenderGraphRenderer(graph: referenced, device: device))
    }

    func testEffectValueUniformUpdate() throws {
        let device = try device()
        let fragment = """
        #include <metal_stdlib>
        using namespace metal;
        struct V { float4 position [[position]]; };
        struct U { float value; };
        fragment float4 fragmentMain(V in [[stage_in]], constant U &u [[buffer(0)]]) {
            return float4(u.value, 0, 0, 1);
        }
        """
        var initial = Data(count: 16)
        var initialVal: Float = 0.25
        withUnsafeBytes(of: &initialVal) { initial.replaceSubrange(0 ..< 4, with: $0) }
        let g = graph(
            fragment: fragment,
            uniforms: initial,
            updates: [SceneRenderGraph.UniformUpdate(offset: 0, value: .effectValue, texture: nil, stride: nil, key: "alpha", components: 1)]
        )
        let renderer = try SceneRenderGraphRenderer(graph: g, device: device)
        let texture = try input(device, size: 4)
        let pixels = try render(renderer, device: device, input: texture, values: ["alpha": 0.75])
        XCTAssertEqual(pixels[0], 191, accuracy: 2)
    }
}
