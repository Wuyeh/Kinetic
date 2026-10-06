import AppKit
import SwiftUI
import XCTest
@testable import Kinetic

/// Kinetic 1.0 Module 11：Unified Square Poster Grid（规格第 5–7 节）。
final class PosterGridTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KineticPosterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func fixture(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
    }

    /// 竖条纹图片：上下方向没有变化，所以背景只要是对称延展，顶部与底部的颜色就一致。
    private func stripedImage(width: Int, height: Int, name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        // 明确的 device RGB 颜色（系统动态颜色不能直接写进位图）。
        let colors: [NSColor] = [NSColor(deviceRed: 0.9, green: 0.1, blue: 0.1, alpha: 1),
                                 NSColor(deviceRed: 0.95, green: 0.6, blue: 0.1, alpha: 1),
                                 NSColor(deviceRed: 0.1, green: 0.8, blue: 0.2, alpha: 1),
                                 NSColor(deviceRed: 0.1, green: 0.2, blue: 0.9, alpha: 1)]
        for x in 0..<width {
            let color = colors[x * colors.count / width]
            for y in 0..<height { rep.setColor(color, atX: x, y: y) }
        }
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    private func wallpaper(poster: URL?) -> Wallpaper {
        Wallpaper(name: "Poster", type: .video, acquisitionOrigin: .localImport,
                  resourceURL: URL(fileURLWithPath: "/kinetic-poster-tests/x.mp4"), thumbnailURL: poster)
    }

    /// 渲染结果：sRGB、RGBA 8 位，第一行在顶部。
    private struct Pixels {
        let width: Int
        let height: Int
        let bytes: [UInt8]
    }

    /// 用界面中实际使用的 Poster 图层绘制，再画进自己的 RGBA 缓冲区逐像素读取。
    @MainActor
    private func render(poster url: URL, side: CGFloat) throws -> Pixels {
        let view = PosterLayerView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        view.artwork = try XCTUnwrap(PosterArtwork(url: url))
        let image = try XCTUnwrap(view.renderedImage())
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(drawn)
        return Pixels(width: width, height: height, bytes: bytes)
    }

    private func color(_ pixels: Pixels, _ fx: CGFloat, _ fy: CGFloat) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        let x = min(pixels.width - 1, Int(CGFloat(pixels.width) * fx))
        let y = min(pixels.height - 1, Int(CGFloat(pixels.height) * fy))
        let i = (y * pixels.width + x) * 4
        let b = pixels.bytes
        return (CGFloat(b[i]) / 255, CGFloat(b[i + 1]) / 255, CGFloat(b[i + 2]) / 255, CGFloat(b[i + 3]) / 255)
    }

    // MARK: - 圆角正方形

    func testPosterIsASquareWithProportionalContinuousCorners() {
        XCTAssertEqual(PosterGeometry.aspectRatio, 1)
        XCTAssertEqual(MainWindowDesignTokens.Grid.previewAspectRatio, 1)
        for side in [180.0, 220.0, 250.0] {
            let radius = PosterGeometry.cornerRadius(forSide: side)
            XCTAssertEqual(radius / side, PosterGeometry.cornerRadiusFraction, accuracy: 0.0001)
            XCTAssertGreaterThan(radius / side, 0.05, "Not as hard as a web card")
            XCTAssertLessThan(radius / side, 0.12, "Not as round as an app icon")
        }
        XCTAssertGreaterThan(PosterGeometry.cornerRadius(forSide: 250), PosterGeometry.cornerRadius(forSide: 180),
                             "Corners scale with the card")
        let path = PosterShape().path(in: CGRect(x: 0, y: 0, width: 200, height: 200))
        XCTAssertEqual(path.boundingRect.width, 200, accuracy: 0.01)
        XCTAssertFalse(path.contains(CGPoint(x: 1, y: 1)), "Rounded corner")
        XCTAssertTrue(path.contains(CGPoint(x: 100, y: 1)))
        let inset = PosterShape().inset(by: 1).path(in: CGRect(x: 0, y: 0, width: 200, height: 200))
        XCTAssertEqual(inset.boundingRect.width, 198, accuracy: 0.01)
    }

    func testNonSquarePostersStayWholeAndCentred() {
        let square = CGRect(x: 0, y: 0, width: 200, height: 200)
        let wide = PosterGeometry.foregroundRect(imageSize: CGSize(width: 1600, height: 900), in: square)
        XCTAssertEqual(wide.width, 200, accuracy: 0.01)
        XCTAssertEqual(wide.height, 112.5, accuracy: 0.01)
        XCTAssertEqual(wide.minY, square.maxY - wide.maxY, accuracy: 0.01, "Wide posters extend equally above and below")
        let tall = PosterGeometry.foregroundRect(imageSize: CGSize(width: 900, height: 1600), in: square)
        XCTAssertEqual(tall.height, 200, accuracy: 0.01)
        XCTAssertEqual(tall.minX, square.maxX - tall.maxX, accuracy: 0.01, "Tall posters extend equally left and right")
        XCTAssertTrue(PosterGeometry.isEffectivelySquare(CGSize(width: 500, height: 505)))
        XCTAssertFalse(PosterGeometry.isEffectivelySquare(CGSize(width: 1600, height: 900)))
    }

    // MARK: - 非正方形 Poster 的背景

    @MainActor
    func testArtworkBuildsASmallBlurredBackdropOnlyForNonSquarePosters() throws {
        let wide = try XCTUnwrap(PosterArtwork(url: try stripedImage(width: 320, height: 180, name: "wide.png")))
        XCTAssertTrue(wide.needsBackdrop)
        XCTAssertFalse(wide.isAnimated)
        let backdrop = try XCTUnwrap(wide.backdrop)
        XCTAssertLessThanOrEqual(max(backdrop.width, backdrop.height), PosterBackdrop.maximumSide)
        XCTAssertEqual(Double(backdrop.width) / Double(backdrop.height), 320.0 / 180.0, accuracy: 0.05)

        let square = try XCTUnwrap(PosterArtwork(url: try stripedImage(width: 200, height: 200, name: "square.png")))
        XCTAssertFalse(square.needsBackdrop)
        XCTAssertNil(square.backdrop)
        XCTAssertNil(PosterArtwork(url: directory.appendingPathComponent("missing.png")))
    }

    /// 横图：中间是完整的原图，上下两侧是同一张图的模糊延展，而且上下对称（不是只向下延展）。
    @MainActor
    func testWidePosterRendersWholeInTheMiddleWithSymmetricBlurAboveAndBelow() throws {
        let url = try stripedImage(width: 400, height: 200, name: "wide-render.png")
        let rep = try render(poster: url, side: 200)
        XCTAssertEqual(rep.width, 200)
        print("Poster render samples:", [0.1, 0.5, 0.9].flatMap { fy in [0.1, 0.5, 0.9].map { color(rep, $0, fy) } })

        // 中间一行：从左到右依次是四种颜色（原图完整显示，没有被裁掉两侧）。
        let left = color(rep, 0.1, 0.5), right = color(rep, 0.9, 0.5)
        XCTAssertGreaterThan(left.r, 0.7, "Leftmost stripe (red) is visible")
        XCTAssertGreaterThan(right.b, 0.6, "Rightmost stripe (blue) is visible")
        // 上下 10% 处：模糊背景，不透明，且上下同一列的颜色一致。
        for fx in [0.3, 0.5, 0.7] {
            let top = color(rep, fx, 0.1), bottom = color(rep, fx, 0.9)
            XCTAssertGreaterThan(top.a, 0.95, "Backdrop fills the square")
            XCTAssertEqual(top.r, bottom.r, accuracy: 0.08)
            XCTAssertEqual(top.g, bottom.g, accuracy: 0.08)
            XCTAssertEqual(top.b, bottom.b, accuracy: 0.08)
        }
        // 背景降低了对比：顶部左侧不像原图那样是纯红。
        XCTAssertLessThan(color(rep, 0.1, 0.1).r - color(rep, 0.1, 0.1).b, left.r - left.b)
    }

    @MainActor
    func testPosterSizeNeverDependsOnItsContent() throws {
        let wide = try stripedImage(width: 900, height: 90, name: "very-wide.png")
        let tall = try stripedImage(width: 60, height: 400, name: "very-tall.png")
        let animated = try fixture("poster-animated-wide", "gif")
        for width in [180.0, 250.0] {
            let sizes = [nil, wide, tall, animated].map { poster in
                NSHostingView(rootView: PosterView(wallpaper: wallpaper(poster: poster)).frame(width: width)).fittingSize
            }
            XCTAssertEqual(Set(sizes.map { "\($0.width)x\($0.height)" }).count, 1, "\(sizes)")
            XCTAssertEqual(sizes[0].height, width, accuracy: 1)
        }
    }

    // MARK: - 动态 Poster

    @MainActor
    func testAnimatedPostersAreDetected() throws {
        let gif = try XCTUnwrap(PosterArtwork(url: try fixture("poster-animated-wide", "gif")))
        XCTAssertTrue(gif.isAnimated)
        XCTAssertGreaterThan(gif.frameCount, 5)
        XCTAssertTrue(gif.needsBackdrop)
        let apng = try XCTUnwrap(PosterArtwork(url: try fixture("poster-animated-tall", "png")))
        XCTAssertTrue(apng.isAnimated, "APNG")
        XCTAssertTrue(apng.needsBackdrop)
    }

    func testAnimationOnlyRunsWhenVisibleAndAllowed() {
        typealias P = AnimatedPosterPlaybackPolicy
        XCTAssertTrue(P.shouldAnimate(isVisibleInScrollView: true, windowIsVisible: true, lowPowerMode: false, reduceMotion: false))
        XCTAssertFalse(P.shouldAnimate(isVisibleInScrollView: false, windowIsVisible: true, lowPowerMode: false, reduceMotion: false),
                       "Offscreen cards pause")
        XCTAssertFalse(P.shouldAnimate(isVisibleInScrollView: true, windowIsVisible: false, lowPowerMode: false, reduceMotion: false))
        XCTAssertFalse(P.shouldAnimate(isVisibleInScrollView: true, windowIsVisible: true, lowPowerMode: true, reduceMotion: false),
                       "Low Power Mode pauses")
        XCTAssertFalse(P.shouldAnimate(isVisibleInScrollView: true, windowIsVisible: true, lowPowerMode: false, reduceMotion: true))
    }

    /// 真实窗口：可见时逐帧播放（背景跟随当前帧），隐藏时停在当前帧，再显示时继续。
    @MainActor
    func testVisibleAnimatedPosterPlaysAndPausesWhenHidden() async throws {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { throw XCTSkip("Low Power Mode pauses animated posters") }
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 300, height: 300),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.orderFrontRegardless()
        let view = PosterLayerView(frame: NSRect(x: 50, y: 50, width: 200, height: 200))
        window.contentView?.addSubview(view)
        view.artwork = try XCTUnwrap(PosterArtwork(url: try fixture("poster-animated-wide", "gif")))

        func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) async -> Bool {
            let deadline = ProcessInfo.processInfo.systemUptime + seconds
            while !condition() {
                if ProcessInfo.processInfo.systemUptime > deadline { return false }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            return true
        }
        if !window.occlusionState.contains(.visible) {
            _ = await waitUntil(2) { window.occlusionState.contains(.visible) }
            view.updatePlayback()
        }
        guard window.occlusionState.contains(.visible) else { throw XCTSkip("Test window is not visible on screen") }

        let started = await waitUntil(5) { view.displayedFrameCount >= 5 }
        XCTAssertTrue(started, "Frames advance while visible (\(view.displayedFrameCount))")
        XCTAssertTrue(view.isAnimating)
        XCTAssertCornerRadius(view)

        view.isHidden = true
        XCTAssertFalse(view.isAnimating, "Hidden posters stop")
        let frozen = view.displayedFrameCount
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertLessThanOrEqual(view.displayedFrameCount, frozen + 1)

        view.isHidden = false
        let resumed = await waitUntil(5) { view.displayedFrameCount >= frozen + 3 }
        XCTAssertTrue(resumed)
        view.stopAnimating()
        XCTAssertFalse(view.isAnimating)
    }

    @MainActor
    private func XCTAssertCornerRadius(_ view: PosterLayerView, file: StaticString = #filePath, line: UInt = #line) {
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.layer?.cornerRadius ?? 0, PosterGeometry.cornerRadius(forSide: 200), accuracy: 0.5,
                       "NSView content clips its own corners", file: file, line: line)
    }

    // MARK: - Live Preview 与 Poster 一致

    @MainActor
    func testWebPreviewRendersAtDesktopProportionsInsideTheSquare() {
        let content = LivePreviewContentView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let web = NSView(frame: content.bounds)
        content.addSubview(web)
        content.contentAspectRatio = 16.0 / 10.0
        content.layoutPlayerLayers()
        XCTAssertEqual(web.frame.width, 200, accuracy: 0.01)
        XCTAssertEqual(web.frame.height, 125, accuracy: 0.01)
        XCTAssertEqual(web.frame.minY, 37.5, accuracy: 0.01, "Centred vertically")
        content.setFrameSize(NSSize(width: 250, height: 250))
        XCTAssertEqual(web.frame.width, 250, accuracy: 0.01, "Follows the card size")
        XCTAssertGreaterThan(WebPreviewSession.desktopAspectRatio, 1)
    }
}
