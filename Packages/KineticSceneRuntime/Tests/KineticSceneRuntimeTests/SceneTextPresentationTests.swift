import CoreGraphics
import Foundation
@_spi(KineticTesting) import KineticWPEEngine
import XCTest

/// Workshop 2887099508: dialogue text whose `startpaused` fade waits for a click, drawn with the editor's
/// default `copybackground`, showed at load as bright boxes with every line on top of each other.
final class SceneTextPresentationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        root = package.appendingPathComponent(".build/TextPresentationFixtures/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try write("project.json", ["type": "scene", "file": "scene.json", "title": "Text presentation test"])
        try write("models/layer.json", ["material": "materials/base.json"])
        try write("materials/base.json", ["passes": [["shader": "solidcolor", "blending": "disabled",
            "constantshadervalues": ["g_Color": [0.2, 0.3, 0.4, 1]]]]])
    }

    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(at: root) } }

    private func write(_ path: String, _ object: Any) throws {
        let target = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: target)
    }

    private func writeScene(texts: [[String: Any]]) throws {
        let background: [String: Any] = ["id": 0, "image": "models/layer.json", "origin": "128 128 0", "size": "256 256"]
        try write("scene.json", ["camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 256, "height": 256], "clearcolor": "0.2 0.3 0.4"],
            "objects": [background] + texts])
    }

    private func text(id: Int, alpha: Any = 1.0, copyBackground: Bool) -> [String: Any] {
        ["id": id, "name": "Text \(id)", "text": "WWWW", "font": "systemfont_arial", "origin": "128 128 0",
         "pointsize": 24, "padding": 32, "color": "1 1 1", "alpha": alpha, "copybackground": copyBackground,
         "opaquebackground": false, "horizontalalign": "center", "verticalalign": "center"]
    }

    private func fade(startPaused: Bool) -> [String: Any] {
        func key(_ frame: Int, _ value: Double) -> [String: Any] { ["frame": frame, "value": value] }
        return ["value": 1.0, "animation": ["c0": [key(0, 0), key(30, 1), key(133, 1), key(150, 0)],
            "options": ["fps": 30, "length": 150, "mode": "single", "name": "fade", "startpaused": startPaused]]]
    }

    private func pixels(_ image: CGImage) throws -> (data: [UInt8], width: Int, height: Int) {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let buffer = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return (Array(UnsafeBufferPointer(start: buffer, count: image.width * image.height * 4)), image.width, image.height)
    }

    /// Pixels clearly brighter than the 0.2 / 0.3 / 0.4 background in every channel (white glyphs or boxes).
    private func brightCount(_ image: CGImage) throws -> Int {
        let (data, width, height) = try pixels(image)
        return (0..<(width * height)).filter { data[$0 * 4] > 150 && data[$0 * 4 + 1] > 150 && data[$0 * 4 + 2] > 150 }.count
    }

    @MainActor private func frame(afterPlaying seconds: Double) async throws -> CGImage {
        let host = try KineticWPESceneHost(sceneFolder: root, engineAssets: nil, size: CGSize(width: 256, height: 256))
        do {
            _ = try await host.prepare(timeout: 10)
            host.play()
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            await host.renderFrameNow()
            let captured = await host.captureFrame()
            await host.dispose()
            return try XCTUnwrap(captured)
        } catch { await host.dispose(); throw error }
    }

    @MainActor func testStartPausedTextFadeStaysHiddenUntilPlayed() async throws {
        // Free-running, the fade is fully in by frame 30 (1 s).
        try writeScene(texts: [text(id: 1, alpha: fade(startPaused: false), copyBackground: false)])
        let running = try await brightCount(frame(afterPlaying: 1.4))
        XCTAssertGreaterThan(running, 50, "Control: a running fade must show the text")

        try writeScene(texts: [text(id: 1, alpha: fade(startPaused: true), copyBackground: false)])
        let paused = try await brightCount(frame(afterPlaying: 1.4))
        XCTAssertEqual(paused, 0, "A startpaused fade holds its first key (alpha 0) until a script plays it")
    }

    @MainActor func testCopyBackgroundTextDrawsOnlyItsGlyphs() async throws {
        try writeScene(texts: [text(id: 1, copyBackground: false)])
        let plain = try await frame(afterPlaying: 0.2)
        try writeScene(texts: [text(id: 1, copyBackground: true)])
        let copied = try await frame(afterPlaying: 0.2)
        let (a, width, height) = try pixels(plain)
        let (b, _, _) = try pixels(copied)
        XCTAssertGreaterThan(try brightCount(plain), 50, "Fixture must draw visible glyphs")
        var largest = 0
        for index in 0..<(width * height * 4) where index % 4 != 3 { largest = max(largest, abs(Int(a[index]) - Int(b[index]))) }
        XCTAssertLessThanOrEqual(largest, 8, "copybackground without effects must look like plain text, not a bright box")
    }

    @MainActor func testStartPausedCopyBackgroundTextStaysHidden() async throws {
        try writeScene(texts: (1...3).map { text(id: $0, alpha: fade(startPaused: true), copyBackground: true) })
        let image = try await frame(afterPlaying: 1.4)
        let (data, width, height) = try pixels(image)
        XCTAssertEqual(try brightCount(image), 0)
        let center = ((height / 2) * width + width / 2) * 4
        XCTAssertEqual(Int(data[center]), 51, accuracy: 4, "Hidden text leaves the background unchanged")
        XCTAssertEqual(Int(data[center + 2]), 102, accuracy: 4)
    }
}
