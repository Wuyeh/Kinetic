import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Metal
@_spi(KineticTesting) import KineticWPEEngine
import UniformTypeIdentifiers
import XCTest
@testable import KineticSceneRuntime

/// 显示方式 › 自定义（2026-10-08）：每一层引擎都只显示用户选定的那部分画布，并且铺满视图。
final class SceneDisplayCropTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        root = package.appendingPathComponent(".build/DisplayCropFixtures/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(at: root) } }

    private func write(_ path: String, _ data: Data) throws {
        let target = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target)
    }
    private func write(_ path: String, json object: Any) throws { try write(path, JSONSerialization.data(withJSONObject: object)) }
    private func u32(_ value: UInt32) -> Data { var value = value.littleEndian; return withUnsafeBytes(of: &value) { Data($0) } }
    private func tex(_ rgba: [UInt8]) -> Data {
        var output = Data("TEXV0005\0TEXI0001\0".utf8)
        for value in [UInt32(0), 2, 4, 4, 4, 4, 0] { output += u32(value) }
        let bytes = Data(Array(repeating: rgba, count: 16).flatMap { $0 })
        output += Data("TEXB0001\0".utf8) + u32(1) + u32(1) + u32(4) + u32(4) + u32(UInt32(bytes.count)) + bytes
        return output
    }
    /// RGB of a pixel, `x` / `y` as fractions of the image (y from the top).
    private func pixel(_ image: CGImage, _ x: Double, _ y: Double) throws -> [Int] {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        let column = min(image.width - 1, Int(x * Double(image.width))), row = min(image.height - 1, Int(y * Double(image.height)))
        let index = (row * image.width + column) * 4
        return [Int(data[index]), Int(data[index + 1]), Int(data[index + 2])]
    }
    /// "red", "green", or the raw colour.
    private func color(_ image: CGImage, _ x: Double, _ y: Double) throws -> String {
        let rgb = try pixel(image, x, y)
        if rgb[0] > 200 && rgb[1] < 60 && rgb[2] < 60 { return "red" }
        if rgb[1] > 200 && rgb[0] < 60 && rgb[2] < 60 { return "green" }
        return "\(rgb)"
    }

    func testRegionMatchesTheEngineAndCanvasSizeIsReadFromTheSceneFile() throws {
        let crop = SceneDisplayCrop(zoom: 2, centerX: 0.2, centerY: 0.9)
        XCTAssertEqual(crop.region(canvas: CGSize(width: 1920, height: 1080), viewport: CGSize(width: 1512, height: 982)),
                       KineticSceneCrop(zoom: 2, centerX: 0.2, centerY: 0.9)
                        .region(source: CGSize(width: 1920, height: 1080), target: CGSize(width: 1512, height: 982)))
        XCTAssertEqual(SceneDisplayCrop.maximumZoom, KineticSceneCrop.maximumZoom)
        try write("project.json", json: ["type": "scene", "file": "scene.json"])
        try write("scene.json", json: ["general": ["orthogonalprojection": ["width": 2560, "height": 1080]], "objects": []])
        XCTAssertEqual(KineticSceneRuntime.canvasSize(root: root), CGSize(width: 2560, height: 1080))
        try write("scene.json", json: ["general": ["orthogonalprojection": ["auto": true]], "objects": []])
        XCTAssertNil(KineticSceneRuntime.canvasSize(root: root), "no stated size: the caller decides")
    }

    /// Bounded tier: a 64×64 canvas, left half red and right half green (the quadrant test below covers y).
    @MainActor func testBoundedTierDrawsOnlyTheChosenRegion() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        try write("project.json", json: ["type": "scene", "file": "scene.json"])
        try write("scene.json", json: ["general": ["orthogonalprojection": ["width": 64, "height": 64], "clearcolor": "0 0 0"],
            "objects": [["id": 1, "image": "red.tex", "origin": "16 32 0", "size": "32 64 0"],
                        ["id": 2, "image": "green.tex", "origin": "48 32 0", "size": "32 64 0"]]])
        try write("red.tex", tex([255, 0, 0, 255])); try write("green.tex", tex([0, 255, 0, 255]))
        let engine = try SceneMetalEngine(graph: SceneRenderGraph.load(root: root))
        let whole = try await engine.firstFrame()
        XCTAssertEqual(try color(whole, 0.1, 0.5), "red", "fixture: red left")
        XCTAssertEqual(try color(whole, 0.9, 0.5), "green", "fixture: green right")
        engine.crop = KineticSceneCrop(zoom: 2, centerX: 0.25, centerY: 0.5)
        let left = try await engine.firstFrame()
        for x in [0.05, 0.5, 0.95] { XCTAssertEqual(try color(left, x, 0.5), "red", "left region at \(x)") }
        engine.crop = KineticSceneCrop(zoom: 2, centerX: 1, centerY: 0.5)
        let right = try await engine.firstFrame()
        for x in [0.05, 0.5, 0.95] { XCTAssertEqual(try color(right, x, 0.5), "green", "right edge at \(x)") }
    }

    /// Bounded tier, vertical axis: the region's y counts from the top of the canvas, like the editor window.
    @MainActor func testBoundedTierRegionCountsFromTheTop() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        try write("project.json", json: ["type": "scene", "file": "scene.json"])
        try write("scene.json", json: ["general": ["orthogonalprojection": ["width": 64, "height": 64], "clearcolor": "0 0 0"],
            "objects": [["id": 1, "image": "red.tex", "origin": "32 16 0", "size": "64 32 0"],
                        ["id": 2, "image": "green.tex", "origin": "32 48 0", "size": "64 32 0"]]])
        try write("red.tex", tex([255, 0, 0, 255])); try write("green.tex", tex([0, 255, 0, 255]))
        let engine = try SceneMetalEngine(graph: SceneRenderGraph.load(root: root))
        let whole = try await engine.firstFrame()
        let top = try color(whole, 0.5, 0.1), bottom = try color(whole, 0.5, 0.9)
        XCTAssertEqual(Set([top, bottom]), ["red", "green"], "fixture: two horizontal bands")
        engine.crop = KineticSceneCrop(zoom: 2, centerX: 0.5, centerY: 0)
        let upper = try await engine.firstFrame()
        XCTAssertEqual(try color(upper, 0.5, 0.9), top, "centerY 0 shows the top band only")
        engine.crop = KineticSceneCrop(zoom: 2, centerX: 0.5, centerY: 1)
        let lower = try await engine.firstFrame()
        XCTAssertEqual(try color(lower, 0.5, 0.1), bottom, "centerY 1 shows the bottom band only")
    }

    /// Complete engine (scripted layers reach it): a 4:1 canvas, left half red, right half green, on a 2:1 view.
    @MainActor func testCompleteEngineShowsTheChosenRegionAndFollowsChanges() async throws {
        let script = "'use strict';\nexport function update(value) {\n\treturn value;\n}"
        try write("project.json", json: ["type": "scene", "file": "scene.json", "title": "Crop"])
        try write("scene.json", json: ["camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 400, "height": 100], "clearcolor": "0 0 0"],
            "objects": [["id": 1, "name": "Red", "image": "models/red.json", "size": "200 100 0",
                         "origin": ["value": "100 50 0", "script": script]],
                        ["id": 2, "name": "Green", "image": "models/green.json", "size": "200 100 0",
                         "origin": ["value": "300 50 0", "script": script]]]])
        try write("models/red.json", json: ["material": "materials/red.json"])
        try write("models/green.json", json: ["material": "materials/green.json"])
        for (name, color) in [("red", [1, 0, 0, 1]), ("green", [0, 1, 0, 1])] {
            try write("materials/\(name).json", json: ["passes": [["shader": "solidcolor", "blending": "disabled",
                "textures": ["pixel.png"], "constantshadervalues": ["g_Color": color]]]])
        }
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let output = try XCTUnwrap(CGImageDestinationCreateWithURL(root.appendingPathComponent("pixel.png") as CFURL,
                                                                    UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(output, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(output))

        let runtime = KineticSceneRuntime(root: root)
        defer { runtime.dispose() }
        runtime.displayView.frame = CGRect(x: 0, y: 0, width: 400, height: 200)
        runtime.displayCrop = SceneDisplayCrop(zoom: 1, centerX: 0, centerY: 0.5)
        do { try await runtime.prepare() } catch { XCTFail("crop scene failed: \(error)"); throw error }
        XCTAssertTrue(runtime.usesFullEngine)
        let host = try XCTUnwrap(runtime.fullHostForTesting)
        let first = try XCTUnwrap(runtime.preparedFrame)
        for x in [0.05, 0.5, 0.95] { XCTAssertEqual(try color(first, x, 0.5), "red", "first frame at \(x)") }
        runtime.play()
        func sample() async throws -> CGImage {
            var image: CGImage?
            for _ in 0..<4 {
                try await Task.sleep(nanoseconds: 80_000_000)
                await host.renderFrameNow()
                image = await host.captureFrame() ?? image
            }
            return try XCTUnwrap(image)
        }
        runtime.displayCrop = SceneDisplayCrop(zoom: 1, centerX: 1, centerY: 0.5)
        let right = try await sample()
        for x in [0.05, 0.5, 0.95] { XCTAssertEqual(try color(right, x, 0.5), "green", "right half at \(x)") }
        runtime.displayCrop = nil
        runtime.displayFit = .fill
        let cover = try await sample()
        XCTAssertEqual(try color(cover, 0.1, 0.5), "red", "back to the centred cover crop")
        XCTAssertEqual(try color(cover, 0.9, 0.5), "green", "back to the centred cover crop")
    }
}
