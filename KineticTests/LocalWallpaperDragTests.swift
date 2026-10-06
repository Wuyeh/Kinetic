import AppKit
import SwiftUI
import XCTest
@testable import Kinetic

@MainActor
final class LocalWallpaperDragTests: XCTestCase {
    private let a = DisplayID("stable-A"), b = DisplayID("stable-B")
    private let first = UUID(), other = UUID(), list = UUID()
    private var frames: [DisplayID: CGRect] {
        [a: .init(x: 100, y: 10, width: 150, height: 100), b: .init(x: 270, y: 10, width: 150, height: 100)]
    }
    private let insideA = CGPoint(x: 175, y: 60), insideB = CGPoint(x: 345, y: 60)

    private func move(_ drag: inout LocalWallpaperDragPresentation, _ point: CGPoint) {
        drag.move(point, from: first, displayFrames: frames, displayIDs: [a, b], listFrames: [:], listIDs: [])
    }
    private func drop(_ drag: inout LocalWallpaperDragPresentation, _ point: CGPoint,
                      displays: [DisplayID]? = nil, valid: Bool = true, playable: Bool = true)
        -> LocalWallpaperDragPresentation.Destination? {
        drag.takeDrop(from: first, at: point, displayFrames: frames, displayIDs: displays ?? [a, b],
                      listFrames: [:], listIDs: [], isInLibrary: valid, isPlayable: playable)
    }

    func testLongPressBeginIsSingleAndDoesNotReplaceAnotherSource() {
        var drag = LocalWallpaperDragPresentation()
        XCTAssertTrue(drag.begin(first))
        XCTAssertFalse(drag.begin(first))
        XCTAssertFalse(drag.begin(other))
        XCTAssertEqual(drag.wallpaperID, first)
        XCTAssertNil(drag.location)
        XCTAssertNil(drag.hoveredDisplayID)
        drag.move(insideA, from: other, displayFrames: frames, displayIDs: [a, b], listFrames: [:], listIDs: [])
        XCTAssertNil(drag.location, "An old card cannot move a newer drag")
        drag.cancel(from: other)
        XCTAssertEqual(drag.wallpaperID, first)
    }

    func testPointerMovesContinuouslyAndOnlyOneTargetGlows() {
        var drag = LocalWallpaperDragPresentation(); drag.begin(first)
        for x in stride(from: 100.5, through: 249.5, by: 0.5) {
            let point = CGPoint(x: x, y: 60)
            move(&drag, point)
            XCTAssertEqual(drag.location, point)
            XCTAssertEqual(drag.hoveredDisplayID, a)
        }
        move(&drag, .init(x: 260, y: 60))
        XCTAssertNil(drag.hoveredDisplayID)
        move(&drag, insideB)
        XCTAssertEqual(drag.hoveredDisplayID, b)
        move(&drag, .init(x: 345, y: 300))
        XCTAssertNil(drag.hoveredDisplayID)
    }

    func testReleaseUsesFinalLocationNotCachedHoverAndConsumesExactlyOnce() {
        var drag = LocalWallpaperDragPresentation(); drag.begin(first); move(&drag, insideA)
        XCTAssertEqual(drop(&drag, insideB), .display(first, b))
        XCTAssertNil(drag.wallpaperID); XCTAssertNil(drag.location); XCTAssertNil(drag.hoveredDisplayID)
        XCTAssertNil(drop(&drag, insideA))
        drag.begin(first); move(&drag, insideA)
        XCTAssertNil(drop(&drag, .init(x: 260, y: 60)), "Outside release must not apply last hovered display")
    }

    func testEscapeSystemInterruptionAndLateReleaseCannotApply() {
        var drag = LocalWallpaperDragPresentation(); drag.begin(first); move(&drag, insideB)
        drag.cancel()
        move(&drag, insideA)
        XCTAssertNil(drop(&drag, insideB))
        XCTAssertNil(drag.location)
        XCTAssertTrue(drag.begin(other), "A new drag can begin after cancellation")
        XCTAssertNil(drop(&drag, insideA), "A late release from the old source cannot consume the new drag")
        XCTAssertEqual(drag.wallpaperID, other)
    }

    func testReorderDisconnectAndRelayoutUseCurrentStableTargets() {
        var drag = LocalWallpaperDragPresentation(); drag.begin(first); move(&drag, insideB)
        drag.refresh(displayFrames: frames, displayIDs: [a], listFrames: [:], listIDs: [])
        XCTAssertNil(drag.hoveredDisplayID)
        XCTAssertNil(drop(&drag, insideB, displays: [a]), "Never fall back to surviving A")
        drag.begin(first)
        XCTAssertEqual(drop(&drag, insideB, displays: [b, a]), .display(first, b))
        drag.begin(first); move(&drag, insideA)
        drag.refresh(displayFrames: [:], displayIDs: [a, b], listFrames: [:], listIDs: [])
        XCTAssertNil(drag.hoveredDisplayID, "Invalidate old geometry until the new layout publishes")
        let changed = [b: frames[a]!]
        drag.refresh(displayFrames: changed, displayIDs: [b, a], listFrames: [:], listIDs: [])
        XCTAssertEqual(drag.hoveredDisplayID, b, "Geometry refresh recomputes hover even with a stationary pointer")
    }

