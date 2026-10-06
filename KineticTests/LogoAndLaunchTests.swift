import AppKit
import SwiftUI
import XCTest
@testable import Kinetic

/// Module 22：动态轨迹 K（菜单栏标志、App 图标）、字标、启动动画与主窗口打开的页面。
@MainActor
final class LogoAndLaunchTests: XCTestCase {
    // MARK: 几何

    func testLogoIsOneVerticalTrajectoryAndOneContinuousArcInsideTheCanvas() {
        XCTAssertEqual(KineticLogo.stem.count, 4)
        XCTAssertEqual(KineticLogo.trajectory.count, 2)
        XCTAssertEqual(KineticLogo.trajectory[0].last, KineticLogo.trajectory[1].first, "弧形轨迹是一条连续的线")
        let points = KineticLogo.stem + KineticLogo.trajectory.flatMap { $0 }
        let inset = KineticLogo.menuBarLineWidth / 2
        for point in points {
            XCTAssertTrue((inset...100 - inset).contains(point.x), "\(point)")
            XCTAssertTrue((inset...100 - inset).contains(point.y), "\(point)")
        }
        // 竖向主轨迹在左，弧形轨迹从右上经中部到右下。
        XCTAssertLessThan(KineticLogo.stem.map(\.x).max()!, KineticLogo.trajectory[0][3].x)
        XCTAssertLessThan(KineticLogo.trajectory[0][0].y, 30)
        XCTAssertGreaterThan(KineticLogo.trajectory[1][3].y, 70)
        XCTAssertGreaterThan(KineticLogo.menuBarLineWidth, KineticLogo.lineWidth, "菜单栏标志比 App 标志略粗")

        let rect = CGRect(x: 0, y: 0, width: 200, height: 100)
        for part in KineticLogo.Part.allCases {
            let bounds = KineticLogo.path(part, in: rect).boundingRect
            XCTAssertFalse(bounds.isEmpty)
            XCTAssertTrue(CGRect(x: 50, y: 0, width: 100, height: 100).contains(bounds), "按比例居中")
        }
    }

    // MARK: 菜单栏标志

