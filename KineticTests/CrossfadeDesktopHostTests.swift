import AppKit
import XCTest
@testable import Kinetic

@MainActor
private final class CrossfadeLog {
    var entries: [String] = []
}

/// 可控 Renderer：记录释放时其内容是否已经离开窗口，以及调用顺序。
@MainActor
private final class CrossfadeFakeRenderer: WallpaperRenderer {
    let wallpaper: Wallpaper
    let displayView: NSView
    var onFailure: (@MainActor (Error) -> Void)?
    private let log: CrossfadeLog
    private var continuation: CheckedContinuation<Void, Error>?
    private(set) var isDisposed = false
    private(set) var wasAttachedWhenDisposed = false
    var isWaitingForPreparation: Bool { continuation != nil }

    init(wallpaper: Wallpaper, log: CrossfadeLog) {
        self.wallpaper = wallpaper
        self.log = log
        displayView = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36))
        displayView.wantsLayer = true
        displayView.layer?.backgroundColor = NSColor.systemTeal.cgColor
    }

    func prepare() async throws {
        try await withCheckedThrowingContinuation { self.continuation = $0 }
    }

    func finishPreparation(_ error: Error? = nil) {
        let pending = continuation
        continuation = nil
        if let error { pending?.resume(throwing: error) } else { pending?.resume() }
    }

    func play() { log.entries.append("play:\(wallpaper.name)") }
    func pause() { log.entries.append("pause:\(wallpaper.name)") }
    func resume() { log.entries.append("resume:\(wallpaper.name)") }
    func setMuted(_ muted: Bool) {}

    func dispose() {
        guard !isDisposed else { return }
        isDisposed = true
        wasAttachedWhenDisposed = displayView.superview != nil
        log.entries.append("dispose:\(wallpaper.name)")
        finishPreparation(CancellationError())
    }
}

private struct CrossfadeFakeError: LocalizedError {
    var errorDescription: String? { "crossfade fake failure" }
}

private final class WeakVideo {
    weak var value: VideoRenderer?
    init(_ value: VideoRenderer) { self.value = value }
}

/// Crossfade Engine。使用真实桌面窗口，确保 Core Animation 真的在屏幕上运行。
final class CrossfadeDesktopHostTests: XCTestCase {
    private let identifier = NSUserInterfaceItemIdentifier("Kinetic.Crossfade.UnitTest")