    func testDeletedUnsupportedAndNoDisplayCancelWithoutApplying() {
        for mode in 0..<3 {
            var drag = LocalWallpaperDragPresentation(); drag.begin(first); move(&drag, insideA)
            XCTAssertNil(drop(&drag, insideA, displays: mode == 2 ? [] : nil,
                              valid: mode != 0, playable: mode != 1))
            XCTAssertNil(drag.wallpaperID)
        }
    }

    func testListDropStillAddsOneSourceIncludingUnsupportedAndNeverApplies() {
        var drag = LocalWallpaperDragPresentation(); drag.begin(first)
        let lists = [list: frames[a]!]
        drag.move(insideA, from: first, displayFrames: frames, displayIDs: [a, b], listFrames: lists, listIDs: [list])
        XCTAssertEqual(drag.hoveredListID, list)
        XCTAssertNil(drag.hoveredDisplayID)
        XCTAssertEqual(drag.takeDrop(from: first, at: insideA, displayFrames: frames, displayIDs: [a, b],
                                    listFrames: lists, listIDs: [list], isInLibrary: true, isPlayable: false), .list(first, list))
        drag.begin(first)
        XCTAssertNil(drag.takeDrop(from: first, at: insideA, displayFrames: [:], displayIDs: [a, b],
                                  listFrames: lists, listIDs: [], isInLibrary: true, isPlayable: true), "Deleted list isn't a target")
    }

    func testCancelledDragAndHoverNeverPrepareThenValidDropOnlyChangesTargetAfterReady() async throws {
        let old = wallpaper("old"), candidate = wallpaper("new")
        var renderers: [Renderer] = []
        let runtime = WallpaperRuntimeManager { wallpaper in
            let renderer = Renderer(wallpaper, waits: wallpaper.id == candidate.id)
            renderers.append(renderer); return renderer
        }
        defer { runtime.shutdown() }
        runtime.addDisplay(a, host: Host()); runtime.addDisplay(b, host: Host())
        runtime.apply(old, to: a); runtime.apply(old, to: b); await settle()
        var drag = LocalWallpaperDragPresentation(); drag.begin(candidate.id)
        drag.move(insideB, from: candidate.id, displayFrames: frames, displayIDs: runtime.displayIDs, listFrames: [:], listIDs: [])
        XCTAssertEqual(renderers.count, 2, "Hold/hover must not prepare a renderer or apply")
        drag.cancel()
        XCTAssertNil(drag.takeDrop(from: candidate.id, at: insideB, displayFrames: frames, displayIDs: runtime.displayIDs,
                                  listFrames: [:], listIDs: [], isInLibrary: true, isPlayable: true))
        XCTAssertEqual(renderers.count, 2)
        drag.begin(candidate.id)
        let destination = drag.takeDrop(from: candidate.id, at: insideB, displayFrames: frames, displayIDs: runtime.displayIDs,
                                       listFrames: [:], listIDs: [], isInLibrary: true, isPlayable: true)
        guard case .display(let id, let target) = destination else { return XCTFail("Missing explicit target") }
        XCTAssertEqual(id, candidate.id); XCTAssertEqual(target, b)
        runtime.apply(candidate, to: target); await settle()
        XCTAssertEqual(runtime.activeWallpaper(on: a)?.id, old.id)
        XCTAssertEqual(runtime.activeWallpaper(on: b)?.id, old.id, "Old wallpaper survives preparation")
        let renderer = try XCTUnwrap(renderers.last)
        renderer.finishPreparation(); await settle()
        XCTAssertEqual(runtime.activeWallpaper(on: a)?.id, old.id)
        XCTAssertEqual(runtime.activeWallpaper(on: b)?.id, candidate.id)
        XCTAssertEqual(renderers.count, 3)
    }

    func testFailedPreparationAfterDropKeepsPreviousWallpaper() async {
        let old = wallpaper("old"), broken = wallpaper("broken")
        let runtime = WallpaperRuntimeManager { Renderer($0, fails: $0.id == broken.id) }
        defer { runtime.shutdown() }
        runtime.addDisplay(a, host: Host()); runtime.apply(old, to: a); await settle()
        var drag = LocalWallpaperDragPresentation(); drag.begin(broken.id)
        if case .display(_, let target) = drag.takeDrop(from: broken.id, at: insideA, displayFrames: frames,
                                                        displayIDs: runtime.displayIDs, listFrames: [:], listIDs: [],
                                                        isInLibrary: true, isPlayable: true) {
            runtime.apply(broken, to: target)
        }
        await settle()
        XCTAssertEqual(runtime.activeWallpaper(on: a)?.id, old.id)
    }

