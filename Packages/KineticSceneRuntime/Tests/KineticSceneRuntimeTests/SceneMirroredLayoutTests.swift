import CoreGraphics
import Foundation
@_spi(KineticTesting) import KineticWPEEngine
import XCTest

/// Workshop 3326873240's media panel mirrors itself (`scale.x = -1`) when it sits on the left of the screen, flips its
/// labels to "left" from a script, and sizes its backdrop from the labels' live `size` and parent-relative `origin`.
/// Kinetic drew the right-aligned backdrop and progress bar behind the cover, left the title under it, and fed the
/// scripts the authored box and world positions.
final class SceneMirroredLayoutTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        root = package.appendingPathComponent(".build/MirroredLayoutFixtures/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try write("project.json", ["type": "scene", "file": "scene.json", "title": "Mirrored layout test"])
        try write("models/background.json", ["material": "materials/background.json"])
        try write("materials/background.json", ["passes": [["shader": "solidcolor", "blending": "disabled",
            "constantshadervalues": ["g_Color": [0.2, 0.3, 0.4, 1]]]]])
        try write("models/white.json", ["material": "materials/white.json"])
        try write("materials/white.json", ["passes": [["shader": "solidcolor", "blending": "disabled",
            "constantshadervalues": ["g_Color": [1, 1, 1, 1]]]]])
    }

    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(at: root) } }

    private func write(_ path: String, _ object: Any) throws {
        let target = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: target)
    }

    private func writeScene(_ objects: [[String: Any]]) throws {
        let background: [String: Any] = ["id": 0, "image": "models/background.json", "origin": "128 128 0", "size": "256 256"]
        try write("scene.json", ["camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 256, "height": 256], "clearcolor": "0.2 0.3 0.4"],
            "objects": [background] + objects])
    }

    /// A 1×1 host that only carries the transform its children hang off.
    private func host(id: Int, name: String, origin: String, scale: String) -> [String: Any] {
        ["id": id, "name": name, "image": "models/background.json", "origin": origin, "scale": scale, "size": "1 1"]
    }

    private func script(_ body: String, value: Any) -> [String: Any] { ["value": value, "script": body] }

    @MainActor private func frame(afterPlaying seconds: Double = 0.6) async throws -> CGImage {
        let host = try KineticWPESceneHost(sceneFolder: root, engineAssets: nil, size: CGSize(width: 256, height: 256))
        do {
            _ = try await host.prepare(timeout: 10)
            host.play()
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            await host.renderFrameNow()
            await host.renderFrameNow()
            let captured = await host.captureFrame()
            await host.dispose()
            return try XCTUnwrap(captured)
        } catch { await host.dispose(); throw error }
    }

    /// Columns (left to right, top-down rows) holding a white-ish pixel inside `rows`.
    private func brightColumns(_ image: CGImage, rows: ClosedRange<Int>) throws -> [Int] {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        let scale = Double(image.width) / 256
        let band = Int(Double(rows.lowerBound) * scale)...Int(Double(rows.upperBound) * scale)
        var columns: [Int] = []
        for x in 0..<image.width {
            let lit = band.contains { y in
                let i = (y * image.width + x) * 4
                return data[i] > 150 && data[i + 1] > 150 && data[i + 2] > 150
            }
            if lit { columns.append(Int(Double(x) / scale)) }
        }
        return columns
    }

    @MainActor func testRightAlignedChildOfMirroredParentGrowsAwayFromItsOrigin() async throws {
        // Mirrored parent at x 128: the child's origin lands at x 148 and, right-aligned in its own (mirrored)
        // space, the 60-wide bar runs 148…208 on screen.
        try writeScene([
            host(id: 1, name: "Panel", origin: "128 128 0", scale: "-1 1 1"),
            ["id": 2, "name": "Bar", "parent": 1, "image": "models/white.json", "origin": "-20 0 0",
             "size": "60 20", "alignment": "right"],
        ])
        let image = try await frame()
        let columns = try brightColumns(image, rows: 124...132)
        XCTAssertFalse(columns.isEmpty, "The bar must draw")
        XCTAssertGreaterThanOrEqual(columns.min() ?? 0, 146, "Nothing may grow back over the mirrored parent's side")
        XCTAssertGreaterThanOrEqual(columns.max() ?? 0, 204, "The bar must reach 60 px right of its origin")
    }

    @MainActor func testMirroredLabelFollowsItsScriptedLeftAlignment() async throws {
        // Panel mirrored; the label mirrors back (upright text) and asks for "left" like 3326873240's scale script,
        // and its text script swaps the authored word for a longer one (the track title). Its origin is 20 px right
        // of the panel on screen, so the text starts there and runs right.
        let flip = """
        export function update(value) {
            value.x = -1;
            thisLayer.horizontalalign = "left";
            return value;
        }
        """
        try writeScene([
            host(id: 1, name: "Panel", origin: "100 128 0", scale: "-1 1 1"),
            ["id": 2, "name": "Label", "parent": 1, "font": "systemfont_arial", "origin": "-20 0 0",
             "text": ["value": "W", "script": "export function update() { return \"WWWW\"; }"],
             "pointsize": 10, "color": "1 1 1", "horizontalalign": "right", "verticalalign": "center",
             "scale": script(flip, value: "1 1 1")],
        ])
        let image = try await frame()
        let columns = try brightColumns(image, rows: 110...146)
        XCTAssertFalse(columns.isEmpty, "The label must draw")
        XCTAssertGreaterThanOrEqual(columns.min() ?? 0, 116, "Left-aligned text starts at its origin (x 120), not before it")
        XCTAssertGreaterThan(columns.max() ?? 0, 150, "and runs to the right of it")
    }

    @MainActor func testScriptsReadLiveTextSizeAndParentRelativeOrigin() async throws {
        // The label's script replaces one W with three. A left-aligned bar sized like 3326873240's backdrop
        // (`size.x × |scale.x| − origin.x`) spans the live text plus the label's 20 px parent-relative inset; read
        // from the authored text or the world origin it would stop far short.
        let label = "export function update() { return \"WWW\"; }"
        let barScale = """
        let label;
        export function init(value) { label = thisScene.getLayer("Label"); }
        export function update(value) {
            value.x = (label.size.x * Math.abs(label.scale.x) - label.origin.x) / 100;
            return value;
        }
        """
        try writeScene([
            host(id: 1, name: "Panel", origin: "80 150 0", scale: "1 1 1"),
            ["id": 2, "name": "Label", "parent": 1, "text": ["value": "W", "script": label], "font": "systemfont_arial",
             "origin": "-20 0 0", "pointsize": 6, "color": "1 1 1", "horizontalalign": "left", "verticalalign": "center"],
            ["id": 3, "name": "Bar", "image": "models/white.json", "origin": "60 60 0", "size": "100 6",
             "alignment": "left", "scale": script(barScale, value: "1 1 1")],
        ])
        let image = try await frame(afterPlaying: 1.0)
        let text = try brightColumns(image, rows: 92...120)
        let bar = try brightColumns(image, rows: 194...198)
        let textEnd = try XCTUnwrap(text.max())
        let barStart = try XCTUnwrap(bar.min()), barEnd = try XCTUnwrap(bar.max())
        XCTAssertGreaterThan(textEnd, 110, "Control: the script's three Ws must be on screen")
        XCTAssertLessThan(textEnd, 200, "Control: the text must end inside the frame")
        XCTAssertEqual(barStart, 60, accuracy: 2, "The bar is left-aligned at x 60")
        // Text runs 60 … textEnd; the bar is (textEnd − 60) + 20 wide.
        XCTAssertEqual(barEnd, textEnd + 20, accuracy: 4, "The bar must follow the live text width and the local origin")
    }

    @MainActor func testTransformReadsAreSnapshots() async throws {
        // `initial = grower.scale` in init must keep the value it read; the grower keeps scaling up afterwards.
        let grow = "let n = 0; export function update(value) { n += 1; value.x = 1 + n * 0.05; return value; }"
        let barScale = """
        let grower, initial;
        export function init(value) {
            grower = thisScene.getLayer("Grower");
            initial = grower.scale;
        }
        export function update(value) {
            const current = grower.scale.x;
            value.x = initial.x;
            return value;
        }
        """
        try writeScene([
            ["id": 1, "name": "Grower", "image": "models/background.json", "origin": "250 250 0", "size": "1 1",
             "scale": script(grow, value: "1 1 1")],
            ["id": 2, "name": "Bar", "image": "models/white.json", "origin": "60 60 0", "size": "100 6",
             "alignment": "left", "scale": script(barScale, value: "1 1 1")],
        ])
        let image = try await frame(afterPlaying: 1.0)
        let bar = try brightColumns(image, rows: 194...198)
        let barStart = try XCTUnwrap(bar.min()), barEnd = try XCTUnwrap(bar.max())
        XCTAssertEqual(barEnd - barStart, 99, accuracy: 4, "A snapshot taken in init must not follow the grower")
    }
}
