import AppKit
import Combine
import AVFoundation
import XCTest
@testable import Kinetic

/// 记录跨对象的调用顺序，用于验证“先显示新内容，再释放旧 Renderer”等规则。
@MainActor
private final class CallLog {
    var entries: [String] = []
}

@MainActor
private final class FakeDesktop: DesktopContentHost {
    let log: CallLog
    private(set) var content: NSView?
    init(log: CallLog) { self.log = log }

    func present(_ contentView: NSView) -> Bool {
        content = contentView
        log.entries.append("present:\(contentView.identifier?.rawValue ?? "?")")
        return true
    }

    func stop() {
        content = nil
        log.entries.append("desktop.stop")
    }
}

/// 可控的 Renderer：准备结果由测试决定，用于证明任何 Renderer（Video/Web/Scene）遵循同一规则。
@MainActor
private final class FakeRenderer: WallpaperRenderer {
    let wallpaper: Wallpaper
    let displayView = NSView()
    var onFailure: (@MainActor (Error) -> Void)?
    let log: CallLog
    private var continuation: CheckedContinuation<Void, Error>?
    private(set) var isDisposed = false
    var isWaitingForPreparation: Bool { continuation != nil }

    init(wallpaper: Wallpaper, log: CallLog, instance: Int) {
        self.wallpaper = wallpaper
        self.log = log
        displayView.identifier = NSUserInterfaceItemIdentifier("\(wallpaper.name)#\(instance)")
    }

    private var tag: String { displayView.identifier?.rawValue ?? "?" }

    func prepare() async throws {
        log.entries.append("prepare:\(tag)")
        try await withCheckedThrowingContinuation { self.continuation = $0 }
    }

    func finishPreparation(_ error: Error? = nil) {
        let pending = continuation
        continuation = nil
        if let error { pending?.resume(throwing: error) } else { pending?.resume() }
    }

    func play() { log.entries.append("play:\(tag)") }
    func pause() { log.entries.append("pause:\(tag)") }
    func resume() { log.entries.append("resume:\(tag)") }
    func setMuted(_ muted: Bool) { log.entries.append("mute:\(tag):\(muted)") }

    func dispose() {
        guard !isDisposed else { return }
        isDisposed = true
        onFailure = nil
        log.entries.append("dispose:\(tag)")
        // 与 VideoRenderer 一致：准备中被释放时，准备以失败结束。
        finishPreparation(CancellationError())
    }
}

private struct FakeError: LocalizedError {
    var errorDescription: String? { "fake failure" }
}

