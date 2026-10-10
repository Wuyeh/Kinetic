import AppKit
import AVFoundation
import SwiftUI
import XCTest
@testable import Kinetic

/// Module 58 — Poster Rendering QA（规格 38「Poster QA」矩阵）：方 / 横 / 竖静态图、动态 GIF / APNG / WebP、视频 Poster、
/// 模糊延展、浅色 / 深色、不同卡片尺寸、滚动、离屏暂停。每种都用界面实际使用的 `PosterLayerView` 绘制并逐像素检查，
/// 同时输出一张对照总图（.build/R4/snapshots/module58-poster-matrix.png）。
@MainActor
final class PosterQATests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("KineticPosterQA-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func fixture(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
    }

    /// 四条彩色竖条（`vertical`）或横条：条纹方向上的对称性可以逐像素检查。
    private func stripes(width: Int, height: Int, vertical: Bool, name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let colors: [NSColor] = [NSColor(deviceRed: 0.9, green: 0.1, blue: 0.1, alpha: 1),
                                 NSColor(deviceRed: 0.95, green: 0.6, blue: 0.1, alpha: 1),
                                 NSColor(deviceRed: 0.1, green: 0.8, blue: 0.2, alpha: 1),
                                 NSColor(deviceRed: 0.1, green: 0.2, blue: 0.9, alpha: 1)]
        for x in 0..<width {
            for y in 0..<height {
                let index = vertical ? x * colors.count / width : y * colors.count / height
                rep.setColor(colors[index], atX: x, y: y)
            }
        }
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    /// 本地视频没有 Poster 时导入流程使用的代表帧（规格 8），按导入时的方式存成图片。
    private func videoPoster() async throws -> URL {
        let video = try fixture("loop", "mp4")
        let found = await PosterFrameSelector.representativeFrame(of: video)
        let frame = try XCTUnwrap(found)
        let url = directory.appendingPathComponent("video-poster.png")
        try XCTUnwrap(NSBitmapImageRep(cgImage: frame).representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    private struct Pixels {
        let image: CGImage
        let width: Int
        let height: Int
        let bytes: [UInt8]

        init(_ image: CGImage) {
            self.image = image
            width = image.width; height = image.height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            bytes.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                        bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            self.bytes = bytes
        }

        /// (fx, fy) 以左上为原点的比例坐标。
        func rgba(_ fx: CGFloat, _ fy: CGFloat) -> [Double] {
            let x = min(width - 1, max(0, Int(CGFloat(width) * fx)))
            let y = min(height - 1, max(0, Int(CGFloat(height) * fy)))
            let i = (y * width + x) * 4
            return (0..<4).map { Double(bytes[i + $0]) / 255 }
        }
    }

    private func render(_ url: URL, side: CGFloat) throws -> Pixels {
        let view = PosterLayerView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        view.artwork = try XCTUnwrap(PosterArtwork(url: url))
        return Pixels(try XCTUnwrap(view.renderedImage(scale: 2)))
    }

    private func distance(_ a: [Double], _ b: [Double]) -> Double {
        zip(a.prefix(3), b.prefix(3)).map { abs($0 - $1) }.max() ?? 1
    }

    // MARK: - 矩阵

    func testEveryPosterKindIsAWholeRoundedSquareAtEveryCardSize() async throws {
        let kinds: [(name: String, url: URL, shape: String)] = [
            ("方图", try stripes(width: 400, height: 400, vertical: true, name: "square.png"), "square"),
            ("横图", try stripes(width: 1600, height: 900, vertical: true, name: "wide.png"), "wideStripes"),
            ("竖图", try stripes(width: 900, height: 1600, vertical: false, name: "tall.png"), "tallStripes"),
            ("GIF", try fixture("poster-animated-wide", "gif"), "wide"),
            ("APNG", try fixture("poster-animated-tall", "png"), "tall"),
            ("WebP", try fixture("poster-animated-wide", "webp"), "wide"),
            ("视频", try await videoPoster(), "video"),
        ]
        let sides: [CGFloat] = [180, 215, 250]
        var sheet: [[CGImage]] = []
        for kind in kinds {
            var row: [CGImage] = []
            for side in sides {
                let pixels = try render(kind.url, side: side)
                let label = "\(kind.name) \(Int(side)) pt"
                XCTAssertEqual(pixels.width, pixels.height, "\(label) 正方形")
                XCTAssertEqual(CGFloat(pixels.width), side * 2, accuracy: 1, "\(label) 尺寸只由卡片决定")
                XCTAssertLessThan(pixels.rgba(0.002, 0.002)[3], 0.2, "\(label) 左上角是圆角")
                XCTAssertLessThan(pixels.rgba(0.998, 0.998)[3], 0.2, "\(label) 右下角是圆角")
                XCTAssertGreaterThan(pixels.rgba(0.5, 0.5)[3], 0.99, "\(label) 中央不透明")
                // 延展区域都由背景填满；条纹图的颜色沿延展方向不变，所以还能检查两侧对称。
                switch kind.shape {
                case "wide", "wideStripes":
                    XCTAssertGreaterThan(pixels.rgba(0.5, 0.05)[3], 0.99, "\(label) 上方由模糊背景填满")
                    XCTAssertGreaterThan(pixels.rgba(0.5, 0.95)[3], 0.99, "\(label) 下方由模糊背景填满")
                    if kind.shape == "wideStripes" {
                        XCTAssertLessThan(distance(pixels.rgba(0.3, 0.06), pixels.rgba(0.3, 0.94)), 0.12, "\(label) 上下对称延展")
                    }
                case "tall", "tallStripes":
                    XCTAssertGreaterThan(pixels.rgba(0.05, 0.5)[3], 0.99, "\(label) 左侧由模糊背景填满")
                    XCTAssertGreaterThan(pixels.rgba(0.95, 0.5)[3], 0.99, "\(label) 右侧由模糊背景填满")
                    if kind.shape == "tallStripes" {
                        XCTAssertLessThan(distance(pixels.rgba(0.06, 0.3), pixels.rgba(0.94, 0.3)), 0.12, "\(label) 左右对称延展")
                    }
                case "square":
                    // 方图直接铺满：四条竖条从左到右都在，没有模糊边。
                    XCTAssertLessThan(distance(pixels.rgba(0.12, 0.5), [0.9, 0.1, 0.1]), 0.15, "\(label) 最左边的条纹完整")
                    XCTAssertLessThan(distance(pixels.rgba(0.88, 0.5), [0.1, 0.2, 0.9]), 0.15, "\(label) 最右边的条纹完整")
                default:
                    break
                }
                row.append(pixels.image)
            }
            sheet.append(row)
        }
        try writeSheet(sheet, rowLabels: kinds.map(\.name), columnLabels: sides.map { "\(Int($0)) pt" },
                       name: "module58-poster-matrix")
    }

    /// 竖图：中间一列能看到最上和最下的条纹（没有裁掉），左右是对称的模糊背景。
    func testTallPosterStaysWholeWithSymmetricBlurLeftAndRight() throws {
        let pixels = try render(try stripes(width: 900, height: 1600, vertical: false, name: "tall-check.png"), side: 200)
        XCTAssertLessThan(distance(pixels.rgba(0.5, 0.04), [0.9, 0.1, 0.1]), 0.15, "最上面的条纹在")
        XCTAssertLessThan(distance(pixels.rgba(0.5, 0.96), [0.1, 0.2, 0.9]), 0.15, "最下面的条纹在")
        for fy in stride(from: 0.1, through: 0.9, by: 0.2) {
            XCTAssertLessThan(distance(pixels.rgba(0.08, fy), pixels.rgba(0.92, fy)), 0.12, "第 \(fy) 行左右对称")
        }
    }

    // MARK: - 动态 WebP

    func testAnimatedWebPIsDetectedDecodedAndPlaysOnlyWhileVisible() async throws {
        let url = try fixture("poster-animated-wide", "webp")
        let artwork = try XCTUnwrap(PosterArtwork(url: url))
        XCTAssertEqual(artwork.frameCount, 4)
        XCTAssertTrue(artwork.isAnimated)
        XCTAssertTrue(artwork.needsBackdrop, "16:9 的 WebP 需要模糊延展")
        XCTAssertEqual(artwork.pixelSize, CGSize(width: 160, height: 90))

        if ProcessInfo.processInfo.isLowPowerModeEnabled { throw XCTSkip("Low Power Mode pauses animated posters") }
        let window = NSWindow(contentRect: NSRect(x: 240, y: 240, width: 300, height: 300),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.orderFrontRegardless()
        let view = PosterLayerView(frame: NSRect(x: 50, y: 50, width: 200, height: 200))
        window.contentView?.addSubview(view)
        view.artwork = artwork
        if !window.occlusionState.contains(.visible) {
            _ = await waitUntil(2) { window.occlusionState.contains(.visible) }
            view.updatePlayback()
        }
        guard window.occlusionState.contains(.visible) else { throw XCTSkip("Test window is not visible on screen") }
        let played = await waitUntil(5) { view.displayedFrameCount >= 6 }
        XCTAssertTrue(played, "WebP 帧在可见时前进（\(view.displayedFrameCount)）")
        view.isHidden = true
        XCTAssertFalse(view.isAnimating, "隐藏后停止")
        view.stopAnimating()
    }

    // MARK: - 滚动与离屏暂停

    /// 30 张动态 Poster 放在滚动区域里：只有看得见的几张在播放；滚到底部后，上面的停下、下面的开始。
    func testOnlyPostersInsideTheScrolledViewportAnimate() async throws {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { throw XCTSkip("Low Power Mode pauses animated posters") }
        let window = NSWindow(contentRect: NSRect(x: 260, y: 160, width: 260, height: 520),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 260, height: 520))
        let side: CGFloat = 200, gap: CGFloat = 20, count = 30
        let document = FlippedView(frame: NSRect(x: 0, y: 0, width: 260, height: CGFloat(count) * (side + gap)))
        scroll.documentView = document
        window.contentView = scroll
        let artwork = try XCTUnwrap(PosterArtwork(url: try fixture("poster-animated-wide", "gif")))
        let posters = (0..<count).map { index -> PosterLayerView in
            let view = PosterLayerView(frame: NSRect(x: 30, y: CGFloat(index) * (side + gap), width: side, height: side))
            document.addSubview(view)
            return view
        }
        window.orderFrontRegardless()
        window.contentView?.layoutSubtreeIfNeeded()
        scroll.tile()
        posters.forEach { $0.artwork = artwork }
        if !window.occlusionState.contains(.visible) {
            _ = await waitUntil(2) { window.occlusionState.contains(.visible) }
            posters.forEach { $0.updatePlayback() }
        }
        guard window.occlusionState.contains(.visible) else { throw XCTSkip("Test window is not visible on screen") }

        func animating() -> Set<Int> { Set(posters.indices.filter { posters[$0].isAnimating }) }
        func visible() -> Set<Int> {
            let viewport = scroll.contentView.bounds
            return Set(posters.indices.filter { posters[$0].frame.intersects(viewport) })
        }
        XCTAssertEqual(animating(), visible(), "开始时只有可见的播放")
        XCTAssertLessThanOrEqual(animating().count, 3)
        XCTAssertTrue(animating().contains(0))

        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.frame.height - scroll.contentView.bounds.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        let settled = await waitUntil(2) { animating() == visible() && animating().contains(count - 1) }
        XCTAssertTrue(settled, "滚到底后：播放 \(animating().sorted())，可见 \(visible().sorted())")
        XCTAssertFalse(animating().contains(0), "滚出可视范围的停下")
        posters.forEach { $0.stopAnimating() }
    }

    // MARK: - 浅色 / 深色

    /// 没有 Poster 的占位（视频 / 网页）在浅色与深色下都使用系统中性色与次要前景。
    func testPlaceholdersInLightAndDark() throws {
        let view = HStack(spacing: 20) {
            PosterView(posterURL: nil, placeholderType: .video).frame(width: 180)
            PosterView(posterURL: nil, placeholderType: .web).frame(width: 180)
        }.padding(20)
        let size = CGSize(width: 440, height: 220)
        let light = try R4SnapshotTests.render(view, size: size, name: "module58-placeholders")
        let dark = try R4SnapshotTests.render(view, size: size, name: "module58-placeholders-dark", appearance: .darkAqua)
        let lightCenter = try sample(light, 0.25, 0.5), darkCenter = try sample(dark, 0.25, 0.5)
        XCTAssertGreaterThan(lightCenter.reduce(0, +) / 3, 0.75, "浅色占位是浅底")
        XCTAssertLessThan(darkCenter.reduce(0, +) / 3, 0.35, "深色占位是深底")
    }

    private func sample(_ url: URL, _ fx: CGFloat, _ fy: CGFloat) throws -> [Double] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return Array(Pixels(image).rgba(fx, fy).prefix(3))
    }

    // MARK: - Helpers

    private func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !condition() {
            if ProcessInfo.processInfo.systemUptime > deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }

    private final class FlippedView: NSView { override var isFlipped: Bool { true } }

    /// 把矩阵画成一张总图：每行一种 Poster，每列一种卡片尺寸；左半浅色、右半深色背景。
    private func writeSheet(_ rows: [[CGImage]], rowLabels: [String], columnLabels: [String], name: String) throws {
        let cell: CGFloat = 520, labelWidth: CGFloat = 160, header: CGFloat = 60
        let columns = rows.first?.count ?? 0
        let half = labelWidth + CGFloat(columns) * cell
        let size = CGSize(width: half * 2, height: header + CGFloat(rows.count) * cell)
        let image = NSImage(size: size)
        image.lockFocus()
        for (offset, background) in [(CGFloat(0), NSColor(white: 0.93, alpha: 1)), (half, NSColor(white: 0.12, alpha: 1))] {
            background.setFill()
            NSRect(x: offset, y: 0, width: half, height: size.height).fill()
            let text = offset == 0 ? NSColor.black : NSColor.white
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 26, weight: .semibold),
                                                             .foregroundColor: text]
            for (column, label) in columnLabels.enumerated() {
                (label as NSString).draw(at: NSPoint(x: offset + labelWidth + CGFloat(column) * cell + 20,
                                                     y: size.height - header + 14), withAttributes: attributes)
            }
            for (index, row) in rows.enumerated() {
                let y = size.height - header - CGFloat(index + 1) * cell
                (rowLabels[index] as NSString).draw(at: NSPoint(x: offset + 20, y: y + cell / 2 - 14), withAttributes: attributes)
                for (column, poster) in row.enumerated() {
                    let side = CGFloat(poster.width)
                    let origin = NSPoint(x: offset + labelWidth + CGFloat(column) * cell + (cell - side) / 2,
                                         y: y + (cell - side) / 2)
                    NSImage(cgImage: poster, size: NSSize(width: side, height: side))
                        .draw(in: NSRect(origin: origin, size: NSSize(width: side, height: side)))
                }
            }
        }
        image.unlockFocus()
        let rep = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        try FileManager.default.createDirectory(at: R4SnapshotTests.folder, withIntermediateDirectories: true)
        try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            .write(to: R4SnapshotTests.folder.appendingPathComponent("\(name).png"))
    }
}
