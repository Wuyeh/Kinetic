import CoreGraphics
import Foundation
import Metal

public enum KineticWPEBackendError: Error, Sendable {
    case unsupported(String)
    case budget
    case disposed
    case missingAsset(String)
}

struct WPEHostAssetReadFailure: Error { let underlying: Error }

private struct KineticHostAssetProvider: WPESceneAssetProvider {
    let reader: @Sendable (String) throws -> Data
    var entryNames: [String] { [] }
    func data(atRelativePath relativePath: String) throws -> Data {
        do { return try reader(relativePath) }
        catch KineticWPEBackendError.missingAsset { throw WPESceneAssetProviderError.fileMissing(relativePath) }
        catch is CancellationError { throw CancellationError() }
        catch { throw WPEHostAssetReadFailure(underlying: error) }
    }
    func exists(atRelativePath relativePath: String) -> Bool { (try? reader(relativePath)) != nil }
    func stagedURL(atRelativePath relativePath: String) throws -> URL {
        // No extraction directory or arbitrary disk-cache policy belongs to the engine.
        throw KineticWPEBackendError.unsupported("staged media: \(relativePath)")
    }
}

/// Host-owned admission for the ported image/material/render-graph path.
/// No WPE app services, JSC contexts, default directories, display links, or UI.
/// Scripts run only in the complete engine tier (`KineticWPESceneHost`); the facade owns desktop presentation.
public final class KineticWPEImageBackend: @unchecked Sendable {
    public let device: MTLDevice
    private let storage: Storage
    private let budget: WPEHostTextureBudget
    public var residentBytes: Int { budget.residentBytes }

    private init(device: MTLDevice, storage: Storage, budget: WPEHostTextureBudget) {
        self.device = device; self.storage = storage; self.budget = budget
    }