final class WallpaperRuntimeManagerTests: XCTestCase {
    @MainActor
    private func waitUntil(timeout: TimeInterval = 8, _ predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !predicate() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                XCTFail("Timed out waiting for runtime condition")
                throw CancellationError()
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @MainActor
    private func makeManager() -> (WallpaperRuntimeManager, FakeDesktop, CallLog, () -> [FakeRenderer]) {
        let log = CallLog()
        let desktop = FakeDesktop(log: log)
        var created: [FakeRenderer] = []
        let manager = WallpaperRuntimeManager(desktop: desktop) { wallpaper in
            let renderer = FakeRenderer(wallpaper: wallpaper, log: log, instance: created.count + 1)
            created.append(renderer)
            return renderer
        }
        return (manager, desktop, log, { created })
    }

    private func wallpaper(_ name: String, _ type: WallpaperType = .video) -> Wallpaper {
        Wallpaper(name: name, type: type, source: .local,
                  resourceURL: URL(fileURLWithPath: "/kinetic-runtime-fixtures/\(name)"))
    }

    @MainActor
    func testSwitchKeepsOldContentUntilNewRendererIsReadyThenReleasesOld() async throws {
        let (manager, desktop, log, renderers) = makeManager()
        let a = wallpaper("A"), b = wallpaper("B")

        manager.apply(a)
        XCTAssertEqual(manager.state.playbackState, .preparing)
        try await waitUntil { renderers().first?.isWaitingForPreparation == true }
        renderers()[0].finishPreparation()
        try await waitUntil { manager.state.playbackState == .playing }
        XCTAssertTrue(desktop.content === renderers()[0].displayView)
        XCTAssertEqual(manager.activeWallpaper, a)

        manager.apply(b)
        try await waitUntil { renderers().count == 2 && renderers()[1].isWaitingForPreparation }
        XCTAssertEqual(manager.state.playbackState, .playing)
        XCTAssertEqual(manager.state.activeWallpaperID, a.id)
        XCTAssertEqual(manager.state.preparingWallpaperID, b.id)
        XCTAssertTrue(desktop.content === renderers()[0].displayView, "Old wallpaper stays visible while B prepares")
        XCTAssertFalse(renderers()[0].isDisposed)

        log.entries.removeAll()
        renderers()[1].finishPreparation()
        try await waitUntil { manager.state.activeWallpaperID == b.id }
        XCTAssertEqual(log.entries, ["present:B#2", "dispose:A#1", "play:B#2"])
        XCTAssertTrue(desktop.content === renderers()[1].displayView)
        XCTAssertEqual(manager.state.playbackState, .playing)
        XCTAssertEqual(manager.lastActiveWallpaper, b)
        manager.shutdown()
    }

    @MainActor
    func testFailedApplyKeepsOldWallpaperAndReportsLocalizedMessage() async throws {
        let (manager, desktop, _, renderers) = makeManager()
        let a = wallpaper("A"), b = wallpaper("雨夜")
        manager.apply(a)
        try await waitUntil { renderers().first?.isWaitingForPreparation == true }
        renderers()[0].finishPreparation()
        try await waitUntil { manager.state.playbackState == .playing }

        manager.apply(b)
        try await waitUntil { renderers().count == 2 && renderers()[1].isWaitingForPreparation }
        renderers()[1].finishPreparation(FakeError())
        try await waitUntil { manager.lastFailure != nil }

        XCTAssertEqual(manager.lastFailure?.wallpaperID, b.id)
        XCTAssertEqual(manager.lastFailure?.message, "无法加载“雨夜”。")
        XCTAssertEqual(manager.lastFailure?.detail, "fake failure")
        XCTAssertEqual(manager.state.playbackState, .playing)
        XCTAssertEqual(manager.state.activeWallpaperID, a.id)
        XCTAssertNil(manager.state.preparingWallpaperID)
        XCTAssertTrue(desktop.content === renderers()[0].displayView, "Desktop never goes black on failure")
        XCTAssertFalse(renderers()[0].isDisposed)
        XCTAssertTrue(renderers()[1].isDisposed)
        manager.shutdown()
    }

    @MainActor
    func testPauseSmartPauseStopAndReenableDriveRendererThroughManager() async throws {
        let (manager, desktop, log, renderers) = makeManager()
        let a = wallpaper("A")
        manager.apply(a)
        try await waitUntil { renderers().first?.isWaitingForPreparation == true }
        renderers()[0].finishPreparation()
        try await waitUntil { manager.state.playbackState == .playing }

        log.entries.removeAll()
        manager.pause()
        manager.setSmartPauseActive(true)
        manager.setSmartPauseActive(false)
        XCTAssertEqual(manager.state.playbackState, .manualPaused)
        manager.resume()
        manager.setSmartPauseActive(true)
        XCTAssertEqual(manager.state.playbackState, .smartPaused)
        manager.setSmartPauseActive(false)
        XCTAssertEqual(log.entries, ["pause:A#1", "resume:A#1", "pause:A#1", "resume:A#1"])

        log.entries.removeAll()
        manager.stop()
        XCTAssertEqual(log.entries, ["desktop.stop", "dispose:A#1"], "Native wallpaper is restored before release")
        XCTAssertEqual(manager.state.playbackState, .stopped)
        XCTAssertNil(desktop.content)
        XCTAssertNil(manager.activeWallpaper)
        XCTAssertEqual(manager.lastActiveWallpaper, a)

        manager.reenable()
        XCTAssertEqual(manager.state.playbackState, .preparing)
        try await waitUntil { renderers().count == 2 && renderers()[1].isWaitingForPreparation }
        XCTAssertEqual(renderers()[1].wallpaper, a, "Re-enable uses a fresh renderer for the last active wallpaper")
        renderers()[1].finishPreparation()
        try await waitUntil { manager.state.playbackState == .playing }
        XCTAssertTrue(desktop.content === renderers()[1].displayView)
        manager.shutdown()
    }

    @MainActor
    func testSupersededPreparationIsCancelledAndItsLateResultIgnored() async throws {
        let (manager, desktop, _, renderers) = makeManager()
        let b = wallpaper("B"), c = wallpaper("C")
        manager.apply(b)
        try await waitUntil { renderers().first?.isWaitingForPreparation == true }
        manager.apply(c)
        XCTAssertTrue(renderers()[0].isDisposed)
        try await waitUntil { renderers().count == 2 && renderers()[1].isWaitingForPreparation }
        // B 的迟到结果（这里是取消错误）不能影响 C。
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(manager.lastFailure)
        XCTAssertEqual(manager.state.preparingWallpaperID, c.id)
        renderers()[1].finishPreparation()
        try await waitUntil { manager.state.playbackState == .playing }
        XCTAssertEqual(manager.state.activeWallpaperID, c.id)
        XCTAssertTrue(desktop.content === renderers()[1].displayView)

        manager.apply(c)
        XCTAssertEqual(renderers().count, 3)
        XCTAssertTrue(renderers()[2].isDisposed, "Ignored duplicate request releases its unused renderer")
        XCTAssertFalse(renderers()[1].isDisposed)
        manager.shutdown()
    }

    @MainActor
    func testUnsupportedOrUnavailableTypesAreRejectedWithoutChangingState() async throws {
        let (manager, desktop, _, renderers) = makeManager()
        manager.apply(wallpaper("场景", .scene))
        XCTAssertEqual(manager.state, WallpaperRuntimeState())
        XCTAssertTrue(renderers().isEmpty)
        XCTAssertEqual(manager.lastFailure?.detail, "当前版本暂不支持此类型。")
        XCTAssertNil(desktop.content)

        // 默认工厂：Web 暂不可用，Scene 不支持。
        XCTAssertThrowsError(try WallpaperRuntimeManager.standardRenderer(for: wallpaper("网页", .web))) {
            XCTAssertEqual($0 as? WallpaperRuntimeError, .rendererUnavailable)
        }
        XCTAssertThrowsError(try WallpaperRuntimeManager.standardRenderer(for: wallpaper("场景", .scene))) {
            XCTAssertEqual($0 as? WallpaperRuntimeError, .unsupportedType)
        }
        XCTAssertTrue(try WallpaperRuntimeManager.standardRenderer(for: wallpaper("视频")) is VideoRenderer)
    }

    @MainActor
    func testActiveRendererFailureKeepsStaticContentAndMarksFailed() async throws {
        let (manager, desktop, log, renderers) = makeManager()
        let a = wallpaper("A")
        manager.apply(a)
        try await waitUntil { renderers().first?.isWaitingForPreparation == true }
        renderers()[0].finishPreparation()
        try await waitUntil { manager.state.playbackState == .playing }

        log.entries.removeAll()
        renderers()[0].onFailure?(FakeError())
        XCTAssertEqual(manager.state.playbackState, .failed)
        XCTAssertEqual(manager.lastFailure?.message, "无法加载“A”。")
        XCTAssertTrue(desktop.content === renderers()[0].displayView)
        manager.pause()
        manager.resume()
        XCTAssertEqual(log.entries, [], "Runtime does not restart or remove a failed renderer by itself")
        manager.stop()
        XCTAssertEqual(manager.state.playbackState, .stopped)
        XCTAssertNil(desktop.content)
    }

    @MainActor
    func testShutdownReleasesActiveAndCandidate() async throws {
        let (manager, desktop, _, renderers) = makeManager()
        manager.apply(wallpaper("A"))
        try await waitUntil { renderers().first?.isWaitingForPreparation == true }
        renderers()[0].finishPreparation()
        try await waitUntil { manager.state.playbackState == .playing }
        manager.apply(wallpaper("B"))
        try await waitUntil { renderers().count == 2 && renderers()[1].isWaitingForPreparation }
        manager.shutdown()
        XCTAssertTrue(renderers().allSatisfy { $0.isDisposed })
        XCTAssertNil(desktop.content)
        XCTAssertEqual(manager.state.playbackState, .stopped)
    }

    /// 真实 VideoRenderer + 真实桌面窗口，经由同一 Runtime 规则。
    @MainActor
    func testRealVideoRendererFollowsRuntimeRulesOnDesktop() async throws {
        let fixtures = { (name: String, ext: String) throws -> Wallpaper in
            let url = try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
            return Wallpaper(name: "\(name).\(ext)", type: .video, source: .local, resourceURL: url)
        }
        let first = try fixtures("loop", "mp4")
        let second = try fixtures("loop", "mov")
        let corrupt = try fixtures("corrupt", "mp4")
        let desktop = DesktopWindowRuntime(identifier: NSUserInterfaceItemIdentifier("Kinetic.Runtime.UnitTest"))
        var videos: [VideoRenderer] = []
        let manager = WallpaperRuntimeManager(desktop: desktop) { wallpaper in
            let renderer = try WallpaperRuntimeManager.standardRenderer(for: wallpaper)
            if let video = renderer as? VideoRenderer { videos.append(video) }
            return renderer
        }
        defer { manager.shutdown(); desktop.stop() }

        manager.apply(first)
        try await waitUntil { manager.state.playbackState == .playing }
        let firstVideo = try XCTUnwrap(videos.first)
        XCTAssertTrue(desktop.window?.contentView === firstVideo.contentView)
        try await waitUntil { firstVideo.currentTime.seconds > 0.5 }

        manager.pause()
        let pausedAt = firstVideo.currentTime.seconds
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(firstVideo.currentTime.seconds, pausedAt, accuracy: 0.025)
        XCTAssertEqual(manager.state.playbackState, .manualPaused)
        manager.setSmartPauseActive(true)
        manager.setSmartPauseActive(false)
        XCTAssertEqual(firstVideo.player?.rate, 0, "Smart condition ending keeps Manual Pause")
        manager.resume()
        try await waitUntil { firstVideo.currentTime.seconds > pausedAt + 0.15 }
        XCTAssertLessThan(pausedAt, firstVideo.currentTime.seconds, "Resume continues from the paused position")

        manager.apply(corrupt)
        try await waitUntil { manager.lastFailure != nil }
        XCTAssertEqual(manager.state.activeWallpaperID, first.id)
        XCTAssertTrue(desktop.window?.contentView === firstVideo.contentView, "Corrupt wallpaper keeps old content")

        manager.apply(second)
        try await waitUntil { manager.state.activeWallpaperID == second.id }
        let secondVideo = try XCTUnwrap(videos.last)
        XCTAssertTrue(desktop.window?.contentView === secondVideo.contentView)
        XCTAssertNil(firstVideo.player, "Previous renderer released after switch")
        try await waitUntil { secondVideo.currentTime.seconds > 0.3 }

        manager.stop()
        XCTAssertNil(desktop.window, "Stop removes the desktop window and restores the native wallpaper")
        XCTAssertNil(secondVideo.player)
        XCTAssertEqual(manager.state.playbackState, .stopped)
    }
}


/// UI-only Active 外观使用真实 Manager 的发布事件；Renderer 准备可控，确保不靠视频加载快慢蒙混通过。
extension WallpaperRuntimeManagerTests {
    @MainActor
    func testCardActiveVisualMovesBeforePreparationWithoutPromotingRuntime() async throws {
        let (manager, desktop, _, renderers) = makeManager()
        var presentation = WallpaperCardPresentation()
        let updates = manager.$state.sink { presentation.synchronize(with: $0) }
        defer { updates.cancel(); manager.shutdown() }
        let a = wallpaper("A"), b = wallpaper("B")
        manager.apply(a)
        try await waitUntil { renderers().first?.isWaitingForPreparation == true }
        renderers()[0].finishPreparation()
        try await waitUntil { manager.state.activeWallpaperID == a.id }

        presentation.beginApply(b.id)
        XCTAssertEqual(presentation.displayedActiveWallpaperID(in: manager.state), b.id,
                       "Card B becomes active in the Apply action, before even calling Runtime")
        XCTAssertEqual(manager.activeWallpaper, a)
        manager.apply(b)
        presentation.synchronize(with: manager.state)
        XCTAssertEqual(presentation.displayedActiveWallpaperID(in: manager.state), b.id)
        XCTAssertEqual(manager.state.activeWallpaperID, a.id)
        XCTAssertTrue(desktop.content === renderers()[0].displayView)
        XCTAssertFalse(renderers()[0].isDisposed)

        manager.pause()
        XCTAssertEqual(presentation.displayedActiveWallpaperID(in: manager.state), b.id)
        XCTAssertEqual(manager.state.playbackState, .manualPaused)
        manager.resume()
        try await waitUntil { renderers()[1].isWaitingForPreparation }
        renderers()[1].finishPreparation()
        try await waitUntil { manager.state.activeWallpaperID == b.id }
        XCTAssertNil(presentation.targetWallpaperID)
        XCTAssertEqual(presentation.displayedActiveWallpaperID(in: manager.state), b.id)
        XCTAssertEqual(manager.activeWallpaper, b)
    }

