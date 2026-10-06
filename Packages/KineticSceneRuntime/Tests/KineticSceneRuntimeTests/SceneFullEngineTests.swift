import AppKit
import CoreGraphics
import Darwin
import Foundation
import ImageIO
@_spi(KineticTesting) import KineticWPEEngine
import UniformTypeIdentifiers
import XCTest
@testable import KineticSceneRuntime

/// Module 28.3 — the complete ported renderer tier. Scenes the bounded runtime and the scriptless image
/// backend decline reach it; SceneScript runs through upstream JavaScriptCore (user decision, 2026-10-05).
final class SceneFullEngineTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        root = package.appendingPathComponent(".build/FullEngineFixtures/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try write("project.json", ["type": "scene", "file": "scene.json", "title": "Full engine test"])
        try writeScene(originScript: "'use strict';\nexport function update(value) {\n\treturn value;\n}")
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
        let output = try XCTUnwrap(CGImageDestinationCreateWithURL(root.appendingPathComponent("pixel.png") as CFURL,
                                                                    UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(output, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(output))
    }

    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(at: root) } }

    private func write(_ path: String, _ object: Any) throws {
        let target = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: target)
    }

    private func writeScene(originScript: String, effects: Bool = true) throws {
        var layer: [String: Any] = ["id": 1, "name": "Scripted layer", "image": "models/layer.json", "size": "64 64 0",
            "origin": ["value": "32 32 0", "script": originScript, "scriptproperties": [String: Any]()]]
        if effects { layer["effects"] = [["id": 2, "file": "effects/probe/effect.json"]] }
        try write("scene.json", ["camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 64, "height": 64], "clearcolor": "0 0 0"],
            "objects": [layer]])
    }

    private func centerPixel(_ image: CGImage) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        let offset = ((image.height / 2) * image.width + image.width / 2) * 4
        return [data[offset], data[offset + 1], data[offset + 2], data[offset + 3]]
    }

    @MainActor func testScriptedSceneIsPreparedByCompleteEngine() async throws {
        let runtime = KineticSceneRuntime(root: root)
        defer { runtime.dispose() }
        do { try await runtime.prepare() } catch { XCTFail("Complete engine preparation error: \(error)"); throw error }
        XCTAssertTrue(runtime.isPrepared)
        XCTAssertTrue(runtime.usesFullEngine)
        XCTAssertFalse(runtime.usesExtendedRenderGraph)
        XCTAssertFalse(runtime.isPlaying)
        let color = try centerPixel(XCTUnwrap(runtime.preparedFrame))
        XCTAssertGreaterThan(color[1], 200, "Effect FBO output reaches the first frame: \(color)")
        XCTAssertLessThan(color[0], 60)
        runtime.play(); XCTAssertTrue(runtime.isPlaying)
        runtime.pause(); XCTAssertFalse(runtime.isPlaying)
        runtime.setMuted(false); runtime.setMuted(true)
        runtime.dispose()
        XCTAssertNil(runtime.fullHostForTesting)
        XCTAssertFalse(runtime.isPrepared)
    }

    /// The fallback / failure frame must look like the screen: authored mid-gray stays mid-gray
    /// (the `_srgb` drawable is not gamma-decoded twice on capture).
    @MainActor func testCapturedFrameKeepsAuthoredColors() async throws {
        try writeScene(originScript: "'use strict';\nexport function update(value) {\n\treturn value;\n}", effects: false)
        try write("materials/base.json", ["passes": [["shader": "solidcolor", "blending": "disabled",
            "constantshadervalues": ["g_Color": [0.5, 0.5, 0.5, 1]]]]])
        let runtime = KineticSceneRuntime(root: root)
        defer { runtime.dispose() }
        try await runtime.prepare()
        XCTAssertTrue(runtime.usesFullEngine)
        let color = try centerPixel(XCTUnwrap(runtime.preparedFrame))
        for channel in color.prefix(3) { XCTAssertEqual(Int(channel), 128, accuracy: 10, "captured \(color)") }
    }

    @MainActor func testOriginScriptRunsThroughJavaScriptCore() async throws {
        try writeScene(originScript: "'use strict';\nexport function update(value) {\n\tvalue.x = -100000;\n\treturn value;\n}")
        let runtime = KineticSceneRuntime(root: root)
        defer { runtime.dispose() }
        try await runtime.prepare()
        let host = try XCTUnwrap(runtime.fullHostForTesting)
        runtime.play()
        var color: [UInt8] = []
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 50_000_000)
            await host.renderFrameNow()
            if let frame = await host.captureFrame() { color = try centerPixel(frame) }
            if color.count == 4, color[1] < 30 { break }
        }
        XCTAssertEqual(color.count, 4)
        XCTAssertLessThan(color[1], 30, "The script moved the layer away, leaving the clear color: \(color)")
    }

    @MainActor func testMissingRequiredModelIsReportedAsMissingAsset() async throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent("models/layer.json"))
        let runtime = KineticSceneRuntime(root: root)
        defer { runtime.dispose() }
        do { try await runtime.prepare(); XCTFail("A missing model was rendered around") }
        catch SceneRuntimeError.missingAsset(let path) { XCTAssertTrue(path.contains("layer"), path) }
        XCTAssertFalse(runtime.isPrepared)
        XCTAssertNil(runtime.fullHostForTesting)
    }

    /// Wallpaper Engine leaves a missing auxiliary texture slot unbound; the complete engine does the same
    /// (no substitute image is drawn), and the solid-color pass still renders.
    @MainActor func testMissingAuxiliaryTextureSlotStaysUnbound() async throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent("pixel.png"))
        let runtime = KineticSceneRuntime(root: root)
        defer { runtime.dispose() }
        try await runtime.prepare()
        XCTAssertTrue(runtime.usesFullEngine)
        XCTAssertGreaterThan(try centerPixel(XCTUnwrap(runtime.preparedFrame))[1], 200)
    }

    /// A burst of GPU command-buffer failures during playback freezes the last presented frame, releases the
    /// complete engine and reports through `onFailure`; one sporadic error is tolerated.
    @MainActor func testGPUFailureBurstDuringPlaybackFreezesLastFrameAndReports() async throws {
        let runtime = KineticSceneRuntime(root: root)
        defer { runtime.dispose() }
        runtime.fullHealthInterval = 50_000_000
        var reported: Error?
        runtime.onFailure = { reported = $0 }
        try await runtime.prepare()
        let host = try XCTUnwrap(runtime.fullHostForTesting)
        runtime.play()
        host.recordGPUFailureForTesting("sporadic")
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertNil(reported); XCTAssertTrue(runtime.isPlaying)
        XCTAssertEqual(host.health.gpuErrorCount, 1)
        for _ in 0..<KineticSceneRuntime.fullGPUFailureBurst { host.recordGPUFailureForTesting("simulated command buffer error") }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while reported == nil, ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        guard case .graphics(let detail)? = reported as? SceneRuntimeError else { return XCTFail("Reported: \(String(describing: reported))") }
        XCTAssertTrue(detail.contains("simulated"), detail)
        XCTAssertFalse(runtime.isPlaying)
        XCTAssertNil(runtime.fullHostForTesting)
        XCTAssertGreaterThan(try centerPixel(XCTUnwrap(runtime.preparedFrame))[1], 200, "frozen frame keeps the last picture")
        runtime.play(); XCTAssertFalse(runtime.isPlaying, "a failed scene stays failed until it is applied again")
    }

    /// The host-fed system spectrum reaches SceneScript (`engine.registerAudioBuffers`); silence switches it off.
    @MainActor func testAudioSpectrumReachesSceneScript() async throws {
        try writeScene(originScript: """
            'use strict';
            let audio;
            export function update(value) {
            \tif (!audio) { audio = engine.registerAudioBuffers(engine.AUDIO_RESOLUTION_16); }
            \tvalue.x = audio.average[0] > 0.5 ? -100000 : 32;
            \treturn value;
            }
            """)
        let runtime = KineticSceneRuntime(root: root)
        defer {
            runtime.dispose()
            KineticWPEAudioInput.publish(left: .init(repeating: 0, count: 64), right: .init(repeating: 0, count: 64))
        }
        try await runtime.prepare()
        let host = try XCTUnwrap(runtime.fullHostForTesting)
        runtime.play()
        func settle(until predicate: ([UInt8]) -> Bool) async throws -> [UInt8] {
            var color: [UInt8] = []
            for _ in 0..<30 {
                try await Task.sleep(nanoseconds: 40_000_000)
                await host.renderFrameNow()
                if let frame = await host.captureFrame() { color = try centerPixel(frame) }
                if color.count == 4, predicate(color) { break }
            }
            return color
        }
        let silent = try await settle(until: { $0[1] > 200 })
        XCTAssertGreaterThan(silent[1], 200, "silent: the layer stays in place \(silent)")
        try runtime.setAudioSpectrum(SceneAudioSpectrum(left: .init(repeating: 1, count: 64), right: .init(repeating: 1, count: 64)))
        XCTAssertTrue(KineticWPEAudioInput.isActive)
        let loud = try await settle(until: { $0[1] < 30 })
        XCTAssertLessThan(loud[1], 30, "loud: the script moved the layer away \(loud)")
        try runtime.setAudioSpectrum(.silence)
        XCTAssertFalse(KineticWPEAudioInput.isActive)
        let quiet = try await settle(until: { $0[1] > 200 })
        XCTAssertGreaterThan(quiet[1], 200, "silence again: the layer returns \(quiet)")
    }

    /// Cursor response: the global-monitor pointer (here injected) reaches SceneScript's `input.cursorWorldPosition`.
    @MainActor func testCursorPositionReachesSceneScript() async throws {
        try writeScene(originScript: """
            'use strict';
            export function update(value) {
            \tvalue.x = input.cursorWorldPosition.x > 40 ? -100000 : 32;
            \treturn value;
            }
            """)
        let runtime = KineticSceneRuntime(root: root)
        defer { runtime.dispose() }
        runtime.displayView.frame = CGRect(x: 0, y: 0, width: 64, height: 64)
        try await runtime.prepare()
        let host = try XCTUnwrap(runtime.fullHostForTesting)
        runtime.play()
        let view = CGRect(x: 1000, y: 500, width: 64, height: 64)
        func settle(cursorX: CGFloat, until predicate: ([UInt8]) -> Bool) async throws -> [UInt8] {
            var color: [UInt8] = []
            for _ in 0..<30 {
                host.simulatePointerForTesting(at: CGPoint(x: view.minX + cursorX, y: view.midY), viewFrameInScreen: view)
                try await Task.sleep(nanoseconds: 40_000_000)
                await host.renderFrameNow()
                if let frame = await host.captureFrame() { color = try centerPixel(frame) }
                if color.count == 4, predicate(color) { break }
            }
            return color
        }
        let left = try await settle(cursorX: 8, until: { $0[1] > 200 })
        XCTAssertGreaterThan(left[1], 200, "cursor on the left: layer in place \(left)")
        let right = try await settle(cursorX: 60, until: { $0[1] < 30 })
        XCTAssertLessThan(right[1], 30, "cursor on the right: the script moved the layer \(right)")
    }

    /// `{"user": key}` bindings take the default from project.json `general.properties` (overrides are Module 29).
    @MainActor func testUserPropertyDefaultsComeFromProjectJSON() async throws {
        try write("scene.json", ["camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 64, "height": 64], "clearcolor": "0 0 0"],
            "objects": [["id": 1, "name": "Toggle", "image": "models/layer.json", "size": "64 64 0",
                "visible": ["user": "showpanel", "value": true],
                "origin": ["value": "32 32 0", "script": "export function update(value) { return value; }"],
                "effects": [["id": 2, "file": "effects/probe/effect.json"]]]]])
        for shown in [false, true] {
            try write("project.json", ["type": "scene", "file": "scene.json", "title": "Properties",
                "general": ["properties": ["showpanel": ["type": "bool", "text": "Show panel", "value": shown, "order": 100]]]])
            let runtime = KineticSceneRuntime(root: root)
            defer { runtime.dispose() }
            try await runtime.prepare()
            XCTAssertTrue(runtime.usesFullEngine)
            let green = try centerPixel(XCTUnwrap(runtime.preparedFrame))[1]
            if shown { XCTAssertGreaterThan(green, 200) } else { XCTAssertLessThan(green, 30, "default false hides the layer") }
        }
    }

    /// Each complete-engine scene owns a render thread; dispose must let it exit (no thread per wallpaper switch).
    @MainActor func testRepeatedPrepareAndDisposeReleasesRenderThreads() async throws {
        func threadCount() -> Int {
            var list: thread_act_array_t?
            var count: mach_msg_type_number_t = 0
            guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return -1 }
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: list), vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
            return Int(count)
        }
        var peak = 0
        func cycle() async throws {
            let runtime = KineticSceneRuntime(root: root)
            try await runtime.prepare()
            XCTAssertTrue(runtime.usesFullEngine)
            runtime.play()
            try await Task.sleep(nanoseconds: 60_000_000)
            peak = max(peak, threadCount())
            runtime.dispose()
        }
        try await cycle()  // warm up one-time engine / JavaScriptCore threads
        try await Task.sleep(nanoseconds: 500_000_000)
        let before = threadCount()
        for _ in 0..<8 { try await cycle() }
        var after = threadCount()
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while after > before + 3, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
            after = threadCount()
        }
        XCTAssertGreaterThan(before, 0)
        XCTAssertGreaterThan(peak, before, "a playing scene owns at least its render thread")
        XCTAssertLessThanOrEqual(after, before + 3, "threads before \(before), peak \(peak), after 8 scenes \(after)")
        print("render-thread soak: before \(before) peak \(peak) after \(after)")
    }

    /// A playing complete-engine scene, driven by its own display link on the render thread, must not grow
    /// the process footprint frame after frame.
    @MainActor func testPlaybackFootprintStaysFlat() async throws {
        func footprintMiB() -> Double {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
            }
            return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
        }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 360), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let runtime = KineticSceneRuntime(root: root)
        defer { runtime.dispose() }
        runtime.displayView.frame = window.contentView!.bounds
        window.contentView!.addSubview(runtime.displayView)
        window.orderFront(nil)
        try await runtime.prepare()
        XCTAssertTrue(runtime.usesFullEngine)
        runtime.play()
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let settled = footprintMiB()
        var samples: [Double] = []
        for _ in 0..<6 {
            try await Task.sleep(nanoseconds: 1_500_000_000)
            samples.append(footprintMiB())
        }
        print("full-engine footprint MiB: settled \(settled) then \(samples)")
        XCTAssertGreaterThan(settled, 0)
        XCTAssertLessThan((samples.last ?? 0) - settled, 64, "footprint grew while playing: \(settled) → \(samples)")
    }

    /// `../<id>/…` references resolve inside the mounted Workshop dependency (loose folder here).
    @MainActor func testWorkshopDependencyIsMountedFromItsFolder() async throws {
        let id = "1234567890"
        let dependency = root.deletingLastPathComponent().appendingPathComponent("dep-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dependency) }
        func writeDependency(_ path: String, _ object: Any) throws {
            let target = dependency.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: object).write(to: target)
        }
        try writeDependency("project.json", ["title": "Asset pack", "type": "scene"])
        try writeDependency("models/panel.json", ["material": "../\(id)/materials/blue.json"])
        try writeDependency("materials/blue.json", ["passes": [["shader": "solidcolor", "blending": "disabled",
            "constantshadervalues": ["g_Color": [0, 0, 1, 1]]]]])
        try write("project.json", ["type": "scene", "file": "scene.json", "dependencies": [id]])
        try write("scene.json", ["camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 64, "height": 64], "clearcolor": "0 0 0"],
            "objects": [["id": 1, "name": "From dependency", "image": "../\(id)/models/panel.json",
                         "size": "64 64 0", "origin": "32 32 0"]]])
        var asked: [String] = []
        let runtime = KineticSceneRuntime(root: root, dependencyFolder: { asked.append($0); return $0 == id ? dependency : nil })
        defer { runtime.dispose() }
        do { try await runtime.prepare() } catch { XCTFail("Dependency scene failed: \(error)"); throw error }
        XCTAssertTrue(runtime.usesFullEngine)
        XCTAssertEqual(asked, [id])
        let color = try centerPixel(XCTUnwrap(runtime.preparedFrame))
        XCTAssertGreaterThan(color[2], 200, "dependency material rendered: \(color)"); XCTAssertLessThan(color[0], 40)

        // The same scene without the dependency on this Mac fails with its ID, and a folder that is not a
        // Workshop item (no project.json / scene.pkg) does not count.
        for resolver in [nil, { (_: String) in self.root.deletingLastPathComponent() }] as [((String) -> URL?)?] {
            let missing = KineticSceneRuntime(root: root, dependencyFolder: resolver)
            defer { missing.dispose() }
            do { try await missing.prepare(); XCTFail("Rendered around a missing dependency") }
            catch SceneRuntimeError.missingAsset(let detail) { XCTAssertTrue(detail.contains(id), detail) }
            XCTAssertNil(missing.fullHostForTesting)
        }
    }

    /// A sprite-sheet TEX (TEXS frames) shows one frame at a time, never the whole atlas. Found with real Workshop
    /// item 3814311518 (2026-10-06): a 2 × 5 sheet of 1920 × 1080 frames was drawn whole, tiling the desktop.
    private func spriteSheetTEX() -> Data {
        func u32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        func f32(_ value: Float) -> Data { withUnsafeBytes(of: value.bitPattern.littleEndian) { Data($0) } }
        // 4 × 2 RGBA atlas: left 2 × 2 red (frame 0), right 2 × 2 green (frame 1).
        var pixels = Data()
        for _ in 0..<2 { pixels += Data([255, 0, 0, 255, 255, 0, 0, 255, 0, 255, 0, 255, 0, 255, 0, 255]) }
        var data = Data("TEXV0005\0TEXI0001\0".utf8)
        for value: UInt32 in [0, 0x6, 4, 2, 4, 2, 0] { data += u32(value) }
        data += Data("TEXB0003\0".utf8) + u32(1) + u32(UInt32(bitPattern: -1)) + u32(1)
        data += u32(4) + u32(2) + u32(0) + u32(UInt32(pixels.count)) + u32(UInt32(pixels.count)) + pixels
        data += Data("TEXS0003\0".utf8) + u32(2) + u32(2) + u32(2)
        for x: Float in [0, 2] { data += u32(0) + f32(1) + f32(x) + f32(0) + f32(2) + f32(0) + f32(0) + f32(2) }
        return data
    }

    @MainActor func testSpriteSheetShowsOneFrameNotTheWholeAtlas() async throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("materials"), withIntermediateDirectories: true)
        try spriteSheetTEX().write(to: root.appendingPathComponent("materials/sheet.tex"))
        try write("models/sheet.json", ["material": "materials/sheet.json", "width": 64, "height": 64, "nopadding": true])
        try write("materials/sheet.json", ["passes": [["shader": "genericimage4", "blending": "translucent",
            "combos": ["SPRITESHEET": 1], "textures": ["sheet"]]]])
        try write("scene.json", ["camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 64, "height": 64], "clearcolor": "0 0 0"],
            "objects": [["id": 1, "name": "Sheet", "image": "models/sheet.json", "size": "64 64 0", "origin": "32 32 0"]]])
        let runtime = KineticSceneRuntime(root: root)
        defer { runtime.dispose() }
        do { try await runtime.prepare() } catch { XCTFail("Sprite sheet scene failed: \(error)"); throw error }
        XCTAssertTrue(runtime.usesFullEngine)
        let frame = try XCTUnwrap(runtime.preparedFrame)
        func pixel(_ image: CGImage, x: Double) throws -> [UInt8] {
            let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
            let offset = ((image.height / 2) * image.width + Int(Double(image.width) * x)) * 4
            return [data[offset], data[offset + 1], data[offset + 2]]
        }
        let left = try pixel(frame, x: 0.25), right = try pixel(frame, x: 0.75)
        XCTAssertGreaterThan(left[0], 200, "frame 0 is red on the left: \(left)")
        XCTAssertGreaterThan(right[0], 200, "frame 0 also fills the right half (not the atlas's green frame): \(right)")
        XCTAssertLessThan(right[1], 60, "\(right)")
    }

    @MainActor func testDisposeDuringPrepareReleasesTheHost() async throws {
        let runtime = KineticSceneRuntime(root: root)
        let preparation = Task { @MainActor in try await runtime.prepare() }
        try await Task.sleep(nanoseconds: 1_000_000)
        runtime.dispose()
        _ = try? await preparation.value
        XCTAssertFalse(runtime.isPrepared)
        XCTAssertNil(runtime.fullHostForTesting)
    }

    /// Switching wallpapers quickly disposes Scenes at every point of preparation. 2026-10-06: a dispose while
    /// the render thread was stopping ran the engine's late QoS bookkeeping inline on the caller and tripped a
    /// render-thread assertion (Debug crash; in Release it changed the caller thread's QoS).
    @MainActor func testDisposeAtAnyPointOfPreparationIsSafe() async throws {
        for step in 0..<12 {
            let runtime = KineticSceneRuntime(root: root)
            let preparation = Task { @MainActor in try await runtime.prepare() }
            try await Task.sleep(nanoseconds: UInt64(step) * 4_000_000)
            runtime.dispose()
            _ = try? await preparation.value
            XCTAssertTrue(runtime.isDisposed, "step \(step)")
            XCTAssertNil(runtime.fullHostForTesting, "step \(step)")
        }
    }
}
