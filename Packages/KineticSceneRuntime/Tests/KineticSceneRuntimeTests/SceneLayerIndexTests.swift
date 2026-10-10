import CoreGraphics
import Foundation
@_spi(KineticTesting) import KineticWPEEngine
import XCTest

/// Workshop 2887099508 checks `thisScene.getLayerIndex(thisLayer)` against its slot in scene.json and stops its
/// script when they differ. Objects that draw nothing in Kinetic (an empty scriptless text, a visible-script
/// host) must still count, as in Wallpaper Engine's layer list.
final class SceneLayerIndexTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        root = package.appendingPathComponent(".build/LayerIndexFixtures/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try write("project.json", ["type": "scene", "file": "scene.json", "title": "Layer index test"])
        try write("models/layer.json", ["material": "materials/red.json"])
        try write("materials/red.json", ["passes": [["shader": "solidcolor", "blending": "disabled",
            "constantshadervalues": ["g_Color": [1, 0, 0, 1]]]]])
    }

    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(at: root) } }

    private func write(_ path: String, _ object: Any) throws {
        let target = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: target)
    }

    @MainActor func testEmptyTextAndScriptHostKeepTheirLayerIndex() async throws {
        let hostScript = "'use strict';\nexport function update(value) {\n\tshared.hostIndex = thisScene.getLayerIndex(thisLayer);\n\treturn value;\n}"
        let panelScript = "'use strict';\nexport function update(value) {\n"
            + "\treturn shared.hostIndex === 1 && thisScene.getLayerIndex(thisLayer) === 2 && thisScene.getLayerCount() === 3;\n}"
        try write("scene.json", ["camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 64, "height": 64], "clearcolor": "0 0 0"],
            "objects": [
                ["id": 1, "name": "Empty", "text": "", "font": "systemfont_arial", "origin": "32 32 0"],
                ["id": 2, "name": "Host", "visible": ["value": true, "script": hostScript]],
                ["id": 3, "name": "Panel", "image": "models/layer.json", "size": "64 64 0", "origin": "32 32 0",
                 "visible": ["value": false, "script": panelScript]]
            ]])
        let host = try KineticWPESceneHost(sceneFolder: root, engineAssets: nil, size: CGSize(width: 64, height: 64))
        do {
            _ = try await host.prepare(timeout: 10)
            host.play()
            try await Task.sleep(nanoseconds: 400_000_000)
            await host.renderFrameNow()
            let captured = await host.captureFrame()
            let image = try XCTUnwrap(captured)
            let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
            let center = ((image.height / 2) * image.width + image.width / 2) * 4
            XCTAssertGreaterThan(data[center], 200,
                "The panel shows only when the empty text and the script host count as layers 0 and 1")
            await host.dispose()
        } catch { await host.dispose(); throw error }
    }
}
