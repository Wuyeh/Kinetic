import AppKit
import XCTest
@testable import Kinetic

/// Kinetic 1.0 Module 5：Runtime 由每台显示器独立的会话组成。
/// 这里用两个假的桌面宿主模拟两台显示器，验证每台显示器的会话互不影响（规格 17、22、23、25）。
@MainActor
private final class Log {
    var entries: [String] = []
}

@MainActor
private final class Desktop: DesktopContentHost {
    let name: String
    let log: Log
    private(set) var content: NSView?
    init(_ name: String, log: Log) {
        self.name = name
        self.log = log
    }

    func present(_ contentView: NSView) -> Bool {
        content = contentView
        log.entries.append("\(name).present:\(contentView.identifier?.rawValue ?? "?")")
        return true
    }

    func stop() {
        content = nil
        log.entries.append("\(name).stop")
    }

    /// 模拟交叉淡化：新内容就位后通知释放旧内容。
    func transition(to contentView: NSView, completion: @escaping @MainActor () -> Void) -> Bool {
        content = contentView
        log.entries.append("\(name).transition:\(contentView.identifier?.rawValue ?? "?")")
        completion()
        return true
    }
}

@MainActor
private final class Renderer: WallpaperRenderer {
    let wallpaper: Wallpaper
    let displayView = NSView()
    var onFailure: (@MainActor (Error) -> Void)?
    let log: Log
    private var continuation: CheckedContinuation<Void, Error>?
    private(set) var isDisposed = false
    private(set) var isMuted = true
    var isWaiting: Bool { continuation != nil }
    var tag: String { displayView.identifier?.rawValue ?? "?" }

    init(wallpaper: Wallpaper, log: Log, instance: Int) {
        self.wallpaper = wallpaper
        self.log = log
        displayView.identifier = NSUserInterfaceItemIdentifier("\(wallpaper.name)#\(instance)")
    }

    func prepare() async throws {
        log.entries.append("prepare:\(tag)")
        try await withCheckedThrowingContinuation { self.continuation = $0 }
    }

    func finish(_ error: Error? = nil) {
        let pending = continuation
        continuation = nil
        if let error { pending?.resume(throwing: error) } else { pending?.resume() }
    }

    func play() { log.entries.append("play:\(tag)") }
    func pause() { log.entries.append("pause:\(tag)") }
    func resume() { log.entries.append("resume:\(tag)") }
    func setMuted(_ muted: Bool) {
        isMuted = muted
        log.entries.append("mute:\(tag):\(muted)")
    }

    func dispose() {
        guard !isDisposed else { return }
        isDisposed = true
        onFailure = nil
        log.entries.append("dispose:\(tag)")
        finish(CancellationError())
    }
}

private struct Failure: LocalizedError {
    var errorDescription: String? { "fake failure" }
}

final class MultiDisplayRuntimeTests: XCTestCase {
    private let displayA = DisplayID("display-A")
    private let displayB = DisplayID("display-B")

    @MainActor
    private final class RendererList {
        var items: [Renderer] = []
    }

    @MainActor
    private final class Harness {
        let log: Log
        let manager: WallpaperRuntimeManager
        private let list: RendererList
        var desktops: [DisplayID: Desktop] = [:]
        var renderers: [Renderer] { list.items }

        init() {
            let log = Log()
            let list = RendererList()
            self.log = log
            self.list = list
            manager = WallpaperRuntimeManager { wallpaper in
                let renderer = Renderer(wallpaper: wallpaper, log: log, instance: list.items.count + 1)
                list.items.append(renderer)
                return renderer
            }
        }

        func addDisplay(_ id: DisplayID, name: String) {
            let desktop = Desktop(name, log: log)
            desktops[id] = desktop
            manager.addDisplay(id, name: name, host: desktop)
        }

        func renderer(_ tag: String) -> Renderer? { renderers.first { $0.tag == tag } }
    }

