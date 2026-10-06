import AppKit
import SwiftUI
import XCTest
@testable import Kinetic

/// Module 11：卡片外观状态、预览区域几何与 Metadata。
final class WallpaperCardTests: XCTestCase {
    private func wallpaper(_ type: WallpaperType = .video, _ source: WallpaperSource = .local,
                           thumbnail: URL? = nil) -> Wallpaper {
        Wallpaper(name: "测试壁纸", type: type, source: source,
                  resourceURL: URL(fileURLWithPath: "/kinetic-card-fixtures/resource"), thumbnailURL: thumbnail)
    }

    private var allStates: [WallpaperCardVisualState] {
        var states: [WallpaperCardVisualState] = []
        for active in [false, true] {
            for selected in [false, true] {
                for hovered in [false, true] {
                    for playable in [false, true] where !(active && !playable) {
                        states.append(WallpaperCardVisualState(isActive: active, isSelected: selected,
                                                               isHovered: hovered, isPlayable: playable))
                    }
                }
            }
        }
        return states
    }

    func testEmphasisPriorityIsActiveThenSelectedAndHoverNeverAddsABorder() {
        for state in allStates {
            let expected: WallpaperCardVisualState.Emphasis =
                state.isActive ? .activeGlow : state.isSelected ? .selection : .none
            XCTAssertEqual(state.emphasis, expected, "\(state)")
            var unhovered = state
            unhovered.isHovered = false
            XCTAssertEqual(state.emphasis, unhovered.emphasis, "Hover must not change the card emphasis")
        }
        // Active + Selected：只显示 Active 光晕，不叠加选中边框。
        let both = WallpaperCardVisualState(isActive: true, isSelected: true, isHovered: false, isPlayable: true)
        XCTAssertEqual(both.emphasis, .activeGlow)
    }

    func testAccessoryShowsActiveBadgeFirstThenHoverActions() {
        for state in allStates {
            let expected: WallpaperCardVisualState.Accessory
            if state.isActive {
                expected = .activeBadge
            } else if state.isHovered {
                expected = state.isPlayable ? .applyButton : .unsupportedBadge
            } else {
                expected = .none
            }
            XCTAssertEqual(state.accessory, expected, "\(state)")
            XCTAssertEqual(state.canApply, state.isPlayable)
        }
        // Normal：只显示预览、名称与 Metadata。
        let normal = WallpaperCardVisualState(isActive: false, isSelected: false, isHovered: false, isPlayable: true)
        XCTAssertEqual(normal.emphasis, .none)
        XCTAssertEqual(normal.accessory, .none)
        // Unsupported 悬停：不显示「应用」，只显示「暂不支持」，也不能应用。
        let unsupported = WallpaperCardVisualState(isActive: false, isSelected: false, isHovered: true, isPlayable: false)
        XCTAssertEqual(unsupported.accessory, .unsupportedBadge)
        XCTAssertFalse(unsupported.canApply)
    }

    func testLocalApplyRequiresAnExplicitTargetOnlyForMultipleDisplays() {
        let first = DisplayID("built-in")
        let second = DisplayID("external")
        let stopped = WallpaperRuntimeState()
        XCTAssertEqual(LocalCardApplyRoute.resolve(RuntimeSummary()), .unavailable)
        let one = RuntimeSummary(displays: [DisplayRuntimeState(displayID: first, displayName: "Built-in", runtime: stopped)])
        XCTAssertEqual(LocalCardApplyRoute.resolve(one), .direct(first))
        let two = RuntimeSummary(displays: one.displays +
            [DisplayRuntimeState(displayID: second, displayName: "External", runtime: stopped)])
        XCTAssertEqual(LocalCardApplyRoute.resolve(two), .chooseDisplay)
    }

