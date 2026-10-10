import CoreGraphics
import Foundation
@_spi(KineticTesting) import KineticWPEEngine
import XCTest

/// Workshop 3326873240's media panel body is a solid layer (no authored alpha) under a tint that writes alpha 1.
/// Wallpaper Engine's solid layer keeps its colour in the layer buffer, so the tint mixes from it; Kinetic stored
/// the transparent solid premultiplied and the body came out black.
final class SceneSolidEffectBaseTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        root = package.appendingPathComponent(".build/SolidEffectBaseFixtures/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try write("project.json", ["type": "scene", "file": "scene.json", "title": "Solid effect base test"])
        try write("models/background.json", ["material": "materials/background.json"])
        try write("materials/background.json", ["passes": [["shader": "solidcolor", "blending": "disabled",
            "constantshadervalues": ["g_Color": [0.2, 0.3, 0.4, 1]]]]])
        let vertex = """
        uniform mat4 g_ModelViewProjectionMatrix;
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec4 v_TexCoord;
        void main() {
            gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
            v_TexCoord = a_TexCoord.xyxy;
        }
        """
        // The panel's tint (BLENDMODE 0): mix toward the tint colour and force alpha to 1.
        try effect("tint", vertex: vertex, fragment: """
        varying vec4 v_TexCoord;
        uniform sampler2D g_Texture0; // {"hidden":true}
        uniform float g_BlendAlpha; // {"material":"alpha","default":1}
        uniform vec3 g_TintColor; // {"material":"color","default":"1 0 0","type":"color"}
        void main() {
            vec4 albedo = texSample2D(g_Texture0, v_TexCoord.xy);
            albedo.rgb = mix(albedo.rgb, g_TintColor, g_BlendAlpha);
            albedo.a = 1.0;
            gl_FragColor = albedo;
        }
        """)
        // Scales the incoming alpha only.
        try effect("opacity", vertex: vertex, fragment: """
        varying vec4 v_TexCoord;
        uniform sampler2D g_Texture0; // {"hidden":true}
        uniform float g_UserAlpha; // {"material":"alpha","default":1}
        void main() {
            vec4 albedo = texSample2D(g_Texture0, v_TexCoord.xy);
            albedo.a *= g_UserAlpha;
            gl_FragColor = albedo;
        }
        """)
    }

    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(at: root) } }

    private func write(_ path: String, _ object: Any) throws {
        let target = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: target)
    }

    private func writeText(_ path: String, _ text: String) throws {
        let target = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: target, atomically: true, encoding: .utf8)
    }

    private func effect(_ name: String, vertex: String, fragment: String) throws {
        try write("effects/test/\(name)/effect.json", ["name": name, "version": 1,
            "passes": [["material": "materials/test/\(name).json"]],
            "dependencies": ["materials/test/\(name).json", "shaders/test/\(name).frag", "shaders/test/\(name).vert"]])
        try write("materials/test/\(name).json", ["passes": [["blending": "normal", "cullmode": "nocull",
            "depthtest": "disabled", "depthwrite": "disabled", "shader": "test/\(name)"]]])
        try writeText("shaders/test/\(name).vert", vertex)
        try writeText("shaders/test/\(name).frag", fragment)
    }

    /// A red built-in solid layer with no authored alpha, followed by `effects`; returns the panel's centre pixel.
    @MainActor private func panelPixel(effects: [[String: Any]]) async throws -> [Int] {
        let panel: [String: Any] = ["id": 2, "name": "Panel", "image": "models/util/solidlayer.json", "color": "1 0 0",
                                    "origin": "128 128 0", "size": "100 40", "effects": effects]
        let background: [String: Any] = ["id": 0, "image": "models/background.json", "origin": "128 128 0", "size": "256 256"]
        try write("scene.json", ["camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 256, "height": 256], "clearcolor": "0.2 0.3 0.4"],
            "objects": [background, panel]])
        let host = try KineticWPESceneHost(sceneFolder: root, engineAssets: nil, size: CGSize(width: 256, height: 256))
        let image: CGImage
        do {
            _ = try await host.prepare(timeout: 10)
            host.play()
            try await Task.sleep(nanoseconds: 300_000_000)
            await host.renderFrameNow()
            let captured = await host.captureFrame()
            await host.dispose()
            image = try XCTUnwrap(captured)
        } catch { await host.dispose(); throw error }
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        let i = ((image.height / 2) * image.width + image.width / 2) * 4
        return [Int(data[i]), Int(data[i + 1]), Int(data[i + 2])]
    }

    private func tint(alpha: Double) -> [String: Any] {
        ["file": "effects/test/tint/effect.json", "id": 10, "visible": true,
         "passes": [["id": 11, "constantshadervalues": ["alpha": alpha, "color": "0 1 0"]]]]
    }

    private let opacity: [String: Any] = ["file": "effects/test/opacity/effect.json", "id": 20, "visible": true,
                                          "passes": [["id": 21, "constantshadervalues": ["alpha": 0.7]]]]

    @MainActor func testTintOverTransparentSolidLayerMixesFromItsColour() async throws {
        // mix(red, green, 0.3) = (0.7, 0.3, 0), opaque.
        let pixel = try await panelPixel(effects: [tint(alpha: 0.3)])
        XCTAssertEqual(pixel[0], 178, accuracy: 4, "The solid layer's red must reach the tint")
        XCTAssertEqual(pixel[1], 77, accuracy: 4)
        XCTAssertEqual(pixel[2], 0, accuracy: 4)
    }

    @MainActor func testLaterEffectsKeepTheirUsualContract() async throws {
        // Tint then 0.7 opacity over the 0.2 / 0.3 / 0.4 background: 0.7 × (0.7, 0.3, 0) + 0.3 × background.
        let pixel = try await panelPixel(effects: [tint(alpha: 0.3), opacity])
        XCTAssertEqual(pixel[0], 140, accuracy: 4)
        XCTAssertEqual(pixel[1], 77, accuracy: 4)
        XCTAssertEqual(pixel[2], 31, accuracy: 4)
    }

    @MainActor func testTransparentSolidLayerStaysTransparentUnderAnAlphaOnlyEffect() async throws {
        // The unauthored alpha under effects is still 0: nothing may appear over the background.
        let pixel = try await panelPixel(effects: [opacity])
        XCTAssertEqual(pixel[0], 51, accuracy: 3)
        XCTAssertEqual(pixel[1], 77, accuracy: 3)
        XCTAssertEqual(pixel[2], 102, accuracy: 3)
    }
}
