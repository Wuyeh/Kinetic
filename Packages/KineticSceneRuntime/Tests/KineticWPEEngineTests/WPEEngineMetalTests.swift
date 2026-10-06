// Adapted from macos-wallpaperengine, commit 3f3e2ba (MIT).
// Copyright (c) 2026 Loomscreen contributors. See NOTICE.md / UPSTREAM_LICENSE.txt.
import Metal
import XCTest
@testable import KineticWPEEngine

/// These exercise the compiled package Metal library and real GPU submission,
/// rather than treating successful schema parsing as a rendered scene.
final class WPEEngineMetalTests: XCTestCase {
    func testPackageLibraryRendersOpaqueSolidColor() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let pass = solid(id: "solid.0", color: [1, 0, 0, 1], target: .scene)
        let output = try executor.render(
            pipeline: pipeline([builtin(pass, uniforms: pass.constants)]),
            size: CGSize(width: 4, height: 4), textures: [:])
        try assertPixel(output, expected: [255, 0, 0, 255])
    }

    func testGLSLTranslationCompilesAndChangesTexturePixels() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let key = "materials/base.png"
        let pass = WPERenderPass(
            id: "custom.0", phase: .effect(file: "effects/multiply_red/effect.json"),
            shader: "effects/multiply_red", source: .image(key), target: .scene,
            textures: [0: .image(key)], binds: [:], constants: [:], combos: [:],
            blending: "disabled", cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled")
        let prepared = WPEPreparedRenderPass(
            pass: pass,
            shader: WPEShaderProgram(
                name: pass.shader, vertexSource: "// executor supplies fullscreen vertex stage",
                fragmentSource: """
                uniform sampler2D g_Texture0;
                varying vec2 v_TexCoord;
                void main() {
                    vec4 c = texture(g_Texture0, v_TexCoord);
                    gl_FragColor = vec4(c.r + 1.0, c.g, c.b, c.a);
                }
                """, isBuiltin: false),
            textureBindings: [0: .image(key)], comboValues: [:], uniformValues: [:])
        let input = try texture(device, pixel: [0, 0, 255, 255])
        let output = try executor.render(pipeline: pipeline([prepared]),
                                         size: CGSize(width: 2, height: 2), textures: [key: input])
        try assertPixel(output, expected: [255, 0, 255, 255])
    }

    func testDeclaredFBOWriteIsReadBySubsequentPass() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let fbo = WPERenderFBO(name: "blur_start_2", scale: 1, format: "rgba8888")
        let write = solid(id: "layer.0", color: [0, 1, 0, 1], target: .fbo(name: fbo.name))
        let copy = WPERenderPass(
            id: "layer.1", phase: .command(file: "effects/copy/effect.json"),
            shader: "commands/copy", source: .fbo(fbo.name), target: .scene,
            textures: [0: .fbo(fbo.name)], binds: [:], constants: [:], combos: [:],
            blending: "disabled", cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled")
        let output = try executor.render(
            pipeline: pipeline([builtin(write, uniforms: write.constants),
                                builtin(copy, bindings: [0: .fbo(fbo.name)])], fbos: [fbo]),
            size: CGSize(width: 4, height: 4), textures: [:])
        try assertPixel(output, expected: [0, 255, 0, 255])
    }

    func testHDRReadbackKeepsAlphaAndClampsNaNBeforeByteConversion() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                                  width: 1, height: 1, mipmapped: false)
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let halfs: [UInt16] = [0x3c00, 0, 0x7e00, 0x3800] // 1, 0, NaN, 0.5
        halfs.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: 8)
        }
        XCTAssertEqual(WPEMetalTextureSnapshotter.convertAuthoredHDRToSRGB8(texture), [255, 0, 0, 128])
    }

    private func solid(id: String, color: [Double], target: WPERenderTarget) -> WPERenderPass {
        WPERenderPass(id: id, phase: .material, shader: "solidcolor", source: .previous,
                      target: target, textures: [:], binds: [:], constants: ["g_Color": .vector(color)],
                      combos: [:], blending: "disabled", cullMode: "nocull",
                      depthTest: "disabled", depthWrite: "disabled")
    }

    private func builtin(_ pass: WPERenderPass, bindings: [Int: WPETextureReference] = [:],
                         uniforms: [String: WPESceneShaderConstantValue] = [:]) -> WPEPreparedRenderPass {
        WPEPreparedRenderPass(pass: pass,
                              shader: WPEShaderProgram(name: pass.shader, vertexSource: "",
                                                       fragmentSource: "", isBuiltin: true),
                              textureBindings: bindings, comboValues: [:], uniformValues: uniforms)
    }

    private func pipeline(_ passes: [WPEPreparedRenderPass], fbos: [WPERenderFBO] = []) -> WPEPreparedRenderPipeline {
        let layer = WPERenderLayer(
            objectID: "layer", objectName: "Layer", imagePath: "materials/base.png", materialPath: nil,
            geometry: .identity, compositeA: "_rt_imageLayerComposite_layer_a",
            compositeB: "_rt_imageLayerComposite_layer_b", localFBOs: fbos, passes: passes.map(\.pass))
        return WPEPreparedRenderPipeline(layers: [WPEPreparedRenderLayer(graphLayer: layer, passes: passes)])
    }

    private func texture(_ device: MTLDevice, pixel: [UInt8]) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                                  width: 2, height: 2, mipmapped: false)
        descriptor.usage = [.shaderRead]; descriptor.storageMode = .shared
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let bytes = Array(repeating: pixel, count: 4).flatMap { $0 }
        bytes.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: 8)
        }
        return texture
    }

    private func assertPixel(_ output: MTLTexture, expected: [Int],
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let staged = try XCTUnwrap(WPEMetalTextureSnapshotter.stagedForCPURead(output), file: file, line: line)
        var pixel = [UInt8](repeating: 0, count: 4)
        staged.getBytes(&pixel, bytesPerRow: 4,
                        from: MTLRegionMake2D(staged.width / 2, staged.height / 2, 1, 1), mipmapLevel: 0)
        for (value, expected) in zip(pixel, expected) {
            XCTAssertLessThanOrEqual(abs(Int(value) - expected), 5, "pixel: \(pixel)", file: file, line: line)
        }
    }
}