    func testStableSelectionAndMarqueeUseWallpaperIDsRatherThanGridPositions() {
        let a = UUID(), b = UUID(), c = UUID()
        var selection = StableCardSelection<UUID>()
        selection.selectOnly(a)
        selection.toggle(b)
        XCTAssertEqual(selection.ids, [a, b])
        selection.toggle(a)
        XCTAssertEqual(selection.ids, [b])

        let frames: [UUID: CGRect] = [
            a: CGRect(x: 20, y: 20, width: 100, height: 100),
            b: CGRect(x: 140, y: 20, width: 100, height: 100),
            c: CGRect(x: 20, y: 150, width: 100, height: 100)
        ]
        // 反向拖拽，只与 b 相交；列位置改变也不改变选中对象的身份。
        selection.replace(with: CardMarqueeSelection.intersectingIDs(
            from: CGPoint(x: 210, y: 90), to: CGPoint(x: 130, y: 10), frames: frames
        ))
        XCTAssertEqual(selection.ids, [b])
        selection.retain([a, c])
        XCTAssertTrue(selection.ids.isEmpty, "Filtered/deleted IDs must not remain selected")
    }

    @MainActor
    func testPlayableMatchesTheRuntimeAvailability() {
        XCTAssertTrue(WallpaperCardVisualState.isPlayable(wallpaper(.video)))
        XCTAssertTrue(WallpaperCardVisualState.isPlayable(wallpaper(.web)))
        XCTAssertTrue(WallpaperCardVisualState.isPlayable(wallpaper(.scene, .steam)))
    }

    @MainActor
    func testMetadataUsesTypeAndShortSource() {
        XCTAssertEqual(WallpaperCardCaption.metadataText(for: wallpaper(.video, .local)), "视频 · 本地")
        XCTAssertEqual(WallpaperCardCaption.metadataText(for: wallpaper(.web, .steam)), "网页 · Steam")
        XCTAssertEqual(WallpaperCardCaption.metadataText(for: wallpaper(.scene, .steam)), "场景 · Steam")
    }

    /// 预览区域的尺寸只由宽度决定：任意比例的缩略图或没有缩略图，都是同样大小的正方形（1.0 Module 11）。
    @MainActor
    func testPreviewAreaGeometryDoesNotDependOnItsContent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KineticCardTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tall = try writeImage(size: NSSize(width: 60, height: 400), to: directory.appendingPathComponent("tall.png"))
        let wide = try writeImage(size: NSSize(width: 900, height: 90), to: directory.appendingPathComponent("wide.png"))

        for width in [180.0, 220.0, 250.0] {
            let sizes = [nil, tall, wide].map { thumbnail in
                NSHostingView(rootView: WallpaperCardPreview(wallpaper: wallpaper(thumbnail: thumbnail))
                    .frame(width: width)).fittingSize
            }
            // 无缩略图、竖图、宽图：预览区域尺寸完全相同。
            XCTAssertEqual(Set(sizes.map { "\($0.width)x\($0.height)" }).count, 1, "\(sizes)")
            // 1:1；高度允许布局对齐到像素网格带来的 1pt 以内误差。
            XCTAssertEqual(sizes[0].width, width, accuracy: 0.5)
            XCTAssertEqual(sizes[0].height, width / MainWindowDesignTokens.Grid.previewAspectRatio, accuracy: 1)
        }
    }

    /// 所有外观状态下，整张卡片的尺寸完全一致：Overlay 与光晕不参与布局。
    @MainActor
    func testCardSizeIsIdenticalAcrossAllVisualStates() {
        for type in [WallpaperType.video, .web] {
            var sizes: Set<String> = []
            for state in allStates {
                let host = NSHostingView(rootView: WallpaperCardContent(
                    wallpaper: wallpaper(type), visualState: state, onSelect: {}, onApply: {}
                ).frame(width: 220))
                let size = host.fittingSize
                sizes.insert("\(Int((size.width * 2).rounded()))x\(Int((size.height * 2).rounded()))")
            }
            XCTAssertEqual(sizes.count, 1, "Card geometry changed across states: \(sizes)")
        }
    }

    private func writeImage(size: NSSize, to url: URL) throws -> URL {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let data = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try data.write(to: url)
        return url
    }
}