    @MainActor
    private func wait(timeout: TimeInterval = 8, _ predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !predicate() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                XCTFail("Timed out waiting for runtime condition")
                throw CancellationError()
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func wallpaper(_ name: String) -> Wallpaper {
        Wallpaper(name: name, type: .video, source: .local,
                  resourceURL: URL(fileURLWithPath: "/kinetic-multi-display-fixtures/\(name)"))
    }

    /// 在目标显示器上应用并等待开始播放。
    @MainActor
    private func applyAndPlay(_ wallpaper: Wallpaper, on display: DisplayID, in harness: Harness,
                              tag: String) async throws {
        harness.manager.apply(wallpaper, to: display)
        try await wait { harness.renderer(tag)?.isWaiting == true }
        harness.renderer(tag)?.finish()
        try await wait { harness.manager.state(of: display)?.activeWallpaperID == wallpaper.id }
    }

    @MainActor
    private func twoDisplays() -> Harness {
        let harness = Harness()
        harness.addDisplay(displayA, name: "A")
        harness.addDisplay(displayB, name: "B")
        return harness
    }

    // MARK: - 会话

    @MainActor
    func testEachDisplayHasItsOwnSessionInOrderAndTheLegacyStateFollowsTheFirst() {
        let harness = twoDisplays()
        XCTAssertEqual(harness.manager.displayIDs, [displayA, displayB])
        XCTAssertEqual(harness.manager.summary.displays.map(\.displayID), [displayA, displayB])
        XCTAssertEqual(harness.manager.summary.displays.map(\.displayName), ["A", "B"])
        XCTAssertEqual(harness.manager.summary.playbackState, .noWallpaper)
        XCTAssertEqual(harness.manager.state, WallpaperRuntimeState())

        // 重复加入只更新名称，不重建会话。
        harness.manager.addDisplay(displayB, name: "Studio Display", host: Desktop("B2", log: harness.log))
        XCTAssertEqual(harness.manager.displayIDs, [displayA, displayB])
        XCTAssertEqual(harness.manager.summary.displays.last?.displayName, "Studio Display")
    }

    @MainActor
    func testApplyChangesOnlyTheTargetDisplay() async throws {
        let harness = twoDisplays()
        let one = wallpaper("W1"), two = wallpaper("W2"), three = wallpaper("W3")
        try await applyAndPlay(one, on: displayA, in: harness, tag: "W1#1")
        try await applyAndPlay(two, on: displayB, in: harness, tag: "W2#2")
        XCTAssertTrue(harness.desktops[displayA]?.content === harness.renderer("W1#1")?.displayView)
        XCTAssertTrue(harness.desktops[displayB]?.content === harness.renderer("W2#2")?.displayView)
        XCTAssertEqual(harness.manager.summary.playingDisplayCount, 2)

        // A：W1 → W3，B 保持 W2：B 不暂停、不黑屏、不重载（规格 22）。
        harness.log.entries.removeAll()
        harness.manager.apply(three, to: displayA)
        try await wait { harness.renderer("W3#3")?.isWaiting == true }
        XCTAssertEqual(harness.manager.state(of: displayA)?.activeWallpaperID, one.id, "A keeps W1 while W3 prepares")
        harness.renderer("W3#3")?.finish()
        try await wait { harness.manager.state(of: displayA)?.activeWallpaperID == three.id }

        XCTAssertEqual(harness.log.entries, ["prepare:W3#3", "A.transition:W3#3", "dispose:W1#1", "play:W3#3"],
                       "Only display A transitions; nothing touches B")
        XCTAssertTrue(harness.desktops[displayB]?.content === harness.renderer("W2#2")?.displayView)
        XCTAssertFalse(harness.renderer("W2#2")?.isDisposed ?? true)
        XCTAssertEqual(harness.manager.state(of: displayB)?.playbackState, .playing)
        harness.manager.shutdown()
    }

    @MainActor
    func testLegacyApplyWithoutTargetNeverGuessesADisplayWhenThereAreSeveral() async throws {
        let harness = twoDisplays()
        harness.manager.apply(wallpaper("W1"))
        XCTAssertTrue(harness.renderers.isEmpty, "No renderer is created without an explicit target")
        XCTAssertEqual(harness.manager.summary.playbackState, .noWallpaper)
        XCTAssertNil(harness.desktops[displayA]?.content)
        XCTAssertNil(harness.desktops[displayB]?.content)

        // 只有一个会话时，v0.1 的入口仍直接应用到它。
        let single = Harness()
        single.addDisplay(.main, name: "")
        let only = wallpaper("W1")
        single.manager.apply(only)
        try await wait { single.renderer("W1#1")?.isWaiting == true }
        XCTAssertEqual(single.manager.state.preparingWallpaperID, only.id)
        XCTAssertEqual(single.manager.state(of: .main)?.preparingWallpaperID, only.id)
        single.manager.shutdown()
    }

    @MainActor
    func testApplyToAnUnknownDisplayDoesNothing() {
        let harness = twoDisplays()
        harness.manager.apply(wallpaper("W1"), to: DisplayID("disconnected"))
        XCTAssertTrue(harness.renderers.isEmpty)
        XCTAssertNil(harness.manager.lastFailure)
        XCTAssertEqual(harness.manager.summary.playbackState, .noWallpaper)
    }

    // MARK: - 失败隔离

    @MainActor
    func testFailureOnOneDisplayKeepsItsOldWallpaperAndReportsThatDisplay() async throws {
        let harness = twoDisplays()
        let one = wallpaper("W1"), two = wallpaper("W2"), broken = wallpaper("雨夜")
        try await applyAndPlay(one, on: displayA, in: harness, tag: "W1#1")
        try await applyAndPlay(two, on: displayB, in: harness, tag: "W2#2")

        harness.manager.apply(broken, to: displayB)
        try await wait { harness.renderer("雨夜#3")?.isWaiting == true }
        harness.renderer("雨夜#3")?.finish(Failure())
        try await wait { harness.manager.lastFailure != nil }

        XCTAssertEqual(harness.manager.lastFailure?.displayID, displayB, "Retry must go back to the same display")
        XCTAssertEqual(harness.manager.lastFailure?.message, "无法加载“雨夜”。")
        XCTAssertEqual(harness.manager.state(of: displayB)?.activeWallpaperID, two.id)
        XCTAssertTrue(harness.desktops[displayB]?.content === harness.renderer("W2#2")?.displayView, "No black screen")
        XCTAssertEqual(harness.manager.state(of: displayA)?.activeWallpaperID, one.id)
        XCTAssertEqual(harness.manager.state(of: displayA)?.playbackState, .playing)

        // 在另一台显示器上准备新壁纸，不清除 B 的错误。
        harness.manager.apply(wallpaper("W4"), to: displayA)
        try await wait { harness.renderer("W4#4")?.isWaiting == true }
        XCTAssertEqual(harness.manager.lastFailure?.displayID, displayB)
        // B 自己重新准备时清除。
        harness.manager.apply(wallpaper("W5"), to: displayB)
        try await wait { harness.renderer("W5#5")?.isWaiting == true }
        XCTAssertNil(harness.manager.lastFailure)
        harness.manager.shutdown()
    }

    @MainActor
    func testRunningFailureOnOneDisplayDoesNotAffectTheOther() async throws {
        let harness = twoDisplays()
        try await applyAndPlay(wallpaper("W1"), on: displayA, in: harness, tag: "W1#1")
        try await applyAndPlay(wallpaper("W2"), on: displayB, in: harness, tag: "W2#2")
        harness.renderer("W1#1")?.onFailure?(Failure())
        XCTAssertEqual(harness.manager.state(of: displayA)?.playbackState, .failed)
        XCTAssertEqual(harness.manager.state(of: displayB)?.playbackState, .playing)
        XCTAssertEqual(harness.manager.lastFailure?.displayID, displayA)
        XCTAssertTrue(harness.desktops[displayA]?.content === harness.renderer("W1#1")?.displayView)
        XCTAssertEqual(harness.manager.summary.playbackState, .playing)
        harness.manager.shutdown()
    }

    // MARK: - 暂停 / 停止 / 重新启用的范围

    @MainActor
    func testPauseAndResumeCanTargetOneDisplayOrAll() async throws {
        let harness = twoDisplays()
        try await applyAndPlay(wallpaper("W1"), on: displayA, in: harness, tag: "W1#1")
        try await applyAndPlay(wallpaper("W2"), on: displayB, in: harness, tag: "W2#2")

        harness.log.entries.removeAll()
        harness.manager.pause(.display(displayA))
        XCTAssertEqual(harness.log.entries, ["pause:W1#1"])
        XCTAssertEqual(harness.manager.state(of: displayA)?.playbackState, .manualPaused)
        XCTAssertEqual(harness.manager.state(of: displayB)?.playbackState, .playing)
        XCTAssertEqual(harness.manager.summary.playbackState, .playing, "At least one display is playing")

        harness.log.entries.removeAll()
        harness.manager.pause()
        XCTAssertEqual(harness.log.entries, ["pause:W2#2"], "Pause all only affects displays still playing")
        XCTAssertEqual(harness.manager.summary.playbackState, .manualPaused)
        XCTAssertFalse(harness.manager.summary.hasEnabledDisplay, "Menu bar logo turns monochrome")

        harness.log.entries.removeAll()
        harness.manager.resume(.display(displayB))
        XCTAssertEqual(harness.log.entries, ["resume:W2#2"])
        XCTAssertEqual(harness.manager.state(of: displayA)?.playbackState, .manualPaused)
        harness.manager.resume()
        XCTAssertEqual(harness.manager.summary.playingDisplayCount, 2)
        harness.manager.shutdown()
    }

    @MainActor
    func testStopOneDisplayRestoresOnlyItsNativeWallpaperAndReenableUsesItsLastWallpaper() async throws {
        let harness = twoDisplays()
        let one = wallpaper("W1"), two = wallpaper("W2")
        try await applyAndPlay(one, on: displayA, in: harness, tag: "W1#1")
        try await applyAndPlay(two, on: displayB, in: harness, tag: "W2#2")

        harness.log.entries.removeAll()
        harness.manager.stop(.display(displayA))
        XCTAssertEqual(harness.log.entries, ["A.stop", "dispose:W1#1"])
        XCTAssertNil(harness.desktops[displayA]?.content)
        XCTAssertEqual(harness.manager.state(of: displayA)?.playbackState, .stopped)
        XCTAssertEqual(harness.manager.state(of: displayB)?.playbackState, .playing)
        XCTAssertEqual(harness.manager.lastActiveWallpaper(on: displayA), one)

        harness.manager.stop()
        XCTAssertEqual(harness.manager.summary.playbackState, .stopped)

        harness.manager.reenable(.display(displayB))
        try await wait { harness.renderer("W2#3")?.isWaiting == true }
        harness.renderer("W2#3")?.finish()
        try await wait { harness.manager.state(of: displayB)?.playbackState == .playing }
        XCTAssertEqual(harness.manager.state(of: displayA)?.playbackState, .stopped, "Only B was re-enabled")

        harness.manager.reenable()
        try await wait { harness.renderer("W1#4")?.isWaiting == true }
        harness.renderer("W1#4")?.finish()
        try await wait { harness.manager.state(of: displayA)?.activeWallpaperID == one.id }
        XCTAssertEqual(harness.renderers.count, 4, "Re-enable all skips a display that is already playing")
        harness.manager.shutdown()
    }

    // MARK: - 智能暂停与音频

    @MainActor
    func testSmartPauseAndAudioApplyToAllDisplaysAndNewDisplaysInheritThem() async throws {
        let harness = twoDisplays()
        try await applyAndPlay(wallpaper("W1"), on: displayA, in: harness, tag: "W1#1")
        try await applyAndPlay(wallpaper("W2"), on: displayB, in: harness, tag: "W2#2")
        harness.manager.pause(.display(displayA))

        harness.log.entries.removeAll()
        harness.manager.setSmartPauseActive(true)
        XCTAssertEqual(harness.log.entries, ["pause:W2#2"])
        XCTAssertEqual(harness.manager.state(of: displayA)?.playbackState, .manualPaused, "Manual pause wins")
        XCTAssertEqual(harness.manager.state(of: displayB)?.playbackState, .smartPaused)
        XCTAssertTrue(harness.manager.summary.hasEnabledDisplay)

        harness.manager.setAudioEnabled(true)
        XCTAssertEqual(harness.renderer("W1#1")?.isMuted, false)
        XCTAssertEqual(harness.renderer("W2#2")?.isMuted, false)

        // 新显示器在智能暂停期间加入：它的壁纸准备好后保持暂停，并继承音频开关。
        let displayC = DisplayID("display-C")
        harness.addDisplay(displayC, name: "C")
        harness.manager.apply(wallpaper("W3"), to: displayC)
        try await wait { harness.renderer("W3#3")?.isWaiting == true }
        harness.renderer("W3#3")?.finish()
        try await wait { harness.manager.state(of: displayC)?.activeWallpaperID != nil }
        XCTAssertEqual(harness.manager.state(of: displayC)?.playbackState, .smartPaused)
        XCTAssertFalse(harness.log.entries.contains("play:W3#3"))
        XCTAssertEqual(harness.renderer("W3#3")?.isMuted, false)

        harness.log.entries.removeAll()
        harness.manager.setSmartPauseActive(false)
        XCTAssertEqual(Set(harness.log.entries), ["resume:W2#2", "play:W3#3"])
        XCTAssertEqual(harness.manager.state(of: displayA)?.playbackState, .manualPaused)
        harness.manager.shutdown()
    }

    // MARK: - 同一张壁纸用在多台显示器

    @MainActor
    func testTheSameWallpaperOnTwoDisplaysUsesTwoRenderersAndCanBeStoppedTogether() async throws {
        let harness = twoDisplays()
        let shared = wallpaper("W1"), other = wallpaper("W2")
        try await applyAndPlay(shared, on: displayA, in: harness, tag: "W1#1")
        try await applyAndPlay(shared, on: displayB, in: harness, tag: "W1#2")
        XCTAssertFalse(harness.renderer("W1#1") === harness.renderer("W1#2"))
        XCTAssertEqual(harness.manager.summary.displays(showing: shared.id), [displayA, displayB])
        XCTAssertTrue(harness.manager.isUsing(shared.id))

        try await applyAndPlay(other, on: displayB, in: harness, tag: "W2#3")
        XCTAssertEqual(harness.manager.summary.displays(showing: shared.id), [displayA])

        // 删除前只停止用到它的显示器。
        harness.manager.stop(displaysInvolving: shared.id)
        XCTAssertFalse(harness.manager.isUsing(shared.id))
        XCTAssertEqual(harness.manager.state(of: displayA)?.playbackState, .stopped)
        XCTAssertEqual(harness.manager.state(of: displayB)?.activeWallpaperID, other.id)
        XCTAssertEqual(harness.manager.state(of: displayB)?.playbackState, .playing)
        harness.manager.shutdown()
    }

    // MARK: - 移除显示器

    @MainActor
    func testRemovingADisplayReleasesItsResourcesWithoutMovingItsWallpaperElsewhere() async throws {
        let harness = twoDisplays()
        let one = wallpaper("W1"), two = wallpaper("W2")
        try await applyAndPlay(one, on: displayA, in: harness, tag: "W1#1")
        try await applyAndPlay(two, on: displayB, in: harness, tag: "W2#2")
        harness.manager.apply(wallpaper("W3"), to: displayB)
        try await wait { harness.renderer("W3#3")?.isWaiting == true }
        harness.renderer("W3#3")?.finish(Failure())
        try await wait { harness.manager.lastFailure != nil }

        harness.log.entries.removeAll()
        let last = harness.manager.removeDisplay(displayB)
        XCTAssertEqual(last?.runtime.activeWallpaperID, two.id, "The assignment is returned for Module 16 to keep")
        XCTAssertEqual(harness.log.entries, ["B.stop", "dispose:W2#2", "B.stop"])
        XCTAssertTrue(harness.renderer("W2#2")?.isDisposed ?? false)
        XCTAssertNil(harness.desktops[displayB]?.content)
        XCTAssertNil(harness.manager.lastFailure, "The removed display's error goes with it")
        XCTAssertEqual(harness.manager.displayIDs, [displayA])
        XCTAssertEqual(harness.manager.state(of: displayA)?.activeWallpaperID, one.id)
        XCTAssertTrue(harness.desktops[displayA]?.content === harness.renderer("W1#1")?.displayView)
        XCTAssertFalse(harness.manager.isUsing(two.id), "Never falls back to another display")
        XCTAssertNil(harness.manager.removeDisplay(displayB))

        // 剩下一个会话时，旧入口作用于它。
        XCTAssertEqual(harness.manager.state.activeWallpaperID, one.id)
        harness.manager.shutdown()
    }

    // MARK: - 汇总

    func testSummaryAggregatesByPriority() {
        func display(_ name: String, _ state: PlaybackState) -> DisplayRuntimeState {
            var runtime = WallpaperRuntimeState()
            runtime.playbackState = state
            return DisplayRuntimeState(displayID: DisplayID(name), displayName: name, runtime: runtime)
        }
        XCTAssertEqual(RuntimeSummary().playbackState, .noWallpaper)
        XCTAssertFalse(RuntimeSummary().hasEnabledDisplay)
        XCTAssertEqual(RuntimeSummary(displays: [display("A", .stopped), display("B", .manualPaused)]).playbackState,
                       .manualPaused)
        XCTAssertEqual(RuntimeSummary(displays: [display("A", .failed), display("B", .smartPaused)]).playbackState,
                       .smartPaused)
        XCTAssertEqual(RuntimeSummary(displays: [display("A", .preparing), display("B", .stopped)]).playbackState,
                       .preparing)
        XCTAssertEqual(RuntimeSummary(displays: [display("A", .noWallpaper), display("B", .stopped)]).playbackState,
                       .stopped)
        XCTAssertTrue(RuntimeSummary(displays: [display("A", .manualPaused), display("B", .smartPaused)])
            .hasEnabledDisplay)
        XCTAssertEqual(Set(RuntimeSummary.aggregatePriority), Set(PlaybackState.allCases))
    }
}
