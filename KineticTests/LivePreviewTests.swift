import AppKit
import AVFoundation
import SwiftUI
import WebKit
import XCTest
@testable import Kinetic

/// 悬停预览的延迟、取消、唯一性、失败回退、资源释放与网页安全边界。
@MainActor
final class LivePreviewTests: XCTestCase {
    // MARK: Fakes & helpers

    private final class Tracker {
        var created: [FakeSession] = []
        var running = 0
        var peak = 0
    }

    private final class FakeSession: LivePreviewSession {
        let wallpaperID: Wallpaper.ID
        let contentView: NSView = NSView()
        private(set) var state: PreviewContentState = .preparing
        var onStateChange: ((PreviewContentState) -> Void)?
        private(set) var started = false
        private(set) var invalidated = false
        private let tracker: Tracker

        init(wallpaperID: Wallpaper.ID, tracker: Tracker) {
            self.wallpaperID = wallpaperID
            self.tracker = tracker
        }

        func start() {
            started = true
            tracker.running += 1
            tracker.peak = max(tracker.peak, tracker.running)
        }

        func invalidate() {
            guard !invalidated else { return }
            invalidated = true
            if started { tracker.running -= 1 }
        }

        func emit(_ newState: PreviewContentState) {
            state = newState
            onStateChange?(newState)
        }
    }

    private func makeCoordinator(_ tracker: Tracker, delay: TimeInterval = 0.08, timeout: TimeInterval = 5)
        -> WallpaperPreviewCoordinator {
        WallpaperPreviewCoordinator(
            delay: delay, slowThreshold: 0.05, timeout: timeout, observesSystem: false,
            isEligible: { _ in true },
            makeSession: { wallpaper in
                let session = FakeSession(wallpaperID: wallpaper.id, tracker: tracker)
                tracker.created.append(session)
                return session
            }
        )
    }

    private func wallpaper(_ type: WallpaperType = .video, url: URL? = nil) -> Wallpaper {
        Wallpaper(name: "预览", type: type, source: .local,
                  resourceURL: url ?? URL(fileURLWithPath: "/kinetic-preview-fixtures/\(UUID().uuidString).mp4"))
    }

    private func fixture(_ name: String, _ ext: String?) throws -> URL {
        try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
    }

