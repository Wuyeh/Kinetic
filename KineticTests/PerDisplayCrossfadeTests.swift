import AppKit
import XCTest
@testable import Kinetic

/// Kinetic 1.0 Module 6：Crossfade 按显示器进行（规格 22、25）。
/// 把主屏幕左右两半当作两台显示器，各自有真实的桌面窗口与 Crossfade 舞台，
/// 验证一台显示器的淡入、停止、暂停、移除都不影响另一台显示器。
@MainActor
private final class Log {
    var entries: [String] = []
}

@MainActor
private final class Renderer: WallpaperRenderer {
    let wallpaper: Wallpaper
    let displayView: NSView
    var onFailure: (@MainActor (Error) -> Void)?
    private let log: Log
    private var continuation: CheckedContinuation<Void, Error>?
    private(set) var isDisposed = false
    private(set) var wasAttachedWhenDisposed = false
    var isWaiting: Bool { continuation != nil }

    init(wallpaper: Wallpaper, log: Log) {
        self.wallpaper = wallpaper
        self.log = log
        displayView = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36))
        displayView.wantsLayer = true
        displayView.layer?.backgroundColor = NSColor.systemTeal.cgColor
    }

    func prepare() async throws {
        try await withCheckedThrowingContinuation { self.continuation = $0 }
    }

    func finish() {
        let pending = continuation
        continuation = nil
        pending?.resume()
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
        let pending = continuation
        continuation = nil
        pending?.resume(throwing: CancellationError())
    }
}

@MainActor
private final class RendererList {
    var items: [Renderer] = []
    func named(_ name: String) -> Renderer? { items.last { $0.wallpaper.name == name } }
}

@MainActor
private final class StubHost: DesktopContentHost {
    func present(_ contentView: NSView) -> Bool { true }
    func stop() {}
}

private final class WeakVideo {
    weak var value: VideoRenderer?
    init(_ value: VideoRenderer) { self.value = value }
}

final class PerDisplayCrossfadeTests: XCTestCase {
    private let left = DisplayID("virtual-left")
    private let right = DisplayID("virtual-right")

    /// 主屏幕的左半 / 右半，作为两台“显示器”。
    @MainActor
    private func halves() throws -> (left: DesktopDisplay, right: DesktopDisplay) {
        let screen = try XCTUnwrap(DesktopDisplay.primary())
        var leftFrame = screen.frame
        leftFrame.size.width = (screen.frame.width / 2).rounded(.down)
        var rightFrame = screen.frame
        rightFrame.origin.x += leftFrame.width
        rightFrame.size.width = screen.frame.width - leftFrame.width
        return (DesktopDisplay(id: screen.id, frame: leftFrame, backingScaleFactor: screen.backingScaleFactor),
                DesktopDisplay(id: screen.id, frame: rightFrame, backingScaleFactor: screen.backingScaleFactor))
    }

    @MainActor
    private final class Harness {
        let log: Log
        let list: RendererList
        let manager: WallpaperRuntimeManager
        let surfaces: [DisplayID: DisplayDesktopSurface]

        init(_ displays: [(DisplayID, DesktopDisplay)], makeRenderer: WallpaperRuntimeManager.RendererFactory? = nil) {
            let log = Log()
            let list = RendererList()
            self.log = log
            self.list = list
            if let makeRenderer {
                manager = WallpaperRuntimeManager(makeRenderer: makeRenderer)
            } else {
                manager = WallpaperRuntimeManager { wallpaper in
                    let renderer = Renderer(wallpaper: wallpaper, log: log)
                    list.items.append(renderer)
                    return renderer
                }
            }
            var surfaces: [DisplayID: DisplayDesktopSurface] = [:]
            for (id, display) in displays {
                let surface = DisplayDesktopSurface(
                    windowIdentifier: NSUserInterfaceItemIdentifier("Kinetic.Crossfade.PerDisplay.\(id.rawValue)"),
                    resolveDisplay: { display })
                surfaces[id] = surface
                manager.addDisplay(id, name: id.rawValue, host: surface.host)
            }
            self.surfaces = surfaces
        }

        func host(_ id: DisplayID) -> CrossfadeDesktopHost { surfaces[id]!.host }
        func desktop(_ id: DisplayID) -> DesktopWindowRuntime { surfaces[id]!.desktop }

