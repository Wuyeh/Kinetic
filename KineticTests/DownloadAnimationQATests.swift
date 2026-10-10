import AppKit
import SwiftUI
import XCTest
@testable import Kinetic

/// Module 59 — Download Animation QA（规格 38「Download Animation QA」，对照规格 11–16）。
/// 单个 / 多个下载、失败、减弱动态效果与 House 排队已由 `SteamDownloadUXTests` 覆盖；这里补齐其余检查项与截图。
@MainActor
final class DownloadAnimationQATests: XCTestCase {
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            if Date() > deadline { XCTFail("Download animation timed out"); return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    // MARK: - House：恰好两次弹簧、在白烟中消失

    /// 规格 16：House 先向上拉伸，再做恰好两次上下弹簧运动，第一次幅度较大、第二次较小，之后静止。
    func testHouseMakesExactlyTwoSpringsWithTheFirstLarger() {
        let samples = (0...2000).map { DownloadAnimationMetrics.bounce(at: Double($0) / 2000) }
        var peaks: [Double] = []
        for i in 1..<(samples.count - 1) where samples[i] > samples[i - 1] && samples[i] >= samples[i + 1] && samples[i] > 0.2 {
            peaks.append(samples[i])
        }
        XCTAssertEqual(peaks.count, 2, "两次向上的弹起：\(peaks)")
        XCTAssertGreaterThan(peaks[0], peaks[1] * 1.5, "第一次明显更大")
        XCTAssertGreaterThan(samples.first { abs($0) > 0.01 } ?? 0, 0, "先向上")
        XCTAssertEqual(samples.last ?? 1, 0, accuracy: 0.0001, "最后静止")
        XCTAssertEqual(DownloadAnimationMetrics.bounce(at: 1.4), 0, accuracy: 0.0001, "之后不再动")
    }

    /// 规格 16：白色烟雾遮住 House，House 在雾中消失，雾随后散开。
    func testHouseVanishesInsideTheSmokeAndTheSmokeClears() {
        let gone = stride(from: 0.0, through: 1.0, by: 0.001).first { DownloadAnimationMetrics.houseOpacity(exit: $0) <= 0 } ?? 1
        XCTAssertGreaterThan(DownloadAnimationMetrics.smokeOpacity(exit: gone), 0.4, "House 消失时雾已经很浓")
        XCTAssertLessThan(gone, 0.5, "House 在雾最浓之前消失")
        XCTAssertEqual(DownloadAnimationMetrics.houseOpacity(exit: 0), 1)
        XCTAssertEqual(DownloadAnimationMetrics.smokeOpacity(exit: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(DownloadAnimationMetrics.smokeOpacity(exit: 1), 0, accuracy: 0.0001, "雾最后散开")
    }

    /// 白烟是中性灰白，浅色与深色窗口上都看得见（之前浅色模式用纯白，几乎看不出）。
    func testSmokeIsNeutralAndVisibleInLightAndDark() throws {
        XCTAssertEqual(DownloadSmoke.mistColor(.dark), .white)
        XCTAssertNotEqual(DownloadSmoke.mistColor(.light), .white)
        let size = CGSize(width: 160, height: 160)
        let smoke = DownloadSmoke(center: CGPoint(x: 80, y: 80), progress: 0.5, reduced: false)
        for (name, appearance) in [("module59-smoke", NSAppearance.Name.aqua), ("module59-smoke-dark", .darkAqua)] {
            let url = try R4SnapshotTests.render(smoke, size: size, name: name, appearance: appearance)
            let image = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
            let center = luminance(image, 0.5, 0.5), corner = luminance(image, 0.04, 0.04)
            XCTAssertGreaterThan(abs(center - corner), 0.06, "\(name)：雾与窗口背景的亮度差 \(abs(center - corner))")
        }
    }

    private func luminance(_ image: CGImage, _ fx: CGFloat, _ fy: CGFloat) -> Double {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -CGFloat(image.width) * fx, y: -CGFloat(image.height) * (1 - fy),
                                       width: CGFloat(image.width), height: CGFloat(image.height)))
        return (0.2126 * Double(pixel[0]) + 0.7152 * Double(pixel[1]) + 0.0722 * Double(pixel[2])) / 255
    }

    // MARK: - 起飞位置

    /// 下载期间卡片滚出可见范围（不再上报位置）：旧位置可能已是别的卡片，Clone 从内容区中央起飞。
    func testCardScrolledAwayBeforeFinishTakesOffFromTheContentCentre() async throws {
        let presentation = SteamDownloadPresentation()
        presentation.durationScale = 0.04
        let visible = CGRect(x: 40, y: 120, width: 190, height: 190)
        presentation.begin(.init(id: "A", image: nil, frame: visible), reduceMotion: false)
        presentation.updateFrames(["A": visible.offsetBy(dx: 0, dy: -60), "other": visible])
        XCTAssertEqual(presentation.posterFrame("A"), visible.offsetBy(dx: 0, dy: -60), "滚动时跟随卡片")
        presentation.updateFrames(["other": visible])
        XCTAssertEqual(presentation.posterFrame("A"), .zero, "滚走后不再用旧位置")
        presentation.updateFrames(["A": visible])
        XCTAssertEqual(presentation.posterFrame("A"), visible, "滚回来后又跟随卡片")
        presentation.updateFrames([:])  // 离开 Steam 页面
        presentation.finish("A", succeeded: true)
        XCTAssertEqual(presentation.current?.poster.frame, .zero)
        try await wait { !presentation.isVisible }
    }

    // MARK: - 时长、窗口尺寸

    /// 规格 15 / 16：飞行约 0.7–1.0 秒；减弱动态效果时只做短促的轻微位移、缩小与淡出。
    func testDurationsFollowTheSpec() {
        XCTAssertGreaterThanOrEqual(DownloadAnimationMetrics.flight, 0.7)
        XCTAssertLessThanOrEqual(DownloadAnimationMetrics.flight, 1.0)
        XCTAssertLessThan(DownloadAnimationMetrics.flightAndImpact(reduced: true), 0.5)
        XCTAssertLessThan(DownloadAnimationMetrics.flightAndImpact(reduced: true),
                          DownloadAnimationMetrics.flightAndImpact(reduced: false) / 2)
    }

    /// 规格 14：House 在工具条右端与窗口右缘之间、不贴边；改变窗口大小时位置随之重新计算（每帧读取容器尺寸）。
    func testHouseStaysInsideTheWindowAndClearOfTheToolbarWhileResizing() {
        let side = DownloadAnimationMetrics.houseSide
        let toolbar = MainWindowDesignTokens.FloatingToolbar.self
        for width in stride(from: CGFloat(520), through: 1800, by: 40) {
            for height: CGFloat in [480, 700, 1100] {
                let center = DownloadAnimationMetrics.houseCenter(in: CGSize(width: width, height: height))
                let house = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
                XCTAssertGreaterThanOrEqual(house.minX, 16, "\(width)×\(height) 不贴左边")
                XCTAssertLessThanOrEqual(house.maxX, width - 16, "\(width)×\(height) 不贴右边")
                XCTAssertLessThan(house.maxY, height, "\(width)×\(height) 在窗口内")
                let barWidth = min(toolbar.width, max(0, width - 32))
                let bar = CGRect(x: (width - barWidth) / 2, y: height - toolbar.bottomInset - toolbar.height,
                                 width: barWidth, height: toolbar.height)
                XCTAssertFalse(house.intersects(bar), "\(width)×\(height) 不压住工具条")
            }
        }
    }

    // MARK: - 截图

    /// 动画关键帧：Clone 飞行、House 两次弹起、白烟退场，浅色 / 深色。
    func testKeyframeSnapshots() throws {
        let poster = NSImage(size: NSSize(width: 180, height: 180), flipped: false) { rect in
            NSColor.systemTeal.setFill(); NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14).fill()
            NSColor.white.withAlphaComponent(0.8).setFill(); NSRect(x: 30, y: 70, width: 120, height: 40).fill()
            return true
        }
        let size = CGSize(width: 900, height: 360)
        let frame = CGRect(x: 30, y: 160, width: 160, height: 160)
        let target = CGPoint(x: 440, y: 90)
        let view = ZStack(alignment: .topLeading) {
            ForEach([0.0, 0.35, 0.65, 0.9], id: \.self) { progress in
                DownloadPosterRibbon(poster: .init(id: "p", image: poster, frame: frame), target: target,
                                     progress: progress, reduced: false)
            }
            ForEach(Array([0.12, 0.37, 0.62].enumerated()), id: \.offset) { index, impact in
                let bounce = DownloadAnimationMetrics.bounce(at: impact)
                Image(systemName: LocalLibraryIcon.symbolName)
                    .font(.system(size: DownloadAnimationMetrics.houseSide, weight: .light))
                    .foregroundStyle(LocalLibraryIcon.color)
                    .scaleEffect(x: 1 - bounce / 100, y: 1 + bounce / 35, anchor: .bottom)
                    .position(x: 600 + CGFloat(index) * 100, y: 90 - bounce)
            }
            ForEach(Array([0.2, 0.45, 0.8].enumerated()), id: \.offset) { index, exit in
                Image(systemName: LocalLibraryIcon.symbolName)
                    .font(.system(size: DownloadAnimationMetrics.houseSide, weight: .light))
                    .foregroundStyle(LocalLibraryIcon.color)
                    .opacity(DownloadAnimationMetrics.houseOpacity(exit: exit))
                    .position(x: 600 + CGFloat(index) * 100, y: 250)
                DownloadSmoke(center: CGPoint(x: 600 + CGFloat(index) * 100, y: 250), progress: exit, reduced: false)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        try R4SnapshotTests.render(view, size: size, name: "module59-keyframes")
        try R4SnapshotTests.render(view, size: size, name: "module59-keyframes-dark", appearance: .darkAqua)
    }
}