    private func wait(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    @discardableResult
    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            await wait(0.02)
        }
        return condition()
    }

    private func hostWindow(_ content: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 320, height: 200),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        content.frame = window.contentView?.bounds ?? .zero
        window.contentView?.addSubview(content)
        window.orderFrontRegardless()
        return window
    }

    // MARK: Coordinator

    func testHoverDelayIs350Milliseconds() {
        XCTAssertEqual(WallpaperPreviewCoordinator.hoverPreviewDelay, 0.35, accuracy: 0.0001)
        XCTAssertTrue((0.3...0.5).contains(WallpaperPreviewCoordinator.hoverPreviewDelay))
        XCTAssertEqual(WallpaperPreviewCoordinator.slowPreparationThreshold, 0.3, accuracy: 0.0001)
    }

    func testNothingIsCreatedUntilTheDelayHasPassed() async {
        let tracker = Tracker()
        let coordinator = makeCoordinator(tracker)
        let a = wallpaper()
        coordinator.hoverBegan(a)
        await wait(0.03)
        XCTAssertTrue(tracker.created.isEmpty)
        XCTAssertEqual(coordinator.pendingWallpaperID, a.id)
        XCTAssertNil(coordinator.activePreview)
        await waitUntil(1) { !tracker.created.isEmpty }
        XCTAssertEqual(tracker.created.count, 1)
        XCTAssertTrue(tracker.created[0].started)
        XCTAssertEqual(coordinator.activePreview?.wallpaperID, a.id)
        XCTAssertEqual(coordinator.activePreview?.state, .preparing)
        coordinator.stopAll()
    }

    func testQuickHoverNeverCreatesAPreview() async {
        let tracker = Tracker()
        let coordinator = makeCoordinator(tracker)
        let a = wallpaper()
        coordinator.hoverBegan(a)
        await wait(0.03)
        coordinator.hoverEnded(a.id)
        XCTAssertNil(coordinator.pendingWallpaperID)
        await wait(0.2)
        XCTAssertTrue(tracker.created.isEmpty)
        XCTAssertNil(coordinator.activePreview)
    }

    func testPassingOverCardsOnlyStartsTheOneThatStays() async {
        let tracker = Tracker()
        let coordinator = makeCoordinator(tracker)
        let a = wallpaper(), b = wallpaper(), c = wallpaper()
        coordinator.hoverBegan(a)
        await wait(0.04)
        coordinator.hoverEnded(a.id)
        coordinator.hoverBegan(b)
        await wait(0.03)
        coordinator.hoverEnded(b.id)
        coordinator.hoverBegan(c)
        await waitUntil(1) { !tracker.created.isEmpty }
        await wait(0.1)
        XCTAssertEqual(tracker.created.map { $0.wallpaperID }, [c.id])
        coordinator.stopAll()
    }

    func testMovingToAnotherCardStopsThePreviousPreviewImmediately() async {
        let tracker = Tracker()
        let coordinator = makeCoordinator(tracker)
        let a = wallpaper(), b = wallpaper()
        coordinator.hoverBegan(a)
        await waitUntil(1) { tracker.created.count == 1 }
        tracker.created[0].emit(.playing)
        XCTAssertEqual(coordinator.activePreview?.state, .playing)

        // SwiftUI 可能先报告进入 B 再报告离开 A：进入 B 时 A 就必须立刻释放。
        coordinator.hoverBegan(b)
        XCTAssertTrue(tracker.created[0].invalidated)
        XCTAssertNil(coordinator.activePreview)
        XCTAssertEqual(tracker.running, 0)
        coordinator.hoverEnded(a.id)
        XCTAssertEqual(coordinator.pendingWallpaperID, b.id)

        await waitUntil(1) { tracker.created.count == 2 }
        XCTAssertEqual(tracker.created[1].wallpaperID, b.id)
        XCTAssertEqual(tracker.peak, 1)
        coordinator.stopAll()
        XCTAssertEqual(tracker.running, 0)
    }

    func testRepeatedHoverEventsDoNotRestartTheSamePreview() async {
        let tracker = Tracker()
        let coordinator = makeCoordinator(tracker)
        let a = wallpaper()
        coordinator.hoverBegan(a)
        await waitUntil(1) { tracker.created.count == 1 }
        tracker.created[0].emit(.playing)
        coordinator.hoverBegan(a)
        await wait(0.15)
        XCTAssertEqual(tracker.created.count, 1)
        XCTAssertFalse(tracker.created[0].invalidated)
        coordinator.stopAll()
    }

    func testRandomHoverSequenceNeverRunsTwoPreviews() async {
        let tracker = Tracker()
        let coordinator = makeCoordinator(tracker, delay: 0.02)
        let cards = (0..<4).map { _ in wallpaper() }
        var generator = SystemRandomNumberGenerator()
        for step in 0..<60 {
            let card = cards[Int.random(in: 0..<cards.count, using: &generator)]
            if step.isMultiple(of: 3) { coordinator.hoverEnded(card.id) } else { coordinator.hoverBegan(card) }
            if let last = tracker.created.last, !last.invalidated, Bool.random(using: &generator) { last.emit(.playing) }
            await wait(Double.random(in: 0...0.05, using: &generator))
            XCTAssertLessThanOrEqual(tracker.running, 1)
        }
        coordinator.stopAll()
        XCTAssertEqual(tracker.peak, 1)
        XCTAssertEqual(tracker.running, 0)
        XCTAssertTrue(tracker.created.allSatisfy { $0.invalidated })
    }

    func testStopAllAndSystemConditionsStopAndBlockPreviews() async {
        let tracker = Tracker()
        let coordinator = makeCoordinator(tracker)
        let a = wallpaper(), b = wallpaper()
        coordinator.hoverBegan(a)
        await waitUntil(1) { tracker.created.count == 1 }
        tracker.created[0].emit(.playing)

        coordinator.setSuppressed(.screenLocked, true)
        XCTAssertTrue(tracker.created[0].invalidated)
        XCTAssertNil(coordinator.activePreview)
        coordinator.hoverBegan(b)
        await wait(0.2)
        XCTAssertEqual(tracker.created.count, 1)

        coordinator.setSuppressed(.screenLocked, false)
        coordinator.hoverBegan(b)
        await waitUntil(1) { tracker.created.count == 2 }
        coordinator.stopAll()
        XCTAssertTrue(tracker.created[1].invalidated)
        XCTAssertNil(coordinator.activePreview)
        XCTAssertNil(coordinator.pendingWallpaperID)
    }

    func testFailureFallsBackToTheThumbnailAndIsNotRetried() async {
        let tracker = Tracker()
        let coordinator = makeCoordinator(tracker)
        let a = wallpaper()
        coordinator.hoverBegan(a)
        await waitUntil(1) { tracker.created.count == 1 }
        tracker.created[0].emit(.failed)
        XCTAssertTrue(tracker.created[0].invalidated)
        XCTAssertEqual(coordinator.activePreview?.state, .failed)
        coordinator.hoverEnded(a.id)
        XCTAssertNil(coordinator.activePreview)
        coordinator.hoverBegan(a)
        await wait(0.2)
        XCTAssertEqual(tracker.created.count, 1)
    }

    func testSlowPreparationShowsProgressAndTimesOut() async {
        let tracker = Tracker()
        let coordinator = makeCoordinator(tracker, timeout: 0.4)
        let a = wallpaper()
        coordinator.hoverBegan(a)
        await waitUntil(1) { tracker.created.count == 1 }
        XCTAssertEqual(coordinator.activePreview?.showsProgress, false)
        await waitUntil(1) { coordinator.activePreview?.showsProgress == true }
        XCTAssertEqual(coordinator.activePreview?.showsProgress, true)
        await waitUntil(2) { coordinator.activePreview?.state == .failed }
        XCTAssertEqual(coordinator.activePreview?.state, .failed)
        XCTAssertEqual(coordinator.activePreview?.showsProgress, false)
        XCTAssertTrue(tracker.created[0].invalidated)
        coordinator.stopAll()
    }

    func testEligibilityCoversTypesAndMissingContent() throws {
        XCTAssertTrue(LivePreviewEligibility.canLivePreview(wallpaper(.video, url: try fixture("loop", "mp4"))))
        XCTAssertTrue(LivePreviewEligibility.canLivePreview(wallpaper(.web, url: try fixture("web-sample", nil))))
        XCTAssertFalse(LivePreviewEligibility.canLivePreview(wallpaper(.scene, url: try fixture("web-sample", nil))))
        XCTAssertFalse(LivePreviewEligibility.canLivePreview(wallpaper(.video)))
        XCTAssertFalse(LivePreviewEligibility.canLivePreview(wallpaper(.video, url: try fixture("web-sample", nil))))
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("KineticNoEntry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        XCTAssertFalse(LivePreviewEligibility.canLivePreview(wallpaper(.web, url: empty)))
    }

    func testIneligibleContentNeverCreatesASession() async throws {
        let coordinator = WallpaperPreviewCoordinator(delay: 0.02, observesSystem: false)
        for item in [wallpaper(.scene, url: try fixture("web-sample", nil)), wallpaper(.video)] {
            coordinator.hoverBegan(item)
            await wait(0.1)
            XCTAssertNil(coordinator.activePreview)
            coordinator.hoverEnded(item.id)
        }
    }

    /// Live Preview 只替换预览区域内部内容：卡片尺寸与没有预览时完全相同。
    func testLivePreviewDoesNotChangeCardGeometry() {
        let tracker = Tracker()
        let item = wallpaper()
        let session = FakeSession(wallpaperID: item.id, tracker: tracker)
        let state = WallpaperCardVisualState(isActive: true, isSelected: true, isHovered: true, isPlayable: true)
        func size(_ preview: WallpaperPreviewCoordinator.ActivePreview?) -> NSSize {
            NSHostingView(rootView: WallpaperCardContent(
                wallpaper: item, visualState: state, onSelect: {}, onApply: {}, livePreview: preview
            ).frame(width: 220)).fittingSize
        }
        let base = size(nil)
        for previewState in [PreviewContentState.preparing, .playing, .failed] {
            for progress in [false, true] {
                let preview = WallpaperPreviewCoordinator.ActivePreview(
                    wallpaperID: item.id, session: session, state: previewState, showsProgress: progress)
                XCTAssertEqual(size(preview), base)
            }
        }
    }

    // MARK: Visibility

    /// 滚动到完全看不见时才通知停止；仍部分可见时不打断。
    func testHostReportsWhenScrolledCompletelyOutOfView() async {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 1000))
        scroll.documentView = document
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 200, height: 100),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer { window.close() }

        var interruptions = 0
        let host = LivePreviewHostView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        host.onInterrupted = { interruptions += 1 }
        document.addSubview(host)

        scroll.contentView.scroll(to: NSPoint(x: 0, y: 60))
        scroll.reflectScrolledClipView(scroll.contentView)
        await wait(0.1)
        XCTAssertEqual(interruptions, 0, "Partly visible preview keeps playing")

        scroll.contentView.scroll(to: NSPoint(x: 0, y: 500))
        scroll.reflectScrolledClipView(scroll.contentView)
        await wait(0.1)
        XCTAssertEqual(interruptions, 1)
        host.releaseContent()
    }

    /// 窗口关闭、最小化、失去焦点或被完全遮挡时通知停止；只是重新变为可见时不通知。
    func testHostReportsWindowLifecycleChanges() async {
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 200, height: 100),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var interruptions = 0
        let host = LivePreviewHostView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        host.onInterrupted = { interruptions += 1 }
        window.contentView?.addSubview(host)

        for name in [NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.post(name: name, object: window)
        }
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        await wait(0.1)
        XCTAssertEqual(interruptions, 4)

        // 别的窗口的事件与之无关。
        let other = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        other.isReleasedWhenClosed = false
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: other)
        await wait(0.1)
        XCTAssertEqual(interruptions, 4)

        host.removeFromSuperview()
        await wait(0.1)
        XCTAssertEqual(interruptions, 5, "Leaving the window stops the preview")
        host.releaseContent()
    }

    // MARK: Video

    func testVideoPreviewIsMutedLoopsAndReleasesEverything() async throws {
        let session = VideoPreviewSession(wallpaper: wallpaper(.video, url: try fixture("loop", "mp4")))
        let window = hostWindow(session.contentView)
        defer { window.close() }
        session.start()
        let playing = await waitUntil(8) { session.state == .playing }
        XCTAssertTrue(playing)

        weak var weakPlayer: AVQueuePlayer?
        weak var weakLooper: AVPlayerLooper?
        do {
            let player = try XCTUnwrap(session.player)
            XCTAssertTrue(player.isMuted)
            XCTAssertEqual(player.volume, 0)
            XCTAssertFalse(player.preventsDisplaySleepDuringVideoPlayback)
            XCTAssertFalse(player.allowsExternalPlayback)
            let looped = await waitUntil(8) { (session.looper?.loopCount ?? 0) >= 1 }
            XCTAssertTrue(looped, "The 2.4 s fixture should have looped at least once")
            XCTAssertTrue(player.isMuted)
            weakPlayer = player
            weakLooper = session.looper
        }

        session.invalidate()
        XCTAssertNil(session.player)
        XCTAssertNil(session.looper)
        XCTAssertNil(session.contentView.superview)
        let released = await waitUntil(5) { weakPlayer == nil && weakLooper == nil }
        XCTAssertTrue(released, "Preview player or looper leaked")
        XCTAssertEqual(LivePreviewDiagnostics.shared.alivePlayers, 0)
    }

    /// 预览播放中改变卡片宽度（窗口 / 侧栏缩放）：内容与视频图层跟随新的预览区域等比例缩放，播放器不重建。
    func testPlayingPreviewFollowsCardResizeWithoutRestarting() async throws {
        let session = VideoPreviewSession(wallpaper: wallpaper(.video, url: try fixture("loop", "mp4")))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 400, height: 300),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = LivePreviewHostView(frame: NSRect(x: 0, y: 0, width: 180, height: 112.5))
        window.contentView?.addSubview(host)
        host.embed(session.contentView)
        session.start()
        defer { session.invalidate() }
        let playing = await waitUntil(8) { session.state == .playing }
        XCTAssertTrue(playing)
        let player = try XCTUnwrap(session.player)

        for width in [180.0, 250.0, 200.0] {
            let height = width / MainWindowDesignTokens.Grid.previewAspectRatio
            host.setFrameSize(NSSize(width: width, height: height))
            host.layoutSubtreeIfNeeded()
            // AppKit 会把尺寸对齐到像素，允许 0.5 pt 以内的差异。
            let content = session.contentView
            XCTAssertEqual(content.frame.size.width, width, accuracy: 0.5)
            XCTAssertEqual(content.frame.size.height, height, accuracy: 0.5)
            let layer = try XCTUnwrap(content.layer?.sublayers?.first { $0 is AVPlayerLayer } as? AVPlayerLayer)
            XCTAssertEqual(layer.frame.size.width, width, accuracy: 0.5)
            XCTAssertEqual(layer.frame.size.height, height, accuracy: 0.5)
            XCTAssertEqual(layer.videoGravity, .resizeAspectFill)
            XCTAssertTrue(session.player === player, "Resizing must not recreate the preview player")
            XCTAssertEqual(session.state, .playing)
        }
        host.releaseContent()
    }

    func testCorruptVideoFailsWithoutRetrying() async throws {
        let coordinator = WallpaperPreviewCoordinator(delay: 0.02, timeout: 3, observesSystem: false)
        let item = wallpaper(.video, url: try fixture("corrupt", "mp4"))
        coordinator.hoverBegan(item)
        let failed = await waitUntil(8) { coordinator.activePreview?.state == .failed }
        XCTAssertTrue(failed)
        let released = await waitUntil(5) { LivePreviewDiagnostics.shared.alivePlayers == 0 }
        XCTAssertTrue(released)
        coordinator.hoverEnded(item.id)
        coordinator.hoverBegan(item)
        await wait(0.2)
        XCTAssertNil(coordinator.activePreview)
        coordinator.stopAll()
    }

    // MARK: Web

    func testWebPreviewIsMutedThrottledAndReleasesTheWebView() async throws {
        let session = try XCTUnwrap(WebPreviewSession(wallpaper: wallpaper(.web, url: try fixture("web-sample", nil))))
        let window = hostWindow(session.contentView)
        defer { window.close() }
        session.start()
        let playing = await waitUntil(15) { session.state == .playing }
        XCTAssertTrue(playing)

        weak var weakWebView: WKWebView?
        do {
            let web = try XCTUnwrap(session.webView)
            XCTAssertEqual(web.configuration.userContentController.userScripts.count, 2)
            let result = try await web.callAsyncJavaScript("""
                const video = document.createElement('video');
                video.muted = false;
                video.volume = 1;
                let audio = 'none';
                try { audio = new AudioContext().state; } catch (e) {}
                return [video.muted, video.volume, audio, String(window.requestAnimationFrame).includes('[native code]')];
                """, arguments: [:], in: nil, contentWorld: .page) as? [Any]
            XCTAssertEqual(result?[0] as? Bool, true)
            XCTAssertEqual((result?[1] as? NSNumber)?.doubleValue, 0)
            XCTAssertEqual(result?[2] as? String, "suspended")
            XCTAssertEqual(result?[3] as? Bool, false)
            weakWebView = web
        }

        session.invalidate()
        XCTAssertNil(session.webView)
        XCTAssertNil(session.contentView.superview)
        let released = await waitUntil(8) { weakWebView == nil }
        XCTAssertTrue(released, "Preview WKWebView leaked")
        XCTAssertEqual(LivePreviewDiagnostics.shared.aliveWebViews, 0)
    }

    func testWebConfigurationKeepsTheSecurityBoundary() {
        let configuration = WebWallpaperPolicy.makeConfiguration(userScripts: [])
        XCTAssertFalse(configuration.preferences.javaScriptCanOpenWindowsAutomatically)
        XCTAssertFalse(configuration.preferences.isElementFullscreenEnabled)
        XCTAssertEqual(configuration.mediaTypesRequiringUserActionForPlayback, .audio)
        XCTAssertFalse(configuration.websiteDataStore.isPersistent)
        XCTAssertFalse(configuration.allowsAirPlayForMediaPlayback)
        XCTAssertTrue(configuration.defaultWebpagePreferences.allowsContentJavaScript)
    }

    /// 安全相关的 WebKit 回调确实接到了会话上（签名不符时 WebKit 会静默使用默认行为）。
    func testWebDelegateHandlesSecurityCallbacks() throws {
        let session = try XCTUnwrap(WebPreviewSession(wallpaper: wallpaper(.web, url: try fixture("web-sample", nil))))
        for selector in [
            "webView:decidePolicyForNavigationAction:decisionHandler:",
            "webView:decidePolicyForNavigationResponse:decisionHandler:",
            "webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:",
            "webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:",
            "webView:runOpenPanelWithParameters:initiatedByFrame:completionHandler:",
            "webView:runJavaScriptAlertPanelWithMessage:initiatedByFrame:completionHandler:",
            "webViewWebContentProcessDidTerminate:"
        ] {
            XCTAssertTrue(session.responds(to: NSSelectorFromString(selector)), selector)
        }
    }

    func testNavigationPolicyStaysInsideTheWallpaperFolder() {
        let root = URL(fileURLWithPath: "/tmp/kinetic-wall", isDirectory: true)
        func allows(_ string: String, main: Bool) -> Bool {
            WebWallpaperPolicy.allowsNavigation(to: URL(string: string), isMainFrame: main, root: root)
        }
        XCTAssertTrue(allows("file:///tmp/kinetic-wall/index.html", main: true))
        XCTAssertTrue(allows("file:///tmp/kinetic-wall/scenes/a.html", main: false))
        XCTAssertFalse(allows("file:///tmp/kinetic-wall-other/index.html", main: true))
        XCTAssertFalse(allows("file:///tmp/kinetic-wall/../secret.txt", main: false))
        XCTAssertFalse(allows("file:///etc/passwd", main: false))
        XCTAssertFalse(allows("https://example.com/", main: true))
        XCTAssertTrue(allows("https://example.com/embed", main: false))
        XCTAssertFalse(allows("http://example.com/", main: false))
        XCTAssertFalse(allows("about:blank", main: true))
        XCTAssertTrue(allows("about:blank", main: false))
        XCTAssertFalse(allows("mailto:someone@example.com", main: false))
        XCTAssertFalse(allows("zoommtg://join", main: false))
        XCTAssertFalse(allows("javascript:alert(1)", main: false))
        XCTAssertFalse(WebWallpaperPolicy.allowsNavigation(to: nil, isMainFrame: false, root: root))
    }

    // MARK: Stress

    /// 50 次悬停 / 离开：视频、网页交替，部分未到延迟、部分准备中、部分已播放、部分直接切换。
    func testFiftyHoverCyclesLeaveNoPlayersOrWebViews() async throws {
        let diagnostics = LivePreviewDiagnostics.shared
        let coordinator = WallpaperPreviewCoordinator(delay: 0.05, observesSystem: false)
        let cards = [
            wallpaper(.video, url: try fixture("loop", "mp4")),
            wallpaper(.web, url: try fixture("web-sample", nil)),
            wallpaper(.video, url: try fixture("loop-warm", "mp4"))
        ]
        let dwell: [TimeInterval] = [0.01, 0.12, 0.35, 0.6]
        diagnostics.resetCounters()
        let startMemory = LivePreviewDiagnostics.memoryFootprint()
        for cycle in 0..<50 {
            let card = cards[cycle % cards.count]
            coordinator.hoverBegan(card)
            await wait(dwell[cycle % dwell.count])
            XCTAssertLessThanOrEqual(diagnostics.runningSessions, 1)
            if !cycle.isMultiple(of: 5) {
                coordinator.hoverEnded(card.id)
                XCTAssertEqual(diagnostics.runningSessions, 0)
            }
        }
        coordinator.stopAll()
        XCTAssertEqual(diagnostics.runningSessions, 0)
        XCTAssertLessThanOrEqual(diagnostics.peakRunningSessions, 1)
        XCTAssertGreaterThan(diagnostics.sessionsStarted, 0)
        let released = await waitUntil(10) { diagnostics.alivePlayers == 0 && diagnostics.aliveWebViews == 0 }
        XCTAssertTrue(released, "players \(diagnostics.alivePlayers), web views \(diagnostics.aliveWebViews)")
        let growth = Double(Int64(LivePreviewDiagnostics.memoryFootprint()) - Int64(startMemory)) / 1_048_576
        print("LivePreview stress: sessions \(diagnostics.sessionsStarted), memory growth \(String(format: "%.1f", growth)) MB")
        XCTAssertLessThan(growth, 150)
    }
}