    @MainActor
    private func waitUntil(timeout: TimeInterval = 8, _ predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !predicate() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                XCTFail("Timed out waiting for crossfade condition")
                throw CancellationError()
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @MainActor
    private func opaqueView(_ color: NSColor) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36))
        view.wantsLayer = true
        view.layer?.backgroundColor = color.cgColor
        return view
    }

    private func wallpaper(_ name: String) -> Wallpaper {
        Wallpaper(name: name, type: .video, source: .local,
                  resourceURL: URL(fileURLWithPath: "/kinetic-crossfade-fixtures/\(name)"))
    }

    @MainActor
    func testStandardDurationMatchesSpec() {
        XCTAssertGreaterThanOrEqual(CrossfadeDesktopHost.standardDuration, 0.3)
        XCTAssertLessThanOrEqual(CrossfadeDesktopHost.standardDuration, 0.4)
    }

    @MainActor
    func testFirstContentAppearsImmediatelyWithoutFade() async throws {
        let desktop = DesktopWindowRuntime(identifier: identifier)
        let host = CrossfadeDesktopHost(desktop: desktop)
        defer { host.stop() }
        let a = opaqueView(.systemBlue)
        var completed = false
        host.transition(to: a) { completed = true }
        XCTAssertTrue(completed, "No outgoing content: nothing to fade from")
        XCTAssertEqual(host.stage.contents, [a])
        XCTAssertEqual(host.stage.slot(containing: a)?.alphaValue, 1)
        XCTAssertFalse(host.isTransitioning)
        XCTAssertTrue(desktop.window?.contentView === host.stage)
        XCTAssertEqual(host.completedTransitionCount, 0)
    }

    @MainActor
    func testOutgoingStaysFullyVisibleUntilIncomingHasFadedIn() async throws {
        let desktop = DesktopWindowRuntime(identifier: identifier)
        let host = CrossfadeDesktopHost(desktop: desktop)
        defer { host.stop() }
        let a = opaqueView(.systemBlue), b = opaqueView(.systemOrange)
        host.present(a)
        let window = try XCTUnwrap(desktop.window)

        var completed = false
        var outgoingDetachedAtCompletion = false
        host.transition(to: b) {
            completed = true
            outgoingDetachedAtCompletion = a.superview == nil
        }
        XCTAssertTrue(host.isTransitioning)
        XCTAssertEqual(host.stage.contents, [a, b], "B fades in above A")
        XCTAssertEqual(host.stage.slot(containing: a)?.alphaValue, 1)
        XCTAssertFalse(completed)

        // 采样表现层透明度，证明是渐变而非硬切；底层 A 始终完全不透明。
        var intermediateOpacities: [Float] = []
        let start = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - start < 0.25 {
            XCTAssertEqual(host.stage.contents.first, a)
            XCTAssertEqual(host.stage.slot(containing: a)?.alphaValue, 1)
            if let opacity = host.stage.slot(containing: b)?.layer?.presentation()?.opacity, opacity > 0.02, opacity < 0.98 {
                intermediateOpacities.append(opacity)
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(completed, "A must not be released before the fade finishes")
        XCTAssertFalse(intermediateOpacities.isEmpty, "Incoming content must pass through intermediate opacity")

        try await waitUntil(timeout: 2) { completed }
        XCTAssertTrue(outgoingDetachedAtCompletion, "A leaves the window before the caller releases it")
        XCTAssertEqual(host.stage.contents, [b])
        XCTAssertEqual(host.stage.slot(containing: b)?.alphaValue, 1)
        XCTAssertEqual(host.stage.subviews.count, 1, "Outgoing container is removed as well")
        XCTAssertTrue(desktop.window === window, "Same desktop window is reused")
        let duration = try XCTUnwrap(host.lastTransitionDuration)
        XCTAssertGreaterThanOrEqual(duration, 0.3)
        XCTAssertLessThan(duration, 1.0)
        XCTAssertEqual(host.completedTransitionCount, 1)
    }

    @MainActor
    func testNewTransitionDuringFadeCompletesThePreviousOneFirst() async throws {
        let desktop = DesktopWindowRuntime(identifier: identifier)
        let host = CrossfadeDesktopHost(desktop: desktop)
        defer { host.stop() }
        let a = opaqueView(.systemBlue), b = opaqueView(.systemOrange), c = opaqueView(.systemGreen)
        host.present(a)
        var bDone = false, cDone = false
        host.transition(to: b) { bDone = true }
        try await Task.sleep(nanoseconds: 100_000_000)
        host.transition(to: c) { cDone = true }
        XCTAssertTrue(bDone)
        XCTAssertNil(a.superview)
        XCTAssertEqual(host.stage.contents, [b, c])
        XCTAssertEqual(host.stage.slot(containing: b)?.alphaValue, 1, "B was snapped to fully opaque before A was removed")
        XCTAssertFalse(cDone)
        try await waitUntil(timeout: 2) { cDone }
        XCTAssertEqual(host.stage.contents, [c])
        XCTAssertEqual(host.completedTransitionCount, 2)
    }

    @MainActor
    func testStopDuringFadeRemovesContentBeforeReleasingOutgoing() async throws {
        let desktop = DesktopWindowRuntime(identifier: identifier)
        let host = CrossfadeDesktopHost(desktop: desktop)
        defer { host.stop() }
        let a = opaqueView(.systemBlue), b = opaqueView(.systemOrange)
        host.present(a)
        var detached = false, windowClosed = false
        host.transition(to: b) {
            detached = a.superview == nil && b.superview == nil
            windowClosed = desktop.window == nil
        }
        host.stop()
        XCTAssertTrue(detached)
        XCTAssertTrue(windowClosed, "Native wallpaper is restored before the old renderer is released")
        XCTAssertTrue(host.stage.contents.isEmpty)
        XCTAssertFalse(host.isTransitioning)

        let c = opaqueView(.systemGreen)
        host.present(c)
        XCTAssertTrue(desktop.window?.contentView === host.stage, "Stage is shown again after stop")
        XCTAssertEqual(host.stage.contents, [c])
    }

    @MainActor
    func testManagerReleasesOldRendererOnlyAfterFadeAndPausesBothDuringFade() async throws {
        let log = CrossfadeLog()
        let desktop = DesktopWindowRuntime(identifier: identifier)
        let host = CrossfadeDesktopHost(desktop: desktop)
        var renderers: [CrossfadeFakeRenderer] = []
        let manager = WallpaperRuntimeManager(desktop: host) { wallpaper in
            let renderer = CrossfadeFakeRenderer(wallpaper: wallpaper, log: log)
            renderers.append(renderer)
            return renderer
        }
        defer { manager.shutdown() }

        manager.apply(wallpaper("A"))
        try await waitUntil { renderers.first?.isWaitingForPreparation == true }
        renderers[0].finishPreparation()
        try await waitUntil { manager.state.playbackState == .playing }
        XCTAssertEqual(host.stage.contents, [renderers[0].displayView])

        manager.apply(wallpaper("B"))
        try await waitUntil { renderers.count == 2 && renderers[1].isWaitingForPreparation }
        log.entries.removeAll()
        renderers[1].finishPreparation()
        try await waitUntil { manager.state.activeWallpaperID == renderers[1].wallpaper.id }
        XCTAssertEqual(log.entries, ["play:B"], "B plays while fading in; A is not released yet")
        XCTAssertEqual(host.stage.contents, [renderers[0].displayView, renderers[1].displayView])
        XCTAssertFalse(renderers[0].isDisposed)

        manager.pause()
        XCTAssertEqual(log.entries, ["play:B", "pause:B", "pause:A"], "Pause also freezes the fading-out wallpaper")

        try await waitUntil(timeout: 2) { renderers[0].isDisposed }
        XCTAssertFalse(renderers[0].wasAttachedWhenDisposed)
        XCTAssertEqual(host.stage.contents, [renderers[1].displayView])
        XCTAssertEqual(manager.state.playbackState, .manualPaused)

        // 淡入中停止：两者都先离开窗口，再释放。
        manager.resume()
        manager.apply(wallpaper("C"))
        try await waitUntil { renderers.count == 3 && renderers[2].isWaitingForPreparation }
        renderers[2].finishPreparation()
        try await waitUntil { host.isTransitioning }
        manager.stop()
        XCTAssertTrue(renderers[1].isDisposed && renderers[2].isDisposed)
        XCTAssertFalse(renderers[1].wasAttachedWhenDisposed)
        XCTAssertFalse(renderers[2].wasAttachedWhenDisposed)
        XCTAssertNil(desktop.window)
        XCTAssertEqual(manager.state.playbackState, .stopped)
    }

    @MainActor
    func testFailedCandidateNeverStartsAFade() async throws {
        let log = CrossfadeLog()
        let desktop = DesktopWindowRuntime(identifier: identifier)
        let host = CrossfadeDesktopHost(desktop: desktop)
        var renderers: [CrossfadeFakeRenderer] = []
        let manager = WallpaperRuntimeManager(desktop: host) { wallpaper in
            let renderer = CrossfadeFakeRenderer(wallpaper: wallpaper, log: log)
            renderers.append(renderer)
            return renderer
        }
        defer { manager.shutdown() }
        manager.apply(wallpaper("A"))
        try await waitUntil { renderers.first?.isWaitingForPreparation == true }
        renderers[0].finishPreparation()
        try await waitUntil { manager.state.playbackState == .playing }

        manager.apply(wallpaper("B"))
        try await waitUntil { renderers.count == 2 && renderers[1].isWaitingForPreparation }
        renderers[1].finishPreparation(CrossfadeFakeError())
        try await waitUntil { manager.lastFailure != nil }
        XCTAssertFalse(host.isTransitioning)
        XCTAssertEqual(host.completedTransitionCount, 0)
        XCTAssertEqual(host.stage.contents, [renderers[0].displayView], "A keeps playing untouched")
        XCTAssertEqual(manager.state.playbackState, .playing)
        XCTAssertFalse(renderers[0].isDisposed)
    }

    /// 真实视频连续切换 50 次，舞台底层始终有完整画面，旧 Renderer 全部释放。
    @MainActor
    func testFiftyRealVideoSwitchesNeverExposeAnEmptyDesktop() async throws {
        func fixture(_ name: String) throws -> Wallpaper {
            let url = try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: "mp4", subdirectory: "Fixtures"))
            return Wallpaper(name: name, type: .video, source: .local, resourceURL: url)
        }
        let blue = try fixture("loop"), warm = try fixture("loop-warm")
        let desktop = DesktopWindowRuntime(identifier: identifier)
        let host = CrossfadeDesktopHost(desktop: desktop)
        var created: [WeakVideo] = []
        let manager = WallpaperRuntimeManager(desktop: host) { wallpaper in
            let renderer = try WallpaperRuntimeManager.standardRenderer(for: wallpaper)
            if let video = renderer as? VideoRenderer { created.append(WeakVideo(video)) }
            return renderer
        }
        defer { manager.shutdown() }

        manager.apply(blue)
        try await waitUntil { manager.state.playbackState == .playing }

        var samples = 0, gaps = 0, fadeSamples = 0
        var durations: [TimeInterval] = []
        for index in 0..<50 {
            let target = index.isMultiple(of: 2) ? warm : blue
            manager.apply(target)
            let deadline = ProcessInfo.processInfo.systemUptime + 10
            while !(manager.state.activeWallpaperID == target.id && !host.isTransitioning) {
                XCTAssertLessThan(ProcessInfo.processInfo.systemUptime, deadline, "Switch \(index + 1) timed out")
                guard ProcessInfo.processInfo.systemUptime < deadline else { break }
                samples += 1
                let baseSlot = host.stage.subviews.first
                let ready = (baseSlot?.subviews.first as? VideoContentView)?.hasPoster == true
                if baseSlot == nil || baseSlot?.alphaValue != 1 || !ready || desktop.window?.isVisible != true { gaps += 1 }
                if host.isTransitioning, host.stage.subviews.count == 2,
                   let opacity = host.stage.subviews.last?.layer?.presentation()?.opacity, opacity > 0.02, opacity < 0.98 {
                    fadeSamples += 1
                }
                try await Task.sleep(nanoseconds: 4_000_000)
            }
            if let duration = host.lastTransitionDuration { durations.append(duration) }
        }

        print("CROSSFADE switches=50 fades=\(host.completedTransitionCount) samples=\(samples) gaps=\(gaps) fadeSamples=\(fadeSamples) avg=\(durations.reduce(0, +) / Double(max(durations.count, 1))) max=\(durations.max() ?? 0)")
        XCTAssertEqual(gaps, 0, "The desktop always shows a fully opaque, decoded frame")
        XCTAssertGreaterThan(samples, 50)
        XCTAssertGreaterThan(fadeSamples, 50, "Real video content visibly passes through intermediate opacity")
        XCTAssertEqual(host.completedTransitionCount, 50)
        XCTAssertEqual(durations.count, 50)
        XCTAssertGreaterThanOrEqual(durations.min() ?? 0, 0.3)
        XCTAssertLessThan(durations.max() ?? .infinity, 1.0)
        XCTAssertNil(manager.lastFailure)
        XCTAssertEqual(host.stage.contents.count, 1)
        XCTAssertEqual(manager.state.activeWallpaperID, blue.id)
        XCTAssertEqual(created.count, 51)
        // 除当前壁纸外，所有旧 Renderer 都已释放。
        try await waitUntil(timeout: 5) { created.dropLast().allSatisfy { $0.value == nil } }
        XCTAssertNotNil(created.last?.value)
    }
}