        func shutdown() {
            manager.shutdown()
            surfaces.values.forEach { $0.desktop.stop() }
        }
    }

    @MainActor
    private func wait(timeout: TimeInterval = 8, _ predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !predicate() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                XCTFail("Timed out waiting for per-display crossfade condition")
                throw CancellationError()
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func wallpaper(_ name: String) -> Wallpaper {
        Wallpaper(name: name, type: .video, source: .local,
                  resourceURL: URL(fileURLWithPath: "/kinetic-per-display-crossfade/\(name)"))
    }

    /// 应用并让候选准备完成；返回候选 Renderer。
    @MainActor
    @discardableResult
    private func apply(_ name: String, to display: DisplayID, in harness: Harness) async throws -> Renderer {
        let wallpaper = wallpaper(name)
        harness.manager.apply(wallpaper, to: display)
        try await wait { harness.list.named(name)?.isWaiting == true }
        let renderer = try XCTUnwrap(harness.list.named(name))
        renderer.finish()
        try await wait { harness.manager.state(of: display)?.activeWallpaperID == wallpaper.id }
        return renderer
    }

    @MainActor
    private func twoDisplays() throws -> Harness {
        let (leftDisplay, rightDisplay) = try halves()
        return Harness([(left, leftDisplay), (right, rightDisplay)])
    }

    // MARK: -

    @MainActor
    func testEachDisplayHasItsOwnWindowAndStage() async throws {
        let (leftDisplay, rightDisplay) = try halves()
        let harness = Harness([(left, leftDisplay), (right, rightDisplay)])
        defer { harness.shutdown() }
        let one = try await apply("W1", to: left, in: harness)
        let two = try await apply("W2", to: right, in: harness)

        XCTAssertFalse(harness.host(left) === harness.host(right))
        XCTAssertFalse(harness.host(left).stage === harness.host(right).stage)
        XCTAssertEqual(harness.host(left).stage.contents, [one.displayView])
        XCTAssertEqual(harness.host(right).stage.contents, [two.displayView])
        XCTAssertEqual(harness.desktop(left).window?.frame, leftDisplay.frame)
        XCTAssertEqual(harness.desktop(right).window?.frame, rightDisplay.frame)
        XCTAssertFalse(harness.desktop(left).window === harness.desktop(right).window)
    }

    @MainActor
    func testCrossfadeOnOneDisplayNeverTouchesTheOther() async throws {
        let harness = try twoDisplays()
        defer { harness.shutdown() }
        let one = try await apply("W1", to: left, in: harness)
        let two = try await apply("W2", to: right, in: harness)
        let rightWindow = harness.desktop(right).window
        harness.log.entries.removeAll()

        harness.manager.apply(wallpaper("W3"), to: left)
        try await wait { harness.list.named("W3")?.isWaiting == true }
        harness.list.named("W3")?.finish()
        try await wait { harness.host(left).isTransitioning }
        let three = try XCTUnwrap(harness.list.named("W3"))

        var intermediate = 0
        let start = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - start < 0.25 {
            XCTAssertEqual(harness.host(right).stage.contents, [two.displayView], "B's stage is untouched")
            XCTAssertEqual(harness.host(right).stage.slot(containing: two.displayView)?.alphaValue, 1)
            XCTAssertFalse(harness.host(right).isTransitioning)
            XCTAssertEqual(harness.host(left).stage.slot(containing: one.displayView)?.alphaValue, 1,
                           "A's old wallpaper stays fully visible under the fade")
            if let opacity = harness.host(left).stage.slot(containing: three.displayView)?.layer?.presentation()?.opacity,
               opacity > 0.02, opacity < 0.98 {
                intermediate += 1
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertGreaterThan(intermediate, 0, "Display A really crossfades")

        try await wait(timeout: 2) { one.isDisposed }
        XCTAssertFalse(one.wasAttachedWhenDisposed)
        XCTAssertEqual(harness.host(left).stage.contents, [three.displayView])
        XCTAssertEqual(harness.host(left).completedTransitionCount, 1)
        XCTAssertEqual(harness.host(right).completedTransitionCount, 0)
        XCTAssertTrue(harness.desktop(right).window === rightWindow, "B's desktop window is never recreated")
        XCTAssertEqual(harness.log.entries, ["play:W3", "dispose:W1"], "Nothing is sent to display B's renderer")
        XCTAssertEqual(harness.manager.state(of: right)?.playbackState, .playing)
    }

    @MainActor
    func testOverlappingCrossfadesOnTwoDisplaysFinishIndependently() async throws {
        let harness = try twoDisplays()
        defer { harness.shutdown() }
        let one = try await apply("W1", to: left, in: harness)
        let two = try await apply("W2", to: right, in: harness)

        harness.manager.apply(wallpaper("W3"), to: left)
        try await wait { harness.list.named("W3")?.isWaiting == true }
        harness.list.named("W3")?.finish()
        try await wait { harness.host(left).isTransitioning }
        try await Task.sleep(nanoseconds: 100_000_000)

        harness.manager.apply(wallpaper("W4"), to: right)
        try await wait { harness.list.named("W4")?.isWaiting == true }
        harness.list.named("W4")?.finish()
        try await wait { harness.host(right).isTransitioning }
        // B 开始淡入不会让 A 的淡入被提前结束。
        XCTAssertTrue(harness.host(left).isTransitioning, "Display A's fade is not snapped by display B")
        XCTAssertFalse(one.isDisposed)
        XCTAssertEqual(harness.host(left).stage.contents.count, 2)

        try await wait(timeout: 3) { one.isDisposed && two.isDisposed }
        XCTAssertFalse(one.wasAttachedWhenDisposed)
        XCTAssertFalse(two.wasAttachedWhenDisposed)
        for display in [left, right] {
            XCTAssertEqual(harness.host(display).completedTransitionCount, 1)
            let duration = try XCTUnwrap(harness.host(display).lastTransitionDuration)
            XCTAssertGreaterThanOrEqual(duration, 0.3, "Each display gets its full fade")
            XCTAssertLessThan(duration, 1.0)
            XCTAssertEqual(harness.host(display).stage.contents.count, 1)
        }
    }

    @MainActor
    func testStopAndRemoveDuringAFadeOnlyAffectThatDisplay() async throws {
        let harness = try twoDisplays()
        defer { harness.shutdown() }
        let one = try await apply("W1", to: left, in: harness)
        let two = try await apply("W2", to: right, in: harness)
        harness.manager.apply(wallpaper("W3"), to: left)
        harness.manager.apply(wallpaper("W4"), to: right)
        try await wait { harness.list.named("W3")?.isWaiting == true && harness.list.named("W4")?.isWaiting == true }
        harness.list.named("W3")?.finish()
        harness.list.named("W4")?.finish()
        try await wait { harness.host(left).isTransitioning && harness.host(right).isTransitioning }
        let three = try XCTUnwrap(harness.list.named("W3"))
        let four = try XCTUnwrap(harness.list.named("W4"))

        // 停止 A：A 的两张壁纸都先离开窗口再释放，A 的窗口关闭；B 的淡入照常完成。
        harness.manager.stop(.display(left))
        XCTAssertNil(harness.desktop(left).window)
        XCTAssertTrue(one.isDisposed && three.isDisposed)
        XCTAssertFalse(one.wasAttachedWhenDisposed || three.wasAttachedWhenDisposed)
        XCTAssertTrue(harness.host(right).isTransitioning, "Display B keeps fading")
        XCTAssertFalse(two.isDisposed)
        try await wait(timeout: 2) { two.isDisposed }
        XCTAssertFalse(two.wasAttachedWhenDisposed)
        XCTAssertEqual(harness.host(right).stage.contents, [four.displayView])

        // 移除 B（例如显示器断开）：B 的窗口关闭、Renderer 释放；A 保持停止，不接管 B 的壁纸。
        harness.manager.apply(wallpaper("W5"), to: right)
        try await wait { harness.list.named("W5")?.isWaiting == true }
        harness.list.named("W5")?.finish()
        try await wait { harness.host(right).isTransitioning }
        let five = try XCTUnwrap(harness.list.named("W5"))
        let last = harness.manager.removeDisplay(right)
        XCTAssertEqual(last?.runtime.activeWallpaperID, five.wallpaper.id)
        XCTAssertNil(harness.desktop(right).window)
        XCTAssertTrue(four.isDisposed && five.isDisposed)
        XCTAssertFalse(four.wasAttachedWhenDisposed || five.wasAttachedWhenDisposed)
        XCTAssertEqual(harness.manager.displayIDs, [left])
        XCTAssertEqual(harness.manager.state(of: left)?.playbackState, .stopped)
        XCTAssertNil(harness.desktop(left).window)
    }

    @MainActor
    func testPausingOneDisplayDuringItsFadeFreezesOnlyItsWallpapers() async throws {
        let harness = try twoDisplays()
        defer { harness.shutdown() }
        try await apply("W1", to: left, in: harness)
        try await apply("W2", to: right, in: harness)
        harness.manager.apply(wallpaper("W3"), to: left)
        harness.manager.apply(wallpaper("W4"), to: right)
        try await wait { harness.list.named("W3")?.isWaiting == true && harness.list.named("W4")?.isWaiting == true }
        harness.list.named("W3")?.finish()
        harness.list.named("W4")?.finish()
        try await wait { harness.host(left).isTransitioning && harness.host(right).isTransitioning }

        harness.log.entries.removeAll()
        harness.manager.pause(.display(left))
        XCTAssertEqual(harness.log.entries, ["pause:W3", "pause:W1"],
                       "Display A freezes both its incoming and outgoing wallpaper; B is not paused")
        try await wait(timeout: 2) { !harness.host(left).isTransitioning && !harness.host(right).isTransitioning }
        XCTAssertEqual(harness.manager.state(of: left)?.playbackState, .manualPaused)
        XCTAssertEqual(harness.manager.state(of: right)?.playbackState, .playing)
        XCTAssertFalse(harness.log.entries.contains("pause:W4") || harness.log.entries.contains("pause:W2"))
    }

    @MainActor
    func testOneHostCannotBeSharedByTwoDisplays() {
        let manager = WallpaperRuntimeManager()
        let shared = StubHost()
        XCTAssertTrue(manager.addDisplay(left, host: shared))
        XCTAssertFalse(manager.addDisplay(right, host: shared), "A shared stage would let A's fade act on B")
        XCTAssertEqual(manager.displayIDs, [left])
        XCTAssertTrue(manager.addDisplay(right, host: StubHost()))
        XCTAssertTrue(manager.addDisplay(left, name: "Renamed", host: shared), "Re-adding the same display only renames it")
        XCTAssertEqual(manager.displayIDs, [left, right])
        XCTAssertEqual(manager.summary.displays.first?.displayName, "Renamed")
    }

    /// 真实连接的显示器（例如作为副屏的 iPad）：每台显示器一个表面，窗口落在各自的屏幕上；
    /// 主显示器交叉淡化时，其他显示器的舞台与 Renderer 不受影响。只连接一台显示器时跳过。
    @MainActor
    func testEveryConnectedScreenGetsItsOwnSurfaceAndCrossfade() async throws {
        func number(of screen: NSScreen) -> CGDirectDisplayID? {
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        }
        let screens = NSScreen.screens.compactMap { screen in
            number(of: screen).map { (screen, $0) }
        }
        guard screens.count >= 2 else { throw XCTSkip("Only one display is connected") }
        let displays: [(DisplayID, DesktopDisplay)] = screens.map { screen, id in
            (DisplayID("screen-\(id)"), DesktopDisplay(id: id, frame: screen.frame, backingScaleFactor: screen.backingScaleFactor))
        }
        let harness = Harness(displays)
        defer { harness.shutdown() }
        var first: Renderer?
        var others: [DisplayID: Renderer] = [:]
        for (index, (id, _)) in displays.enumerated() {
            let renderer = try await apply("S\(index)", to: id, in: harness)
            if index == 0 { first = renderer } else { others[id] = renderer }
        }
        for ((id, display), (screen, screenNumber)) in zip(displays, screens) {
            let window = try XCTUnwrap(harness.desktop(id).window)
            XCTAssertEqual(window.frame, display.frame, "\(screen.localizedName)")
            XCTAssertEqual(window.screen.flatMap { number(of: $0) }, screenNumber,
                           "Window sits on \(screen.localizedName)")
        }

        let main = displays[0].0
        harness.log.entries.removeAll()
        harness.manager.apply(wallpaper("S-next"), to: main)
        try await wait { harness.list.named("S-next")?.isWaiting == true }
        harness.list.named("S-next")?.finish()
        try await wait { harness.host(main).isTransitioning }
        for (id, renderer) in others {
            XCTAssertEqual(harness.host(id).stage.contents, [renderer.displayView])
            XCTAssertFalse(harness.host(id).isTransitioning)
        }
        try await wait(timeout: 2) { first?.isDisposed == true }
        XCTAssertEqual(harness.log.entries, ["play:S-next", "dispose:S0"], "Only the main display changes")
        for (id, renderer) in others {
            XCTAssertFalse(renderer.isDisposed)
            XCTAssertEqual(harness.host(id).completedTransitionCount, 0)
            XCTAssertEqual(harness.manager.state(of: id)?.playbackState, .playing)
        }
    }

    /// 真实视频：A 单独切换 10 次（B 始终不变），然后 A、B 同时切换 10 次；两台显示器的舞台底层始终有完整画面。
    @MainActor
    func testRealVideoSwitchesOnTwoDisplaysNeverExposeAnEmptyDesktop() async throws {
        func fixture(_ name: String) throws -> Wallpaper {
            let url = try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: "mp4", subdirectory: "Fixtures"))
            return Wallpaper(name: name, type: .video, source: .local, resourceURL: url)
        }
        let blue = try fixture("loop"), warm = try fixture("loop-warm")
        let (leftDisplay, rightDisplay) = try halves()
        var created: [WeakVideo] = []
        let harness = Harness([(left, leftDisplay), (right, rightDisplay)]) { wallpaper in
            let renderer = try WallpaperRuntimeManager.standardRenderer(for: wallpaper)
            if let video = renderer as? VideoRenderer { created.append(WeakVideo(video)) }
            return renderer
        }
        defer { harness.shutdown() }

        harness.manager.apply(blue, to: left)
        harness.manager.apply(warm, to: right)
        try await wait { harness.manager.summary.playingDisplayCount == 2 }

        var samples = 0, gaps = 0
        func sample() {
            samples += 1
            for display in [left, right] {
                let base = harness.host(display).stage.subviews.first
                let ready = (base?.subviews.first as? VideoContentView)?.hasPoster == true
                if base == nil || base?.alphaValue != 1 || !ready || harness.desktop(display).window?.isVisible != true {
                    gaps += 1
                }
            }
        }
        func settle(_ targets: [(DisplayID, Wallpaper)]) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 10
            while !targets.allSatisfy({ display, wallpaper in
                harness.manager.state(of: display)?.activeWallpaperID == wallpaper.id
                    && !harness.host(display).isTransitioning
            }) {
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    XCTFail("Switch timed out")
                    throw CancellationError()
                }
                sample()
                try await Task.sleep(nanoseconds: 4_000_000)
            }
        }

