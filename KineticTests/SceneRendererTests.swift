import AppKit
import KineticSceneRuntime
import XCTest
@testable import Kinetic

@MainActor
private final class SceneTestHost: DesktopContentHost {
    var content: NSView?
    func present(_ contentView: NSView) -> Bool { content = contentView; return true }
    func stop() { content = nil }
}

final class SceneRendererTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = TestWorkspaceDirectory.make(".build/Module27-28/AdapterFixtures")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let root { try FileManager.default.removeItem(at: root) } }
    private func fixtures() throws -> (Wallpaper, Wallpaper, Wallpaper) {
        let projects = try SceneAcceptanceFixtures.create(in: root)
        return (Wallpaper(name: "warm", type: .scene, source: .local, resourceURL: projects.warm),
                Wallpaper(name: "cool", type: .scene, source: .local, resourceURL: projects.cool),
                Wallpaper(name: "invalid", type: .scene, source: .local, resourceURL: projects.invalid))
    }
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while !condition() {
            if ProcessInfo.processInfo.systemUptime > deadline { XCTFail("Scene runtime timeout"); throw CancellationError() }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    @MainActor func testAdapterFirstFrameAndCommonLifecycle() async throws {
        let (warm, _, _) = try fixtures()
        let renderer = SceneRenderer(wallpaper: warm)
        try await renderer.prepare()
        XCTAssertNotNil(renderer.scene.preparedFrame); XCTAssertFalse(renderer.scene.isPlaying)
        renderer.play(); XCTAssertTrue(renderer.scene.isPlaying)
        renderer.pause(); XCTAssertFalse(renderer.scene.isPlaying); XCTAssertNotNil(renderer.scene.preparedFrame)
        renderer.resume(); renderer.setMuted(false); XCTAssertFalse(renderer.scene.isMuted)
        renderer.dispose(); renderer.dispose(); XCTAssertTrue(renderer.scene.isDisposed)
    }
    @MainActor func testWrongTypeRejected() async throws {
        let (warm, _, _) = try fixtures()
        let wallpaper = Wallpaper(name: "wrong", type: .video, source: .local, resourceURL: warm.resourceURL)
        let renderer = SceneRenderer(wallpaper: wallpaper)
        defer { renderer.dispose() }
        do { try await renderer.prepare(); XCTFail("wrong type accepted") } catch {}
        XCTAssertFalse(renderer.scene.isPrepared)
    }
    @MainActor func testPortedGraphThroughExistingSessionAndFailedReplacementRetainsIt() async throws {
        let fixtures = try XCTUnwrap(Bundle.main.url(forResource: "scene-graph-sample", withExtension: nil, subdirectory: "Fixtures"))
        let warm = Wallpaper(name: "extended warm", type: .scene, source: .local, resourceURL: fixtures.appendingPathComponent("warm"))
        let invalid = Wallpaper(name: "extended missing", type: .scene, source: .local, resourceURL: fixtures.appendingPathComponent("invalid"))
        let host = SceneTestHost()
        let runtime = WallpaperRuntimeManager(desktop: host, makeRenderer: { SceneRenderer(wallpaper: $0, engineAssets: nil) })
        defer { runtime.shutdown() }
        runtime.apply(warm)
        try await wait { runtime.state.activeWallpaperID == warm.id }
        let old = try XCTUnwrap(host.content)
        XCTAssertEqual(runtime.state.playbackState, .playing)
        runtime.pause(); XCTAssertEqual(runtime.state.playbackState, .manualPaused)
        runtime.resume(); XCTAssertEqual(runtime.state.playbackState, .playing)
        runtime.apply(invalid)
        try await wait { runtime.lastFailure != nil }
        XCTAssertTrue(old === host.content); XCTAssertEqual(runtime.state.activeWallpaperID, warm.id)
        runtime.stop(); XCTAssertNil(host.content)
    }
    /// Module 28.3: scripted + effect + particle scenes reach the complete engine (SceneScript through
    /// JavaScriptCore) via the existing per-display session; a missing required model keeps the old wallpaper.
    @MainActor func testCompleteEngineSceneThroughExistingSessionAndMissingModelRetainsIt() async throws {
        let fixtures = try XCTUnwrap(Bundle.main.url(forResource: "scene-full-sample", withExtension: nil, subdirectory: "Fixtures"))
        let warm = Wallpaper(name: "complete warm", type: .scene, source: .local, resourceURL: fixtures.appendingPathComponent("warm"))
        let cool = Wallpaper(name: "complete cool", type: .scene, source: .local, resourceURL: fixtures.appendingPathComponent("cool"))
        let invalid = Wallpaper(name: "complete missing", type: .scene, source: .local, resourceURL: fixtures.appendingPathComponent("invalid"))
        let host = SceneTestHost()
        var renderers: [Wallpaper.ID: SceneRenderer] = [:]
        let runtime = WallpaperRuntimeManager(desktop: CrossfadeDesktopHost(desktop: host), makeRenderer: { wallpaper in
            let renderer = SceneRenderer(wallpaper: wallpaper, engineAssets: nil)
            renderers[wallpaper.id] = renderer
            return renderer
        })
        defer { runtime.shutdown() }
        runtime.apply(warm)
        try await wait { runtime.state.activeWallpaperID == warm.id }
        let first = try XCTUnwrap(renderers[warm.id])
        XCTAssertTrue(first.scene.usesFullEngine, "warm fixture must reach the complete engine tier")
        XCTAssertNotNil(first.scene.preparedFrame)
        XCTAssertTrue(first.scene.isPlaying); XCTAssertEqual(runtime.state.playbackState, .playing)
        let old = try XCTUnwrap(host.content)
        runtime.pause(); XCTAssertEqual(runtime.state.playbackState, .manualPaused); XCTAssertFalse(first.scene.isPlaying)
        runtime.resume(); XCTAssertEqual(runtime.state.playbackState, .playing); XCTAssertTrue(first.scene.isPlaying)
        runtime.apply(invalid)
        try await wait { runtime.lastFailure != nil }
        XCTAssertTrue(old === host.content); XCTAssertEqual(runtime.state.activeWallpaperID, warm.id)
        let detail = runtime.lastFailure?.detail ?? ""
        XCTAssertTrue(detail.contains("missing-full-engine-panel"), detail)
        let hint = String(SceneRendererError.engineAssetsRequired("").localizedDescription.prefix(10))
        XCTAssertTrue(detail.hasPrefix(hint), "Without engine assets the failure says where to add them: \(detail)")
        try await wait { renderers[invalid.id]?.scene.isDisposed == true }
        runtime.apply(cool)
        try await wait { runtime.state.activeWallpaperID == cool.id }
        XCTAssertTrue(try XCTUnwrap(renderers[cool.id]).scene.usesFullEngine)
        XCTAssertEqual(runtime.state.playbackState, .playing)
        runtime.stop(); XCTAssertNil(host.content)
    }
    /// 28.4：设置 › 播放 › 场景壁纸显示方式作用于新建的场景，并立即更新正在显示的场景。
    @MainActor func testDisplayFitSettingReachesNewAndShowingScenes() {
        let original = SceneRenderer.displayFit
        defer { SceneRenderer.applyDisplayFit(original) }
        let wallpaper = Wallpaper(name: "fit", type: .scene, source: .local,
                                  resourceURL: FileManager.default.temporaryDirectory.appendingPathComponent("no-scene-\(UUID().uuidString)"))
        SceneRenderer.applyDisplayFit(.fit)
        let renderer = SceneRenderer(wallpaper: wallpaper, engineAssets: nil)
        defer { renderer.dispose() }
        XCTAssertEqual(renderer.scene.displayFit, .fit)
        SceneRenderer.applyDisplayFit(.fill)
        XCTAssertEqual(renderer.scene.displayFit, .fill)
        XCTAssertEqual(SceneDisplayFit(SceneDisplayFitSetting.automatic), .automatic)
        XCTAssertEqual(SceneDisplayFit(SceneDisplayFitSetting.fit), .fit)
    }
    /// 28.4：缺少创意工坊依赖项时，错误按编号说明并指向 设置 › Steam（与是否设置引擎素材无关），旧壁纸保留。
    @MainActor func testMissingWorkshopDependencyPointsToSteamSettings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KineticDependencyScene-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["type": "scene", "file": "scene.json", "dependencies": ["4402"]])
            .write(to: root.appendingPathComponent("project.json"))
        try JSONSerialization.data(withJSONObject: ["camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 64, "height": 64]], "objects": [[String: Any]]()])
            .write(to: root.appendingPathComponent("scene.json"))
        let wallpaper = Wallpaper(name: "needs 4402", type: .scene, source: .local, resourceURL: root)
        for assets in [nil, FileManager.default.temporaryDirectory] as [URL?] {
            let renderer = SceneRenderer(wallpaper: wallpaper, engineAssets: assets)
            defer { renderer.dispose() }
            do { try await renderer.prepare(); XCTFail("A missing dependency was rendered around") }
            catch let error as SceneRendererError {
                XCTAssertEqual(error, .workshopDependencyMissing("4402"))
                let text = error.localizedDescription
                XCTAssertTrue(text.contains("4402") && text.contains("Steam"), text)
            }
        }
        XCTAssertEqual(KineticSceneRuntime.missingDependencyID(inDetail: KineticSceneRuntime.missingDependencyDetail("4402")), "4402")
        XCTAssertNil(KineticSceneRuntime.missingDependencyID(inDetail: "models/util/composelayer.json"))
        XCTAssertNil(KineticSceneRuntime.missingDependencyID(inDetail: KineticSceneRuntime.missingDependencyDetail("../x")))
    }
    /// Two displays each own a complete-engine scene (own render thread / host); pausing or stopping one
    /// leaves the other playing.
    @MainActor func testTwoDisplaysRunSeparateCompleteEngineScenes() async throws {
        let fixtures = try XCTUnwrap(Bundle.main.url(forResource: "scene-full-sample", withExtension: nil, subdirectory: "Fixtures"))
        let warm = Wallpaper(name: "complete warm", type: .scene, source: .local, resourceURL: fixtures.appendingPathComponent("warm"))
        let cool = Wallpaper(name: "complete cool", type: .scene, source: .local, resourceURL: fixtures.appendingPathComponent("cool"))
        let first = SceneTestHost(), second = SceneTestHost(), a = DisplayID("full-A"), b = DisplayID("full-B")
        var renderers: [Wallpaper.ID: SceneRenderer] = [:]
        let runtime = WallpaperRuntimeManager { wallpaper in
            let renderer = SceneRenderer(wallpaper: wallpaper, engineAssets: nil)
            renderers[wallpaper.id] = renderer
            return renderer
        }
        defer { runtime.shutdown() }
        runtime.addDisplay(a, host: CrossfadeDesktopHost(desktop: first))
        runtime.addDisplay(b, host: CrossfadeDesktopHost(desktop: second))
        runtime.apply(warm, to: a); runtime.apply(cool, to: b)
        try await wait { runtime.state(of: a)?.activeWallpaperID == warm.id && runtime.state(of: b)?.activeWallpaperID == cool.id }
        let left = try XCTUnwrap(renderers[warm.id]), right = try XCTUnwrap(renderers[cool.id])
        XCTAssertTrue(left.scene.usesFullEngine); XCTAssertTrue(right.scene.usesFullEngine)
        XCTAssertTrue(left.scene.isPlaying); XCTAssertTrue(right.scene.isPlaying)
        runtime.pause(.display(a)); XCTAssertFalse(left.scene.isPlaying); XCTAssertTrue(right.scene.isPlaying)
        runtime.resume(.display(a)); XCTAssertTrue(left.scene.isPlaying)
        runtime.setAudioEnabled(true); XCTAssertFalse(left.scene.isMuted); XCTAssertFalse(right.scene.isMuted)
        runtime.setAudioEnabled(false); XCTAssertTrue(left.scene.isMuted)
        runtime.stop(.display(a))
        XCTAssertNil(first.content); XCTAssertNotNil(second.content); XCTAssertTrue(right.scene.isPlaying)
        try await wait { left.scene.isDisposed }
        XCTAssertEqual(runtime.state(of: b)?.playbackState, .playing)
    }
    @MainActor func testSceneThroughExistingRuntimeAndFailureRetainsOldSurface() async throws {
        let (warm, _, invalid) = try fixtures()
        let host = SceneTestHost()
        let runtime = WallpaperRuntimeManager(desktop: CrossfadeDesktopHost(desktop: host), makeRenderer: { SceneRenderer(wallpaper: $0) })
        defer { runtime.shutdown() }
        runtime.apply(warm); try await wait { runtime.state.activeWallpaperID == warm.id }
        let old = host.content
        XCTAssertNotNil(old); XCTAssertEqual(runtime.state.playbackState, .playing)
        runtime.apply(invalid); try await wait { runtime.lastFailure != nil }
        XCTAssertTrue(old === host.content); XCTAssertEqual(runtime.state.activeWallpaperID, warm.id)
        XCTAssertTrue(runtime.lastFailure?.detail.contains("missing-engine-resource") == true)
        runtime.pause(); XCTAssertEqual(runtime.state.playbackState, .manualPaused)
        runtime.resume(); XCTAssertEqual(runtime.state.playbackState, .playing)
        runtime.stop(); XCTAssertNil(host.content)
    }
    @MainActor func testTwoDisplaysOwnSeparateSceneInstances() async throws {
        let (warm, cool, _) = try fixtures()
        let first = SceneTestHost(), second = SceneTestHost(), a = DisplayID("scene-A"), b = DisplayID("scene-B")
        var renderers: [SceneRenderer] = []
        let runtime = WallpaperRuntimeManager { wallpaper in
            let renderer = SceneRenderer(wallpaper: wallpaper); renderers.append(renderer); return renderer
        }
        defer { runtime.shutdown() }
        runtime.addDisplay(a, host: CrossfadeDesktopHost(desktop: first)); runtime.addDisplay(b, host: CrossfadeDesktopHost(desktop: second))
        runtime.apply(warm, to: a); runtime.apply(cool, to: b)
        try await wait { runtime.state(of: a)?.activeWallpaperID == warm.id && runtime.state(of: b)?.activeWallpaperID == cool.id }
        runtime.pause(.display(a)); XCTAssertFalse(renderers[0].scene.isPlaying); XCTAssertTrue(renderers[1].scene.isPlaying)
        runtime.setAudioEnabled(true); XCTAssertTrue(renderers.allSatisfy { !$0.scene.isMuted })
        runtime.stop(.display(a)); XCTAssertNil(first.content); XCTAssertNotNil(second.content); XCTAssertTrue(renderers[1].scene.isPlaying)
    }
    @MainActor func testRapidApplyLatestWinsWithoutChangingStateMachine() async throws {
        let (warm, cool, _) = try fixtures()
        let host = SceneTestHost()
        let runtime = WallpaperRuntimeManager(desktop: CrossfadeDesktopHost(desktop: host), makeRenderer: { SceneRenderer(wallpaper: $0) })
        defer { runtime.shutdown() }
        runtime.apply(warm); runtime.apply(cool)
        try await wait { runtime.state.activeWallpaperID == cool.id }
        XCTAssertEqual(runtime.state.playbackState, .playing); XCTAssertNil(runtime.lastFailure)
    }
    @MainActor func testStopDuringPrepareCannotPromoteLateScene() async throws {
        let (warm, _, _) = try fixtures()
        let host = SceneTestHost()
        let runtime = WallpaperRuntimeManager(desktop: host, makeRenderer: { SceneRenderer(wallpaper: $0) })
        defer { runtime.shutdown() }
        runtime.apply(warm); runtime.stop()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNil(host.content); XCTAssertNil(runtime.state.activeWallpaperID)
    }

    @MainActor func testWorkerFailureFreezesOnlyItsOwnDisplayAndOtherSceneRemainsUsable() async throws {
        let (warm, cool, _) = try fixtures()
        let path = root.appendingPathComponent("looping/scene.json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
        var objects = json["objects"] as! [[String: Any]]
        objects[1]["origin"] = ["value": "480 270 0",
            "script": "export function init(v){Promise.resolve().then(()=>{while(true){}});return v;}"]
        json["objects"] = objects
        try JSONSerialization.data(withJSONObject: json).write(to: path)
        let looping = Wallpaper(name: "microtask-loop", type: .scene, source: .local,
                                resourceURL: root.appendingPathComponent("looping"))
        let a = DisplayID("worker-failure-A"), b = DisplayID("healthy-B")
        let first = SceneTestHost(), second = SceneTestHost()
        var renderers: [Wallpaper.ID: SceneRenderer] = [:]
        let runtime = WallpaperRuntimeManager { wallpaper in
            let renderer = SceneRenderer(wallpaper: wallpaper)
            renderers[wallpaper.id] = renderer
            return renderer
        }
        defer { runtime.shutdown() }
        runtime.addDisplay(a, host: CrossfadeDesktopHost(desktop: first))
        runtime.addDisplay(b, host: CrossfadeDesktopHost(desktop: second))
        runtime.apply(warm, to: a); runtime.apply(cool, to: b)
        try await wait { runtime.activeWallpaper(on: a)?.id == warm.id && runtime.activeWallpaper(on: b)?.id == cool.id }
        runtime.apply(looping, to: a)
        try await wait { runtime.state(of: a)?.playbackState == .failed }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertNotNil(first.content, "脚本失控仍保留目标屏的静态兜底")
        XCTAssertNotNil(second.content)
        XCTAssertEqual(runtime.state(of: b)?.playbackState, .playing)
        XCTAssertEqual(runtime.activeWallpaper(on: b)?.id, cool.id)
        XCTAssertTrue(try XCTUnwrap(renderers[cool.id]).scene.isPlaying)
        runtime.pause(.display(b)); XCTAssertEqual(runtime.state(of: b)?.playbackState, .manualPaused)
        runtime.resume(.display(b)); XCTAssertEqual(runtime.state(of: b)?.playbackState, .playing)
        runtime.stop(.display(a)); XCTAssertNil(first.content); XCTAssertNotNil(second.content)
    }
}
