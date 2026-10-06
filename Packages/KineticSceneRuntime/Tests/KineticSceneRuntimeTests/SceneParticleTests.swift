import Foundation
import Metal
import XCTest
@testable import KineticSceneRuntime

final class SceneParticleTests: XCTestCase {
    private func definition(_ extra: [String: Any] = [:]) throws -> SceneParticleDefinition {
        var json: [String: Any] = ["material": "material.json", "maxcount": 128,
                                  "emitter": [["name": "sphererandom", "rate": 10]],
                                  "initializer": [["name": "lifetime", "value": 2]], "operator": []]
        json.merge(extra, uniquingKeysWith: { _, value in value })
        return try .parse(SceneJSON.parse(JSONSerialization.data(withJSONObject: json)), limits: .init())
    }
    func testContinuousBirthsAndLifetimeAreDeterministic() throws {
        let particles = try definition()
        XCTAssertEqual(particles.instances(at: 0, seed: 1).count, 0)
        XCTAssertEqual(particles.instances(at: 0.5, seed: 1).count, 5)
        XCTAssertEqual(particles.instances(at: 4, seed: 1).count, 20)
        let a = particles.instances(at: 1, seed: 1), b = particles.instances(at: 1, seed: 1)
        XCTAssertEqual(a.map(\.geometry), b.map(\.geometry)); XCTAssertEqual(a.map(\.color), b.map(\.color))
    }
    func testGravityDragFadeAndPausedTimeDoNotDependOnFrameCount() throws {
        let particles = try definition(["emitter": [["name": "sphererandom", "rate": 0, "instantaneous": 1]],
            "initializer": [["name": "lifetime", "value": 2], ["name": "velocity", "value": "10 0 0"]],
            "operator": [["name": "movement", "gravity": "0 -10 0"], ["name": "alphafade", "fadeintime": 0.5, "fadeouttime": 0.5]]])
        let half = try XCTUnwrap(particles.instances(at: 0.5, seed: 1).first)
        XCTAssertEqual(half.geometry.x, 5, accuracy: 0.001); XCTAssertEqual(half.geometry.y, -1.25, accuracy: 0.001)
        XCTAssertEqual(half.color.w, 1, accuracy: 0.001)
        let late = try XCTUnwrap(particles.instances(at: 1.75, seed: 1).first)
        XCTAssertEqual(late.color.w, 0.5, accuracy: 0.001)
        XCTAssertEqual(particles.instances(at: 0.5, seed: 1).first?.geometry, half.geometry)
        XCTAssertTrue(particles.instances(at: 2, seed: 1).isEmpty)
    }
    func testParticleBudgetsAndUnknownComponentsFailExplicitly() throws {
        for extra: [String: Any] in [["maxcount": 100_000], ["maxcount": 1],
             ["operator": [["name": "unknown"]]], ["initializer": [["name": "unknown"]]],
             ["emitter": [["name": "unknown"]]], ["children": [["name": "child"]]], ["renderer": [["name": "rope"]]]] {
            XCTAssertThrowsError(try definition(extra))
        }
    }
    func testParticleShaderPipelineCompilesWithImageFragment() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let library = try device.makeLibrary(source: SceneShader.vertex + SceneShader.particleVertex + SceneShader.imageFragment, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "sceneParticleVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "sceneFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        XCTAssertNotNil(try device.makeRenderPipelineState(descriptor: descriptor))
    }
}
