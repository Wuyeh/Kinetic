import AppKit
import KineticSceneRuntime
import XCTest
@testable import Kinetic

@MainActor private final class PropertyHost: DesktopContentHost {
    var content: NSView?
    func present(_ contentView: NSView) -> Bool { content = contentView; return true }
    func stop() { content = nil }
}
@MainActor private final class PropertyRenderer: WallpaperRenderer {
    let wallpaper: Wallpaper
    let displayView = NSView()
    var onFailure: (@MainActor (Error) -> Void)?
    var fail = false
    init(_ wallpaper: Wallpaper) { self.wallpaper = wallpaper }
    func prepare() async throws { if fail { throw ScenePropertyStoreError.incompatiblePreset } }
    func play() {}
    func pause() {}
    func resume() {}
    func setMuted(_ muted: Bool) {}
    func dispose() {}
}

final class ScenePropertyStoreTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = TestWorkspaceDirectory.make(".build/Module29/StoreFixtures")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let root { try FileManager.default.removeItem(at: root) } }
    private func wallpaper(_ workshopID: String? = nil) -> Wallpaper {
        Wallpaper(name: "场景", type: .scene, source: .local, resourceURL: root,
                  steamMetadata: workshopID.map { SteamMetadata(workshopID: $0) })
    }
    private func schema() throws -> ScenePropertySchema {
        try ScenePropertySchema(data: Data(#"{"type":"scene","general":{"properties":{"shown":{"type":"bool","value":true},"speed":{"type":"slider","min":0,"max":10,"value":1},"header":{"type":"group"}}}}"#.utf8))
    }
    @MainActor func testPersistencePresetCRUDAndDefaultReset() throws {
        let storage = LibraryStorageLocation(rootURL: root), wallpaper = wallpaper(), schema = try schema()
        let store = ScenePropertyStore(storage: storage)
        try store.save(values: ["speed": .number(2)], for: wallpaper, schema: schema, runtime: nil)
        let id = try store.createPreset(name: "慢", values: ["speed": .number(2)], for: wallpaper, schema: schema)
        try store.renamePreset(id, name: "晚间", for: wallpaper)
        let restored = ScenePropertyStore(storage: storage)
        XCTAssertNil(restored.loadError)
        XCTAssertEqual(restored.configuration(for: wallpaper.id).values, ["speed": .number(2)])
        XCTAssertEqual(restored.configuration(for: wallpaper.id).presets.first?.name, "晚间")
        try restored.save(values: [:], for: wallpaper, schema: schema, runtime: nil)
        XCTAssertTrue(restored.configuration(for: wallpaper.id).values.isEmpty)
        XCTAssertEqual(restored.configuration(for: wallpaper.id).presets.count, 1)
        try restored.deletePreset(id, for: wallpaper)
        XCTAssertTrue(ScenePropertyStore(storage: storage).configuration(for: wallpaper.id).presets.isEmpty)
    }
    @MainActor func testOwnPresetRoundTripAndWrongIdentityRejected() throws {
        let store = ScenePropertyStore(storage: .init(rootURL: root)), wallpaper = wallpaper(), schema = try schema()
        let data = try ScenePropertyStore.exportPreset(name: "夜间", values: ["shown": .bool(false)], for: wallpaper, schema: schema)
        let id = try store.importPreset(data: data, for: wallpaper, schema: schema)
        XCTAssertEqual(store.configuration(for: wallpaper.id).presets.first?.id, id)
        XCTAssertThrowsError(try store.importPreset(data: data, for: self.wallpaper(), schema: schema))
        XCTAssertEqual(store.configuration(for: wallpaper.id).values, [:], "import is not an implicit Apply")
    }
    @MainActor func testCommunityPresetOnlyMatchesBaseAndValidatesEveryValue() throws {
        let store = ScenePropertyStore(storage: .init(rootURL: root)), wallpaper = wallpaper("123456"), schema = try schema()
        let data = Data(#"{"type":"scene","dependency":"123456","title":"社区","preset":{"speed":2,"header":""}}"#.utf8)
        try store.importPreset(data: data, for: wallpaper, schema: schema)
        XCTAssertEqual(store.configuration(for: wallpaper.id).presets.first?.values, ["speed": .number(2)])
        XCTAssertThrowsError(try store.importPreset(data: data, for: self.wallpaper("654321"), schema: schema))
        let unsafe = Data(#"{"type":"scene","dependency":"123456","title":"社区","preset":{"speed":999}}"#.utf8)
        XCTAssertThrowsError(try store.importPreset(data: unsafe, for: wallpaper, schema: schema))
        XCTAssertEqual(store.configuration(for: wallpaper.id).presets.count, 1)
    }
    @MainActor func testFailedValidationAndFailedWriteDoNotPublish() throws {
        let store = ScenePropertyStore(storage: .init(rootURL: root)), wallpaper = wallpaper(), schema = try schema()
        try store.save(values: ["speed": .number(1)], for: wallpaper, schema: schema, runtime: nil)
        let oldData = try Data(contentsOf: store.fileURL)
        XCTAssertThrowsError(try store.save(values: ["speed": .number(99)], for: wallpaper, schema: schema, runtime: nil))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), oldData)
        try FileManager.default.removeItem(at: store.fileURL)
        try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.save(values: ["speed": .number(3)], for: wallpaper, schema: schema, runtime: nil))
        XCTAssertEqual(store.configuration(for: wallpaper.id).values, ["speed": .number(1)])
    }
    @MainActor func testCorruptedDocumentRemainsUntouchedAndBlocksWrites() throws {
        let url = root.appendingPathComponent("scene-properties.json"), data = Data("broken".utf8)
        try data.write(to: url)
        let store = ScenePropertyStore(storage: .init(rootURL: root))
        XCTAssertNotNil(store.loadError)
        XCTAssertThrowsError(try store.createPreset(name: "x", values: [:], for: wallpaper(), schema: schema()))
        XCTAssertEqual(try Data(contentsOf: url), data)
    }
    @MainActor func testSizeAndNameBudgets() throws {
        let store = ScenePropertyStore(storage: .init(rootURL: root)), wallpaper = wallpaper(), schema = try schema()
        XCTAssertThrowsError(try store.createPreset(name: " ", values: [:], for: wallpaper, schema: schema))
        XCTAssertThrowsError(try store.createPreset(name: String(repeating: "x", count: 81), values: [:], for: wallpaper, schema: schema))
        XCTAssertThrowsError(try store.importPreset(data: Data(repeating: 0, count: ScenePropertyStore.maximumPresetBytes + 1), for: wallpaper, schema: schema))
    }
    func testReloadEventKeepsOrdinaryApplyIdempotentAndProtectsOtherCandidate() {
        let a = UUID(), b = UUID()
        var machine = WallpaperRuntimeMachine()
        _ = machine.handle(.apply(a)); _ = machine.handle(.preparationSucceeded(a))
        XCTAssertEqual(machine.handle(.apply(a)), [])
        _ = machine.handle(.pause)
        XCTAssertEqual(machine.handle(.reloadActive(a)), [.prepareCandidate(a)])
        XCTAssertEqual(machine.handle(.reloadActive(a)), [.discardCandidate, .prepareCandidate(a)])
        _ = machine.handle(.preparationSucceeded(a))
        XCTAssertEqual(machine.playbackState, .manualPaused)
        _ = machine.handle(.apply(b))
        XCTAssertEqual(machine.handle(.reloadActive(a)), [])
        XCTAssertEqual(machine.candidateWallpaperID, b)
        _ = machine.handle(.stop)
        XCTAssertEqual(machine.handle(.reloadActive(a)), [])
        XCTAssertEqual(machine.playbackState, .stopped)
    }
    func testSmartPauseSurvivesSettingsReloadAndFailure() {
        let a = UUID()
        var machine = WallpaperRuntimeMachine()
        _ = machine.handle(.apply(a)); _ = machine.handle(.preparationSucceeded(a))
        _ = machine.handle(.smartPauseChanged(true))
        _ = machine.handle(.reloadActive(a)); _ = machine.handle(.preparationFailed(a))
        XCTAssertEqual(machine.playbackState, .smartPaused)
        XCTAssertEqual(machine.activeWallpaperID, a)
        _ = machine.handle(.reloadActive(a)); _ = machine.handle(.preparationSucceeded(a))
        XCTAssertEqual(machine.playbackState, .smartPaused)
    }
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !condition() {
            if ProcessInfo.processInfo.systemUptime > deadline { XCTFail("session timeout"); throw CancellationError() }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    @MainActor func testApplyScopePauseIntentAndFailedReplacementKeepOldFrame() async throws {
        let store = ScenePropertyStore(storage: .init(rootURL: root)), wallpaper = wallpaper(), other = self.wallpaper(), schema = try schema()
        let a = DisplayID("properties-A"), b = DisplayID("properties-B"), c = DisplayID("properties-C")
        let hostA = PropertyHost(), hostB = PropertyHost(), hostC = PropertyHost()
        var creations: [Wallpaper.ID] = [], fail = false
        let runtime = WallpaperRuntimeManager { wallpaper in
            creations.append(wallpaper.id)
            let renderer = PropertyRenderer(wallpaper); renderer.fail = fail; return renderer
        }
        defer { runtime.shutdown() }
        runtime.addDisplay(a, host: hostA); runtime.addDisplay(b, host: hostB); runtime.addDisplay(c, host: hostC)
        runtime.apply(wallpaper, to: a); runtime.apply(other, to: b); runtime.apply(wallpaper, to: c)
        try await wait { runtime.activeWallpaper(on: a) != nil && runtime.activeWallpaper(on: b) != nil && runtime.activeWallpaper(on: c) != nil }
        runtime.pause(.display(a)); runtime.stop(.display(c))
        let bView = hostB.content, oldA = hostA.content
        creations = []; fail = true
        try store.save(values: ["speed": .number(2)], for: wallpaper, schema: schema, runtime: runtime)
        try await wait { runtime.lastFailure != nil }
        XCTAssertEqual(creations, [wallpaper.id])
        XCTAssertTrue(hostA.content === oldA); XCTAssertTrue(hostB.content === bView); XCTAssertNil(hostC.content)
        XCTAssertEqual(runtime.state(of: a)?.playbackState, .manualPaused)
        fail = false
        try store.save(values: ["speed": .number(3)], for: wallpaper, schema: schema, runtime: runtime)
        try await wait { hostA.content !== oldA }
        XCTAssertEqual(runtime.state(of: a)?.playbackState, .manualPaused)
        XCTAssertTrue(hostB.content === bView); XCTAssertNil(hostC.content)
    }
}