    @MainActor
    func testFailedApplyRollsCardVisualBackToActualWallpaper() async throws {
        let (manager, desktop, _, renderers) = makeManager()
        var presentation = WallpaperCardPresentation()
        let updates = manager.$state.sink { presentation.synchronize(with: $0) }
        defer { updates.cancel(); manager.shutdown() }
        let a = wallpaper("A"), b = wallpaper("B")
        manager.apply(a)
        try await waitUntil { renderers().first?.isWaitingForPreparation == true }
        renderers()[0].finishPreparation()
        try await waitUntil { manager.state.activeWallpaperID == a.id }

        presentation.beginApply(b.id)
        manager.apply(b)
        presentation.synchronize(with: manager.state)
        XCTAssertEqual(presentation.displayedActiveWallpaperID(in: manager.state), b.id)
        try await waitUntil { renderers()[1].isWaitingForPreparation }
        renderers()[1].finishPreparation(FakeError())
        try await waitUntil { manager.lastFailure != nil }
        XCTAssertNil(presentation.targetWallpaperID)
        XCTAssertEqual(presentation.displayedActiveWallpaperID(in: manager.state), a.id)
        XCTAssertEqual(manager.activeWallpaper, a)
        XCTAssertTrue(desktop.content === renderers()[0].displayView)
        XCTAssertFalse(renderers()[0].isDisposed)
    }

