import Foundation
import Metal
import XCTest
@testable import KineticSceneRuntime

final class SceneMaterialTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        root = package.appendingPathComponent(".build/MaterialFixtures/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeJSON("project.json", ["type": "scene", "file": "scene.json"])
        try writeJSON("scene.json", ["general": ["orthogonalprojection": ["width": 16, "height": 16], "clearcolor": "0 0 0"],
            "objects": [["id": 1, "image": "material.json", "origin": "8 8 0", "size": "16 16 0"]]])
        try texture("red.tex", [255, 0, 0, 255])
        try texture("blue.tex", [0, 0, 255, 255])
        try texture("green.tex", [0, 255, 0, 255])
    }
    override func tearDownWithError() throws { if let root { try FileManager.default.removeItem(at: root) } }
    private func write(_ path: String, _ data: Data) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
    private func writeJSON(_ path: String, _ object: Any) throws {
        try write(path, JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }
    private func shader(_ path: String, _ source: String) throws { try write("shaders/" + path, Data(source.utf8)) }
    private func u32(_ value: UInt32) -> Data { var value = value.littleEndian; return withUnsafeBytes(of: &value) { Data($0) } }
    private func texture(_ path: String, _ pixel: [UInt8]) throws {
        var data = Data("TEXV0005\0TEXI0001\0".utf8)
        for value: UInt32 in [0, 2, 4, 4, 4, 4, 0] { data += u32(value) }
        data += Data("TEXB0001\0".utf8)
        for value: UInt32 in [1, 1, 4, 4, 64] { data += u32(value) }
        data += Data(Array(repeating: pixel, count: 16).flatMap { $0 })
        try write(path, data)
    }
    private func material(_ passes: [[String: Any]]) throws { try writeJSON("material.json", ["passes": passes]) }
    private func center(_ engine: SceneMetalEngine) async throws -> [UInt8] {
        let image = try await engine.firstFrame(), bytes = try XCTUnwrap(image.dataProvider?.data) as Data
        let index = (image.height / 2 * image.width + image.width / 2) * 4
        return Array(bytes[index..<(index + 4)])
    }
    private func assertPixel(_ pixel: [UInt8], _ expected: [Int], file: StaticString = #filePath, line: UInt = #line) {
        for i in 0..<4 { XCTAssertEqual(Int(pixel[i]), expected[i], accuracy: 1, file: file, line: line) }
    }

    func testTwoTextureSlotsUseMaterialAliasOverrideAndAuthoredDefault() async throws {
        try shader("blend.frag", """
        uniform sampler2D g_Texture0;
        uniform sampler2D g_Texture1;
        uniform float g_Amount; // {"material":"amount","default":0.25}
        varying vec2 v_TexCoord;
        void main(){gl_FragColor=mix(texture2D(g_Texture1,v_TexCoord),texture2D(g_Texture0,v_TexCoord),g_Amount);}
        """)
        try material([["shader": "blend", "textures": ["red.tex", "blue.tex"]]])
        var graph = try SceneRenderGraph.load(root: root)
        XCTAssertEqual(graph.residentBytes, 128)
        assertPixel(try await center(SceneMetalEngine(graph: graph)), [191, 0, 64, 255])
        try material([["shader": "blend", "textures": ["red.tex", "blue.tex"], "constantshadervalues": ["amount": 0.75]]])
        graph = try SceneRenderGraph.load(root: root)
        assertPixel(try await center(SceneMetalEngine(graph: graph)), [64, 0, 191, 255])
    }

    func testNullHolesKeepSlotSevenInsteadOfCompactingToSlotOne() async throws {
        try shader("slot.frag", "uniform sampler2D g_Texture7;varying vec2 v_TexCoord;void main(){gl_FragColor=texture2D(g_Texture7,v_TexCoord);}")
        let inputs: [Any] = ["red.tex", NSNull(), NSNull(), NSNull(), NSNull(), NSNull(), NSNull(), ["name": "green.tex"]]
        try material([["shader": "slot", "textures": inputs]])
        let graph = try SceneRenderGraph.load(root: root)
        XCTAssertEqual(graph.nodes[0].passTextures[0].count, 8)
        XCTAssertNil(graph.nodes[0].passTextures[0][1])
        XCTAssertNotNil(graph.nodes[0].passTextures[0][7])
        assertPixel(try await center(SceneMetalEngine(graph: graph)), [0, 255, 0, 255])
    }

    func testLinearPassesBindDifferentSecondaryTexturesAndPreserveAlphaOnce() async throws {
        try texture("gray.tex", [128, 128, 128, 255])
        try shader("blend.frag", """
        uniform sampler2D g_Texture0;
        uniform sampler2D g_Texture1;
        uniform float g_Alpha; // {"default":0.5}
        varying vec2 v_TexCoord;
        void main(){gl_FragColor=mix(texture2D(g_Texture0,v_TexCoord),texture2D(g_Texture1,v_TexCoord),0.5)*vec4(1.0,1.0,1.0,g_Alpha);}
        """)
        try shader("mask.frag", "uniform sampler2D g_Texture0;uniform sampler2D g_Texture1;varying vec2 v_TexCoord;void main(){gl_FragColor=texture2D(g_Texture0,v_TexCoord)*texture2D(g_Texture1,v_TexCoord);}")
        try material([["shader": "blend", "textures": ["red.tex", "blue.tex"]],
                      ["shader": "mask", "textures": ["previous", "gray.tex"]]])
        let graph = try SceneRenderGraph.load(root: root)
        XCTAssertEqual(graph.nodes[0].preprocessFragments.count, 1)
        assertPixel(try await center(SceneMetalEngine(graph: graph)), [32, 0, 32, 255])
    }

    func testPaddedSecondaryTextureUsesItsOwnLogicalSize() async throws {
        // The second allocated column is green padding, not authored image content.
        var data = Data("TEXV0005\0TEXI0001\0".utf8)
        for value: UInt32 in [0, 3, 2, 1, 1, 1, 0] { data += u32(value) }
        data += Data("TEXB0001\0".utf8)
        for value: UInt32 in [1, 1, 2, 1, 8] { data += u32(value) }
        data += Data([0, 0, 255, 255, 0, 255, 0, 255])
        try write("padded.tex", data)
        try shader("padding.frag", "uniform sampler2D g_Texture1;void main(){gl_FragColor=texture2D(g_Texture1,vec2(0.75,0.5));}")
        try material([["shader": "padding", "textures": ["red.tex", "padded.tex"]]])
        assertPixel(try await center(SceneMetalEngine(graph: SceneRenderGraph.load(root: root))), [255, 0, 0, 255])
    }

    func testBoolIntVectorConstantsAndIncludedDefaultsCompileToRealMetal() async throws {
        try shader("values.glsl", """
        uniform bool g_Enabled; // {"material":"enabled","default":false}
        uniform int g_Count; // {"default":2}
        uniform vec3 g_Tint; // {"default":"0.25 0.5 0.75"}
        #if 0
        uniform vec3 g_Unknown; // {broken json ignored in inactive branch}
        #endif
        """)
        try shader("typed.frag", """
        #include "values.glsl"
        void main(){gl_FragColor=g_Enabled&&g_Count==2?vec4(g_Tint,1.0):vec4(0.0,0.0,0.0,1.0);}
        """)
        try material([["shader": "typed", "textures": ["red.tex"], "constantshadervalues": ["enabled": true]]])
        assertPixel(try await center(SceneMetalEngine(graph: SceneRenderGraph.load(root: root))), [191, 128, 64, 255])
    }

    func testMissingUnboundAndFramebufferSecondarySlotsFailExplicitly() throws {
        try shader("sample.frag", "uniform sampler2D g_Texture1;void main(){gl_FragColor=texture2D(g_Texture1,vec2(0.5));}")
        for inputs: [Any] in [["red.tex"], ["red.tex", NSNull()], ["red.tex", "previous"],
                             ["red.tex", "_rt_FullFrameBuffer"], ["red.tex", "missing.tex"], ["red.tex", "../escape"]] {
            try material([["shader": "sample", "textures": inputs]])
            XCTAssertThrowsError(try SceneRenderGraph.load(root: root))
        }
        try material([["shader": "sample", "textures": Array(repeating: "red.tex", count: 9)]])
        XCTAssertThrowsError(try SceneRenderGraph.load(root: root))
        XCTAssertThrowsError(try SceneShader.translate("uniform sampler2D g_Texture8;void main(){gl_FragColor=texture2D(g_Texture8,vec2(0.5));}", textureSlots: [0, 8]))
    }

    func testAllAuxiliaryAllocationsCountAgainstResidentBudget() throws {
        try shader("sum.frag", "uniform sampler2D g_Texture0;uniform sampler2D g_Texture1;varying vec2 v_TexCoord;void main(){gl_FragColor=texture2D(g_Texture0,v_TexCoord)*texture2D(g_Texture1,v_TexCoord);}")
        try material([["shader": "sum", "textures": ["red.tex", "blue.tex"]]])
        var limits = SceneLimits(); limits.maximumResidentBytes = 127
        XCTAssertThrowsError(try SceneRenderGraph.load(root: root, limits: limits))
        limits.maximumResidentBytes = 128
        XCTAssertEqual(try SceneRenderGraph.load(root: root, limits: limits).residentBytes, 128)
        try material([["shader": "sum", "textures": ["red.tex", "blue.tex"]], ["shader": "sum", "textures": ["previous", "blue.tex"]]])
        limits.maximumResidentBytes = 255
        XCTAssertThrowsError(try SceneRenderGraph.load(root: root, limits: limits))
        limits.maximumResidentBytes = 256
        XCTAssertEqual(try SceneRenderGraph.load(root: root, limits: limits).residentBytes, 256)
    }

    func testInvalidConstantsCannotInjectSourceOrSilentlyFallBack() throws {
        let source = "uniform vec3 g_Value;\nvoid main(){gl_FragColor=vec4(g_Value,1.0);}"
        for value: SceneJSON in [.string("1 2);discard;("), .array([.number(1), .number(2)]),
                                .number(1e100), .bool(true), .object(["value": .number(1)])] {
            XCTAssertThrowsError(try SceneShader.translate(source, constants: ["g_Value": value]))
        }
        XCTAssertThrowsError(try SceneShader.translate("void main(){gl_FragColor=vec4(1.0);}", constants: ["unknown": .number(1)]))
        XCTAssertThrowsError(try SceneShader.translate("uniform int g_Count;\nvoid main(){gl_FragColor=vec4(float(g_Count));}", constants: ["g_Count": .number(1.5)]))
        let ambiguous = "uniform float g_Value; // {\"material\":\"value\",\"default\":1}\nvoid main(){gl_FragColor=vec4(g_Value);}"
        XCTAssertThrowsError(try SceneShader.translate(ambiguous, constants: ["g_Value": .number(1), "value": .number(2)]))
        XCTAssertThrowsError(try SceneShaderConstants(Dictionary(uniqueKeysWithValues: (0..<65).map { ("value\($0)", SceneJSON.number(1)) })))
        try material([["shader": "genericimage", "textures": ["red.tex"], "constantshadervalues": ["unknown": 1]]])
        XCTAssertThrowsError(try SceneRenderGraph.load(root: root))
    }
}
