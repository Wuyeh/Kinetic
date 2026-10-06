import Foundation
import Metal
import simd
import XCTest
@testable import KineticSceneRuntime

final class ScenePuppetTests: XCTestCase {
    private func word(_ value: UInt32) -> Data { var value = value.littleEndian; return withUnsafeBytes(of: &value) { Data($0) } }
    private func half(_ value: UInt16) -> Data { var value = value.littleEndian; return withUnsafeBytes(of: &value) { Data($0) } }
    private func floats(_ values: [Float]) -> Data { values.reduce(into: Data()) { $0 += word($1.bitPattern) } }
    private func string(_ value: String) -> Data { Data(value.utf8) + Data([0]) }
    private var layer: SceneJSON { .array([.object(["id": .number(1)])]) }
    private func fixture(index: UInt16 = 2, parent: UInt32 = UInt32.max, boneIndex: UInt32 = 0, animation: Bool = true) -> Data {
        var data = string("MDLV0017") + word(0) + word(1) + word(1)
        data += string("material.json") + word(0) + floats([-16,-16,0,16,16,0]) + word(0x1800008)
        var vertices = Data()
        for point: [Float] in [[-16,-16,0], [16,-16,0], [0,16,0]] {
            vertices += floats(point) + word(boneIndex) + word(0) + word(0) + word(0) + floats([1,0,0,0,0.5,0.5])
        }
        data += word(UInt32(vertices.count)) + vertices + word(6) + half(0) + half(1) + half(index)
        let skeletonStart = data.count
        var skeleton = string("MDLS0001") + word(0) + half(1) + half(0)
        skeleton += string("root") + word(0) + word(parent) + word(64) +
            floats([1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]) + string("")
        skeleton.replaceSubrange(9..<13, with: word(UInt32(skeletonStart + skeleton.count)))
        data += skeleton
        if animation {
            let animationStart = data.count
            var block = string("MDLA0001") + word(0) + word(1)
            block += word(1) + word(0) + string("move") + string("loop") + floats([1]) + word(2) + word(0) + word(1)
            block += word(0) + word(108)
            for translation: Float in [0,10,0] { block += floats([translation,0,0,0,0,0,1,1,1]) }
            block += word(0)
            block.replaceSubrange(9..<13, with: word(UInt32(animationStart + block.count)))
            data += block
        }
        return data
    }
    func testBinaryMeshBoneAndInterpolatedAnimation() throws {
        let puppet = try ScenePuppet.parse(fixture(), animationLayers: layer, limits: .init())
        XCTAssertEqual(puppet.meshes.count, 1); XCTAssertEqual(puppet.meshes[0].indices, [0,1,2])
        XCTAssertEqual(puppet.bones.count, 1)
        XCTAssertEqual(try puppet.palette(at: 0)[0].columns.3.x, 0, accuracy: 0.001)
        XCTAssertEqual(try puppet.palette(at: 0.5)[0].columns.3.x, 5, accuracy: 0.001)
        XCTAssertEqual(try puppet.palette(at: 1)[0].columns.3.x, 10, accuracy: 0.001)
        XCTAssertEqual(try puppet.palette(at: 2)[0].columns.3.x, 0, accuracy: 0.001)
    }
    func testTruncationBadIndexBoneAndParentFail() {
        for data in [Data(fixture().prefix(25)), fixture(index: 4), fixture(parent: 0), fixture(boneIndex: 9)] {
            XCTAssertThrowsError(try ScenePuppet.parse(data, animationLayers: layer, limits: .init()))
        }
    }
    func testOversizedGeometryAndUnimplementedAnimationFail() {
        var limits = SceneLimits(); limits.maximumPuppetVertices = 2
        XCTAssertThrowsError(try ScenePuppet.parse(fixture(), animationLayers: layer, limits: limits))
        XCTAssertThrowsError(try ScenePuppet.parse(fixture(), animationLayers: .array([.object(["id": .number(99)])]), limits: .init()))
        XCTAssertThrowsError(try ScenePuppet.parse(fixture(), animationLayers: .array([.object(["id": .number(1), "additive": .bool(true)])]), limits: .init()))
    }
    func testPuppetGPUBufferLayoutAndPipeline() throws {
        XCTAssertEqual(MemoryLayout<ScenePuppetVertex>.stride, 64)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let library = try device.makeLibrary(source: SceneShader.vertex + SceneShader.particleVertex + SceneShader.puppetVertex + SceneShader.imageFragment, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "scenePuppetVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "sceneFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        XCTAssertNotNil(try device.makeRenderPipelineState(descriptor: descriptor))
    }

    func testPuppetInvalidTimeAndComposedAnimatedOverflowAreRejected() throws {
        let original = try ScenePuppet.parse(fixture(), animationLayers: layer, limits: .init())
        for time: Double in [.infinity, .nan, -1] { XCTAssertThrowsError(try original.palette(at: time)) }
        let bones: [ScenePuppet.Bone] = (0..<14).map { .init(parent: $0 == 0 ? nil : $0 - 1, bind: matrix_identity_float4x4) }
        let key = ScenePuppet.Key(translation: .zero, rotation: .init(angle: 0, axis: .init(0,0,1)), scale: .init(repeating: 1000))
        let animation = ScenePuppet.Animation(id: 1, fps: 1, frames: 1,
            channels: Array(repeating: [key, key], count: bones.count))
        let puppet = ScenePuppet(meshes: original.meshes, bones: bones, animations: [animation],
            inverseWorldBind: Array(repeating: matrix_identity_float4x4, count: bones.count), animationID: 1, speed: 1)
        XCTAssertThrowsError(try puppet.palette(at: 0)) { XCTAssertTrue($0 is SceneRuntimeError) }
    }
}