        // 第一阶段：只有 A 切换，B 的 Renderer 与舞台保持不变。
        let rightContent = harness.host(right).stage.contents.first
        for index in 0..<10 {
            let target = index.isMultiple(of: 2) ? warm : blue
            harness.manager.apply(target, to: left)
            try await settle([(left, target)])
            XCTAssertTrue(harness.host(right).stage.contents.first === rightContent, "Display B never reloads")
        }
        XCTAssertEqual(harness.host(left).completedTransitionCount, 10)
        XCTAssertEqual(harness.host(right).completedTransitionCount, 0)
        XCTAssertEqual(harness.manager.state(of: right)?.playbackState, .playing)

        // 第二阶段：两台同时切换。
        for index in 0..<10 {
            let leftTarget = index.isMultiple(of: 2) ? warm : blue
            let rightTarget = index.isMultiple(of: 2) ? blue : warm
            harness.manager.apply(leftTarget, to: left)
            harness.manager.apply(rightTarget, to: right)
            try await settle([(left, leftTarget), (right, rightTarget)])
        }

        print("MODULE6-1.0 left=\(harness.host(left).completedTransitionCount) right=\(harness.host(right).completedTransitionCount) samples=\(samples) gaps=\(gaps)")
        XCTAssertEqual(gaps, 0, "Both desktops always show a fully opaque, decoded frame")
        XCTAssertGreaterThan(samples, 40)
        XCTAssertEqual(harness.host(left).completedTransitionCount, 20)
        XCTAssertEqual(harness.host(right).completedTransitionCount, 10)
        XCTAssertNil(harness.manager.lastFailure)
        XCTAssertEqual(created.count, 32)
        // 除两台显示器当前的壁纸外，所有旧 Renderer 都已释放。
        try await wait(timeout: 5) { created.filter { $0.value != nil }.count == 2 }
    }
}
