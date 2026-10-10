import AppKit
import AVFoundation
import XCTest
@testable import Kinetic

@MainActor private final class DraftProbeRenderer: WallpaperRenderer {
    let wallpaper: Wallpaper, options: VideoPlaybackOptions
    let displayView = NSView()
    var onFailure: (@MainActor (Error) -> Void)?
    var blocked = false, fails = false, disposed = false, muted = false
    var played = 0
    private var continuation: CheckedContinuation<Void, Never>?
    init(_ wallpaper: Wallpaper, _ options: VideoPlaybackOptions) { self.wallpaper = wallpaper; self.options = options }
    func prepare() async throws {
        if blocked { await withCheckedContinuation { continuation = $0 } }
        if fails { throw VideoOptionsError.composition }
    }
    func complete() { continuation?.resume(); continuation = nil }
    func play() { played += 1 }; func pause() {}; func resume() { play() }
    func setMuted(_ muted: Bool) { self.muted = muted }
    func dispose() { guard !disposed else { return }; disposed = true }
}
@MainActor private final class DraftDesktopHost: DesktopContentHost {
    var content: NSView?
    func present(_ contentView: NSView) -> Bool { content = contentView; return true }
    func stop() { content = nil }
}

@MainActor
final class VideoPlaybackPreviewTests: XCTestCase {
    private func wallpaper() -> Wallpaper {
        Wallpaper(name: "草稿", type: .video, source: .local,
                  resourceURL: URL(fileURLWithPath: "/preview-fixture.mp4"))
    }
    private func wait(_ condition: () -> Bool, timeout: Double = 10) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                XCTFail("Preview did not reach expected state"); throw VideoRendererError.preparationTimedOut
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    func testRealDraftPreviewChangesWithoutSavingOrReloadingDesktopUntilCommit() async throws {
        let root = TestWorkspaceDirectory.make(".build/Module30/DraftPreview/StoreFixtures")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try XCTUnwrap(Bundle.main.url(forResource: "loop", withExtension: "mp4", subdirectory: "Fixtures"))
        let video = Wallpaper(name: "自制视频", type: .video, source: .local, resourceURL: url)
        let before = try Data(contentsOf: url)
        let store = VideoPlaybackStore(storage: .init(rootURL: root))
        var desktops: [VideoRenderer] = []
        let runtime = WallpaperRuntimeManager { wallpaper in
            let renderer = VideoRenderer(wallpaper: wallpaper, options: store.configuration(for: wallpaper.id))
            desktops.append(renderer); return renderer
        }
        let id = DisplayID("draft-preview-desktop"), host = DraftDesktopHost()
        runtime.addDisplay(id, host: host); runtime.apply(video, to: id)
        defer { runtime.shutdown() }
        try await wait { runtime.state(of: id)?.playbackState == .playing }
        runtime.pause(.display(id))
        let old = try XCTUnwrap(desktops.first), oldItem = old.player?.currentItem
        let preview = VideoPlaybackPreview(debounceNanoseconds: 0)
        defer { preview.stop() }
        var draft = VideoPlaybackOptions(); draft.effect = .grayscale; draft.speed = 2; draft.displayFit = .fit
        preview.update(video, options: draft)
        try await wait { preview.previewOptions == draft && !preview.isPreparing }
        let prepared = try XCTUnwrap(preview.renderer as? VideoRenderer)
        XCTAssertTrue(prepared.contentView.hasPoster)
        XCTAssertNotNil(prepared.player?.currentItem?.videoComposition)
        XCTAssertEqual(prepared.contentView.playerLayer.videoGravity, .resizeAspect)
        XCTAssertEqual(prepared.player?.rate, 2); XCTAssertTrue(prepared.isMuted)
        XCTAssertEqual(desktops.count, 1, "Draft must not create a desktop candidate")
        XCTAssertTrue(host.content === old.displayView); XCTAssertTrue(old.player?.currentItem === oldItem)
        XCTAssertEqual(old.player?.rate, 0); XCTAssertEqual(runtime.state(of: id)?.playbackState, .manualPaused)
        XCTAssertEqual(store.configuration(for: video.id), .init())
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        try store.save(draft, for: video, runtime: runtime)
        try await wait { old.options == draft }
        XCTAssertEqual(desktops.count, 1, "Saving options must retain the active player's timeline")
        XCTAssertTrue(host.content === old.displayView); XCTAssertTrue(old.player?.currentItem === oldItem)
        XCTAssertEqual(old.options, draft)
        XCTAssertEqual(runtime.state(of: id)?.playbackState, .manualPaused)
        XCTAssertEqual(store.configuration(for: video.id), draft)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }
    func testEveryRealDraftUsesTheSamePreviewPlayerAndCurrentFrame() async throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "loop", withExtension: "mp4", subdirectory: "Fixtures"))
        let video = Wallpaper(name: "连续预览", type: .video, source: .local, resourceURL: url)
        var count = 0
        let preview = VideoPlaybackPreview(debounceNanoseconds: 0) { wallpaper, options in
            count += 1; return VideoRenderer(wallpaper: wallpaper, options: options)
        }
        defer { preview.stop() }
        preview.update(video, options: .init()); try await wait { preview.renderer != nil }
        let renderer = try XCTUnwrap(preview.renderer as? VideoRenderer)
        try await wait { renderer.currentTime.seconds > 0.6 }
        renderer.pause()
        try await Task.sleep(nanoseconds: 30_000_000)
        let time = renderer.currentTime.seconds, player = renderer.player, item = player?.currentItem
        var options = VideoPlaybackOptions()
        for change in [
            { (o: inout VideoPlaybackOptions) in o.speed = 2 },
            { o in o.effect = .grayscale }, { o in o.effect = .sepia },
            { o in o.brightness = 0.15; o.contrast = 1.2; o.saturation = 0.4 },
            { o in o.displayFit = .fit; o.volume = 0.4 },
            { o in o.frameRate = .fps24 }, { o in o.dynamicRange = .sdr },
            { o in o.preloadBudgetMiB = 64 }, { o in o = .init() }
        ] {
            change(&options); preview.update(video, options: options)
            try await wait { preview.previewOptions == options && !preview.isPreparing }
            XCTAssertTrue(preview.renderer === renderer); XCTAssertTrue(renderer.player === player)
            XCTAssertTrue(renderer.player?.currentItem === item)
            XCTAssertEqual(renderer.currentTime.seconds, time, accuracy: 0.0001)
            XCTAssertEqual(renderer.player?.rate, 0); XCTAssertTrue(renderer.isMuted)
        }
        XCTAssertEqual(count, 1)
        renderer.resume(); try await wait { renderer.currentTime.seconds > time + 0.1 }
        XCTAssertEqual(renderer.player?.rate, 1)
        print("MODULE30 continuity preview factory=\(count), paused playhead=\(time), same player/item through 9 drafts")
    }
    func testLatestDraftWinsAndLateCompletionCannotReappearAfterStop() async throws {
        var created: [DraftProbeRenderer] = []
        let preview = VideoPlaybackPreview(debounceNanoseconds: 0) { wallpaper, options in
            let renderer = DraftProbeRenderer(wallpaper, options); renderer.blocked = true
            created.append(renderer); return renderer
        }
        defer { preview.stop(); created.forEach { $0.complete() } }
        let video = wallpaper()
        preview.update(video, options: .init()); try await wait { created.count == 1 }
        var next = VideoPlaybackOptions(); next.effect = .sepia
        preview.update(video, options: next); try await wait { created.count == 2 }
        XCTAssertTrue(created[0].disposed)
        created[1].complete(); try await wait { preview.previewOptions == next }
        created[0].complete(); try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(preview.renderer === created[1]); XCTAssertEqual(created[0].played, 0)
        XCTAssertTrue(created[1].muted); XCTAssertEqual(preview.surface.subviews.count, 1)
        next.speed = 0.5; preview.update(video, options: next); try await wait { created.count == 3 }
        preview.stop(); created[2].complete(); try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(created.allSatisfy(\.disposed))
        XCTAssertTrue(preview.surface.subviews.isEmpty); XCTAssertNil(preview.renderer)
        XCTAssertNil(preview.previewOptions); XCTAssertEqual(created[2].played, 0)
    }
    func testInvalidOrFailedDraftRetainsPreviousPreviewAndRecoveryClearsError() async throws {
        var created: [DraftProbeRenderer] = []
        let preview = VideoPlaybackPreview(debounceNanoseconds: 0) { wallpaper, options in
            let renderer = DraftProbeRenderer(wallpaper, options); renderer.fails = options.effect == .sepia
            created.append(renderer); return renderer
        }
        defer { preview.stop() }
        let video = wallpaper(); preview.update(video, options: .init())
        try await wait { preview.renderer != nil }
        let old = created[0]
        var invalid = VideoPlaybackOptions(); invalid.speed = .nan
        preview.update(video, options: invalid); try await wait { preview.error != nil }
        XCTAssertEqual(created.count, 1); XCTAssertTrue(preview.renderer === old); XCTAssertFalse(old.disposed)
        var bad = VideoPlaybackOptions(); bad.effect = .sepia
        preview.update(video, options: bad); try await wait { created.count == 2 && preview.error != nil }
        XCTAssertTrue(preview.renderer === old); XCTAssertFalse(old.disposed); XCTAssertTrue(created[1].disposed)
        bad.effect = .grayscale; preview.update(video, options: bad)
        old.onFailure?(VideoOptionsError.composition)
        try await wait { preview.previewOptions == bad }
        XCTAssertNil(preview.error); XCTAssertTrue(old.disposed); XCTAssertEqual(preview.surface.subviews.count, 1)
    }
    func testBurstIsCoalescedAndCloseReleasesPreviewWithoutStoppingNewOwner() async throws {
        var created: [DraftProbeRenderer] = []
        let preview = VideoPlaybackPreview(debounceNanoseconds: 80_000_000) { wallpaper, options in
            let renderer = DraftProbeRenderer(wallpaper, options); created.append(renderer); return renderer
        }
        defer { preview.stop() }
        let video = wallpaper(), owner = UUID()
        var final = VideoPlaybackOptions()
        for step in 0...10 {
            final.brightness = Double(step) / 20
            preview.update(video, options: final, ownerID: owner)
        }
        try await wait { preview.previewOptions == final }
        XCTAssertEqual(created.count, 1)
        preview.stop(ownerID: UUID()); XCTAssertFalse(created[0].disposed)
        let window = NSWindow(contentRect: .init(x: -4000, y: -4000, width: 420, height: 262),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = preview.surface; window.orderFrontRegardless()
        window.close(); try await wait { preview.renderer == nil }
        XCTAssertTrue(created[0].disposed); XCTAssertTrue(preview.surface.subviews.isEmpty)
    }
}
