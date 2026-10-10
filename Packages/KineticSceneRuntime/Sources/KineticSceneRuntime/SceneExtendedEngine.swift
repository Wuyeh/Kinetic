import Foundation
import CoreGraphics
import KineticWPEEngine
import Metal
import os

/// The ported render-graph path receives only the existing bounded asset reader.
/// Scripted / animated object families are declined here and reach the complete engine tier
/// (`KineticWPESceneHost`, SceneScript through upstream JavaScriptCore).
final class SceneExtendedEngine: @unchecked Sendable {
    let backend: KineticWPEImageBackend
    let frame: CGImage
    /// The authored canvas (orthographic projection) size.
    let canvasSize: CGSize
    var device: MTLDevice { backend.device }
    var residentBytes: Int { backend.residentBytes }

    private init(backend: KineticWPEImageBackend, frame: CGImage, canvasSize: CGSize) {
        self.backend = backend; self.frame = frame; self.canvasSize = canvasSize
    }
    static func prepare(root: URL, engineAssets: URL?, limits: SceneLimits) async throws -> Self {
        let assets = try SceneAssetResolver(root: root, additionalRoots: engineAssets.map { [$0] } ?? [], limits: limits)
        let metadata = try SceneImportMetadata.inspect(root: root, limits: limits)
        let project = try SceneJSON.parse(assets.readSceneOwned("project.json", maximumBytes: limits.maximumJSONBytes), limits: limits)
        if let dependencies = project["dependencies"].array, !dependencies.isEmpty {
            throw SceneRuntimeError.unsupported("external Workshop dependencies")
        }
        let source = try assets.readSceneOwned(metadata.entry, maximumBytes: limits.maximumJSONBytes)
        let json = try SceneJSON.parse(source, limits: limits)
        let projection = json["general"]["orthogonalprojection"]
        let width = projection["width"].number ?? 1920, height = projection["height"].number ?? 1080
        guard width.isFinite, height.isFinite, width >= 1, height >= 1,
              width <= Double(limits.maximumTextureEdge), height <= Double(limits.maximumTextureEdge) else {
            throw SceneRuntimeError.budgetExceeded("extended scene projection")
        }
        let frameBytes = Int(width.rounded(.up)) * Int(height.rounded(.up)) * 8
        guard frameBytes < limits.maximumResidentBytes else { throw SceneRuntimeError.budgetExceeded("extended first frame") }
        let ledger = SceneExtendedReadLedger(assets: assets, limits: limits)
        let backend: KineticWPEImageBackend
        do {
            _ = try ledger.validate(source, path: metadata.entry)
            backend = try await KineticWPEImageBackend.prepare(sceneData: source,
                maximumBytes: limits.maximumResidentBytes, maximumEdge: limits.maximumTextureEdge, externalBytes: frameBytes,
                maximumPasses: limits.maximumObjects, maximumPrograms: limits.maximumShaderPrograms,
                reader: { try ledger.read($0) })
            if let rejected = ledger.rejectedRead { await backend.dispose(); throw rejected }
        } catch { throw ledger.rejectedRead ?? translate(error) }
        do {
            try Task.checkCancellation()
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                width: Int(width.rounded(.up)), height: Int(height.rounded(.up)), mipmapped: false)
            descriptor.storageMode = .shared; descriptor.usage = [.renderTarget, .shaderRead]
            guard let target = backend.device.makeTexture(descriptor: descriptor) else { throw SceneRuntimeError.graphics("extended first frame target") }
            try await backend.render(time: 0, cursor: SIMD2(repeating: 0.5), target: target)
            try Task.checkCancellation()
            let image = try SceneMetalEngine.snapshot(target)
            return Self(backend: backend, frame: image, canvasSize: CGSize(width: width, height: height))
        } catch { await backend.dispose(); throw translate(error) }
    }
    static func translate(_ error: Error) -> Error {
        switch error {
        case KineticWPEBackendError.budget: return SceneRuntimeError.budgetExceeded("extended engine textures / render targets")
        case KineticWPEBackendError.unsupported(let detail): return SceneRuntimeError.unsupported(detail)
        case KineticWPEBackendError.disposed: return SceneRuntimeError.disposed
        case KineticWPEBackendError.missingAsset(let path): return SceneRuntimeError.missingAsset(path)
        case is SceneRuntimeError, is CancellationError: return error
        // Any other ported-engine failure (for example an unresolved auxiliary mask slot) means this
        // optional tier cannot draw the Scene; the complete engine decides and reports exact paths.
        default: return SceneRuntimeError.unsupported("extended engine: \(error)")
        }
    }
}

private final class SceneExtendedReadLedger: @unchecked Sendable {
    let assets: SceneAssetResolver
    let limits: SceneLimits
    private struct State { var sizes: [String: Int] = [:]; var total = 0; var shaderTotal = 0 }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let rejected = OSAllocatedUnfairLock<Error?>(initialState: nil)
    var rejectedRead: Error? { rejected.withLock { $0 } }
    init(assets: SceneAssetResolver, limits: SceneLimits) { self.assets = assets; self.limits = limits }
    func read(_ path: String) throws -> Data {
        try Task.checkCancellation()
        do {
            let canonical = try ScenePath.canonical(path)
            let data = try assets.read(canonical)
            return try validate(data, path: canonical)
        }
        catch SceneRuntimeError.missingAsset { throw KineticWPEBackendError.missingAsset(path) }
        catch is CancellationError { throw CancellationError() }
        catch { rejected.withLock { if $0 == nil { $0 = error } }; throw error }
    }
    func validate(_ data: Data, path: String) throws -> Data {
        let ext = (path as NSString).pathExtension.lowercased()
        if ext == "json" {
            let value = try SceneJSON.parse(data, limits: limits)
            func check(_ value: SceneJSON) throws {
                if let fields = value.object {
                    for (key, child) in fields {
                        if ["script", "scripts"].contains(key.lowercased()), child != .null {
                            throw SceneRuntimeError.unsupported("extended SceneScript host API; complete engine (JavaScriptCore) required")
                        }
                        try check(child)
                    }
                } else if let values = value.array { for child in values { try check(child) } }
            }
            try check(value)
        } else if ["tex", "png", "jpg", "jpeg", "gif", "bmp", "webp"].contains(ext) {
            // Decode through the bounded admission parser first. The original payload stays read-only.
            let texture = try SceneTexture.decode(data, limits: limits)
            guard texture.residentBytes <= limits.maximumResidentBytes else { throw SceneRuntimeError.budgetExceeded(path) }
        } else if ext == "mdl" {
            throw SceneRuntimeError.unsupported("extended Puppet host adapter")
        }
        try state.withLock { state in
            guard state.sizes[path] == nil else { return }
            guard data.count <= limits.maximumResidentBytes - state.total else { throw SceneRuntimeError.budgetExceeded("extended asset working set") }
            if ["frag", "vert", "glsl", "h"].contains(ext) {
                guard data.count <= limits.maximumShaderBytes - state.shaderTotal else { throw SceneRuntimeError.budgetExceeded("extended shader sources") }
                state.shaderTotal += data.count
            }
            state.sizes[path] = data.count; state.total += data.count
        }
        return data
    }
}