    func testSplitViewSourceAndTargetUseTheSameActualWindowCoordinates() async throws {
        final class Readings {
            var source = CGRect.zero
            var targets: [DisplayID: CGRect] = [:]
        }
        struct SourceFrame: PreferenceKey {
            static var defaultValue = CGRect.zero
            static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
                let next = nextValue()
                if !next.isEmpty { value = next }
            }
        }
        let readings = Readings(), model = wallpaper("Source")
        let sourceCoordinates = WindowDragCoordinates()
        let targets = [a, b].enumerated().map {
            DisplayTargetItem(display: .init(displayID: $1, displayName: "Display \($0)", runtime: .init(),
                                             frame: .init(x: 0, y: 0, width: 1600, height: 1000)),
                              index: $0, wallpaper: nil)
        }
        let window = NSWindow(contentRect: .init(x: 60, y: 80, width: 1000, height: 620),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = NavigationSplitView {
            Text("Sidebar").navigationSplitViewColumnWidth(min: 185, ideal: 225, max: 275)
        } detail: {
            WallpaperCard(wallpaper: model, isSelected: false, isActive: false,
                          onSelect: {}, onApply: {}, onContextMenu: { _ in NSMenu() })
                .frame(width: 180)
                .background { WindowDragCoordinateProbe(reference: sourceCoordinates) }
                .background {
                    GeometryReader { proxy in Color.clear.preference(key: SourceFrame.self, value: proxy.frame(in: .global)) }
                }
                .frame(minWidth: 675, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.leading, 30).padding(.top, 160)
                .onPreferenceChange(SourceFrame.self) { readings.source = $0 }
        }
        .navigationSplitViewStyle(.balanced)
        .overlay {
            LocalWallpaperDragOverlay(wallpaper: model, location: .init(x: 400, y: 300),
                                      items: targets, hoveredID: b)
        }
        .onPreferenceChange(DisplayTargetFrameKey.self) { readings.targets = $0 }
        let host = NSHostingView(rootView: view)
        window.contentView = host; window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 150_000_000)
        let probe = try XCTUnwrap(sourceCoordinates.view)
        let actual = host.convert(probe.bounds, from: probe)
        let converted = try XCTUnwrap(sourceCoordinates.windowPoint(forLocalPoint: .zero))
        XCTAssertEqual(converted.x, actual.minX, accuracy: 0.001)
        XCTAssertNotEqual(readings.source.minX, actual.minX, "Native split columns have a separate SwiftUI global origin")
        let actualTop = host.isFlipped ? actual.minY : host.bounds.maxY - actual.maxY
        XCTAssertEqual(converted.y, actualTop, accuracy: 0.001)
        let mapped = try XCTUnwrap(sourceCoordinates.windowFrames([model.id: readings.source], globalOrigin: readings.source.origin)[model.id])
        XCTAssertEqual(mapped.width, actual.width, accuracy: 0.001)
        XCTAssertEqual(mapped.minY, actualTop, accuracy: 0.001)
        let left = try XCTUnwrap(readings.targets[a]), right = try XCTUnwrap(readings.targets[b])
        XCTAssertEqual((left.minX + right.maxX) / 2, host.bounds.midX, accuracy: 0.001)
        XCTAssertEqual(left.minY, MainWindowDesignTokens.DisplayTarget.topInset + MainWindowDesignTokens.DisplayTarget.inset,
                       accuracy: 0.001)
        let targetPoint = CGPoint(x: right.midX, y: right.midY)
        let cardLocal = try XCTUnwrap(sourceCoordinates.localPoint(forWindowPoint: targetPoint))
        let delivered = try XCTUnwrap(sourceCoordinates.windowPoint(forLocalPoint: cardLocal))
        XCTAssertEqual(delivered.x, targetPoint.x, accuracy: 0.001)
        XCTAssertEqual(delivered.y, targetPoint.y, accuracy: 0.001)
        XCTAssertEqual(DisplayTargetHitTesting.target(at: delivered, frames: readings.targets, availableIDs: [a, b]), b)
    }

    private func wallpaper(_ name: String) -> Wallpaper {
        Wallpaper(name: name, type: .video, source: .local, resourceURL: URL(fileURLWithPath: "/drag-tests/video.mp4"))
    }
    private func settle() async { for _ in 0..<40 { await Task.yield() } }
    private final class Host: DesktopContentHost {
        func present(_ view: NSView) -> Bool { true }
        func stop() {}
    }
    private final class Renderer: WallpaperRenderer {
        let wallpaper: Wallpaper
        let displayView = NSView()
        var onFailure: (@MainActor (Error) -> Void)?
        private let waits: Bool, fails: Bool
        private var continuation: CheckedContinuation<Void, Error>?
        init(_ wallpaper: Wallpaper, waits: Bool = false, fails: Bool = false) {
            self.wallpaper = wallpaper; self.waits = waits; self.fails = fails
        }
        func prepare() async throws {
            if fails { throw NSError(domain: "DragTest", code: 1) }
            if waits { try await withCheckedThrowingContinuation { continuation = $0 } }
        }
        func finishPreparation() { continuation?.resume(); continuation = nil }
        func play() {}
        func pause() {}
        func resume() {}
        func setMuted(_ muted: Bool) {}
        func dispose() { continuation?.resume(throwing: CancellationError()); continuation = nil }
    }
}