    @MainActor
    func testLatestApplyOwnsCardVisualDespiteOlderCancellationAndStopClearsIt() async throws {
        let (manager, _, _, renderers) = makeManager()
        var presentation = WallpaperCardPresentation()
        let updates = manager.$state.sink { presentation.synchronize(with: $0) }
        defer { updates.cancel(); manager.shutdown() }
        let a = wallpaper("A"), b = wallpaper("B"), c = wallpaper("C")
        manager.apply(a)
        try await waitUntil { renderers().first?.isWaitingForPreparation == true }
        renderers()[0].finishPreparation()
        try await waitUntil { manager.state.activeWallpaperID == a.id }

        presentation.beginApply(b.id)
        manager.apply(b)
        presentation.synchronize(with: manager.state)
        try await waitUntil { renderers()[1].isWaitingForPreparation }
        presentation.beginApply(c.id)
        XCTAssertEqual(presentation.displayedActiveWallpaperID(in: manager.state), c.id)
        manager.apply(c)
        presentation.synchronize(with: manager.state)
        XCTAssertEqual(presentation.displayedActiveWallpaperID(in: manager.state), c.id)
        XCTAssertEqual(manager.activeWallpaper, a)
        try await waitUntil { renderers()[2].isWaitingForPreparation }
        XCTAssertTrue(renderers()[1].isDisposed)
        // 让 B 的取消结果有机会回到 MainActor；不能把 C 的 UI 回滚到 A/B。
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(presentation.displayedActiveWallpaperID(in: manager.state), c.id)
        XCTAssertEqual(manager.state.preparingWallpaperID, c.id)

        manager.stop()
        XCTAssertNil(presentation.targetWallpaperID)
        XCTAssertNil(presentation.displayedActiveWallpaperID(in: manager.state))
        XCTAssertNil(manager.activeWallpaper)
        XCTAssertTrue(renderers()[2].isDisposed)
    }

