import CoreGraphics
import Foundation
import Metal
import simd

/// Constructed on the preparation worker, then exclusively used by the owning runtime.
/// No global device/pipeline/texture cache can retain a retired wallpaper.
final class SceneMetalEngine: @unchecked Sendable {
    struct Vertex { var position: SIMD2<Float>; var uv: SIMD2<Float> }
    struct Uniforms { var color: SIMD4<Float>; var inputs: SIMD4<Float>; var sampling: SIMD4<Float> }
    struct ParticleUniforms { var transform: simd_float3x3; var projection: SIMD4<Float>; var view: SIMD4<Float> }
    struct TextureInput {
        let texture: MTLTexture
        let sampler: MTLSamplerState
        let sampling: SIMD4<Float>
    }
    struct Preprocess { let pipeline: MTLRenderPipelineState; let target: MTLTexture; let inputs: [TextureInput?] }
    struct Draw {
        let node: SceneRenderNode
        let texture: MTLTexture
        let sampler: MTLSamplerState
        let pipeline: MTLRenderPipelineState
        let particleBuffer: MTLBuffer?
        let puppetVertices: MTLBuffer?
        let puppetIndices: MTLBuffer?
        let puppetPalette: MTLBuffer?
        let preprocessors: [Preprocess]
        let inputs: [TextureInput?]
    }
    let device: MTLDevice
    let queue: MTLCommandQueue
    let graph: SceneRenderGraph
    private let draws: [Draw]
    private var scriptValues: [String: SceneJSON] = [:]

    func applyScriptValues(_ values: [String: SceneJSON]) throws {
        guard values.count == graph.document.scripts.count else { throw SceneRuntimeError.malformed("script value count") }
        for binding in graph.document.scripts {
            guard let value = values[binding.id] else { throw SceneRuntimeError.malformed("script value ID") }
            try binding.validateOutput(value)
        }
        scriptValues = values
    }

    private func scriptedLayers() throws -> [String: (simd_float3x3, SIMD4<Float>, Bool)] {
        guard !graph.document.scripts.isEmpty else { return [:] }
        var overrides: [String: [String: SceneJSON]] = [:]
        for binding in graph.document.scripts {
            if let value = scriptValues[binding.id] { overrides[binding.layerID, default: [:]][binding.target] = value }
        }
        let layers = Dictionary(uniqueKeysWithValues: graph.document.layers.map { ($0.id, $0) })
        var states: [String: (simd_float3x3, SIMD4<Float>, Bool)] = [:]
        func world(_ layer: SceneLayer) throws -> (simd_float3x3, SIMD4<Float>, Bool) {
            if let state = states[layer.id] { return state }
            let values = overrides[layer.id] ?? [:]
            func xy(_ key: String, _ fallback: SIMD2<Float>) -> SIMD2<Float> {
                guard let value = values[key] else { return fallback }
                return SIMD2(Float(value["x"].number!), Float(value["y"].number!))
            }
            let transform = SceneTransform(origin: xy("origin", layer.transform.origin), scale: xy("scale", layer.transform.scale),
                rotation: values["angles"].map { Float($0["z"].number!) * .pi / 180 } ?? layer.transform.rotation)
            var color = layer.color
            if let value = values["color"] { color.x = Float(value["x"].number!); color.y = Float(value["y"].number!); color.z = Float(value["z"].number!) }
            if let value = values["alpha"] { color.w = Float(value.number!) }
            let parent = try layer.parentID.flatMap { layers[$0] }.map(world) ?? (matrix_identity_float3x3, SIMD4(repeating: 1), true)
            let matrix = try checkedSceneMatrix(parent.0 * transform.matrix, context: "scripted layer hierarchy: \(layer.id)")
            let result = (matrix, color, parent.2 && (values["visible"]?.bool ?? layer.visible))
            states[layer.id] = result
            return result
        }
        for layer in graph.document.layers { _ = try world(layer) }
        return states
    }

