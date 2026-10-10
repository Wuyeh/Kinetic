import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@_spi(KineticTesting) import KineticWPEEngine
@testable import KineticSceneRuntime

/// Explicit, local-only acceptance against a user-supplied wallpaper; never bundles the material.
final class SceneAudioAcceptanceTests: XCTestCase {
    @MainActor func testUserWallpaperUsesHostSpectrumWithoutRestart() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["KINETIC_AUDIO_WALLPAPER_ROOT"], let output = env["KINETIC_AUDIO_QA_OUTPUT"] else {
            throw XCTSkip("Explicit user-wallpaper acceptance only")
        }
        let root = URL(fileURLWithPath: path), destination = URL(fileURLWithPath: output)
        guard root.lastPathComponent == "3147346398" else { throw XCTSkip("Bar-region acceptance is specific to the user-provided wallpaper") }
        let assets = env["KINETIC_AUDIO_ENGINE_ASSETS"].map { URL(fileURLWithPath: $0) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("scene.pkg").path))
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        SceneExternalInputs.publishSystemAudio(nil)
        SceneExternalInputs.publishMedia(playing: true, title: "Kinetic Audio Acceptance", artist: "Test", duration: 100, position: 20)
        let runtime = KineticSceneRuntime(root: root, engineAssets: assets)
        runtime.displayView.frame = CGRect(x: 0, y: 0, width: 768, height: 432)
        runtime.displayView.layoutSubtreeIfNeeded()
        do {
            try await runtime.prepare()
            let host = try XCTUnwrap(runtime.fullHostForTesting)
            runtime.play()
            await runtime.setPreviewFrameRateCeiling(30)
            var barPixels = [String: Int]()
            func save(_ name: String) async throws {
                try await Task.sleep(nanoseconds: 400_000_000)
                await host.renderFrameNow()
                let captured = await runtime.capturePreviewFrame()
                let frame = try XCTUnwrap(captured)
                let encoder = try XCTUnwrap(CGImageDestinationCreateWithURL(destination.appendingPathComponent(name + ".png") as CFURL,
                    UTType.png.identifier as CFString, 1, nil))
                CGImageDestinationAddImage(encoder, frame, nil)
                XCTAssertTrue(CGImageDestinationFinalize(encoder))
                let context = try XCTUnwrap(CGContext(data: nil, width: frame.width, height: frame.height, bitsPerComponent: 8,
                    bytesPerRow: frame.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(frame, in: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
                let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
                var count = 0
                // Authored white frequency bars occupy the bottom centre, distinct from the changing room lighting.
                for y in Int(Double(frame.height) * 0.92)..<frame.height {
                    for x in Int(Double(frame.width) * 0.3)..<Int(Double(frame.width) * 0.7) {
                        let i = (y * frame.width + x) * 4
                        let channels = [Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2])]
                        if channels.min()! > 8, channels.max()! - channels.min()! < 6 { count += 1 }
                    }
                }
                barPixels[name] = count
            }
            try await save("silent")
            let time = runtime.sceneTime
            let bands = (0..<64).map { Float(0.2 + 0.6 * abs(sin(Double($0) * 0.3))) }
            SceneExternalInputs.publishSystemAudio(try .init(left: bands, right: bands))
            try await save("spectrum")
            SceneExternalInputs.publishSystemAudio(nil)
            try await save("silent-again")
            XCTAssertGreaterThan(barPixels["spectrum"]!, max(barPixels["silent"]!, barPixels["silent-again"]!) + 100,
                                 "Actual author's white bars respond and return to flat: \(barPixels)")
            XCTAssertTrue(runtime.fullHostForTesting === host)
            XCTAssertGreaterThan(runtime.sceneTime, time)
            XCTAssertEqual(host.health.gpuErrorCount, 0)
            try JSONSerialization.data(withJSONObject: ["whiteBarPixels": barPixels, "sameHost": true,
                "continuousClock": true, "shaderSkips": host.health.skippedShaderCount, "input": "synthetic spectrum, not live capture"], options: [.prettyPrinted, .sortedKeys])
                .write(to: destination.appendingPathComponent("bar-response.json"))
            print("KAUDIO_SCENE fullEngine=\(runtime.usesFullEngine) shaderSkips=\(host.health.skippedShaderCount) clockContinuous=true")
            await runtime.disposeAwaitingResources()
        } catch {
            await runtime.disposeAwaitingResources()
            SceneExternalInputs.publishSystemAudio(nil)
            SceneExternalInputs.publishMedia(playing: false, title: nil)
            throw error
        }
        SceneExternalInputs.publishSystemAudio(nil)
        SceneExternalInputs.publishMedia(playing: false, title: nil)
    }
}
