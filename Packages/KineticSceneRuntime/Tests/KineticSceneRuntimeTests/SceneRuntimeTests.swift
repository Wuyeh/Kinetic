import AppKit
import Compression
import CoreGraphics
import Foundation
import Metal
import MetalKit
import XCTest
@testable import KineticSceneRuntime

final class SceneRuntimeTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        folder = package.appendingPathComponent(".build/TestFixtures/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let folder { try FileManager.default.removeItem(at: folder) } }
    private func write(_ path: String, _ data: Data) throws {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
    private func json(_ raw: Any) throws -> Data { try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]) }
    private func document(_ layers: [[String: Any]]) throws -> Data {
        try json(["general": ["orthogonalprojection": ["width": 64, "height": 64], "clearcolor": "0 0 0"], "objects": layers])
    }
    private func fixture(_ layers: [[String: Any]]? = nil) throws {
        try write("project.json", json(["type": "scene", "file": "scene.json"]))
        try write("scene.json", document(layers ?? [["id": 1, "image": "red.tex", "origin": "32 32 0", "size": "64 64 0"]]))
        try write("red.tex", tex(width: 4, height: 4, bytes: Data(Array(repeating: [UInt8(255), 0, 0, 255], count: 16).flatMap { $0 })))
    }
    private func u32(_ value: UInt32) -> Data { var value = value.littleEndian; return withUnsafeBytes(of: &value) { Data($0) } }
    private func package(_ entries: [(String, Data)], magic: String = "PKGV0001") -> Data {
        var output = u32(UInt32(magic.utf8.count)) + Data(magic.utf8) + u32(UInt32(entries.count))
        var offset: UInt32 = 0
        for (path, bytes) in entries {
            output += u32(UInt32(path.utf8.count)) + Data(path.utf8) + u32(offset) + u32(UInt32(bytes.count))
            offset += UInt32(bytes.count)
        }
        for (_, bytes) in entries { output += bytes }
        return output
    }
    private func tex(width: UInt32 = 1, height: UInt32 = 1, format: UInt32 = 0, bytes: Data = Data([255, 0, 0, 255])) -> Data {
        var output = Data("TEXV0005\0TEXI0001\0".utf8)
        for value in [format, 2, width, height, width, height, 0] { output += u32(value) }
        output += Data("TEXB0001\0".utf8) + u32(1) + u32(1) + u32(width) + u32(height) + u32(UInt32(bytes.count)) + bytes
        return output
    }
    private func expectFailure(_ body: () throws -> Void) { XCTAssertThrowsError(try body()) { XCTAssertTrue($0 is SceneRuntimeError, "\($0)") } }

    func testDirectoryReadAndMissingAsset() throws {
        try write("nested/item", Data("hello".utf8))
        let resolver = try SceneAssetResolver(root: folder)
        XCTAssertEqual(try resolver.read("nested/item"), Data("hello".utf8))
        expectFailure { _ = try resolver.read("missing") }
    }
    func testRejectsPathEscapesAndEncodedPaths() throws {
        let resolver = try SceneAssetResolver(root: folder)
        for path in ["../secret", "/etc/passwd", "a/../../b", "a\\..\\b", "file:///etc/passwd", "%2e%2e/secret", "a//b", "a\0b", "./a"] {
            expectFailure { _ = try resolver.read(path) }
        }
    }
    func testRejectsSymlinkFileAndDirectory() throws {
        try write("real/item", Data([1]))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link"), withDestinationURL: folder.appendingPathComponent("real/item"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("dirlink"), withDestinationURL: folder.appendingPathComponent("real"))
        let resolver = try SceneAssetResolver(root: folder)
        expectFailure { _ = try resolver.read("link") }
        expectFailure { _ = try resolver.read("dirlink/item") }
    }
    func testRootSymlinkRejected() throws {
        let url = folder.appendingPathComponent("rootlink")
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: folder)
        expectFailure { _ = try SceneAssetResolver(root: url) }
    }
    func testDirectoryBudgetBeforeRead() throws {
        try write("large", Data(count: 20))
        let resolver = try SceneAssetResolver(root: folder)
        expectFailure { _ = try resolver.read("large", maximumBytes: 10) }
    }
    func testPackageRelativeOffsetAndCaseInsensitiveLookup() throws {
        try write("scene.pkg", package([("nested/ONE", Data([1, 2, 3])), ("two", Data([4, 5]))]))
        let resolver = try SceneAssetResolver(root: folder)
        XCTAssertEqual(try resolver.read("nested/one"), Data([1, 2, 3]))
        XCTAssertEqual(try resolver.read("two"), Data([4, 5]))
    }
    func testModernPackageVersionsReadSceneEntryWithTheSameBoundedIndex() throws {
        let entry = try document([])
        try write("project.json", json(["type": "Scene", "file": "scene.json"]))
        for magic in ["PKGV0001", "PKGV0002", "PKGV0003", "PKGV0022", "PKGV0023", "PKGV0024", "PKGV0025", "PKGV0099"] {
            try write("scene.pkg", package([("scene.json", entry), ("nested/data", Data([7, 8]))], magic: magic))
            let resolver = try SceneAssetResolver(root: folder)
            XCTAssertEqual(try resolver.readSceneOwned("scene.json"), entry, magic)
            XCTAssertEqual(try resolver.read("nested/data"), Data([7, 8]), magic)
            XCTAssertEqual(try SceneImportMetadata.inspect(root: folder).entry, "scene.json", magic)
        }
    }
    func testModernPackageStillRejectsUnsafeIndexAndReadBudgets() throws {
        for entries in [[("../escape", Data([1]))], [("A", Data([1])), ("a", Data([2]))]] {
            try write("scene.pkg", package(entries, magic: "PKGV0024"))
            expectFailure { _ = try SceneAssetResolver(root: folder) }
        }
        var truncated = package([("asset", Data([1]))], magic: "PKGV0024")
        truncated.removeLast()
        try write("scene.pkg", truncated)
        expectFailure { _ = try SceneAssetResolver(root: folder) }
        try write("scene.pkg", package([("asset", Data([1, 2]))], magic: "PKGV0024"))
        let resolver = try SceneAssetResolver(root: folder)
        expectFailure { _ = try resolver.read("asset", maximumBytes: 1) }
    }
    /// Later package revisions are accepted by their index structure (as the complete engine does); malformed
    /// identifiers are not.
    func testMalformedPackageIdentifiersStayRejected() throws {
        for magic in ["PKGV0000", "PKGV0100", "PKGV9999", "PKGV0x24", "PKGV00024", "PKGV-024", "TEXV0024", "PKGVABCD"] {
            try write("scene.pkg", package([], magic: magic))
            expectFailure { _ = try SceneAssetResolver(root: folder) }
        }
    }
    func testPackageLooseOverride() throws {
        try write("scene.pkg", package([("same", Data([1]))]))
        try write("same", Data([2]))
        XCTAssertEqual(try SceneAssetResolver(root: folder).read("same"), Data([2]))
    }
    func testPackageDuplicateCaseCollisionRejected() throws {
        try write("scene.pkg", package([("A", Data([1])), ("a", Data([2]))]))
        expectFailure { _ = try SceneAssetResolver(root: folder) }
    }
    func testPackageTraversalRejected() throws {
        try write("scene.pkg", package([("../escape", Data([1]))]))
        expectFailure { _ = try SceneAssetResolver(root: folder) }
    }
    func testTruncatedPackageIndexRejected() throws {
        try write("scene.pkg", Data(package([("asset", Data([1]))]).prefix(20)))
        expectFailure { _ = try SceneAssetResolver(root: folder) }
    }
    func testPackagePayloadOutsideFileRejected() throws {
        var bytes = package([("asset", Data([1]))]); bytes.removeLast()
        try write("scene.pkg", bytes)
        expectFailure { _ = try SceneAssetResolver(root: folder) }
    }
    func testUnknownPackageVersionRejected() throws {
        try write("scene.pkg", package([], magic: "PKGV9999"))
        expectFailure { _ = try SceneAssetResolver(root: folder) }
    }
    func testPackageEntryCountBudget() throws {
        try write("scene.pkg", package([("one", Data()), ("two", Data())]))
        var limits = SceneLimits(); limits.maximumPackageEntries = 1
        expectFailure { _ = try SceneAssetResolver(root: folder, limits: limits) }
    }
    func testExplicitAdditionalRootsOnly() throws {
        try write("engine/material", Data([7]))
        let root = folder.appendingPathComponent("wallpaper")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        expectFailure { _ = try SceneAssetResolver(root: root).read("material") }
        XCTAssertEqual(try SceneAssetResolver(root: root, additionalRoots: [folder.appendingPathComponent("engine")]).read("material"), Data([7]))
    }
    func testJSONDepthAndNodeBudget() throws {
        var limits = SceneLimits(); limits.maximumJSONDepth = 3
        expectFailure { _ = try SceneJSON.parse(Data("[[[[0]]]]".utf8), limits: limits) }
        limits.maximumJSONNodes = 2
        expectFailure { _ = try SceneJSON.parse(Data("[1,2,3]".utf8), limits: limits) }
        XCTAssertEqual(try SceneJSON.parse(Data("[\"[\\\"[\"]".utf8)), .array([.string("[\"[")]))
    }
    func testJSONBoolDoesNotBecomeNumber() throws {
        let value = try SceneJSON.parse(Data("{\"number\":1,\"flag\":true}".utf8))
        XCTAssertEqual(value["number"].number, 1); XCTAssertEqual(value["flag"].bool, true)
        XCTAssertNil(value["flag"].number)
    }
    func testTypedSchemaPreservesOrderAndAuthoredDefaults() throws {
        let parsed = try SceneDocument.parse(document([
            ["id": "second", "image": "b.tex", "origin": ["value": "20 30 0"], "alpha": ["value": 0.5]],
            ["id": "first", "text": "Kinetic", "font": "Helvetica", "pointsize": 24]
        ]))
        XCTAssertEqual(parsed.layers.map(\.id), ["second", "first"])
        XCTAssertEqual(parsed.layers[0].transform.origin, SIMD2(20, 30)); XCTAssertEqual(parsed.layers[0].color.w, 0.5)
    }
    func testDuplicateAndCyclicParentsRejected() throws {
        expectFailure { _ = try SceneDocument.parse(document([["id": 1, "image": "a"], ["id": 1, "image": "b"]])) }
        expectFailure { _ = try SceneDocument.parse(document([["id": "a", "image": "a", "parent": "b"], ["id": "b", "image": "b", "parent": "a"]])) }
        expectFailure { _ = try SceneDocument.parse(document([["id": "a", "image": "a", "parent": "missing"]])) }
    }
    func testMalformedVectorDoesNotDropBadComponents() throws {
        expectFailure { _ = try SceneDocument.parse(document([["id": 1, "image": "a", "origin": "bad 1 2"]])) }
    }
    func testUnsupportedScriptLocationsParticlesAndPuppetAreNotSilentlyFlattened() throws {
        for item: [String: Any] in [
            ["id": 1, "image": "a", "size": ["value": "1 1 0", "script": "while(true){}"]],
            ["id": 1, "particle": "p.json", "instance": true], ["id": 1, "image": "a", "animationlayers": [["animation": "warp"]]]
        ] { expectFailure { _ = try SceneDocument.parse(document([item])) } }
        try fixture([["id": 1, "model": "puppet.mdl"]])
        expectFailure { _ = try SceneRenderGraph.load(root: folder) }
    }
    func testUnsupportedPerspectiveAndPostprocessingRejected() throws {
        for general: [String: Any] in [["orthogonalprojection": NSNull()], ["bloom": true], ["camerashake": true]] {
            expectFailure { _ = try SceneDocument.parse(json(["general": general, "objects": []])) }
        }
    }
    func testTEXRGBAAndMipPayload() throws {
        let decoded = try SceneTexture.decode(tex(), limits: .init())
        XCTAssertEqual(decoded.format, .rgba); XCTAssertEqual(decoded.mips[0].bytes, Data([255, 0, 0, 255]))
        XCTAssertEqual(decoded.logicalSize, SIMD2(1, 1)); XCTAssertTrue(decoded.clamp)
    }
    /// TEXB0002+ container: per mip `compressed`, `inflated size`, then the stored bytes; v3+ adds the
    /// FreeImage format (-1 = raw pixels), v4 adds the video flag.
    private func texChain(version: Int, format: UInt32 = 0, width: UInt32, height: UInt32, freeImage: Int32 = -1,
                          mips: [(width: UInt32, height: UInt32, compressed: Bool, inflated: Int, payload: Data)]) -> Data {
        var output = Data("TEXV0005\0TEXI0001\0".utf8)
        for value in [format, 2, width, height, width, height, 0] { output += u32(value) }
        output += Data("TEXB000\(version)\0".utf8) + u32(1)
        if version >= 3 { output += u32(UInt32(bitPattern: freeImage)) }
        if version >= 4 { output += u32(0) }
        output += u32(UInt32(mips.count))
        for mip in mips {
            output += u32(mip.width) + u32(mip.height) + u32(mip.compressed ? 1 : 0) + u32(UInt32(mip.inflated))
                + u32(UInt32(mip.payload.count)) + mip.payload
        }
        return output
    }
    private func png(width: Int, height: Int, rgba: [UInt8]) throws -> Data {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(rgba) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: .init(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    }
    /// Wallpaper Engine compresses TEX mips as raw LZ4 blocks (no frame header). Found with real Workshop
    /// item 3814311518, whose valid masks were rejected as "TEX LZ4 payload" (2026-10-05).
    func testTEXRawLZ4MipPayloadDecodes() throws {
        let pixels = Data((0..<64).map { UInt8(($0 * 37) & 0xff) })
        var compressed = Data(count: 256)
        let count = compressed.withUnsafeMutableBytes { destination in
            pixels.withUnsafeBytes { source in
                compression_encode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, 256,
                    source.bindMemory(to: UInt8.self).baseAddress!, pixels.count, nil, COMPRESSION_LZ4_RAW)
            }
        }
        XCTAssertGreaterThan(count, 0)
        let data = texChain(version: 4, width: 4, height: 4,
                            mips: [(4, 4, true, pixels.count, compressed.prefix(count))])
        let decoded = try SceneTexture.decode(data, limits: .init())
        XCTAssertEqual(decoded.mips[0].bytes, pixels)
        // A damaged block is still rejected.
        let damaged = texChain(version: 4, width: 4, height: 4, mips: [(4, 4, true, pixels.count, Data(repeating: 0xff, count: 8))])
        expectFailure { _ = try SceneTexture.decode(damaged, limits: .init()) }
    }
    /// An encoded (PNG) chain stores each level as its own image: the first level is decoded, the downscaled
    /// copies are read past (3779018156, 2026-10-05). A nested TEX in a later level is still rejected.
    func testTEXEncodedMipChainUsesTheFirstImage() throws {
        let full = try png(width: 2, height: 2, rgba: Array(repeating: [UInt8(0), 255, 0, 255], count: 4).flatMap { $0 })
        let small = try png(width: 1, height: 1, rgba: [255, 0, 0, 255])
        let data = texChain(version: 4, width: 2, height: 2, freeImage: 13,
                            mips: [(2, 2, false, 0, full), (1, 1, false, 0, small)])
        let decoded = try SceneTexture.decode(data, limits: .init())
        XCTAssertEqual(decoded.mips.first?.width, 2); XCTAssertEqual(decoded.mips.first?.height, 2)
        let bytes = try XCTUnwrap(decoded.mips.first?.bytes)
        XCTAssertLessThan(bytes[0], 30); XCTAssertGreaterThan(bytes[1], 225); XCTAssertEqual(bytes[3], 255, "green first level, not the red copy")
        let nested = texChain(version: 4, width: 2, height: 2, freeImage: 13,
                              mips: [(2, 2, false, 0, full), (1, 1, false, 0, Data("TEXV0005".utf8))])
        expectFailure { _ = try SceneTexture.decode(nested, limits: .init()) }
    }
    func testRasterOrientationKeepsTopAndBottomRows() throws {
        let input = Data([255, 0, 0, 255, 255, 0, 0, 255, 0, 0, 255, 255, 0, 0, 255, 255])
        let provider = try XCTUnwrap(CGDataProvider(data: input as CFData))
        let image = try XCTUnwrap(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: .init(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let texture = try SceneTexture.raster(image, limits: .init())
        XCTAssertEqual(texture.mips[0].bytes, input)
    }
    func testTEXLuminanceAlphaFormat() throws {
        let decoded = try SceneTexture.decode(tex(format: 8, bytes: Data([120, 80])), limits: .init())
        XCTAssertEqual(decoded.format, .rg); XCTAssertEqual(decoded.mips[0].bytes.count, 2)
    }
    func testTEXTruncationAndDimensionBudget() throws {
        expectFailure { _ = try SceneTexture.decode(Data(tex().dropLast()), limits: .init()) }
        expectFailure { _ = try SceneTexture.decode(tex(width: UInt32.max), limits: .init()) }
        expectFailure { _ = try SceneTexture.decode(tex(width: 0), limits: .init()) }
    }
    func testTEXUnknownAndAnimationRejected() throws {
        expectFailure { _ = try SceneTexture.decode(tex(format: 99), limits: .init()) }
        expectFailure { _ = try SceneTexture.decode(tex() + Data("TEXS0001\0".utf8), limits: .init()) }
    }
    func testGraphLoadsSceneJSONFromPackage() throws {
        try fixture()
        let scene = try Data(contentsOf: folder.appendingPathComponent("scene.json"))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("scene.json"))
        try write("scene.pkg", package([("scene.json", scene)]))
        XCTAssertEqual(try SceneRenderGraph.load(root: folder).nodes.count, 1)
    }
    func testModelMaterialAndTextureReference() throws {
        try fixture([["id": 1, "image": "model.json"]])
        try write("model.json", json(["material": "material.json"]))
        try write("material.json", json(["passes": [["shader": "genericimage", "textures": ["red.tex"]]]]))
        XCTAssertEqual(try SceneRenderGraph.load(root: folder).nodes[0].texture.format, .rgba)
    }
    func testMaterialCycleAndMissingEngineResourceRejected() throws {
        try fixture([["id": 1, "image": "a.json"]])
        try write("a.json", json(["material": "b.json"])); try write("b.json", json(["material": "a.json"]))
        expectFailure { _ = try SceneRenderGraph.load(root: folder) }
        try write("a.json", json(["material": "materials/engine-only.json"]))
        XCTAssertThrowsError(try SceneRenderGraph.load(root: folder)) { XCTAssertEqual($0 as? SceneRuntimeError, .missingAsset("materials/engine-only.json")) }
    }
    func testEngineAssetsRootIsSearchedAfterSceneFiles() throws {
        try fixture([["id": 1, "image": "a.json"]])
        try write("a.json", json(["material": "materials/engine-only.json"]))
        let engine = folder.appendingPathComponent("engine-assets")
        func writeEngine(_ path: String, _ data: Data) throws {
            let url = engine.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        expectFailure { _ = try SceneRenderGraph.load(root: folder) }
        try writeEngine("materials/engine-only.json", json(["passes": [["shader": "genericimage", "textures": ["red.tex"]]]]))
        XCTAssertEqual(try SceneRenderGraph.load(root: folder, engineAssets: engine).nodes.count, 1)
        // Scene-owned files win over engine files with the same path.
        try writeEngine("nested/item", Data("engine".utf8)); try write("nested/item", Data("scene".utf8))
        let resolver = try SceneAssetResolver(root: folder, additionalRoots: [engine])
        XCTAssertEqual(resolver.rootCount, 2)
        XCTAssertEqual(try resolver.read("nested/item"), Data("scene".utf8))
        // project.json and the scene entry come only from the scene root.
        try writeEngine("only-engine.json", Data("{}".utf8))
        XCTAssertEqual(try resolver.read("only-engine.json"), Data("{}".utf8))
        expectFailure { _ = try resolver.readSceneOwned("only-engine.json") }
        try FileManager.default.removeItem(at: folder.appendingPathComponent("project.json"))
        try writeEngine("project.json", json(["type": "scene", "file": "scene.json"]))
        expectFailure { _ = try SceneRenderGraph.load(root: folder, engineAssets: engine) }
    }
    func testResidentBudgetAndParentVisibility() throws {
        try fixture([["id": "parent", "image": "red.tex", "visible": false], ["id": "child", "image": "red.tex", "parent": "parent"]])
        XCTAssertTrue(try SceneRenderGraph.load(root: folder).nodes.isEmpty)
        try fixture()
        var limits = SceneLimits(); limits.maximumResidentBytes = 10
        expectFailure { _ = try SceneRenderGraph.load(root: folder, limits: limits) }
    }
    func testShaderTranslationRejectsUnboundedLoopsAndUnknownUniforms() throws {
        expectFailure { _ = try SceneShader.translate("void main(){while(true){} gl_FragColor=vec4(1);}") }
        expectFailure { _ = try SceneShader.translate("uniform float secret; void main(){gl_FragColor=vec4(secret);}") }
        let result = try SceneShader.translate("uniform sampler2D g_Texture0; varying vec2 v_TexCoord; void main(){gl_FragColor=texture2D(g_Texture0,v_TexCoord);}")
        XCTAssertTrue(result.contains("kinetic_sample(g_Texture0,s0,textureSampling[0],in.uv)"))
    }
    func testShaderIncludeCycleAndTraversal() throws {
        try write("shaders/a.frag", Data("#include \"b.frag\"".utf8)); try write("shaders/b.frag", Data("#include \"a.frag\"".utf8))
        let resolver = try SceneAssetResolver(root: folder)
        expectFailure { _ = try SceneShader.fragment("shaders/a.frag", resolver: resolver) }
        try write("shaders/a.frag", Data("#include \"../secret\"".utf8))
        expectFailure { _ = try SceneShader.fragment("shaders/a.frag", resolver: resolver) }
    }
    func testInvalidLimitsDoNotAllocate() throws {
        var limits = SceneLimits(); limits.maximumAssetBytes = Int.max
        expectFailure { _ = try SceneAssetResolver(root: folder, limits: limits) }
    }

    @MainActor func testMetalFirstFramePixelsAndPauseResumeDispose() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        try fixture()
        let runtime = KineticSceneRuntime(root: folder)
        defer { runtime.dispose() }
        try await runtime.prepare()
        XCTAssertTrue(runtime.isPrepared); XCTAssertFalse(runtime.isPlaying); XCTAssertTrue(runtime.isMuted)
        let frame = try XCTUnwrap(runtime.preparedFrame)
        let bytes = try XCTUnwrap(frame.dataProvider?.data) as Data
        let center = (32 * 64 + 32) * 4
        XCTAssertEqual(bytes[center + 2], 255); XCTAssertEqual(bytes[center], 0); XCTAssertEqual(bytes[center + 3], 255)
        runtime.play(); try await Task.sleep(nanoseconds: 30_000_000); runtime.pause()
        let paused = runtime.sceneTime
        try await Task.sleep(nanoseconds: 30_000_000); XCTAssertEqual(runtime.sceneTime, paused, accuracy: 0.0001)
        runtime.resume(); try await Task.sleep(nanoseconds: 30_000_000); XCTAssertGreaterThan(runtime.sceneTime, paused)
        runtime.setMuted(false); XCTAssertFalse(runtime.isMuted)
        runtime.dispose(); runtime.dispose()
        XCTAssertTrue(runtime.isDisposed); XCTAssertNil(runtime.preparedFrame); XCTAssertEqual(runtime.residentTextureBytes, 0)
        do { try await runtime.prepare(); XCTFail("disposed prepare") } catch { XCTAssertEqual(error as? SceneRuntimeError, .disposed) }
    }
    @MainActor func testTwoInstancesDoNotShareTimeOrResources() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        try fixture()
        let first = KineticSceneRuntime(root: folder), second = KineticSceneRuntime(root: folder)
        defer { first.dispose(); second.dispose() }
        try await first.prepare(); try await second.prepare()
        first.play(); second.play(); first.pause(); first.dispose()
        XCTAssertTrue(second.isPlaying); XCTAssertNotNil(second.preparedFrame); XCTAssertGreaterThan(second.residentTextureBytes, 0)
    }
    @MainActor func testFirstFrameBudgetRejectedBeforeReadyEvenWhenAssetsFit() async throws {
        try fixture()
        var limits = SceneLimits()
        limits.maximumResidentBytes = 1000
        let graph = try SceneRenderGraph.load(root: folder, limits: limits)
        XCTAssertLessThan(graph.residentBytes, limits.maximumResidentBytes)
        do {
            _ = try await SceneMetalEngine(graph: graph).firstFrame()
            XCTFail("small assets do not imply that framebuffer / fallback allocations fit")
        } catch {
            XCTAssertEqual(error as? SceneRuntimeError, .budgetExceeded("scene first-frame buffers"))
        }
        // Since 2026-10-05 a bounded-tier refusal hands the Scene on (the complete engine is the final arbiter);
        // the bounded engine itself never becomes Ready over its budget.
        let runtime = KineticSceneRuntime(root: folder, limits: limits)
        defer { runtime.dispose() }
        do { try await runtime.prepare() } catch { XCTAssertTrue(error is SceneRuntimeError, "Actual error: \(error)") }
        XCTAssertEqual(runtime.residentTextureBytes, 0, "no bounded / image-tier engine was kept")
        XCTAssertFalse(runtime.usesExtendedRenderGraph)
        if runtime.isPrepared { XCTAssertTrue(runtime.usesFullEngine) }
    }
    @MainActor func testBadSceneNeverBecomesPrepared() async throws {
        try fixture([["id": 1, "image": "missing.tex"]])
        let runtime = KineticSceneRuntime(root: folder)
        defer { runtime.dispose() }
        do { try await runtime.prepare(); XCTFail("missing scene succeeded") } catch {}
        XCTAssertFalse(runtime.isPrepared); XCTAssertNil(runtime.preparedFrame); XCTAssertFalse(runtime.isPlaying)
    }

    @MainActor func testScriptInitAffectsGPUFirstFrameBeforeReady() async throws {
        try fixture([["id": 1, "image": "red.tex", "origin": "32 32 0", "size": "64 64 0",
                      "alpha": ["value": 1, "script": "export function init(value) { return 0.25; }"]]])
        let runtime = KineticSceneRuntime(root: folder)
        defer { runtime.dispose() }
        try await runtime.prepare()
        XCTAssertNotNil(runtime.scripts); XCTAssertFalse(runtime.isPlaying)
        let frame = try XCTUnwrap(runtime.preparedFrame)
        let bytes = try XCTUnwrap(frame.dataProvider?.data) as Data
        XCTAssertEqual(Int(bytes[(32 * frame.width + 32) * 4 + 2]), 64, accuracy: 1)
        runtime.play(); runtime.pause()
        let time = runtime.sceneTime
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(runtime.sceneTime, time, accuracy: 0.001)
        runtime.dispose(); XCTAssertNil(runtime.scripts); XCTAssertEqual(runtime.residentTextureBytes, 0)
    }

    @MainActor func testStopDuringInfiniteScriptSetupCannotBecomeReady() async throws {
        try fixture([["id": 1, "image": "red.tex",
                      "alpha": ["value": 1, "script": "while(true){}"]]])
        let runtime = KineticSceneRuntime(root: folder)
        let task = Task { try await runtime.prepare() }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while runtime.scripts?.webView == nil, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertNotNil(runtime.scripts)
        runtime.dispose()
        do { try await task.value; XCTFail("disposed Scene became ready") } catch {}
        XCTAssertFalse(runtime.isPrepared); XCTAssertNil(runtime.preparedFrame); XCTAssertNil(runtime.scripts)
    }

    func testTypedScriptBindingBudgetAndMalformedAuthoredProperties() throws {
        let parsed = try SceneDocument.parse(document([["id": "a", "image": "a",
            "origin": ["value": "1 2 0", "script": "export function update(v){return v;}"]]]))
        XCTAssertEqual(parsed.scripts.count, 1); XCTAssertEqual(parsed.scripts.first?.target, "origin")
        expectFailure { _ = try SceneDocument.parse(document([["id": 1, "image": "a",
            "alpha": ["value": 1, "script": String(repeating: " ", count: 262_145)]]])) }
        expectFailure { _ = try SceneDocument.parse(document([["id": 1, "image": "a",
            "alpha": ["value": 1, "script": "export function update(v){return v;}", "scriptproperties": ["x": ["unsupported": 2]]]]])) }
    }

    func testAggregateShaderSourceBudgetAndArraysRejected() throws {
        try fixture()
        var limits = SceneLimits(); limits.maximumShaderBytes = 4
        expectFailure { _ = try SceneRenderGraph.load(root: folder, limits: limits) }
        try write("shaders/array.frag", Data("void main(){float x[10000];gl_FragColor=vec4(1.0);}".utf8))
        expectFailure { _ = try SceneShader.fragment("shaders/array.frag", resolver: SceneAssetResolver(root: folder)) }
    }
    @MainActor func testParticleInstancingActuallyDrawsGPUFirstFrame() async throws {
        try fixture([["id": 1, "particle": "particle.json", "origin": "32 32 0"]])
        try write("material.json", json(["passes": [["textures": ["red.tex"], "shader": "genericimage"]]]))
        try write("particle.json", json(["material": "material.json", "maxcount": 8,
            "emitter": [["name": "sphererandom", "rate": 0, "instantaneous": 1]],
            "initializer": [["name": "size", "value": 32]], "operator": [["name": "alphafade", "fadeintime": 0, "fadeouttime": 0]]]))
        let runtime = KineticSceneRuntime(root: folder)
        defer { runtime.dispose() }
        try await runtime.prepare()
        let frame = try XCTUnwrap(runtime.preparedFrame), bytes = try XCTUnwrap(frame.dataProvider?.data) as Data
        XCTAssertEqual(bytes[(32 * 64 + 32) * 4 + 2], 255, "sprite center must be red on GPU")
        XCTAssertEqual(bytes[(4 * 64 + 4) * 4 + 2], 0, "outside the sprite remains the authored background")
    }

    @MainActor func testExplicitDrawableScriptTimeoutFreezesMostRecentGPUFrameAndSurvivesResize() async throws {
        _ = NSApplication.shared
        try fixture([["id": 1, "image": "red.tex", "origin": "32 32 0", "size": "64 64 0",
            "alpha": ["value": 1, "script": "export function update(v){if(engine.runtime>0.3){while(true){}}return 0.5;}"]]])
        let runtime = KineticSceneRuntime(root: folder)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 128, height: 128), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { runtime.dispose(); window.orderOut(nil); window.close() }
        try await runtime.prepare()
        window.contentView = runtime.displayView; window.orderFrontRegardless()
        runtime.displayView.layoutSubtreeIfNeeded()
        let view = try XCTUnwrap(runtime.displayView.subviews.compactMap { $0 as? MTKView }.first)
        guard view.bounds.width > 0, view.currentDrawable != nil else {
            throw XCTSkip("Test-process window has no drawable; actual App display loop still requires manual acceptance")
        }
        var failure: Error?
        runtime.onFailure = { failure = $0 }
        runtime.play()
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while failure == nil, ProcessInfo.processInfo.systemUptime < deadline {
            view.draw()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(failure, "actual drawable loop must hit the Worker deadline")
        XCTAssertFalse(runtime.isPlaying); XCTAssertNil(runtime.scripts)
        let frame = try XCTUnwrap(runtime.preparedFrame)
        let bytes = try XCTUnwrap(frame.dataProvider?.data) as Data
        let pixel = (frame.height / 2 * frame.width + frame.width / 2) * 4
        XCTAssertEqual(Int(bytes[pixel + 2]), 128, accuracy: 1, "retain recent alpha=0.5 frame, not prepare alpha=1")
        window.setContentSize(NSSize(width: 180, height: 160))
        XCTAssertTrue(runtime.preparedFrame === frame, "resizing a failed renderer must retain its static fallback")
        runtime.dispose(); XCTAssertNil(runtime.preparedFrame); XCTAssertEqual(runtime.residentTextureBytes, 0)
    }
    func testMissingOrInvalidFontIsNotSilentlyReplaced() throws {
        XCTAssertThrowsError(try SceneTexture.text("Hello", font: "Kinetic-Nonexistent-Font", pointSize: 24, size: nil, limits: .init()))
        XCTAssertThrowsError(try SceneTexture.text("Hello", font: "bad.ttf", pointSize: 24, size: nil, limits: .init(), fontData: Data([0,1,2])))
        XCTAssertFalse(try SceneTexture.text("Hello", font: "Helvetica", pointSize: 24, size: nil, limits: .init()).mips.isEmpty)
    }
    @MainActor func testTwoPassMaterialReadsPreviousAndPreservesStraightAlpha() async throws {
        try fixture([["id": 1, "image": "material.json", "origin": "32 32 0", "size": "64 64 0"]])
        try write("material.json", json(["passes": [
            ["shader": "halfalpha", "textures": ["red.tex"]], ["shader": "genericimage", "textures": ["previous"]]]]))
        try write("shaders/halfalpha.frag", Data("uniform sampler2D g_Texture0;varying vec2 v_TexCoord;void main(){gl_FragColor=texture2D(g_Texture0,v_TexCoord)*vec4(1.0,1.0,1.0,0.5);}".utf8))
        let graph = try SceneRenderGraph.load(root: folder)
        XCTAssertEqual(graph.nodes.first?.preprocessFragments.count, 1)
        let engine = try SceneMetalEngine(graph: graph)
        let frame = try await engine.firstFrame(), bytes = try XCTUnwrap(frame.dataProvider?.data) as Data
        XCTAssertEqual(Int(bytes[(32 * 64 + 32) * 4 + 2]), 128, accuracy: 1, "intermediate alpha must not blend twice")
    }
    func testMaterialPassBudgetAndUnresolvedFramebufferFailExplicitly() throws {
        try fixture([["id": 1, "image": "material.json"]])
        for passes in [
            Array(repeating: ["shader": "genericimage", "textures": ["red.tex"]], count: 9),
            [["shader": "genericimage", "textures": ["previous"]]],
            [["shader": "genericimage", "textures": ["_rt_FullFrameBuffer"]]],
            [["shader": "genericimage", "textures": ["red.tex"]], ["shader": "genericimage", "textures": ["_rt_Unknown"]]]
        ] {
            try write("material.json", json(["passes": passes]))
            expectFailure { _ = try SceneRenderGraph.load(root: folder) }
        }
        try write("material.json", json(["passes": [["textures": ["red.tex"]], ["textures": ["previous"]]]]))
        var limits = SceneLimits(); limits.maximumResidentBytes = 100
        expectFailure { _ = try SceneRenderGraph.load(root: folder, limits: limits) }
    }

    @MainActor func testShaderMacrosPureHelpersAndNegativeModuloProduceCorrectMetalPixels() async throws {
        try fixture([["id": 1, "image": "material.json", "origin": "32 32 0", "size": "64 64 0"]])
        try write("material.json", json(["passes": [["shader": "math", "textures": ["red.tex"]]]]))
        try write("shaders/math.frag", Data("""
        #define HALF 0.5
        #define QUARTER (HALF * HALF)
        float tint(float x){return square(x);}
        float square(float x){return x*x;}
        void main(){gl_FragColor=vec4(mod(-0.25,1.0),tint(HALF),QUARTER,1.0);}
        """.utf8))
        let graph = try SceneRenderGraph.load(root: folder)
        let engine = try SceneMetalEngine(graph: graph)
        let frame = try await engine.firstFrame()
        let pixels = try XCTUnwrap(frame.dataProvider?.data) as Data
        let center = (32 * 64 + 32) * 4
        XCTAssertEqual(Int(pixels[center + 2]), 191, accuracy: 1, "GLSL mod(-0.25,1) is 0.75")
        XCTAssertEqual(Int(pixels[center + 1]), 64, accuracy: 1)
        XCTAssertEqual(Int(pixels[center]), 64, accuracy: 1)
    }

    func testShaderHelperRecursionGlobalResourcesAndPointerParametersRejected() throws {
        for source in [
            "float a(float x){return a(x);}void main(){gl_FragColor=vec4(a(1.0));}",
            "float a(float x){return b(x);}float b(float x){return a(x);}void main(){gl_FragColor=vec4(a(1.0));}",
            "uniform float g_Time;float a(float x){return g_Time;}void main(){gl_FragColor=vec4(a(1.0));}",
            "float a(float *x){return 1.0;}void main(){gl_FragColor=vec4(1.0);}",
            "float a(out float x){return 1.0;}void main(){gl_FragColor=vec4(1.0);}"
        ] { expectFailure { _ = try SceneShader.translate(source) } }
    }

    func testShaderMacroCycleExpansionAndCountBudgets() throws {
        expectFailure { _ = try SceneShader.translate("#define A B\n#define B A\nvoid main(){gl_FragColor=vec4(A);}") }
        let many = (0..<65).map { "#define K\($0) 1.0" }.joined(separator: "\n")
        expectFailure { _ = try SceneShader.translate(many + "\nvoid main(){gl_FragColor=vec4(1.0);}") }
        var expanded = "#define A0 1.0\n"
        for index in 1..<10 {
            expanded += "#define A\(index) " + Array(repeating: "A\(index-1)", count: 8).joined(separator: "+") + "\n"
        }
        expectFailure { _ = try SceneShader.translate(expanded + "void main(){gl_FragColor=vec4(A9);}") }
        let oversized = "#define A " + String(repeating: "1.0+", count: 10_000) + "1.0\n" +
            "void main(){gl_FragColor=vec4(" + Array(repeating: "A", count: 40).joined(separator: "+") + ");}"
        expectFailure { _ = try SceneShader.translate(oversized) }
    }

    func testShaderHelperCountAndDepthBudgets() throws {
        let helpers = (0..<33).map { "float f\($0)(float x){return x;}" }.joined(separator: "\n")
        expectFailure { _ = try SceneShader.translate(helpers + "\nvoid main(){gl_FragColor=vec4(1.0);}") }
        let deep = (0..<17).map { "float f\($0)(float x){return \($0 == 16 ? "x" : "f\($0+1)(x)");}" }.joined(separator: "\n")
        expectFailure { _ = try SceneShader.translate(deep + "\nvoid main(){gl_FragColor=vec4(f0(1.0));}") }
        let nested = "void main(){gl_FragColor=vec4(" + String(repeating: "sin(", count: 33) +
            "1.0" + String(repeating: ")", count: 33) + ");}"
        expectFailure { _ = try SceneShader.translate(nested) }
    }

    @MainActor func testMaterialComboOverridesShaderDefaultAndProducesSelectedMetalPixels() async throws {
        try fixture([["id": 1, "image": "material.json", "origin": "32 32 0", "size": "64 64 0"]])
        try write("shaders/variants.frag", Data("""
        // [COMBO] {"combo":"MODE","default":1}
        #if MODE == 1
        void main(){gl_FragColor=vec4(1.0,0.0,0.0,1.0);}
        #elif MODE == 2
        void main(){gl_FragColor=vec4(0.0,1.0,0.0,1.0);}
        #else
        void main(){gl_FragColor=vec4(0.0,0.0,1.0,1.0);}
        #endif
        """.utf8))
        for (combos, channel) in [([String: Int](), 2), (["MODE": 2], 1), (["MODE": 0], 0)] {
            try write("material.json", json(["passes": [["shader": "variants", "textures": ["red.tex"], "combos": combos]]]))
            let engine = try SceneMetalEngine(graph: SceneRenderGraph.load(root: folder))
            let frame = try await engine.firstFrame(), pixels = try XCTUnwrap(frame.dataProvider?.data) as Data
            for component in 0..<3 { XCTAssertEqual(pixels[(32 * 64 + 32) * 4 + component], component == channel ? 255 : 0) }
        }
    }

    func testConditionalIncludesShareGuardsAndNeverReadInactiveResources() throws {
        try write("shaders/common.frag", Data("""
        #ifndef COMMON_INCLUDED
        #define COMMON_INCLUDED
        #define VALUE 0.25
        float tint(float x){return x*x;}
        #endif
        """.utf8))
        try write("shaders/main.frag", Data("""
        #include "common.frag"
        #include "common.frag"
        #if 0
        #include "missing-engine-resource.frag"
        void main(){while(true){}}
        #endif
        void main(){gl_FragColor=vec4(tint(VALUE));}
        """.utf8))
        let output = try SceneShader.fragment("shaders/main.frag", resolver: SceneAssetResolver(root: folder))
        XCTAssertEqual(output.components(separatedBy: "float tint(").count - 1, 1)
        XCTAssertTrue(output.contains("tint(0.25)")); XCTAssertFalse(output.contains("while"))
        try write("shaders/main.frag", Data("#if 1\n#include \"missing-engine-resource.frag\"\n#endif".utf8))
        XCTAssertThrowsError(try SceneShader.fragment("shaders/main.frag", resolver: SceneAssetResolver(root: folder))) {
            guard case SceneRuntimeError.missingAsset(let path) = $0 else { return XCTFail("\($0)") }
            XCTAssertEqual(path, "shaders/missing-engine-resource.frag")
        }
    }

    func testConditionalExpressionPrecedenceShortCircuitAndScopedMacros() throws {
        let source = """
        #define ENABLED
        #define MODE 2
        #if defined(ENABLED) && !defined(MISSING) && MODE * 3 + 1 == 7 && ((1 << MODE) | 1) == 5 && 010 == 8 && 0x10 == 16
        #define COLOR 0.25
        #else
        #define COLOR 0.75
        #endif
        #if 0 && (1 / 0)
        forbidden
        #elif 1 || (9223372036854775807 + 1)
        void main(){gl_FragColor=vec4(COLOR);}
        #endif
        #undef COLOR
        #define COLOR 0.5
        """
        let output = try SceneShader.translate(source)
        XCTAssertTrue(output.contains("float4(0.25)")); XCTAssertFalse(output.contains("forbidden"))
    }

    func testMalformedConditionalAndExpressionBudgetsFailBeforeMetal() throws {
        for source in [
            "#else", "#endif", "#if 1\nvoid main(){}", "#if 1\n#else\n#else\n#endif",
            "#if 0\n#else\n#elif 1\n#endif", "#if 1 / 0\n#endif", "#if 1 << 63\n#endif",
            "#if 9223372036854775807 + 1\n#endif", "#if (1\n#endif", "#if 08\n#endif",
            "#define F(x) x\nvoid main(){gl_FragColor=vec4(F(1));}",
            "#if " + String(repeating: "(", count: 17) + "1" + String(repeating: ")", count: 17) + "\n#endif",
            "#if " + Array(repeating: "1", count: 70).joined(separator: "+") + "\n#endif",
            String(repeating: "#if 1\n", count: 17) + String(repeating: "#endif\n", count: 17)
        ] { expectFailure { _ = try SceneShader.translate(source) } }
        expectFailure { _ = try SceneShaderPreprocessor(combos: ["MODE": Int.min]) }
        expectFailure { _ = try SceneShaderPreprocessor(combos: ["MODE()": 1]) }
    }

    func testMalformedMaterialCombosAndUnsupportedBuiltinCombosAreNotIgnored() throws {
        try fixture([["id": 1, "image": "material.json"]])
        for combos: Any in [["MODE": 1.5], ["MODE": "huge"], ["MODE()": 1], ["MODE": 1_000_001], [1, 2]] {
            try write("material.json", json(["passes": [["shader": "authored", "textures": ["red.tex"], "combos": combos]]]))
            expectFailure { _ = try SceneRenderGraph.load(root: folder) }
        }
        try write("material.json", json(["passes": [["shader": "genericimage", "textures": ["red.tex"], "combos": ["CLEARALPHA": 1]]]]))
        expectFailure { _ = try SceneRenderGraph.load(root: folder) }
    }

    func testFiniteLocalTransformsCannotOverflowTheComposedLayerHierarchy() throws {
        let layers: [[String: Any]] = (0..<14).map { index in
            var layer: [String: Any] = ["id": index, "image": "red.tex", "scale": "1000 1000 1"]
            if index > 0 { layer["parent"] = index - 1 }
            return layer
        }
        try fixture(layers)
        XCTAssertEqual(try SceneDocument.parse(Data(contentsOf: folder.appendingPathComponent("scene.json"))).layers.count, 14)
        expectFailure { _ = try SceneRenderGraph.load(root: folder) }
    }

    @MainActor func testValidScriptOutputsCannotSendAnOverflowedHierarchyToMetal() async throws {
        let layers: [[String: Any]] = (0..<14).map { index in
            var layer: [String: Any] = ["id": index, "image": "red.tex",
                "scale": ["value": "1 1 1", "script": "export function update(v){v.x=1000;v.y=1000;return v;}"]]
            if index > 0 { layer["parent"] = index - 1 }
            return layer
        }
        try fixture(layers)
        let graph = try SceneRenderGraph.load(root: folder), engine = try SceneMetalEngine(graph: graph)
        _ = try await engine.firstFrame()
        let executor = SceneScriptExecutor()
        defer { executor.dispose() }
        _ = try await executor.prepare(graph.document.scripts)
        let values = try await executor.update(time: 1, delta: 0.033, cursor: .init(repeating: 0.5))
        try engine.applyScriptValues(values)
        do { _ = try await engine.firstFrame(); XCTFail("overflowed script hierarchy accepted") }
        catch { XCTAssertTrue(error is SceneRuntimeError) }
    }

    @MainActor func testExtremeQuadAndProjectionFailBeforeSubmittingInvalidGeometry() async throws {
        try fixture([["id": 1, "image": "red.tex", "scale": "1000 1000 1", "size": "1e38 1e38 0"]])
        var engine = try SceneMetalEngine(graph: SceneRenderGraph.load(root: folder))
        do { _ = try await engine.firstFrame(); XCTFail("overflowed quad accepted") }
        catch { XCTAssertTrue(error is SceneRuntimeError) }
        try fixture()
        try write("scene.json", json(["general": ["orthogonalprojection": ["width": 1e-40, "height": 64]],
            "objects": [["id": 1, "image": "red.tex"]]]))
        engine = try SceneMetalEngine(graph: SceneRenderGraph.load(root: folder))
        do { _ = try await engine.firstFrame(); XCTFail("overflowed projection accepted") }
        catch { XCTAssertTrue(error is SceneRuntimeError) }
    }
}