    private func pixels(of image: NSImage) throws -> (bitmap: NSBitmapImageRep, opaque: Int) {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36,
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                                   bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: 36, height: 36))
        NSGraphicsContext.restoreGraphicsState()
        var opaque = 0
        for x in 0..<36 {
            for y in 0..<36 where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                opaque += 1
            }
        }
        return (bitmap, opaque)
    }

    /// 壁纸未启用 / 暂停 / 停止：黑白模板图；播放 / 智能暂停：品牌主色（规格 4、用户要求）。两种都必须真的画出了图形。
    func testMenuBarLogoIsTemplateWhenIdleAndAccentWhenPlaying() throws {
        let idle = KineticLogo.menuBarImage(accent: false)
        let playing = KineticLogo.menuBarImage(accent: true)
        XCTAssertTrue(idle.isTemplate)
        XCTAssertFalse(playing.isTemplate)
        XCTAssertEqual(idle.size, NSSize(width: 18, height: 18))
        XCTAssertEqual(playing.size, idle.size)

        let idlePixels = try pixels(of: idle)
        XCTAssertGreaterThan(idlePixels.opaque, 60, "图形可见，不是空图")
        let playingPixels = try pixels(of: playing)
        XCTAssertGreaterThan(playingPixels.opaque, 60)
        var accentHits = 0
        for x in 0..<36 {
            for y in 0..<36 {
                guard let color = playingPixels.bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      color.alphaComponent > 0.9 else { continue }
                if abs(color.redComponent - 88.0 / 255) < 0.08, abs(color.greenComponent - 191.0 / 255) < 0.08,
                   abs(color.blueComponent - 218.0 / 255) < 0.08 { accentHits += 1 }
            }
        }
        XCTAssertGreaterThan(accentHits, 20, "播放时为 #58BFDA")
    }

    func testMenuBarStateMapping() {
        func accent(_ state: PlaybackState) -> Bool {
            var runtime = WallpaperRuntimeState()
            runtime.playbackState = state
            return MenuBarPlaybackPresentation(state: runtime, canReenable: false).iconUsesAccent
        }
        XCTAssertTrue(accent(.playing))
        XCTAssertTrue(accent(.smartPaused))
        XCTAssertFalse(accent(.manualPaused))
        XCTAssertFalse(accent(.stopped))
        XCTAssertFalse(accent(.noWallpaper))
    }

    // MARK: App 图标

    func testAppIconIsCompiledIntoTheBundle() throws {
        let info = Bundle.main.infoDictionary ?? [:]
        XCTAssertEqual(info["CFBundleIconName"] as? String, "AppIcon")
        let resources = try XCTUnwrap(Bundle.main.resourceURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: resources.appendingPathComponent("Assets.car").path))
    }

    // MARK: 字标「Kinetic」

    /// 「inetic」与 K 同一坐标系：基线与 K 底端对齐、字母依次排列且间距均匀，整个字标左右留白相等。
    func testWordmarkLettersSitOnTheBaselineInOrderAndTheWordmarkIsCentered() {
        let letters = KineticWordmark.letterPaths
        XCTAssertEqual(letters.count, 6, "i n e t i c")
        let halfStroke = KineticLogo.lineWidth / 2
        let bounds = letters.map(\.cgPath.boundingBoxOfPath)
        for (index, rect) in bounds.enumerated() {
            XCTAssertEqual(rect.maxY, KineticWordmark.baseline, accuracy: 0.05, "第 \(index) 个字母落在基线上")
        }
        XCTAssertEqual(KineticLogo.stem.last!.y, KineticWordmark.baseline, "与 K 的底端对齐")
        for index in [1, 2, 5] { // n、e、c 的顶端就是 x 高
            XCTAssertEqual(bounds[index].minY, KineticWordmark.xHeight, accuracy: 0.05)
        }
        XCTAssertEqual(bounds[0].minY, KineticWordmark.dotY, accuracy: 0.05, "i 有圆点")
        XCTAssertLessThan(bounds[3].minY, KineticWordmark.xHeight, "t 高出 x 高")

        let square = CGRect(x: 0, y: 0, width: 100, height: 100)
        let logoRight = KineticLogo.Part.allCases
            .map { KineticLogo.path($0, in: square).cgPath.boundingBoxOfPath.maxX }
            .max()! + halfStroke
        var previousRight = logoRight
        for rect in bounds {
            let gap = rect.minX - halfStroke - previousRight
            XCTAssertTrue((8...16).contains(gap), "字母间距 \(gap)")
            previousRight = rect.maxX + halfStroke
        }

        let left = KineticLogo.path(.stem, in: square).cgPath.boundingBoxOfPath.minX - halfStroke
        let right = KineticWordmark.unitWidth - previousRight
        XCTAssertEqual(left, right, accuracy: 1, "字标左右留白相等")

        let rect = CGRect(x: 10, y: 20, width: KineticWordmark.unitWidth * 2, height: 200)
        let mapped = KineticWordmark.lettersPath(in: rect).cgPath.boundingBoxOfPath
        XCTAssertEqual(mapped.minX, 10 + bounds[0].minX * 2, accuracy: 0.1)
        XCTAssertEqual(mapped.maxY, 20 + KineticWordmark.baseline * 2, accuracy: 0.1)
    }

    // MARK: 主窗口打开的页面

    func testMainWindowOpensOnSteamFirstAndThenOnTheLastPage() throws {
        let suite = "KineticTests.MainWindowPage.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = LibraryStorageLocation(rootURL: URL(fileURLWithPath: "/tmp/KineticPageA", isDirectory: true))
        let other = LibraryStorageLocation(rootURL: URL(fileURLWithPath: "/tmp/KineticPageB", isDirectory: true))

        XCTAssertEqual(MainWindowPageStore(defaults: defaults, library: library).initialPage, .steam,
                       "第一次进入是资料库中的 Steam 页面")
        MainWindowPageStore(defaults: defaults, library: library).save(.favorites)
        XCTAssertEqual(MainWindowPageStore(defaults: defaults, library: library).initialPage, .favorites,
                       "之后回到上次停留的页面")
        MainWindowPageStore(defaults: defaults, library: library).save(.local)
        XCTAssertEqual(MainWindowPageStore(defaults: defaults, library: library).initialPage, .local)
        XCTAssertEqual(MainWindowPageStore(defaults: defaults, library: other).initialPage, .steam, "按资料库分别记录")

        defaults.set([library.rootURL.standardizedFileURL.path: "unknown"], forKey: MainWindowPageStore.storageKey)
        XCTAssertEqual(MainWindowPageStore(defaults: defaults, library: library).initialPage, .steam)

        // 1.0 Module 10：「全部」已删除；以前停在「全部」的，下次打开进入内容相同的「本地」。
        defaults.set([library.rootURL.standardizedFileURL.path: "all"], forKey: MainWindowPageStore.storageKey)
        XCTAssertEqual(MainWindowPageStore(defaults: defaults, library: library).initialPage, .local)
    }

    // MARK: 启动动画

    func testLaunchAnimationHoldsTheFullWordmarkBeforeFadingOut() {
        typealias Timing = LaunchAnimationView.Timing
        XCTAssertTrue((0.2...1.0).contains(Timing.hold), "完整字标停留几百毫秒")
        XCTAssertGreaterThan(Timing.fadeOut, 0)
        XCTAssertGreaterThanOrEqual(Timing.expandDelay, Timing.trajectoryDraw, "K 画完后才缩小左移")
        XCTAssertLessThan(LaunchAnimationView.wordmarkHeight, LaunchAnimationView.logoSide, "K 缩小")
        XCTAssertTrue((0...LaunchAnimationView.wordmarkHeight * 0.1).contains(LaunchAnimationView.opticalLift),
                      "视觉居中只做轻微上移")
        let total = Timing.trajectoryDelay + Timing.expandDelay + Timing.lettersDelay + Timing.lettersReveal
            + Timing.hold + Timing.fadeOut
        XCTAssertLessThan(total, 3.5)
    }

    func testLaunchAnimationPlaysOnceAndRespectsReduceMotion() {
        XCTAssertTrue(LaunchAnimationPolicy.shouldPlay(alreadyPlayed: false, reduceMotion: false, isRunningTests: false))
        XCTAssertFalse(LaunchAnimationPolicy.shouldPlay(alreadyPlayed: true, reduceMotion: false, isRunningTests: false))
        XCTAssertFalse(LaunchAnimationPolicy.shouldPlay(alreadyPlayed: false, reduceMotion: true, isRunningTests: false),
                       "减弱动态效果时不播放")
        XCTAssertFalse(LaunchAnimationPolicy.shouldPlay(alreadyPlayed: false, reduceMotion: false, isRunningTests: true))
        XCTAssertFalse(LaunchAnimationPolicy.consume(), "测试宿主中不播放")
    }
}
