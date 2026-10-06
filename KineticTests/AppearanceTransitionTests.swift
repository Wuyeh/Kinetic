import AppKit
import XCTest
@testable import Kinetic

/// 主题切换：外观取值、淡化加在窗口根图层（含窗口背景与标题栏）而不是只加在内容视图、
/// 外观不变时不做过渡、快速连续切换不阻塞且以最后一次选择为准。
@MainActor
final class AppearanceTransitionTests: XCTestCase {
    private var originalAppearance: NSAppearance?
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        originalAppearance = NSApp.appearance
    }

    override func tearDown() async throws {
        NSApp.appearance = originalAppearance
        windows.forEach { $0.orderOut(nil); $0.close() }
        windows = []
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -4_000, y: -4_000, width: 320, height: 200),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView()
        content.wantsLayer = true
        window.contentView = content
        window.orderFrontRegardless()
        windows.append(window)
        return window
    }

    private func rootLayer(of window: NSWindow) -> CALayer? {
        var root: NSView? = window.contentView
        while let parent = root?.superview { root = parent }
        return root?.layer
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testModesMapToApplicationAppearance() {
        XCTAssertNil(AppearanceTransition.appearance(for: .system), "跟随系统必须清除覆盖")
        XCTAssertEqual(AppearanceTransition.appearance(for: .light)?.name, .aqua)
        XCTAssertEqual(AppearanceTransition.appearance(for: .dark)?.name, .darkAqua)
    }

    /// 淡化加在窗口根图层（框架视图，含窗口背景、标题栏和工具栏）上，而不是只加在内容视图上；
    /// 桌面壁纸窗口和不可见窗口不参与。
    func testFadeTargetsEachVisibleWindowsRootLayer() throws {
        let window = makeWindow()
        spin(0.1)  // 窗口第一次显示后框架视图才有图层
        let root = try XCTUnwrap(rootLayer(of: window))
        XCTAssertFalse(root === window.contentView?.layer, "根图层应是窗口框架视图的图层")

        let desktop = makeWindow()
        desktop.identifier = AppDelegate.desktopWallpaperWindowIdentifier
        let hidden = makeWindow()
        hidden.orderOut(nil)

        let layers = AppearanceTransition.transitionLayers()
        XCTAssertTrue(layers.contains { $0 === root })
        XCTAssertFalse(layers.contains { $0 === window.contentView?.layer })
        XCTAssertFalse(layers.contains { $0 === rootLayer(of: desktop) }, "桌面壁纸窗口不参与主题过渡")
        XCTAssertFalse(layers.contains { $0 === rootLayer(of: hidden) })
    }

    func testFadeIsShortAndSmooth() {
        let fade = AppearanceTransition.makeTransition()
        XCTAssertEqual(fade.type, .fade)
        XCTAssertEqual(fade.duration, AppearanceTransition.duration, accuracy: 0.001)
        XCTAssertTrue((0.2...0.4).contains(fade.duration), "短暂的淡化")
        XCTAssertEqual(fade.timingFunction, CAMediaTimingFunction(name: .easeInEaseOut))
    }

    func testFadeStartsOnlyWhenTheAppearanceChanges() throws {
        let window = makeWindow()
        let transition = AppearanceTransition()
        transition.apply(.light, animated: false)
        spin(0.1)
        let expectsFade = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        XCTAssertEqual(transition.apply(.dark, animated: true), expectsFade)
        XCTAssertEqual(NSApp.appearance?.name, .darkAqua)
        if expectsFade {
            let root = try XCTUnwrap(rootLayer(of: window))
            XCTAssertTrue(root.animation(forKey: AppearanceTransition.animationKey) is CATransition,
                          "整窗（含背景）一起淡化")
        }
        XCTAssertFalse(transition.apply(.dark, animated: true), "外观不变时不做过渡")
        XCTAssertFalse(transition.apply(.system, animated: false), "启动时直接应用，不做过渡")
        XCTAssertNil(NSApp.appearance, "跟随系统清除覆盖")
    }

    /// 测试宿主运行着真实主窗口：切换时整窗（框架视图图层，含窗口背景）带上淡化，内容视图不单独淡化。
    func testMainWindowFadesAsAWhole() throws {
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, "减少动态效果开启时不做过渡")
        let deadline = Date().addingTimeInterval(5)
        var main: NSWindow?
        while main == nil && Date() < deadline {
            main = NSApp.windows.first { $0.isVisible && $0.styleMask.contains(.fullSizeContentView)
                && $0.identifier != AppDelegate.desktopWallpaperWindowIdentifier && !windows.contains($0) }
            if main == nil { spin(0.1) }
        }
        let window = try XCTUnwrap(main, "测试宿主没有打开主窗口")
        let transition = AppearanceTransition()
        let current = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        let other: AppearanceMode = current == .darkAqua ? .light : .dark
        transition.apply(current == .darkAqua ? .dark : .light, animated: false)
        spin(0.1)

        XCTAssertTrue(transition.apply(other, animated: true))
        let root = try XCTUnwrap(rootLayer(of: window))
        XCTAssertTrue(root.animation(forKey: AppearanceTransition.animationKey) is CATransition,
                      "整窗（含背景、标题栏）一起淡化")
        XCTAssertNil(window.contentView?.layer?.animation(forKey: AppearanceTransition.animationKey))
        spin(0.2)
        let running = root.animation(forKey: AppearanceTransition.animationKey)
        XCTAssertEqual(running?.duration ?? 0, AppearanceTransition.duration, accuracy: 0.001,
                       "窗口重绘后仍是本过渡，没有被系统替换")
        spin(2)
        XCTAssertNil(root.animation(forKey: AppearanceTransition.animationKey), "过渡结束后自动移除")
    }

    func testRapidSwitchingDoesNotBlockAndEndsOnTheLastChoice() {
        let window = makeWindow()
        let transition = AppearanceTransition()
        let modes: [AppearanceMode] = [.dark, .light, .system, .dark, .light, .dark,
                                       .system, .light, .dark, .system, .light, .dark]
        var slowest: CFTimeInterval = 0
        for mode in modes {
            let start = CACurrentMediaTime()
            transition.apply(mode, animated: true)
            slowest = max(slowest, CACurrentMediaTime() - start)
            spin(0.03)
        }
        XCTAssertLessThan(slowest, 0.1, "每次切换都应立即返回，不在主线程抓取画面")
        XCTAssertEqual(NSApp.appearance?.name, .darkAqua)
        spin(0.5)
        XCTAssertEqual(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)

        transition.apply(.light, animated: true)
        spin(0.5)
        XCTAssertEqual(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .aqua)
    }
}
