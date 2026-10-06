import AppKit
import SwiftUI
import XCTest
@testable import Kinetic

@MainActor
final class DisplayTargetUITests: XCTestCase {
    private let a = DisplayID("stable-A")
    private let b = DisplayID("stable-B")

    private func display(_ id: DisplayID, name: String = "", size: CGSize? = nil,
                         active: Wallpaper.ID? = nil, preparing: Wallpaper.ID? = nil,
                         last: Wallpaper.ID? = nil) -> DisplayRuntimeState {
        DisplayRuntimeState(displayID: id, displayName: name,
                            runtime: .init(activeWallpaperID: active, preparingWallpaperID: preparing,
                                           lastActiveWallpaperID: last),
                            frame: size.map { CGRect(origin: .zero, size: $0) })
    }

    private func wallpaper(_ name: String = "Rain") -> Wallpaper {
        Wallpaper(name: name, type: .video, source: .local,
                  resourceURL: URL(fileURLWithPath: "/kinetic-ui-fixtures/video.mp4"),
                  thumbnailURL: URL(fileURLWithPath: "/kinetic-ui-fixtures/poster.png"))
    }

    func testDeviceProjectionPreservesStableIdentityGeometryAndHumanNamesAcrossReordering() {
        let rain = wallpaper(), snow = wallpaper("Snow")
        let first = display(a, name: " Built-in Display ", size: .init(width: 1600, height: 1000), active: rain.id)
        let second = display(b, name: "Studio Display", size: .init(width: 1080, height: 1920), active: snow.id)
        let models = [first, second].enumerated().map {
            DisplayTargetItem(display: $1, index: $0, wallpaper: $1.displayID == a ? rain : snow)
        }
        let reordered = [second, first].enumerated().map {
            DisplayTargetItem(display: $1, index: $0, wallpaper: $1.displayID == a ? rain : snow)
        }
        XCTAssertEqual(reordered.map(\.id), [b, a])
        XCTAssertEqual(models[0], reordered[1])
        XCTAssertEqual(models[1], reordered[0])
        XCTAssertEqual(models[0].name, "Built-in Display")
        XCTAssertEqual(models[1].aspectRatio, 1080.0 / 1920.0)
        XCTAssertEqual(models[1].wallpaperName, "Snow")
    }

    func testPreviewUsesCurrentActiveNotPreparingOrStoppedHistory() {
        let old = wallpaper("Old"), candidate = wallpaper("New")
        let switching = display(a, active: old.id, preparing: candidate.id, last: old.id)
        XCTAssertEqual(DisplayTargetItem(display: switching, index: 0, wallpaper: old).thumbnailURL, old.thumbnailURL)
        XCTAssertNil(DisplayTargetItem(display: switching, index: 0, wallpaper: candidate).thumbnailURL)
        let stopped = display(a, last: old.id)
        XCTAssertNil(DisplayTargetItem(display: stopped, index: 0, wallpaper: old).wallpaperName)
        XCTAssertNil(DisplayTargetItem(display: stopped, index: 0, wallpaper: old).thumbnailURL)
    }

    func testPreviewSizesKeepExactDisplayAspectRatioIncludingPortraitAndUltrawide() {
        for size in [CGSize(width: 16, height: 10), .init(width: 16, height: 9),
                     .init(width: 9, height: 16), .init(width: 32, height: 9)] {
            let item = DisplayTargetItem(display: display(a, size: size), index: 0, wallpaper: nil)
            XCTAssertEqual(item.previewSize.width / item.previewSize.height, size.width / size.height, accuracy: 0.00001)
            XCTAssertLessThanOrEqual(item.previewSize.width, MainWindowDesignTokens.DisplayTarget.previewBox.width)
            XCTAssertLessThanOrEqual(item.previewSize.height, MainWindowDesignTokens.DisplayTarget.previewBox.height)
        }
        for invalid in [CGSize.zero, .init(width: CGFloat.infinity, height: 100), .init(width: 200, height: -1)] {
            let item = DisplayTargetItem(display: display(a, name: "  ", size: invalid), index: 2, wallpaper: nil)
            XCTAssertEqual(item.aspectRatio, 1.6)
            XCTAssertEqual(item.name, "显示器 3")
        }
    }

    func testStripBoundsAndRenderedSizeRemainSafeForManyMixedDisplays() {
        let items = (0..<7).map {
            DisplayTargetItem(display: display(DisplayID("screen-\($0)"),
                                              size: .init(width: $0 == 2 ? 9 : 16, height: $0 == 2 ? 16 : 10)),
                              index: $0, wallpaper: nil)
        }
        for width: CGFloat in [900, 640, 380] {
            let expected = DisplayTargetStrip.size(items: items, availableWidth: width)
            let host = NSHostingView(rootView: DisplayTargetStrip(items: items, hoveredID: nil, availableWidth: width))
            let actual = host.fittingSize
            XCTAssertEqual(actual.width, expected.width, accuracy: 1)
            XCTAssertEqual(actual.height, expected.height, accuracy: 1)
            XCTAssertLessThanOrEqual(actual.width, min(640, width - 48) + 1)
            XCTAssertLessThanOrEqual(actual.height, 128 + 1)
        }
    }

