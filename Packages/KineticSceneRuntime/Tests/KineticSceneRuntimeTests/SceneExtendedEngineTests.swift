import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Metal
import KineticWPEEngine
import XCTest
@testable import KineticSceneRuntime

final class SceneExtendedEngineTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        root = package.appendingPathComponent(".build/ExtendedFixtures/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try write("project.json", ["type": "scene", "file": "scene.json", "title": "FBO test"])
        try write("scene.json", ["camera": ["center": "0 0 0"], "general": ["orthogonalprojection": ["width": 16, "height": 16], "clearcolor": "0 0 0"],
            "objects": [["id": 1, "name": "FBO layer", "image": "models/layer.json", "origin": "8 8 0", "size": "16 16 0",
                "effects": [["id": 2, "file": "effects/probe/effect.json"]]]]])
        try write("models/layer.json", ["material": "materials/base.json"])
        try write("materials/base.json", ["passes": [["shader": "solidcolor", "blending": "disabled",
            "textures": ["pixel.png"], "constantshadervalues": ["g_Color": [1, 0, 0, 1]]]]])
        try write("materials/green.json", ["passes": [["shader": "solidcolor", "blending": "disabled",
            "constantshadervalues": ["g_Color": [0, 1, 0, 1]]]]])
        try write("materials/copy.json", ["passes": [["shader": "commands/copy", "blending": "disabled"]]])
        try write("effects/probe/effect.json", ["fbos": [["name": "_rt_KineticProbe", "scale": 1, "format": "rgba8888"]],
            "passes": [["material": "materials/green.json", "target": "_rt_KineticProbe"],
                       ["material": "materials/copy.json", "bind": [["index": 0, "name": "_rt_KineticProbe"]]]]])
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let output = try XCTUnwrap(CGImageDestinationCreateWithURL(root.appendingPathComponent("pixel.png") as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(output, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(output))
    }
    override func tearDownWithError() throws { if let root { try FileManager.default.removeItem(at: root) } }
    private func write(_ path: String, _ object: Any) throws {
        let target = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: target)
    }
    private func pixel(_ image: CGImage) throws -> [UInt8] {
        let data = try XCTUnwrap(image.dataProvider?.data) as Data
        let offset = (image.height / 2 * image.width + image.width / 2) * 4
        return Array(data[offset..<(offset + 4)])
    }
    @MainActor func testFacadeUsesPortedGraphAndActuallyReadsNamedFBO() async throws {
        let runtime = KineticSceneRuntime(root: root)
        defer { runtime.dispose() }
        do { try await runtime.prepare() }
        catch { XCTFail("Actual graph preparation error: \(error)"); throw error }
        XCTAssertTrue(runtime.usesExtendedRenderGraph)
        let color = try pixel(XCTUnwrap(runtime.preparedFrame))
        XCTAssertLessThan(color[0], 10); XCTAssertGreaterThan(color[1], 245)
        XCTAssertLessThan(color[2], 10); XCTAssertEqual(color[3], 255)
        XCTAssertFalse(runtime.isPlaying)
        runtime.play(); runtime.pause()
        XCTAssertFalse(runtime.isPlaying); XCTAssertNotNil(runtime.preparedFrame)
        runtime.resume(); XCTAssertTrue(runtime.isPlaying)
    }
    @MainActor func testExtendedFirstFrameTargetsShareResidentBudget() async throws {
        var limits = SceneLimits(); limits.maximumResidentBytes = 2_200
        do { _ = try await SceneExtendedEngine.prepare(root: root, engineAssets: nil, limits: limits); XCTFail("FBO allocation must fail before Ready") }
        catch SceneRuntimeError.budgetExceeded {}
        // The over-budget image tier is never kept; the complete engine decides (2026-10-05 tier policy).
        let runtime = KineticSceneRuntime(root: root, limits: limits)
        defer { runtime.dispose() }
        do { try await runtime.prepare() } catch { XCTAssertTrue(error is SceneRuntimeError, "Actual error: \(error)") }
        XCTAssertFalse(runtime.usesExtendedRenderGraph)
        if runtime.isPrepared { XCTAssertTrue(runtime.usesFullEngine) }
    }
    /// Only an unsafe path, disposal or cancellation stops the tier chain (a tier's own malformed / budget /
    /// graphics verdict moves on, 2026-10-05); an escaping reference is never rendered by any tier.
    @MainActor func testUnsafePathIsNeverRendered() async throws {
        try write("models/layer.json", ["material": "../outside.json"])
        let runtime = KineticSceneRuntime(root: root)
        defer { runtime.dispose() }
        do { try await runtime.prepare(); XCTFail("an escaping path was rendered") }
        catch { XCTAssertFalse(runtime.isPrepared, "\(error)") }
        XCTAssertFalse(runtime.usesFullEngine)
    }
    /// 2026-10-05 user decision: authored scripts run in the complete engine through upstream JavaScriptCore.
    /// The scriptless image backend still never executes them; a runaway script is contained, not hung on.
    @MainActor func testScriptedSceneSkipsImageBackendAndRunawayScriptIsContained() async throws {
        let target = root.appendingPathComponent("materials/green.json")
        try write("materials/green.json", ["passes": [["shader": "solidcolor",
            "constantshadervalues": ["g_Color": ["value": "0 1 0 1", "script": "while(true){}"]]]]])
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        do { _ = try await SceneExtendedEngine.prepare(root: root, engineAssets: nil, limits: .init()); XCTFail("Image backend admitted a script") }
        catch { XCTAssertTrue(error.localizedDescription.contains("JavaScriptCore"), "Actual error: \(error)") }
        let runtime = KineticSceneRuntime(root: root)
        defer { runtime.dispose() }
        let started = ProcessInfo.processInfo.systemUptime
        do { try await runtime.prepare() } catch { XCTAssertTrue(error is SceneRuntimeError, "Actual error: \(error)") }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, SceneLimits().preparationTimeout + 2)
        XCTAssertFalse(runtime.usesExtendedRenderGraph)
        if runtime.isPrepared { XCTAssertTrue(runtime.usesFullEngine) }
    }
    func testExtendedShaderTimeChangesPixelsAndDisposeReleasesResources() async throws {
        try write("materials/green.json", ["passes": [["shader": "kinetic_probe", "blending": "disabled"]]])
        try FileManager.default.createDirectory(at: root.appendingPathComponent("shaders"), withIntermediateDirectories: true)
        try Data("attribute vec3 a_Position;\nuniform mat4 g_ModelViewProjectionMatrix;\nvoid main() {\n gl_Position=g_ModelViewProjectionMatrix*vec4(a_Position,1.0);\n}\n".utf8).write(to: root.appendingPathComponent("shaders/kinetic_probe.vert"))
        try Data("uniform float g_Time; void main(){float r=0.0; for(int i=0;i<4;i++){r+=0.25;} gl_FragColor=vec4(r*g_Time,0.0,1.0-g_Time,1.0);}".utf8)
            .write(to: root.appendingPathComponent("shaders/kinetic_probe.frag"))
        let engine = try await SceneExtendedEngine.prepare(root: root, engineAssets: nil, limits: .init())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 16, height: 16, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.renderTarget, .shaderRead]
        let target = try XCTUnwrap(engine.device.makeTexture(descriptor: descriptor))
        try await engine.backend.render(time: 1, cursor: SIMD2(repeating: 0.5), target: target)
        let first = try pixel(SceneMetalEngine.snapshot(target))
        try await engine.backend.render(time: 0, cursor: SIMD2(repeating: 0.5), target: target)
        let second = try pixel(SceneMetalEngine.snapshot(target))
        XCTAssertGreaterThan(first[2], 245); XCTAssertLessThan(first[0], 10)
        XCTAssertGreaterThan(second[0], 245); XCTAssertLessThan(second[2], 10)
        XCTAssertGreaterThan(engine.residentBytes, 0)
        await engine.backend.dispose()
        XCTAssertEqual(engine.residentBytes, 0)
        do { try await engine.backend.render(time: 0, cursor: SIMD2(repeating: 0.5), target: target); XCTFail("Disposed engine rendered") }
        catch { XCTAssertTrue(error is KineticWPEBackendError) }
    }
    /// The bounded and image tiers decline Workshop dependencies; the complete engine mounts them or
    /// reports the missing item by its ID (never renders around it).
    @MainActor func testUnresolvedWorkshopDependencyIsReportedMissing() async throws {
        try write("project.json", ["type": "scene", "file": "scene.json", "dependencies": ["123"]])
        let runtime = KineticSceneRuntime(root: root)
        defer { runtime.dispose() }
        do { try await runtime.prepare(); XCTFail("Unresolved dependency ignored") }
        catch SceneRuntimeError.missingAsset(let detail) { XCTAssertTrue(detail.contains("123"), detail) }
        XCTAssertFalse(runtime.isPrepared)
    }
    /// A ported image-tier failure outside the runtime's own errors (here an unresolved auxiliary texture
    /// that the upstream resolver reports as its private `fileMissing`) hands the Scene to the complete
    /// engine instead of aborting preparation. Found with real Workshop item 3779018156 (2026-10-05).
    @MainActor func testImageTierResolverFailureHandsOffToCompleteEngine() async throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent("pixel.png"))
        do { _ = try await SceneExtendedEngine.prepare(root: root, engineAssets: nil, limits: SceneLimits()); XCTFail("image tier drew around") }
        catch SceneRuntimeError.unsupported(let detail) { XCTAssertTrue(detail.hasPrefix("extended engine:"), detail) }
        let runtime = KineticSceneRuntime(root: root)
        defer { runtime.dispose() }
        do { try await runtime.prepare() }
        catch { XCTFail("Preparation stopped before the complete engine: \(error)"); throw error }
        XCTAssertTrue(runtime.usesFullEngine)
        XCTAssertFalse(runtime.usesExtendedRenderGraph)
        let frame = try XCTUnwrap(runtime.preparedFrame)
        let context = try XCTUnwrap(CGContext(data: nil, width: frame.width, height: frame.height, bitsPerComponent: 8,
            bytesPerRow: frame.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(frame, in: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
        let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        XCTAssertGreaterThan(data[((frame.height / 2) * frame.width + frame.width / 2) * 4 + 1], 200, "the effect's green pass rendered")
    }
    func testForeignImageTierErrorsBecomeUnsupportedButRuntimeErrorsStay() {
        struct Foreign: Error {}
        guard case SceneRuntimeError.unsupported = SceneExtendedEngine.translate(Foreign()) else { return XCTFail("foreign error leaked") }
        XCTAssertEqual(SceneExtendedEngine.translate(SceneRuntimeError.malformed("x")) as? SceneRuntimeError, .malformed("x"))
        XCTAssertEqual(SceneExtendedEngine.translate(SceneRuntimeError.budgetExceeded("y")) as? SceneRuntimeError, .budgetExceeded("y"))
        XCTAssertTrue(SceneExtendedEngine.translate(CancellationError()) is CancellationError)
    }
    func testSceneImportIdentificationChecksOwnEntryAndUnsafePreview() throws {
        let metadata = try SceneImportMetadata.inspect(root: root)
        XCTAssertEqual(metadata.title, "FBO test"); XCTAssertEqual(metadata.entry, "scene.json")
        try write("project.json", ["type": "scene", "file": "scene.json", "preview": "../private.png"])
        XCTAssertThrowsError(try SceneImportMetadata.inspect(root: root))
        try write("project.json", ["type": "scene", "file": "../scene.json"])
        XCTAssertThrowsError(try SceneImportMetadata.inspect(root: root))
    }
}
