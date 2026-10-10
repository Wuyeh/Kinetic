import AppKit
import XCTest
@testable import Kinetic

@MainActor private final class VideoSettingsHost: DesktopContentHost {
    var content: NSView?
    func present(_ contentView: NSView) -> Bool { content = contentView; return true }
    func stop() { content = nil }
}
@MainActor private final class VideoSettingsRenderer: WallpaperRenderer {
    let wallpaper: Wallpaper, options: VideoPlaybackOptions
    let displayView = NSView()
    var onFailure: (@MainActor (Error) -> Void)?
    var fail: Bool, paused = true, muted = true, disposed = false
    init(_ wallpaper: Wallpaper, _ options: VideoPlaybackOptions, fail: Bool) { self.wallpaper = wallpaper; self.options = options; self.fail = fail }
    func prepare() async throws { if fail { throw VideoOptionsError.preparationBudget } }
    func play() { paused = false }; func pause() { paused = true }; func resume() { play() }
    func setMuted(_ muted: Bool) { self.muted = muted }; func dispose() { disposed = true }
}

final class VideoPlaybackStoreTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = TestWorkspaceDirectory.make(".build/Module30/StoreFixtures")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let root { try FileManager.default.removeItem(at: root) } }
    private func wallpaper(_ type: WallpaperType = .video) -> Wallpaper {
        Wallpaper(name: "视频", type: type, source: .local, resourceURL: root.appendingPathComponent("loop.mp4"))
    }
    @MainActor func testPerWallpaperRoundTripAndResetWithoutSourceMutation() throws {
        let store = VideoPlaybackStore(storage: .init(rootURL: root)), a = wallpaper(), b = wallpaper()
        var options = VideoPlaybackOptions(); options.speed = 0.5; options.effect = .sepia; options.volume = 0.3
        try Data("source".utf8).write(to: a.resourceURL)
        try store.save(options, for: a, runtime: nil)
        let restored = VideoPlaybackStore(storage: .init(rootURL: root))
        XCTAssertEqual(restored.configuration(for: a.id), options)
        XCTAssertEqual(restored.configuration(for: b.id), .init())
        XCTAssertEqual(try Data(contentsOf: a.resourceURL), Data("source".utf8))
        try restored.save(.init(), for: a, runtime: nil)
        XCTAssertEqual(VideoPlaybackStore(storage: .init(rootURL: root)).configuration(for: a.id), .init())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("library.json").path))
    }
    @MainActor func testValidationAndAtomicWriteFailureDoNotPublish() throws {
        let store = VideoPlaybackStore(storage: .init(rootURL: root)), wallpaper = wallpaper()
        var options = VideoPlaybackOptions(); options.speed = 0.5
        try store.save(options, for: wallpaper, runtime: nil)
        options.volume = .infinity
        XCTAssertThrowsError(try store.save(options, for: wallpaper, runtime: nil))
        XCTAssertEqual(store.configuration(for: wallpaper.id).speed, 0.5)
        XCTAssertThrowsError(try store.save(.init(), for: self.wallpaper(.web), runtime: nil))
        try FileManager.default.removeItem(at: store.fileURL)
        try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.save(.init(), for: wallpaper, runtime: nil))
        XCTAssertEqual(store.configuration(for: wallpaper.id).speed, 0.5)
    }
    @MainActor func testCorruptFutureOrOversizedFilesRemainUntouched() throws {
        for data in [Data("bad".utf8), Data(#"{"version":999,"wallpapers":{}}"#.utf8), Data(repeating: 0, count: VideoPlaybackStore.maximumBytes + 1)] {
            let url = root.appendingPathComponent("video-settings.json")
            try data.write(to: url)
            let store = VideoPlaybackStore(storage: .init(rootURL: root))
            XCTAssertNotNil(store.loadError)
            XCTAssertThrowsError(try store.save(.init(), for: wallpaper(), runtime: nil))
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
    }
    @MainActor func testSaveReloadsOnlyMatchingActiveSessionsAndKeepsPauseMuteAndOldFrameOnFailure() async throws {
        let store = VideoPlaybackStore(storage: .init(rootURL: root)), a = wallpaper(), b = wallpaper()
        var created: [VideoSettingsRenderer] = [], fail = false
        let runtime = WallpaperRuntimeManager { wallpaper in
            let renderer = VideoSettingsRenderer(wallpaper, store.configuration(for: wallpaper.id), fail: fail)
            created.append(renderer); return renderer
        }
        defer { runtime.shutdown() }
        let da = DisplayID("A"), db = DisplayID("B"), hostA = VideoSettingsHost(), hostB = VideoSettingsHost()
        runtime.addDisplay(da, host: hostA); runtime.addDisplay(db, host: hostB)
        runtime.apply(a, to: da); runtime.apply(b, to: db)
        try await settle(runtime)
        runtime.pause(.display(da)); runtime.setAudioEnabled(true, on: da)
        let other = created.last!
        var options = VideoPlaybackOptions(); options.speed = 2; options.volume = 0.25
        try store.save(options, for: a, runtime: runtime); try await settle(runtime)
        XCTAssertEqual(created.count, 3)
        let active = created.last!
        XCTAssertEqual(active.options, options); XCTAssertTrue(active.paused); XCTAssertFalse(active.muted)
        XCTAssertFalse(other.disposed); XCTAssertEqual(runtime.state(of: db)?.playbackState, .playing)
        XCTAssertEqual(runtime.state(of: da)?.playbackState, .manualPaused)
        fail = true; options.effect = .sepia
        try store.save(options, for: a, runtime: runtime); try await settle(runtime)
        XCTAssertTrue(hostA.content === active.displayView); XCTAssertFalse(active.disposed)
        XCTAssertEqual(runtime.state(of: da)?.playbackState, .manualPaused)
        runtime.stop(.display(da))
        let count = created.count
        try store.save(.init(), for: a, runtime: runtime)
        XCTAssertEqual(created.count, count); XCTAssertEqual(runtime.state(of: da)?.playbackState, .stopped)
    }
    @MainActor func testRapidSavedSettingsKeepRealDesktopTimelineAndOtherDisplayUnchanged() async throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "loop", withExtension: "mp4", subdirectory: "Fixtures"))
        let a = Wallpaper(name: "连续桌面 A", type: .video, source: .local, resourceURL: url)
        let b = Wallpaper(name: "隔离桌面 B", type: .video, source: .local, resourceURL: url)
        let store = VideoPlaybackStore(storage: .init(rootURL: root))
        var created: [VideoRenderer] = []
        let runtime = WallpaperRuntimeManager { wallpaper in
            let renderer = VideoRenderer(wallpaper: wallpaper, options: store.configuration(for: wallpaper.id))
            created.append(renderer); return renderer
        }
        defer { runtime.shutdown() }
        let da = DisplayID("continuous-A"), db = DisplayID("continuous-B")
        let ha = VideoSettingsHost(), hb = VideoSettingsHost()
        runtime.addDisplay(da, host: ha); runtime.addDisplay(db, host: hb)
        runtime.apply(a, to: da); runtime.apply(b, to: db); try await settle(runtime)
        let active = try XCTUnwrap(created.first { $0.wallpaper.id == a.id })
        let other = try XCTUnwrap(created.first { $0.wallpaper.id == b.id })
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while active.currentTime.seconds < 0.5 {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw VideoRendererError.preparationTimedOut }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        runtime.pause(.display(da)); runtime.setAudioEnabled(true, on: da)
        try await Task.sleep(nanoseconds: 30_000_000)
        let time = active.currentTime.seconds, player = active.player, item = player?.currentItem
        var final = VideoPlaybackOptions()
        for step in 0..<12 {
            final.effect = step.isMultiple(of: 2) ? .grayscale : .sepia
            final.speed = step.isMultiple(of: 2) ? 0.5 : 2
            final.brightness = Double(step) / 40
            try store.save(final, for: a, runtime: runtime)
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        while active.options != final {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw VideoRendererError.preparationTimedOut }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(created.count, 2, "Saved edits must not recreate any desktop renderer")
        XCTAssertTrue(active.player === player); XCTAssertTrue(player?.currentItem === item)
        XCTAssertTrue(ha.content === active.displayView); XCTAssertTrue(hb.content === other.displayView)
        XCTAssertEqual(active.currentTime.seconds, time, accuracy: 0.0001)
        XCTAssertEqual(active.player?.rate, 0); XCTAssertFalse(active.isMuted)
        XCTAssertEqual(other.options, .init()); XCTAssertTrue(other.isMuted)
        XCTAssertEqual(runtime.state(of: da)?.playbackState, .manualPaused)
        XCTAssertEqual(runtime.state(of: db)?.playbackState, .playing); XCTAssertNil(runtime.lastFailure)
        XCTAssertEqual(VideoPlaybackStore(storage: .init(rootURL: root)).configuration(for: a.id), final)
        final.effect = .grayscale; try store.save(final, for: a, runtime: runtime)
        await Task.yield(); runtime.stop(.display(da))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(active.player); XCTAssertNil(ha.content); XCTAssertTrue(hb.content === other.displayView)
        try store.save(.init(), for: a, runtime: runtime)
        XCTAssertEqual(created.count, 2); XCTAssertEqual(runtime.state(of: da)?.playbackState, .stopped)
        print("MODULE30 continuity saved bursts=12, same player/item at \(time), independent B unchanged, stop wins")
    }
    @MainActor private func settle(_ runtime: WallpaperRuntimeManager) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while runtime.displayIDs.contains(where: { runtime.state(of: $0)?.preparingWallpaperID != nil }) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw VideoRendererError.preparationTimedOut }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