    func testHitTestingExcludesClippedAndDisconnectedTargetsAndHasOnlyOneHover() {
        let raw = [a: CGRect(x: 10, y: 10, width: 100, height: 60),
                   b: CGRect(x: 120, y: 10, width: 100, height: 60)]
        let visible = DisplayTargetHitTesting.clippedFrames(raw, viewport: .init(x: 0, y: 0, width: 170, height: 90))
        XCTAssertEqual(visible[b]?.width, 50)
        XCTAssertEqual(DisplayTargetHitTesting.target(at: .init(x: 140, y: 30), frames: visible, availableIDs: [a, b]), b)
        XCTAssertNil(DisplayTargetHitTesting.target(at: .init(x: 180, y: 30), frames: visible, availableIDs: [a, b]))
        XCTAssertNil(DisplayTargetHitTesting.target(at: .init(x: 140, y: 30), frames: visible, availableIDs: [a]))
        XCTAssertNil(DisplayTargetHitTesting.target(at: nil, frames: visible, availableIDs: [a, b]))
        XCTAssertTrue(DisplayTargetHitTesting.clippedFrames(raw, viewport: .zero).isEmpty)
        let overlap = [a: raw[a]!, b: raw[a]!]
        XCTAssertEqual(DisplayTargetHitTesting.target(at: .init(x: 40, y: 30), frames: overlap, availableIDs: [b, a]), b)
    }

    func testRealWindowPublishesVisibleTargetFramesWithoutAStateFeedbackLoop() async throws {
        final class Readings { var frames: [DisplayID: CGRect] = [:] }
        let readings = Readings()
        let items = [a, b].enumerated().map {
            DisplayTargetItem(display: display($1, size: .init(width: 1600, height: 1000)), index: $0, wallpaper: nil)
        }
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 160),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: DisplayTargetStrip(items: items, hoveredID: nil, availableWidth: 600)
            .onPreferenceChange(DisplayTargetFrameKey.self) { readings.frames = $0 })
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(Set(readings.frames.keys), [a, b], "The production strip must actually publish hit-test frames")
        let left = try XCTUnwrap(readings.frames[a]), right = try XCTUnwrap(readings.frames[b])
        XCTAssertEqual(left.width / left.height, 1.6, accuracy: 0.001)
        XCTAssertLessThan(left.maxX, right.minX)
        XCTAssertEqual(DisplayTargetHitTesting.target(at: .init(x: right.midX, y: right.midY),
                                                      frames: readings.frames, availableIDs: [a, b]), b)
    }

    func testPickerCancelDeletionAndDisconnectNeverSelectAnotherDisplay() {
        let rain = wallpaper()
        var picker = DisplayApplyPresentation()
        picker.present(rain.id); picker.cancel()
        XCTAssertNil(picker.takeSelection(b, availableIDs: [a, b], isInLibrary: { _ in true }))
        picker.present(rain.id)
        XCTAssertNil(picker.takeSelection(b, availableIDs: [a], isInLibrary: { _ in true }))
        XCTAssertFalse(picker.isPresented)
        picker.present(rain.id)
        XCTAssertNil(picker.takeSelection(a, availableIDs: [a, b], isInLibrary: { _ in false }))
        XCTAssertFalse(picker.isPresented)
    }

    func testPickerConsumesOneRequestAndUsesStableIDAfterReordering() {
        let rain = wallpaper(), snow = wallpaper("Snow")
        var picker = DisplayApplyPresentation()
        picker.present(rain.id)
        XCTAssertEqual(picker.takeSelection(b, availableIDs: [b, a], isInLibrary: { $0 == rain.id }), rain.id)
        XCTAssertNil(picker.takeSelection(a, availableIDs: [b, a], isInLibrary: { _ in true }))
        picker.present(snow.id)
        XCTAssertEqual(picker.takeSelection(a, availableIDs: [b, a], isInLibrary: { $0 == snow.id }), snow.id)
    }

    func testPickerApplicationChangesOnlyChosenRuntimeSessionAndCancellationPreparesNothing() async throws {
        var made: [TestRenderer] = []
        let runtime = WallpaperRuntimeManager { wallpaper in
            let renderer = TestRenderer(wallpaper); made.append(renderer); return renderer
        }
        defer { runtime.shutdown() }
        runtime.addDisplay(a, host: TestHost()); runtime.addDisplay(b, host: TestHost())
        let rain = wallpaper(), snow = wallpaper("Snow")
        runtime.apply(rain, to: a); await settle()
        var picker = DisplayApplyPresentation()
        picker.present(snow.id)
        XCTAssertEqual(made.count, 1, "Opening a picker never prepares or replaces a wallpaper")
        let id = try XCTUnwrap(picker.takeSelection(b, availableIDs: runtime.displayIDs, isInLibrary: { $0 == snow.id }))
        XCTAssertEqual(id, snow.id)
        runtime.apply(snow, to: b); await settle()
        XCTAssertEqual(runtime.activeWallpaper(on: a)?.id, rain.id)
        XCTAssertEqual(runtime.activeWallpaper(on: b)?.id, snow.id)
        picker.present(rain.id); picker.cancel()
        XCTAssertNil(picker.takeSelection(b, availableIDs: runtime.displayIDs, isInLibrary: { _ in true }))
        XCTAssertEqual(made.count, 2)
        picker.present(rain.id)
        runtime.removeDisplay(b)
        XCTAssertNil(picker.takeSelection(b, availableIDs: runtime.displayIDs, isInLibrary: { _ in true }))
        XCTAssertEqual(runtime.activeWallpaper(on: a)?.id, rain.id)
        XCTAssertEqual(made.count, 2)
    }

    private func settle() async { for _ in 0..<30 { await Task.yield() } }

    private final class TestHost: DesktopContentHost {
        func present(_ view: NSView) -> Bool { true }
        func stop() {}
    }
    private final class TestRenderer: WallpaperRenderer {
        let wallpaper: Wallpaper
        let displayView = NSView()
        var onFailure: (@MainActor (Error) -> Void)?
        init(_ wallpaper: Wallpaper) { self.wallpaper = wallpaper }
        func prepare() async throws {}
        func play() {}
        func pause() {}
        func resume() {}
        func setMuted(_ muted: Bool) {}
        func dispose() {}
    }
}