    public static func prepare(sceneData: Data, maximumBytes: Int, maximumEdge: Int,
        externalBytes: Int = 0, maximumPasses: Int = 2_048, maximumPrograms: Int = 32,
        reader: @escaping @Sendable (String) throws -> Data) async throws -> KineticWPEImageBackend {
        try Task.checkCancellation()
        let provider = KineticHostAssetProvider(reader: reader)
        let document = try WPESceneDocumentParser.parse(data: sceneData)
        let rejected = document.diagnostics.filter { $0.severity != .info }
        guard rejected.isEmpty else { throw KineticWPEBackendError.unsupported("scene parser diagnostics: \(rejected)") }
        guard document.textObjects.isEmpty, document.particleObjects.isEmpty, document.soundObjects.isEmpty,
              document.scriptHostObjects.isEmpty, document.lightObjects.isEmpty,
              WPESceneScriptInstanceInventory(document: document).total == 0,
              document.cameraMotion == nil, document.authoredCamera.paths == nil,
              !document.general.usesPerspectiveProjection else {
            throw KineticWPEBackendError.unsupported("extended non-image/script/camera object")
        }
        guard document.imageObjects.allSatisfy({ object in
            object.effects.allSatisfy { $0.visibleScript == nil && $0.passOverrides.allSatisfy { $0.constantScripts.isEmpty } }
                && object.originAnimation == nil
        }), document.transformHostObjects.allSatisfy({ $0.originAnimation == nil }) else {
            throw KineticWPEBackendError.unsupported("extended scripted/keyframed layer")
        }
        let graph = try WPERenderGraphBuilder(primaryProvider: provider).build(document: document)
        let pipeline = try WPERenderPipelineBuilder(primaryProvider: provider).build(graph: graph,
            canonicalCompositeRotationEnabled: false, sceneHDR: document.general.usesHDRRendering,
            fullFramePassthroughElisionEnabled: false)
        guard pipeline.layers.allSatisfy({ $0.puppetModel == nil }), !pipeline.layers.isEmpty else {
            throw KineticWPEBackendError.unsupported("extended puppet/empty pipeline")
        }
        let passes = pipeline.layers.flatMap(\.passes)
        guard passes.count <= maximumPasses,
              Set(passes.map { $0.pass.shader + String(describing: $0.comboValues.sorted { $0.key < $1.key }) }).count <= maximumPrograms else {
            throw KineticWPEBackendError.budget
        }
        guard passes.allSatisfy({ $0.shader != nil }) else { throw KineticWPEBackendError.unsupported("unresolved shader program") }
        for layer in pipeline.layers {
            let geometry = layer.graphLayer.geometry
            let values = Array(0..<3).flatMap { [geometry.origin[$0], geometry.scale[$0], geometry.angles[$0], geometry.color[$0]] }
                + [geometry.alpha, geometry.brightness]
                + (layer.modelMatrixOverride ?? [])
                + (geometry.shapePoints ?? []).flatMap { [$0.x, $0.y] }
            guard values.allSatisfy({ $0.isFinite && Float($0).isFinite }),
                  geometry.size.map({ $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0 }) ?? true else {
                throw KineticWPEBackendError.unsupported("non-finite extended geometry")
            }
        }
        let camera = WPEMetalCameraUniforms(orthogonalProjection: document.general.orthogonalProjection,
            sceneCamera: document.camera, usesPerspectiveProjection: false,
            lightAmbientColor: document.general.lightAmbientColor, lightSkylightColor: document.general.lightSkylightColor,
            sceneHDR: document.general.usesHDRRendering, bloom: document.general.bloom)
        guard camera.renderSize.width.isFinite, camera.renderSize.height.isFinite,
              camera.renderSize.width > 0, camera.renderSize.height > 0,
              camera.renderSize.width <= CGFloat(maximumEdge), camera.renderSize.height <= CGFloat(maximumEdge) else {
            throw KineticWPEBackendError.budget
        }
        guard let device = MTLCreateSystemDefaultDevice() else { throw WPEMetalRenderExecutorError.commandQueueUnavailable }
        let budget = WPEHostTextureBudget(maximumBytes: maximumBytes, maximumEdge: maximumEdge)
        try budget.setExternalBytes(externalBytes)
        let resolver = WPEMultiRootResourceResolver(primaryProvider: provider, dependencyMounts: [])
        let loader = WPEMetalTextureLoader(device: device)
        var paths = Set<String>()
        for layer in pipeline.layers {
            for pass in layer.passes {
                for reference in Array(pass.textureBindings.values) + Array(pass.pass.textures.values)
                    + Array(pass.pass.binds.values) + [pass.pass.source] {
                    switch reference {
                    case .image(let path), .asset(let path): paths.insert(path)
                    case .previous, .fbo: break
                    }
                }
            }
        }
        var textures: [String: MTLTexture] = [:]
        for path in paths.sorted() {
            try Task.checkCancellation()
            // Reader validates decoded sizes before this point; each upload is reserved first.
            if let payload = try? resolver.resolveTexturePayload(relativePath: path) {
                guard payload.animationTrack == nil, payload.videoPayload == nil else {
                    throw KineticWPEBackendError.unsupported("extended animated/video TEX")
                }
                guard let level = payload.mipmaps.first else { throw KineticWPEBackendError.unsupported("empty TEX") }
                // Conservative worst-case RGBA32F plus the full mip chain; checked before upload.
                let estimate = payload.mipmaps.reduce(0) { $0 + $1.width * $1.height * 16 }
                textures[path] = try await budget.allocateAsync(bytes: estimate, width: level.width, height: level.height) {
                    try await loader.makeTexture(from: payload, label: path)
                }
            } else {
                let resolved = try resolver.resolveImage(relativePath: path)
                let bytes = resolved.image.width * resolved.image.height * 16
                // The blocking ImageIO upload has no author callback and stays off the main actor.
                textures[path] = try await budget.allocateAsync(bytes: bytes, width: resolved.image.width, height: resolved.image.height) {
                    try await loader.makeTexture(from: resolved.image, label: path)
                }
            }
        }
        let storage = try Storage(device: device, document: document, pipeline: pipeline, camera: camera,
                                  textures: textures, budget: budget)
        return Self(device: device, storage: storage, budget: budget)
    }

