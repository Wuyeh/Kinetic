import Foundation
import XCTest
@testable import KineticWPEEngine

final class WPEEngineBoundaryTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        folder = package.appendingPathComponent(".build/TestFixtures/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let folder { try FileManager.default.removeItem(at: folder) }
    }

    private var payload: WPEShaderTranslationCache.Payload {
        .init(schemaVersion: WPEShaderTranslationCache.schemaVersion,
              vertexFunctionName: "vertex", fragmentFunctionName: "fragment", mslSource: "test",
              uniformLayout: [], samplerNames: [], textureSlotCount: 0)
    }

    func testDefaultShaderCacheIsMemoryOnly() {
        let cache = WPEShaderTranslationCache()
        let key = UUID().uuidString
        cache.store(payload, for: key)
        XCTAssertEqual(cache.lookup(key), payload)
        cache.dropMemoryForTesting()
        XCTAssertNil(cache.lookup(key), "An engine with no host-owned root must not write a disk cache.")
        cache.remove(key)
    }

    func testExplicitShaderCacheRootSurvivesRestartAndHashesKeys() throws {
        let key = "../../" + UUID().uuidString
        let cache = WPEShaderTranslationCache(rootURL: folder)
        cache.store(payload, for: key)
        let restarted = WPEShaderTranslationCache(rootURL: folder)
        XCTAssertEqual(restarted.lookup(key), payload)
        let schema = folder.appendingPathComponent("v\(WPEShaderTranslationCache.schemaVersion)")
        let files = try FileManager.default.contentsOfDirectory(at: schema, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.deletingPathExtension().lastPathComponent.count, 64)
        restarted.remove(key)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: schema.path).isEmpty)
    }

    func testDisabledDiskCacheDoesNotPruneOrWriteHostDirectory() throws {
        let old = folder.appendingPathComponent("v0/keep.txt")
        try FileManager.default.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: old)
        let cache = WPEShaderTranslationCache(rootURL: folder, diskByteLimit: 0)
        cache.store(payload, for: "test")
        cache.remove("test")
        cache.dropMemoryForTesting()
        XCTAssertNil(cache.lookup("test"))
        XCTAssertEqual(try Data(contentsOf: old), Data([1]))
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            folder.appendingPathComponent("v\(WPEShaderTranslationCache.schemaVersion)").path))
    }

    func testActorJobsUseRenderThreadAndShutdownReleasesIt() async {
        let actor = WPEDisplayRenderActor(label: "com.kinetic.scene.engine-test")
        let allOnRenderThread = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<64 {
                group.addTask { await actor.run { $0.isOnRenderThread && !Thread.isMainThread } }
            }
            var valid = true
            for await value in group { valid = valid && value }
            return valid
        }
        XCTAssertTrue(allOnRenderThread)
        let stopped = await actor.shutdown()
        XCTAssertTrue(stopped)
    }
}
