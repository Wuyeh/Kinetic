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

    @MainActor func testPreviewHostPatchesAuthoredVisibilityWithoutResettingClockOrRecreatingHost() async throws {
        try write("project.json", ["type": "scene", "file": "scene.json", "general": ["properties": [
            "showpanel": ["type": "bool", "value": true, "text": "显示"]]]])
        try write("scene.json", ["camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 64, "height": 64], "clearcolor": "0 0 0"],
            "objects": [["id": 1, "image": "models/layer.json", "size": "64 64 0", "origin": "32 32 0",
                         "visible": ["user": "showpanel", "value": true]]]])
        let runtime = KineticSceneRuntime(root: root)
        runtime.displayView.frame = CGRect(x: 0, y: 0, width: 64, height: 64)
        defer { runtime.dispose() }
        try await runtime.prepare()
        let host = try XCTUnwrap(runtime.fullHostForTesting)
        await runtime.setPreviewFrameRateCeiling(15)
        runtime.play(); try await Task.sleep(nanoseconds: 80_000_000)
        let time = runtime.sceneTime
        let accepted = try await runtime.updatePropertyValues(["showpanel": .bool(false)])
        XCTAssertTrue(accepted); XCTAssertTrue(runtime.fullHostForTesting === host)
        XCTAssertGreaterThanOrEqual(runtime.sceneTime, time)
        await host.renderFrameNow()
        let frame = await host.captureFrame()
        let hidden = try centerPixel(XCTUnwrap(frame))
        XCTAssertLessThan(hidden[0], 40)
        runtime.pause(); let frozenTime = runtime.sceneTime
        let resumed = try await runtime.updatePropertyValues(["showpanel": .bool(true)])
        XCTAssertTrue(resumed); XCTAssertFalse(runtime.isPlaying)
        XCTAssertEqual(runtime.sceneTime, frozenTime, accuracy: 0.001)
        await runtime.disposeAwaitingResources()
        XCTAssertTrue(host.isDisposed); XCTAssertNil(runtime.fullHostForTesting)
        XCTAssertTrue(runtime.isDisposed)
    }

    @MainActor func testUnsupportedPreviewPatchDoesNotMutateHostAndConcurrentDisposeWaitsForRelease() async throws {
        try write("project.json", ["type": "scene", "file": "scene.json", "general": ["properties": [
            "unbound": ["type": "slider", "value": 1, "min": 0, "max": 2, "step": 0.001]]]])
        let runtime = KineticSceneRuntime(root: root)
        try await runtime.prepare(); let host = try XCTUnwrap(runtime.fullHostForTesting)
        let accepted = try await runtime.updatePropertyValues(["unbound": .number(2)])
        XCTAssertFalse(accepted); XCTAssertTrue(runtime.fullHostForTesting === host); XCTAssertTrue(runtime.isPrepared)
        async let first: Void = host.dispose()
        async let second: Void = host.dispose()
        _ = await (first, second)
        XCTAssertTrue(host.isDisposed); XCTAssertFalse(host.isLoaded)
        runtime.dispose()
    }

    @MainActor func testLiveImageAlphaKeepsCurrentHostClockAndActuallyChangesPixels() async throws {
        try write("project.json", ["type": "scene", "file": "scene.json", "general": ["properties": [
            "opacity": ["type": "slider", "value": 1, "min": 0, "max": 1, "step": 0.001]]]])
        try write("materials/base.json", ["passes": [["shader": "solidlayer", "blending": "translucent",
            "constantshadervalues": ["g_Color": [1, 0, 0, 1]]]]])
        try write("scene.json", ["camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 64, "height": 64], "clearcolor": "0 0 0", "clearenabled": true],
            "objects": [["id": 1, "image": "models/layer.json", "size": "64 64 0", "origin": "32 32 0",
                         "alpha": ["user": "opacity", "value": 1]]]])
        let runtime = KineticSceneRuntime(root: root)
        defer { runtime.dispose() }
        try await runtime.prepare(); let host = try XCTUnwrap(runtime.fullHostForTesting)
        runtime.play(); try await Task.sleep(nanoseconds: 100_000_000)
        let time = runtime.sceneTime
        await host.renderFrameNow(); let before = try centerPixel(requireFrame(await host.captureFrame()))
        let accepted = try await runtime.updatePropertyValues(["opacity": .number(0.25)])
        XCTAssertTrue(accepted); XCTAssertTrue(runtime.fullHostForTesting === host)
        XCTAssertGreaterThanOrEqual(runtime.sceneTime, time); XCTAssertTrue(runtime.isPlaying)
        await host.renderFrameNow(); let after = try centerPixel(requireFrame(await host.captureFrame()))
        XCTAssertLessThan(after[0], before[0], "The accepted patch must change rendered pixels")
        runtime.pause(); let paused = runtime.sceneTime
        let reset = try await runtime.updatePropertyValues([:]); XCTAssertTrue(reset)
        XCTAssertFalse(runtime.isPlaying); XCTAssertEqual(runtime.sceneTime, paused, accuracy: 0.001)
    }

    @MainActor func testLiveTextSizeAndGroupVisibilityScalePreserveAnimatedTextState() async throws {
        try write("project.json", ["type": "scene", "file": "scene.json", "general": ["properties": [
            "size": ["type": "slider", "value": 3, "min": 1, "max": 8, "step": 0.001],
            "scale": ["type": "slider", "value": 1, "min": 0.25, "max": 2, "step": 0.001],
            "shown": ["type": "bool", "value": true]]]])
        // A text script guarantees the full engine; the ongoing clock must survive edits.
        let script = "'use strict'; export function update(value) { return 'TEXT'; }"
        try write("scene.json", ["camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 128, "height": 96], "clearcolor": "0 0 0"],
            "objects": [["id": 10, "solid": true, "origin": "64 48 0", "scale": ["user": "scale", "value": "1 1 1"],
                         "visible": ["user": "shown", "value": true]],
                        ["id": 2, "parent": 10, "origin": "0 0 0", "pointsize": ["user": "size", "value": 3],
                         "text": ["value": "TEXT", "script": script], "color": "1 1 1"]]])
        let runtime = KineticSceneRuntime(root: root)
        defer { runtime.dispose() }
        try await runtime.prepare(); let host = try XCTUnwrap(runtime.fullHostForTesting)
        runtime.play(); try await Task.sleep(nanoseconds: 100_000_000)
        await host.renderFrameNow(); let before = try litPixelCount(requireFrame(await host.captureFrame()))
        var values: [String: ScenePropertyValue] = ["size": .number(6)]
        let t = runtime.sceneTime
        let patched = try await runtime.updatePropertyValues(values); XCTAssertTrue(patched)
        await host.renderFrameNow(); let large = try litPixelCount(requireFrame(await host.captureFrame()))
        XCTAssertGreaterThan(large, before); XCTAssertTrue(runtime.fullHostForTesting === host)
        XCTAssertGreaterThanOrEqual(runtime.sceneTime, t)
        values["scale"] = .number(0.5)
        let patched2 = try await runtime.updatePropertyValues(values); XCTAssertTrue(patched2)
        await host.renderFrameNow(); let small = try litPixelCount(requireFrame(await host.captureFrame()))
        XCTAssertLessThan(small, large)
        values["shown"] = .bool(false)
        let patched3 = try await runtime.updatePropertyValues(values); XCTAssertTrue(patched3)
        await host.renderFrameNow(); let hidden = try litPixelCount(requireFrame(await host.captureFrame())); XCTAssertEqual(hidden, 0)
        runtime.pause(); let frozen = runtime.sceneTime
        values["shown"] = .bool(true)
        let patched4 = try await runtime.updatePropertyValues(values); XCTAssertTrue(patched4)
        await host.renderFrameNow(); let shown = try litPixelCount(requireFrame(await host.captureFrame())); XCTAssertGreaterThan(shown, 0)
        XCTAssertFalse(runtime.isPlaying); XCTAssertEqual(runtime.sceneTime, frozen, accuracy: 0.001)
        for i in 0..<10 {
            values["size"] = .number(i.isMultiple(of: 2) ? 3 : 6)
            let patched5 = try await runtime.updatePropertyValues(values); XCTAssertTrue(patched5)
            XCTAssertTrue(runtime.fullHostForTesting === host)
        }
    }

    @MainActor func testNestedGroupVisibilityRestoresDescendantsAndPreservesScriptOwnClaims() async throws {
        try write("project.json", ["type": "scene", "file": "scene.json", "general": ["properties": [
            "outer": ["type": "bool", "value": true], "inner": ["type": "bool", "value": true]]]])
        let textScript = "'use strict'; export function update(value) { return 'TEXT'; }"
        try write("scene.json", ["camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 128, "height": 96], "clearcolor": "0 0 0"],
            "objects": [["id": 10, "solid": true, "origin": "64 48 0", "visible": ["user": "outer", "value": true]],
                        ["id": 20, "parent": 10, "solid": true, "visible": ["user": "inner", "value": true]],
                        ["id": 2, "parent": 20, "origin": "0 0 0", "pointsize": 5,
                         "text": ["value": "TEXT", "script": textScript], "color": "1 1 1"]]])
        let runtime = KineticSceneRuntime(root: root); defer { runtime.dispose() }
        try await runtime.prepare(); let host = try XCTUnwrap(runtime.fullHostForTesting)
        runtime.play(); try await Task.sleep(nanoseconds: 100_000_000)
        let time = runtime.sceneTime
        for _ in 0..<4 {
            for (values, shown) in [(["outer": ScenePropertyValue.bool(false)], false),
                                   (["outer": .bool(false), "inner": .bool(false)], false),
                                   (["outer": .bool(true), "inner": .bool(false)], false),
                                   (["outer": .bool(true), "inner": .bool(true)], true)] {
                let accepted = try await runtime.updatePropertyValues(values); XCTAssertTrue(accepted)
                await host.renderFrameNow()
                let count = try litPixelCount(requireFrame(await host.captureFrame()))
                if shown { XCTAssertGreaterThan(count, 0) } else { XCTAssertEqual(count, 0) }
                XCTAssertTrue(runtime.fullHostForTesting === host)
                XCTAssertGreaterThanOrEqual(runtime.sceneTime, time)
            }
        }
    }

    @MainActor func testBoundStaticPositionScriptMovesPixelsWithoutReplacingHost() async throws {
        try write("project.json", ["type": "scene", "file": "scene.json", "general": ["properties": [
            "x": ["type": "slider", "value": 0.5, "min": 0, "max": 1, "step": 0.001]]]])
        let script = "'use strict'; export function update(value) { value.x = scriptProperties.x * engine.canvasSize.x; return value; }"
        try write("scene.json", ["camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 64, "height": 64], "clearcolor": "0 0 0"],
            "objects": [["id": 1, "image": "models/layer.json", "size": "16 16 0",
                         "origin": ["value": "32 32 0", "script": script,
                                    "scriptproperties": ["x": ["user": "x", "value": 0.5]]]]]])
        let runtime = KineticSceneRuntime(root: root); defer { runtime.dispose() }
        try await runtime.prepare(); let host = try XCTUnwrap(runtime.fullHostForTesting)
        runtime.play(); try await Task.sleep(nanoseconds: 100_000_000)
        await host.renderFrameNow(); let before = try centerPixel(requireFrame(await host.captureFrame()))
        let time = runtime.sceneTime
        let moved = try await runtime.updatePropertyValues(["x": .number(0)]); XCTAssertTrue(moved)
        await host.renderFrameNow(); let after = try centerPixel(requireFrame(await host.captureFrame()))
        XCTAssertGreaterThan(before[0], 200); XCTAssertLessThan(after[0], 40)
        XCTAssertTrue(runtime.fullHostForTesting === host); XCTAssertGreaterThanOrEqual(runtime.sceneTime, time)
        runtime.pause(); let paused = runtime.sceneTime
        let reset = try await runtime.updatePropertyValues([:]); XCTAssertTrue(reset)
        await host.renderFrameNow(); let restored = try centerPixel(requireFrame(await host.captureFrame()))
        XCTAssertGreaterThan(restored[0], 200); XCTAssertTrue(runtime.fullHostForTesting === host)
        XCTAssertFalse(runtime.isPlaying); XCTAssertEqual(runtime.sceneTime, paused, accuracy: 0.001)
    }

    private func litPixelCount(_ image: CGImage) throws -> Int {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<(image.width * image.height)).filter { max(bytes[$0 * 4], bytes[$0 * 4 + 1], bytes[$0 * 4 + 2]) > 80 }.count
    }

    private func requireFrame(_ frame: CGImage?) throws -> CGImage { try XCTUnwrap(frame) }

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

    /// App inputs arriving before a scene exists replay into its media gate, then audio updates in place.
    @MainActor func testHostMediaAndAudioReplayWithoutRecreatingSceneOrClock() async throws {
        try writeScene(originScript: """
            'use strict';
            let audio;
            let ready = false;
            export function mediaPropertiesChanged(event) { ready = event.title === 'KineticAudioAcceptance'; }
            export function update(value) {
                if (!audio) { audio = engine.registerAudioBuffers(engine.AUDIO_RESOLUTION_16); }
                value.x = ready && audio.average[0] > 0.5 ? -100000 : 32;
                return value;
            }
            """)
        SceneExternalInputs.publishMedia(playing: true, title: "KineticAudioAcceptance", duration: 100, position: 20)
        SceneExternalInputs.publishSystemAudio(nil)
        let runtime = KineticSceneRuntime(root: root)
        defer {
            runtime.dispose()
            SceneExternalInputs.publishSystemAudio(nil)
            SceneExternalInputs.publishMedia(playing: false, title: nil)
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
        XCTAssertGreaterThan(silent[1], 200)
        let time = runtime.sceneTime
        SceneExternalInputs.publishSystemAudio(try .init(left: .init(repeating: 1, count: 64), right: .init(repeating: 1, count: 64)))
        let loud = try await settle(until: { $0[1] < 30 })
        XCTAssertLessThan(loud[1], 30, "A preloaded media title opened the author's gate")
        SceneExternalInputs.publishMedia(playing: false, title: nil)
        let noPlayer = try await settle(until: { $0[1] > 200 })
        XCTAssertGreaterThan(noPlayer[1], 200, "Clearing media reaches the author without reloading")
        XCTAssertTrue(runtime.fullHostForTesting === host)
        XCTAssertGreaterThan(runtime.sceneTime, time)
        SceneExternalInputs.publishSystemAudio(nil)
        XCTAssertFalse(KineticWPEAudioInput.isActive)
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

    @MainActor func testPropertyOverridesReachGPUWithoutWritingSourceManifest() async throws {
        try write("project.json", ["type": "scene", "file": "scene.json", "title": "Properties",
            "general": ["properties": ["showpanel": ["type": "bool", "value": false]]]])
        try write("scene.json", ["camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 64, "height": 64], "clearcolor": "0 0 0"],
            "objects": [["id": 1, "name": "Toggle", "image": "models/layer.json", "size": "64 64 0",
                "visible": ["user": "showpanel", "value": false], "origin": "32 32 0",
                "effects": [["id": 2, "file": "effects/probe/effect.json"]]]]])
        let source = try Data(contentsOf: root.appendingPathComponent("project.json"))
        for shown in [false, true, false] {
            let runtime = KineticSceneRuntime(root: root, propertyValues: ["showpanel": .bool(shown)])
            defer { runtime.dispose() }
            try await runtime.prepare()
            XCTAssertTrue(runtime.usesFullEngine)
            let green = try centerPixel(XCTUnwrap(runtime.preparedFrame))[1]
            if shown { XCTAssertGreaterThan(green, 200) } else { XCTAssertLessThan(green, 30) }
            runtime.play(); runtime.pause(); XCTAssertNotNil(runtime.preparedFrame)
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("project.json")), source)
        let invalid = KineticSceneRuntime(root: root, propertyValues: ["unknown": .bool(true)])
        defer { invalid.dispose() }
        do { try await invalid.prepare(); XCTFail("Unknown override accepted") } catch {}
        XCTAssertFalse(invalid.isPrepared)
    }

    @MainActor func testColorPropertyOverridesReachImageTint() async throws {
        try write("scene.json", ["camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 64, "height": 64], "clearcolor": "0 0 0"],
            "objects": [["id": 1, "name": "Tinted image", "image": "models/layer.json", "size": "64 64 0",
                         "origin": "32 32 0", "color": ["user": "tint", "value": "1 0 0"]]]])
        try write("project.json", ["type": "scene", "file": "scene.json", "title": "Color",
            "general": ["properties": ["tint": ["type": "color", "value": "1 0 0"]]]])
        try write("materials/base.json", ["passes": [["shader": "genericimage2", "blending": "disabled", "textures": ["pixel.png"]]]])
        for (values, channel) in [([String: ScenePropertyValue](), 0), (["tint": .string("0 1 0")], 1)] {
            let runtime = KineticSceneRuntime(root: root, propertyValues: values)
            defer { runtime.dispose() }
            try await runtime.prepare()
            let pixel = try centerPixel(XCTUnwrap(runtime.preparedFrame))
            XCTAssertGreaterThan(pixel[channel], 200)
            XCTAssertLessThan(pixel[1 - channel], 30)
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
        // The sample points assume the square canvas fills the view; under 自动 a square canvas is letterboxed on a
        // 16:10 test screen and the probe would land between two texels of this tiny 4×2 atlas.
        runtime.displayFit = .fill
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

    /// A child of a text object follows the text object's origin (its alignment anchor), not the synthesized
    /// glyph quad's centre. 2026-10-06, Workshop 3379996991: the date under a right-aligned clock (both moved by a
    /// scripted group) drew half a clock width to the left and up over the clock.
    @MainActor func testChildOfTextObjectFollowsTheTextOrigin() async throws {
        try write("scene.json", ["camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 400, "height": 200], "clearcolor": "0 0 0"],
            "objects": [
                // The script moves the group (authored at the canvas corner), as 3379996991's position sliders do.
                ["id": 3, "name": "Group",
                 "origin": ["value": "0 0 0", "script": "'use strict';\nexport function update(value) {\n\treturn new Vec3(300, 100, 0);\n}"]],
                ["id": 1, "name": "Clock", "parent": 3, "text": ["value": "WWWW"], "font": "systemfont_arial",
                 "pointsize": 12, "color": "1 1 1", "horizontalalign": "right", "verticalalign": "bottom",
                 "origin": "0 0 0", "padding": 0],
                ["id": 2, "name": "Marker", "parent": 1, "text": ["value": "MM"], "font": "systemfont_arial",
                 "pointsize": 12, "color": "1 0 0", "horizontalalign": "left", "verticalalign": "top",
                 "origin": "0 -10 0", "padding": 0]
            ]])
        let runtime = KineticSceneRuntime(root: root)
        defer { runtime.dispose() }
        do { try await runtime.prepare() } catch { XCTFail("Text scene failed: \(error)"); throw error }
        XCTAssertTrue(runtime.usesFullEngine)
        let host = try XCTUnwrap(runtime.fullHostForTesting)
        runtime.play()
        var image = try XCTUnwrap(runtime.preparedFrame)
        for _ in 0..<5 {
            try await Task.sleep(nanoseconds: 100_000_000)
            await host.renderFrameNow()
            if let frame = await host.captureFrame() { image = frame }
        }
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        var whiteMin = Int.max, whiteMax = Int.min, redMin = Int.max, whiteBottom = Int.min, redTop = Int.max
        for y in 0..<image.height {
            for x in 0..<image.width {
                let i = (y * image.width + x) * 4
                let r = Int(data[i]), g = Int(data[i + 1]), b = Int(data[i + 2])
                if r > 170, g > 170, b > 170 { whiteMin = min(whiteMin, x); whiteMax = max(whiteMax, x); whiteBottom = max(whiteBottom, y) }
                if r > 170, g < 80, b < 80 { redMin = min(redMin, x); redTop = min(redTop, y) }
            }
        }
        XCTAssertLessThan(whiteMin, whiteMax, "clock text drawn"); XCTAssertNotEqual(redMin, Int.max, "marker text drawn")
        let clockWidth = Double(whiteMax - whiteMin)
        // The marker starts at the clock's right edge (the clock's origin), not half a clock width to the left.
        XCTAssertLessThan(abs(Double(redMin - whiteMax)), clockWidth * 0.2,
                          "marker left \(redMin) vs clock right \(whiteMax), clock width \(clockWidth)")
        // …and below the clock's baseline (rows grow downward in the captured image), never over the glyphs.
        XCTAssertGreaterThanOrEqual(redTop, whiteBottom, "marker top \(redTop) vs clock bottom \(whiteBottom)")
    }

    /// 28.4 display fit (user decision: default "automatic"). A canvas whose shape differs a lot from the display is
    /// shown whole with bars; "fill" crops it to fill like Wallpaper Engine. Workshop 3814497358 (a portrait scene on
    /// a landscape display) otherwise lost its clock and audio bars off-screen.
    func testDisplayFitDecision() {
        let mac = CGSize(width: 3024, height: 1964)
        XCTAssertFalse(SceneDisplayFit.automatic.letterboxes(canvas: CGSize(width: 3840, height: 2160), viewport: mac),
                       "16:9 on 16:10 fills like Wallpaper Engine")
        XCTAssertTrue(SceneDisplayFit.automatic.letterboxes(canvas: CGSize(width: 1212, height: 2155), viewport: mac),
                      "portrait on landscape shows the whole canvas")
        XCTAssertTrue(SceneDisplayFit.automatic.letterboxes(canvas: CGSize(width: 1920, height: 1080), viewport: CGSize(width: 1080, height: 1920)))
        XCTAssertTrue(SceneDisplayFit.automatic.letterboxes(canvas: CGSize(width: 3440, height: 1440), viewport: CGSize(width: 1280, height: 1024)),
                      "more than a quarter cropped")
        XCTAssertFalse(SceneDisplayFit.automatic.letterboxes(canvas: CGSize(width: 1000, height: 1000), viewport: CGSize(width: 1000, height: 1020)))
        XCTAssertFalse(SceneDisplayFit.fill.letterboxes(canvas: CGSize(width: 1212, height: 2155), viewport: mac))
        XCTAssertTrue(SceneDisplayFit.fit.letterboxes(canvas: CGSize(width: 3840, height: 2160), viewport: mac))
        XCTAssertFalse(SceneDisplayFit.automatic.letterboxes(canvas: .zero, viewport: mac))
        XCTAssertFalse(SceneDisplayFit.automatic.letterboxes(canvas: CGSize(width: CGFloat.nan, height: 1), viewport: mac))
    }

    @MainActor func testDisplayFitLetterboxesOrFillsTheCompleteEngineView() async throws {
        try write("scene.json", ["camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 400, "height": 100], "clearcolor": "0 0 0"],
            "objects": [["id": 1, "name": "Wide", "image": "models/layer.json", "size": "400 100 0",
                         "origin": ["value": "200 50 0", "script": "'use strict';\nexport function update(value) {\n\treturn value;\n}"]]]])
        let runtime = KineticSceneRuntime(root: root)
        defer { runtime.dispose() }
        runtime.displayFit = .fit
        do { try await runtime.prepare() } catch { XCTFail("Wide scene failed: \(error)"); throw error }
        XCTAssertTrue(runtime.usesFullEngine)
        let host = try XCTUnwrap(runtime.fullHostForTesting)
        runtime.play()
        func sample() async throws -> (top: [UInt8], center: [UInt8]) {
            var image: CGImage?
            for _ in 0..<4 {
                try await Task.sleep(nanoseconds: 80_000_000)
                await host.renderFrameNow()
                image = await host.captureFrame() ?? image
            }
            let frame = try XCTUnwrap(image)
            let context = try XCTUnwrap(CGContext(data: nil, width: frame.width, height: frame.height, bitsPerComponent: 8,
                bytesPerRow: frame.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(frame, in: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
            let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
            func pixel(_ y: Int) -> [UInt8] { let i = (y * frame.width + frame.width / 2) * 4; return [data[i], data[i + 1], data[i + 2]] }
            return (pixel(2), pixel(frame.height / 2))
        }
        let fitted = try await sample()
        XCTAssertGreaterThan(fitted.center[0], 200, "the canvas is shown: \(fitted.center)")
        XCTAssertLessThan(fitted.top[0], 40, "a 4:1 canvas leaves bars above and below: \(fitted.top)")
        runtime.displayFit = .fill
        let filled = try await sample()
        XCTAssertGreaterThan(filled.top[0], 200, "fill crops the canvas to cover the view: \(filled.top)")
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