    /// - Parameter letterboxed: show the whole canvas (contain) instead of cropping it to fill the target (cover).
    /// - Parameter crop: Kinetic's 自定义 display region; when set it replaces cover / contain.
    public func render(time: Double, cursor: SIMD2<Double>, target: MTLTexture, letterboxed: Bool = false,
                       crop: KineticSceneCrop? = nil) async throws {
        try await storage.render(time: time, cursor: cursor, target: target, letterboxed: letterboxed, crop: crop)
    }
    public func setExternalBytes(_ bytes: Int) throws { try budget.setExternalBytes(bytes) }
    public func dispose() async { await storage.dispose() }

    private actor Storage {
        private var executor: WPEMetalRenderExecutor?
        private var textures: [String: MTLTexture]
        private let pipeline: WPEPreparedRenderPipeline
        private let camera: WPEMetalCameraUniforms
        init(device: MTLDevice, document: WPESceneDocument, pipeline: WPEPreparedRenderPipeline,
             camera: WPEMetalCameraUniforms, textures: [String: MTLTexture], budget: WPEHostTextureBudget) throws {
            let executor = try WPEMetalRenderExecutor(device: device,
                diagnosticControls: .init(environment: ["WPE_DIAGNOSTIC_DISABLE_FBO_ALIASING": "1"]), hostIsolated: true)
            executor.targetPool.hostBudget = budget
            executor.depthCache.hostBudget = budget
            executor.uniformArena.hostBudget = budget
            executor.synchronizeFrameCompletion = true
            let color = document.general.clearColor
            executor.sceneClearColor = .init(red: color.x, green: color.y, blue: color.z, alpha: 1)
            executor.sceneClearEnabled = document.general.clearEnabled.resolvedValue
            self.executor = executor; self.textures = textures; self.pipeline = pipeline; self.camera = camera
        }
        func render(time: Double, cursor: SIMD2<Double>, target: MTLTexture, letterboxed: Bool, crop: KineticSceneCrop?) throws {
            try Task.checkCancellation()
            guard let executor else { throw KineticWPEBackendError.disposed }
            try executor.targetPool.hostBudget?.checkAdmission()
            guard time.isFinite, time >= 0, cursor.x.isFinite, cursor.y.isFinite else { throw KineticWPEBackendError.budget }
            let source = try executor.render(pipeline: pipeline, size: camera.renderSize, textures: textures,
                runtimeUniforms: .init(time: time, daytime: 0, brightness: 1, pointerPosition: cursor), cameraUniforms: camera)
            try executor.targetPool.hostBudget?.checkAdmission()
            guard executor.shaderErrorSink.summary.count == 0 else {
                throw KineticWPEBackendError.unsupported("shader compilation: \(executor.shaderErrorSink.summary.entries)")
            }
            guard executor.gpuErrorSink.summary.count == 0 else { throw WPEMetalRenderExecutorError.commandBufferFailed }
            guard let command = executor.textureSourceCommandQueue.makeCommandBuffer() else { throw WPEMetalRenderExecutorError.commandBufferFailed }
            try executor.encodePresentPass(source: source, target: target,
                                          fitMode: crop.map { .custom($0) } ?? (letterboxed ? .contain : .cover),
                                          worldSourceSize: camera.renderSize, uniforms: nil, into: command)
            command.commit(); command.waitUntilCompleted()
            guard command.status == .completed else { throw WPEMetalRenderExecutorError.commandBufferFailed }
        }
        func dispose() { executor?.releaseTransientResources(); executor = nil; textures = [:] }
    }
}