    @MainActor
    func testSynchronousRendererRejectionClearsCardTargetWithoutStatePublication() async throws {
        let log = CallLog()
        let desktop = FakeDesktop(log: log)
        let a = wallpaper("A"), rejected = wallpaper("Rejected")
        let renderer = FakeRenderer(wallpaper: a, log: log, instance: 1)
        let manager = WallpaperRuntimeManager(desktop: desktop) { wallpaper in
            if wallpaper.id == rejected.id { throw FakeError() }
            return renderer
        }
        defer { manager.shutdown() }
        manager.apply(a)
        try await waitUntil { renderer.isWaitingForPreparation }
        renderer.finishPreparation()
        try await waitUntil { manager.state.activeWallpaperID == a.id }
        let originalState = manager.state
        var presentation = WallpaperCardPresentation()
        presentation.beginApply(rejected.id)
        XCTAssertEqual(presentation.displayedActiveWallpaperID(in: manager.state), rejected.id)
        manager.apply(rejected)
        XCTAssertEqual(manager.state, originalState, "Factory rejection does not publish a new runtime state")
        presentation.synchronize(with: manager.state)
        XCTAssertNil(presentation.targetWallpaperID)
        XCTAssertEqual(presentation.displayedActiveWallpaperID(in: manager.state), a.id)
        XCTAssertEqual(manager.lastFailure?.wallpaperID, rejected.id)
    }
}