    init(graph: SceneRenderGraph) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw SceneRuntimeError.graphics("Metal unavailable")
        }
        self.device = device; self.queue = queue; self.graph = graph
        var draws: [Draw] = [], pipelines: [String: MTLRenderPipelineState] = [:]
        for node in graph.nodes {
            try Task.checkCancellation()
            let primary = try Self.upload(node.texture, device: device)
            let texture = primary.texture, sampler = primary.sampler
            let passInputs = try node.passTextures.map { row in try row.map { try $0.map { try Self.upload($0, device: device) } } }
            let vertexName = node.puppet != nil ? "scenePuppetVertex" : node.particles != nil ? "sceneParticleVertex" : "sceneVertex"
            let key = node.blend.rawValue + vertexName + node.fragment
            let pipeline: MTLRenderPipelineState
            if let cached = pipelines[key] { pipeline = cached }
            else {
                do {
                    let library = try device.makeLibrary(source: SceneShader.vertex + "\n" + SceneShader.particleVertex + "\n" + SceneShader.puppetVertex + "\n" + node.fragment, options: nil)
                    let descriptor = MTLRenderPipelineDescriptor()
                    descriptor.vertexFunction = library.makeFunction(name: vertexName)
                    descriptor.fragmentFunction = library.makeFunction(name: "sceneFragment")
                    let color = descriptor.colorAttachments[0]!
                    color.pixelFormat = .bgra8Unorm; color.isBlendingEnabled = true
                    color.sourceRGBBlendFactor = .sourceAlpha; color.sourceAlphaBlendFactor = .one
                    color.destinationRGBBlendFactor = node.blend == .additive ? .one : .oneMinusSourceAlpha
                    color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                    pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
                    pipelines[key] = pipeline
                } catch { throw SceneRuntimeError.graphics("shader pipeline: \(error.localizedDescription)") }
            }
            let buffer: MTLBuffer?
            if let particles = node.particles {
                guard let allocated = device.makeBuffer(length: particles.count * MemoryLayout<SceneParticleInstance>.stride, options: .storageModeShared) else {
                    throw SceneRuntimeError.graphics("particle instance buffer")
                }
                buffer = allocated
            } else { buffer = nil }
            var puppetVertices: MTLBuffer?, puppetIndices: MTLBuffer?, puppetPalette: MTLBuffer?
            if let puppet = node.puppet, let index = node.puppetMeshIndex {
                let mesh = puppet.meshes[index]
                puppetVertices = mesh.vertices.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
                puppetIndices = mesh.indices.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
                puppetPalette = device.makeBuffer(length: max(1, puppet.bones.count) * MemoryLayout<simd_float4x4>.stride, options: .storageModeShared)
                guard puppetVertices != nil, puppetIndices != nil, puppetPalette != nil else { throw SceneRuntimeError.graphics("Puppet GPU buffers") }
            }
            var preprocessors: [Preprocess] = []
            for (index, fragment) in node.preprocessFragments.enumerated() {
                let key = "preprocess" + fragment
                let pipeline: MTLRenderPipelineState
                if let cached = pipelines[key] { pipeline = cached }
                else {
                    let library = try device.makeLibrary(source: SceneShader.vertex + "\n" + fragment, options: nil)
                    let descriptor = MTLRenderPipelineDescriptor()
                    descriptor.vertexFunction = library.makeFunction(name: "sceneVertex")
                    descriptor.fragmentFunction = library.makeFunction(name: "sceneFragment")
                    descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
                    // Store straight alpha between passes; final composition blends once.
                    descriptor.colorAttachments[0].isBlendingEnabled = false
                    pipeline = try device.makeRenderPipelineState(descriptor: descriptor); pipelines[key] = pipeline
                }
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                    width: Int(ceil(node.texture.logicalSize.x)), height: Int(ceil(node.texture.logicalSize.y)), mipmapped: false)
                descriptor.storageMode = .shared; descriptor.usage = [.renderTarget, .shaderRead]
                guard let target = device.makeTexture(descriptor: descriptor) else { throw SceneRuntimeError.graphics("material pass target") }
                preprocessors.append(.init(pipeline: pipeline, target: target, inputs: passInputs[index]))
            }
            draws.append(.init(node: node, texture: texture, sampler: sampler, pipeline: pipeline, particleBuffer: buffer,
                puppetVertices: puppetVertices, puppetIndices: puppetIndices, puppetPalette: puppetPalette, preprocessors: preprocessors, inputs: passInputs.last ?? []))
        }
        self.draws = draws
    }

    private static func upload(_ source: SceneTexture, device: MTLDevice) throws -> TextureInput {
        if source.format.isBlockCompressed && !device.supportsBCTextureCompression {
            throw SceneRuntimeError.unsupported("BC texture compression on this GPU")
        }
        let first = source.mips[0]
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: source.format.metal,
            width: first.width, height: first.height, mipmapped: source.mips.count > 1)
        descriptor.mipmapLevelCount = source.mips.count; descriptor.storageMode = .shared; descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw SceneRuntimeError.graphics("texture allocation") }
        for (level, mip) in source.mips.enumerated() {
            mip.bytes.withUnsafeBytes { buffer in
                texture.replace(region: MTLRegionMake2D(0, 0, mip.width, mip.height), mipmapLevel: level,
                    withBytes: buffer.baseAddress!, bytesPerRow: source.format.rowBytes(mip.width))
            }
        }
        let descriptorSampler = MTLSamplerDescriptor()
        descriptorSampler.minFilter = source.nearest ? .nearest : .linear
        descriptorSampler.magFilter = descriptorSampler.minFilter
        descriptorSampler.mipFilter = source.mips.count > 1 ? .linear : .notMipmapped
        descriptorSampler.sAddressMode = source.clamp ? .clampToEdge : .repeat
        descriptorSampler.tAddressMode = descriptorSampler.sAddressMode
        guard let sampler = device.makeSamplerState(descriptor: descriptorSampler) else { throw SceneRuntimeError.graphics("sampler allocation") }
        return .init(texture: texture, sampler: sampler, sampling: SIMD4(source.logicalSize.x / Float(first.width),
            source.logicalSize.y / Float(first.height), source.format == .rg ? 1 : source.format == .r ? 2 : 0, 0))
    }

    private static func bind(_ inputs: [TextureInput?], primary: MTLTexture, sampler: MTLSamplerState,
                             sampling: SIMD4<Float>, encoder: MTLRenderCommandEncoder) {
        var transforms = [SIMD4<Float>](repeating: SIMD4(1, 1, 0, 0), count: 8)
        encoder.setFragmentTexture(primary, index: 0); encoder.setFragmentSamplerState(sampler, index: 0)
        transforms[0] = sampling
        for slot in 1..<8 {
            let input = slot < inputs.count ? inputs[slot] : nil
            // Clear unused slots on every draw; bindings from the preceding pass cannot leak.
            encoder.setFragmentTexture(input?.texture, index: slot)
            encoder.setFragmentSamplerState(input?.sampler, index: slot)
            if let input { transforms[slot] = input.sampling }
        }
        transforms.withUnsafeMutableBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
    }

    func encode(target: MTLTexture, time: TimeInterval, cursor: SIMD2<Float>, command: MTLCommandBuffer) throws {
        guard time.isFinite, time >= 0, time <= 100 * 365.25 * 86_400,
              cursor.x.isFinite, cursor.y.isFinite else { throw SceneRuntimeError.malformed("scene frame inputs") }
        var processed: [Int: MTLTexture] = [:]
        for (index, draw) in draws.enumerated() where !draw.preprocessors.isEmpty {
            var source = draw.texture
            let mip = draw.node.texture.mips[0]
            var sampling = SIMD4(draw.node.texture.logicalSize.x / Float(mip.width), draw.node.texture.logicalSize.y / Float(mip.height),
                                draw.node.texture.format == .rg ? 1 : draw.node.texture.format == .r ? 2 : 0, 0)
            for pass in draw.preprocessors {
                let descriptor = MTLRenderPassDescriptor()
                descriptor.colorAttachments[0].texture = pass.target
                descriptor.colorAttachments[0].loadAction = .clear; descriptor.colorAttachments[0].storeAction = .store
                descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
                guard let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else { throw SceneRuntimeError.graphics("material pass encoder") }
                var vertices = [Vertex(position: SIMD2(-1,-1), uv: SIMD2(0,1)), Vertex(position: SIMD2(1,-1), uv: SIMD2(1,1)),
                    Vertex(position: SIMD2(-1,1), uv: SIMD2(0,0)), Vertex(position: SIMD2(-1,1), uv: SIMD2(0,0)),
                    Vertex(position: SIMD2(1,-1), uv: SIMD2(1,1)), Vertex(position: SIMD2(1,1), uv: SIMD2(1,0))]
                var uniforms = Uniforms(color: SIMD4(repeating: 1),
                    inputs: SIMD4(Float(time.truncatingRemainder(dividingBy: 86_400)), cursor.x, cursor.y, 0), sampling: sampling)
                encoder.setRenderPipelineState(pass.pipeline)
                vertices.withUnsafeMutableBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
                Self.bind(pass.inputs, primary: source, sampler: draw.sampler, sampling: sampling, encoder: encoder)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6); encoder.endEncoding()
                source = pass.target; sampling = SIMD4(1,1,0,0)
            }
            processed[index] = source
        }
        let descriptor = MTLRenderPassDescriptor()
        let color = graph.document.clearColor
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = .clear; descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColorMake(Double(color.x), Double(color.y), Double(color.z), 1)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else { throw SceneRuntimeError.graphics("render encoder") }
        defer { encoder.endEncoding() }
        let projection = graph.document.size
        let screen = SIMD2(Float(target.width), Float(target.height))
        let fill = max(screen.x / projection.x, screen.y / projection.y)
        let cursorShift = (cursor - SIMD2(repeating: 0.5)) * graph.document.cameraParallax * projection
        guard fill.isFinite, cursorShift.x.isFinite, cursorShift.y.isFinite else { throw SceneRuntimeError.malformed("scene projection / cursor transform") }
        let states = try scriptedLayers()
        for (index, draw) in draws.enumerated() {
            let state = states[draw.node.id]
            if state?.2 == false { continue }
            let half = draw.node.size / 2
            func vertex(_ local: SIMD2<Float>, uv: SIMD2<Float>) throws -> Vertex {
                let world = (state?.0 ?? draw.node.transform) * SIMD3(local.x, local.y, 1)
                let clip = (SIMD2(world.x, world.y) - projection / 2 - cursorShift) * fill / screen * 2
                guard clip.x.isFinite, clip.y.isFinite else { throw SceneRuntimeError.malformed("non-finite layer vertices: \(draw.node.id)") }
                return .init(position: clip, uv: uv)
            }
            var vertices = try [
                vertex(SIMD2(-half.x, -half.y), uv: SIMD2(0, 1)), vertex(SIMD2(half.x, -half.y), uv: SIMD2(1, 1)),
                vertex(SIMD2(-half.x, half.y), uv: SIMD2(0, 0)), vertex(SIMD2(-half.x, half.y), uv: SIMD2(0, 0)),
                vertex(SIMD2(half.x, -half.y), uv: SIMD2(1, 1)), vertex(SIMD2(half.x, half.y), uv: SIMD2(1, 0))
            ]
            let mip = draw.node.texture.mips[0]
            var uniforms = Uniforms(color: state?.1 ?? draw.node.color, inputs: SIMD4(Float(time.truncatingRemainder(dividingBy: 86_400)), cursor.x, cursor.y, 0),
                sampling: SIMD4(draw.node.texture.logicalSize.x / Float(mip.width), draw.node.texture.logicalSize.y / Float(mip.height),
                                draw.node.texture.format == .rg ? 1 : draw.node.texture.format == .r ? 2 : 0, 0))
            if processed[index] != nil { uniforms.sampling = SIMD4(1,1,0,0) }
            encoder.setRenderPipelineState(draw.pipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            Self.bind(draw.inputs, primary: processed[index] ?? draw.texture, sampler: draw.sampler, sampling: uniforms.sampling, encoder: encoder)
            if let puppet = draw.node.puppet, let index = draw.node.puppetMeshIndex,
               let vertices = draw.puppetVertices, let indices = draw.puppetIndices, let paletteBuffer = draw.puppetPalette {
                let palette = try puppet.palette(at: time)
                palette.withUnsafeBytes { paletteBuffer.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
                var puppetUniforms = ParticleUniforms(transform: state?.0 ?? draw.node.transform,
                    projection: SIMD4(projection.x, projection.y, screen.x, screen.y), view: SIMD4(fill, cursorShift.x, cursorShift.y, 0))
                encoder.setVertexBuffer(vertices, offset: 0, index: 0)
                encoder.setVertexBytes(&puppetUniforms, length: MemoryLayout<ParticleUniforms>.stride, index: 2)
                encoder.setVertexBuffer(paletteBuffer, offset: 0, index: 3)
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: puppet.meshes[index].indices.count,
                    indexType: .uint32, indexBuffer: indices, indexBufferOffset: 0)
            } else if let particles = draw.node.particles, let buffer = draw.particleBuffer {
                let seed = draw.node.id.utf8.reduce(UInt64(0xcbf29ce484222325)) { ($0 ^ UInt64($1)) &* 0x100000001b3 }
                let instances = particles.instances(at: time, seed: seed)
                guard !instances.isEmpty else { continue }
                instances.withUnsafeBytes { buffer.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
                var particleUniforms = ParticleUniforms(transform: state?.0 ?? draw.node.transform,
                    projection: SIMD4(projection.x, projection.y, screen.x, screen.y), view: SIMD4(fill, cursorShift.x, cursorShift.y, 0))
                encoder.setVertexBuffer(buffer, offset: 0, index: 1)
                encoder.setVertexBytes(&particleUniforms, length: MemoryLayout<ParticleUniforms>.stride, index: 2)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: instances.count)
            } else {
                vertices.withUnsafeMutableBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }
        }
    }

    /// Offscreen GPU completion is the Ready gate; MTKView attachment is not readiness.
    func firstFrame() async throws -> CGImage {
        let size = graph.document.size
        let scale = min(1, 1_920 / max(size.x, size.y))
        let width = max(1, Int(size.x * scale)), height = max(1, Int(size.y * scale))
        // Both the owned render target and CPU fallback copy must fit before either allocation.
        // Runtime frame buffers already have the same admission check after attachment.
        guard width * height * 8 <= graph.limits.maximumResidentBytes - graph.residentBytes else {
            throw SceneRuntimeError.budgetExceeded("scene first-frame buffers")
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.renderTarget]
        guard let target = device.makeTexture(descriptor: descriptor), let command = queue.makeCommandBuffer() else {
            throw SceneRuntimeError.graphics("first frame allocation")
        }
        try encode(target: target, time: 0, cursor: SIMD2(repeating: 0.5), command: command)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            command.addCompletedHandler { result in
                if result.status == .completed { continuation.resume() }
                else { continuation.resume(throwing: SceneRuntimeError.graphics(result.error?.localizedDescription ?? "first frame GPU failure")) }
            }
            command.commit()
        }
        try Task.checkCancellation()
        return try Self.snapshot(target)
    }

    /// Only completed, shared offscreen targets may be read. Called on preparation/failure,
    /// never on every normal frame and never on a framebuffer-only drawable.
    static func snapshot(_ target: MTLTexture) throws -> CGImage {
        let width = target.width, height = target.height
        guard target.storageMode == .shared, target.pixelFormat == .bgra8Unorm else { throw SceneRuntimeError.graphics("frame snapshot texture") }
        var data = Data(count: width * height * 4)
        data.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: width * 4,
            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0) }
        guard let provider = CGDataProvider(data: data as CFData), let image = CGImage(width: width, height: height, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw SceneRuntimeError.graphics("first frame snapshot")
        }
        return image
    }
}
