import AppKit
import SwiftUI
import XCTest
@testable import Kinetic

@MainActor
private final class ClockTestSurface: OverlaySurface {
    var views: [UUID: NSView] = [:]
    func present(_ view: NSView, for id: UUID, display: DesktopDisplay) throws { views[id] = view }
    func remove(_ id: UUID) { views[id] = nil }
    func realign(_ display: DesktopDisplay) {}
    func setOrder(_ ids: [UUID]) {}
    func close() { views.removeAll() }
}

/// Module 42: Nixie Clock overlay — settings, time digits, placement, update cadence and the editor.
@MainActor
final class NixieClockTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() { roots.forEach { try? FileManager.default.removeItem(at: $0) }; super.tearDown() }
    private var utc: Calendar { var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!; return calendar }
    private func time(_ hour: Int, _ minute: Int, _ second: Int = 0, nanosecond: Int = 0) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: hour, minute: minute, second: second, nanosecond: nanosecond))!
    }
    private func context(paused: Bool = false, animated: Bool = true) -> OverlayContext {
        .init(frame: .init(x: 0, y: 0, width: 1512, height: 982), backingScaleFactor: 2, maximumFramesPerSecond: 30,
              allowsAnimation: animated, isPaused: paused)
    }
    private func configuration(_ options: NixieClockOptions = .init(), display: String = "display-A") throws -> OverlayConfiguration {
        var value = OverlayConfiguration(kind: .clock, displayID: .init(display)); value.isEnabled = true
        return try options.applying(to: value)
    }

    func testSettingsRoundTripAndRejectInvalidValues() throws {
        var options = NixieClockOptions()
        XCTAssertEqual(try NixieClockOptions(configuration: configuration()), options)
        options.uses24Hour = false; options.leadingZero = false; options.blinksSeparator = false
        options.transparentBackground = false; options.opacity = 0.4; options.scale = 2.5; options.position = .init(x: 0.2, y: 0.9)
        XCTAssertEqual(try NixieClockOptions(configuration: configuration(options)), options)
        var base = OverlayConfiguration(kind: .clock, displayID: .init("display-A"))
        XCTAssertEqual(try NixieClockOptions(configuration: base), NixieClockOptions(), "Missing keys use defaults")
        for bad: [String: OverlayParameter] in [["opacity": .number(0.1)], ["opacity": .number(.nan)], ["scale": .number(3.5)],
                                               ["x": .number(1.2)], ["y": .number(-0.1)], ["uses24Hour": .number(1)],
                                               ["opacity": .boolean(true)], ["unknown": .boolean(true)]] {
            base.parameters = bad
            XCTAssertThrowsError(try NixieClockOptions(configuration: base), "\(bad)")
        }
        XCTAssertThrowsError(try options.applying(to: OverlayConfiguration(kind: .particles, displayID: .init("display-A"))))
        options.scale = 9; XCTAssertThrowsError(try options.applying(to: configuration()))
    }

    func testDigitsFollowHourFormatAndLeadingZero() {
        func digits(_ date: Date, _ uses24Hour: Bool, _ leadingZero: Bool) -> [Int?] {
            NixieClockOptions.digits(at: date, calendar: utc, uses24Hour: uses24Hour, leadingZero: leadingZero)
        }
        XCTAssertEqual(digits(time(9, 5), true, true), [0, 9, 0, 5])
        XCTAssertEqual(digits(time(9, 5), true, false), [nil, 9, 0, 5])
        XCTAssertEqual(digits(time(23, 59), true, false), [2, 3, 5, 9])
        XCTAssertEqual(digits(time(0, 30), true, true), [0, 0, 3, 0])
        XCTAssertEqual(digits(time(0, 30), false, true), [1, 2, 3, 0], "Midnight reads 12 on a 12-hour clock")
        XCTAssertEqual(digits(time(12, 0), false, false), [1, 2, 0, 0])
        XCTAssertEqual(digits(time(13, 7), false, true), [0, 1, 0, 7])
        XCTAssertEqual(digits(time(13, 7), false, false), [nil, 1, 0, 7])
        XCTAssertTrue(NixieClockOptions.separatorLit(at: time(1, 1, 2), calendar: utc, blinking: true))
        XCTAssertFalse(NixieClockOptions.separatorLit(at: time(1, 1, 3), calendar: utc, blinking: true))
        XCTAssertTrue(NixieClockOptions.separatorLit(at: time(1, 1, 3), calendar: utc, blinking: false))
        XCTAssertEqual(NixieClockFace.spoken([nil, 9, 0, 5]), "9:05")
    }

    func testPlacementStaysInsideAnyDisplayAndDragsClampToTheEdges() {
        var options = NixieClockOptions()
        for width in stride(from: 120.0, through: 6_000, by: 470) {
            for height in stride(from: 90.0, through: 3_400, by: 330) {
                for scale in [0.5, 1, 2.2, 3] {
                    for x in [0.0, 0.5, 1] {
                        options.scale = scale; options.position = .init(x: x, y: 1 - x)
                        let canvas = CGSize(width: width, height: height)
                        let frame = try! XCTUnwrap(options.frame(in: canvas))
                        XCTAssertGreaterThanOrEqual(frame.minX, 0); XCTAssertGreaterThanOrEqual(frame.minY, 0)
                        XCTAssertLessThanOrEqual(frame.maxX, width + 0.001); XCTAssertLessThanOrEqual(frame.maxY, height + 0.001)
                        XCTAssertEqual(frame.width / frame.height, 2.5, accuracy: 0.0001, "The tubes never distort")
                    }
                }
            }
        }
        options = .init(); let canvas = CGSize(width: 1512, height: 982)
        XCTAssertEqual(options.frame(in: canvas)?.size, NixieClockOptions.baseSize)
        let far = options.moved(by: .init(width: 10_000, height: 10_000), in: canvas)
        XCTAssertEqual(far.position.x, 1); XCTAssertEqual(far.position.y, 1)
        let back = far.moved(by: .init(width: -10_000, height: -10_000), in: canvas)
        XCTAssertEqual(back.position.x, 0); XCTAssertEqual(back.position.y, 0)
        XCTAssertEqual(options.moved(by: CGSize(width: CGFloat.nan, height: 3), in: canvas), options)
        XCTAssertNil(options.frame(in: .zero))
    }

    func testUpdatesOnlyOnSecondOrMinuteBoundariesAndNeverWhilePausedOrDisposed() async throws {
        var clock = time(9, 5, 2, nanosecond: 250_000_000)
        let overlay = NixieClockOverlay(now: { clock }, calendar: utc)
        try await overlay.prepare(configuration: configuration(), context: context())
        XCTAssertEqual(overlay.state.digits, [0, 9, 0, 5]); XCTAssertTrue(overlay.state.separatorLit)
        XCTAssertNil(overlay.timer, "Prepared but not shown yet")
        overlay.play()
        XCTAssertNotNil(overlay.timer); XCTAssertEqual(overlay.nextInterval(from: clock), 0.76, accuracy: 0.001)
        clock = time(9, 5, 3)
        overlay.refresh(); XCTAssertFalse(overlay.state.separatorLit, "Blinks on odd seconds")
        // Reduce Motion or blinking off: steady separator, one update per minute.
        try overlay.update(configuration: configuration(), context: context(animated: false))
        XCTAssertTrue(overlay.state.separatorLit); XCTAssertEqual(overlay.nextInterval(from: clock), 57.01, accuracy: 0.001)
        var steady = NixieClockOptions(); steady.blinksSeparator = false
        try overlay.update(configuration: configuration(steady), context: context())
        XCTAssertEqual(overlay.nextInterval(from: clock), 57.01, accuracy: 0.001); XCTAssertNotNil(overlay.timer)
        // A system pause keeps the reading and stops all updates.
        try overlay.update(configuration: configuration(steady), context: context(paused: true))
        XCTAssertNil(overlay.timer); XCTAssertFalse(overlay.isPlaying)
        clock = time(10, 0)
        XCTAssertEqual(overlay.state.digits, [0, 9, 0, 5])
        overlay.play(); XCTAssertNil(overlay.timer, "Play cannot override a paused context")
        try overlay.update(configuration: configuration(steady), context: context()); overlay.play()
        XCTAssertEqual(overlay.state.digits, [1, 0, 0, 0]); XCTAssertNotNil(overlay.timer)
        // An invalid edit keeps the live settings.
        var invalid = try configuration(); invalid.parameters["opacity"] = .number(5)
        XCTAssertThrowsError(try overlay.update(configuration: invalid, context: context()))
        XCTAssertFalse(overlay.state.options.blinksSeparator)
        overlay.pause(); XCTAssertNil(overlay.timer)
        overlay.play(); overlay.dispose(); overlay.dispose()
        XCTAssertNil(overlay.timer); XCTAssertTrue(overlay.isDisposed); overlay.play(); XCTAssertNil(overlay.timer)
        XCTAssertThrowsError(try overlay.update(configuration: configuration(), context: context()))
    }

    func testRealTimerTicksAtTheNextBoundaryAndReleases() async throws {
        weak var released: NixieClockOverlay?
        do {
            let overlay = NixieClockOverlay()
            released = overlay
            try await overlay.prepare(configuration: configuration(), context: context()); overlay.play()
            let deadline = ProcessInfo.processInfo.systemUptime + 2.5
            while overlay.tickCount == 0 && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
            XCTAssertGreaterThan(overlay.tickCount, 0); XCTAssertNotNil(overlay.timer)
            overlay.dispose()
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(released)
    }

    func testEditorDraftsOnlySaveWritesTheChosenDisplayAndDisableRemovesIt() async throws {
        let root = TestWorkspaceDirectory.make(".build/Module42/Fixtures")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); roots.append(root)
        let store = OverlayStore(storage: .init(rootURL: root))
        func display(_ name: String) -> DisplayDescriptor {
            .init(id: .init(name), name: name, desktop: .init(id: 1, frame: .init(x: -5000, y: -5000, width: 1512, height: 982),
                                                              backingScaleFactor: 2), isPersistent: true)
        }
        let a = display("display-A"), b = display("display-B")
        let registry = DisplayRegistry(discover: { [a, b] }); registry.start()
        let surfaces = [a.id: ClockTestSurface(), b.id: ClockTestSurface()]
        let manager = OverlayManager(store: store, registry: registry, readReduceMotion: { false }, makeSurface: { surfaces[$0]! })
        var overlays: [NixieClockOverlay] = []
        manager.register(.clock) { _ in let overlay = NixieClockOverlay(); overlays.append(overlay); return overlay }; manager.start()
        defer { manager.shutdown(); registry.stop() }
        let editor = NixieClockEditorModel(manager: manager, registry: registry); editor.opened()
        XCTAssertEqual(editor.displaySize, CGSize(width: 1512, height: 982))
        editor.selectDisplay(b.id); editor.isEnabled = true
        editor.options.uses24Hour = false; editor.move(by: .init(width: 10_000, height: 10_000))
        XCTAssertEqual(editor.options.position.x, 1); XCTAssertTrue(store.configurations.isEmpty, "Drafts never write storage")
        editor.save(); XCTAssertNil(editor.error)
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while manager.states.first?.lifecycle != .running && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(manager.states.first?.lifecycle, .running)
        XCTAssertEqual(surfaces[a.id]?.views.count, 0); XCTAssertEqual(surfaces[b.id]?.views.count, 1)
        let saved = try NixieClockOptions(configuration: OverlayStore(storage: .init(rootURL: root)).configurations[0])
        XCTAssertFalse(saved.uses24Hour); XCTAssertEqual(saved.position.x, 1)
        XCTAssertEqual(overlays.count, 1); XCTAssertFalse(overlays[0].state.options.uses24Hour)
        editor.options.opacity = 0.5; editor.save(); XCTAssertEqual(overlays.count, 1, "Edits update the running clock in place")
        XCTAssertEqual(overlays[0].state.options.opacity, 0.5)
        editor.isEnabled = false; editor.save()
        XCTAssertTrue(overlays[0].isDisposed); XCTAssertNil(overlays[0].timer); XCTAssertEqual(surfaces[b.id]?.views.count, 0)
        // The display page (formerly the window preview) shows each display's draft or saved clock; a drag there
        // edits that display's draft and targets the window to it.
        XCTAssertFalse(editor.draft(on: b.id).isEnabled); XCTAssertFalse(editor.isDirty(on: b.id))
        editor.isEnabled = true; XCTAssertTrue(editor.isDirty(on: b.id)); XCTAssertTrue(editor.canApply(on: b.id))
        XCTAssertFalse(editor.draft(on: a.id).isEnabled); XCTAssertFalse(editor.canApply(on: a.id))
        let start = editor.options
        editor.move(from: start, by: .init(width: -10_000, height: 0), on: a.id)
        XCTAssertEqual(editor.selectedDisplayID, a.id); XCTAssertEqual(editor.options.position.x, 0)
        XCTAssertFalse(editor.draft(on: b.id).isEnabled, "B shows its saved, disabled clock again")
        editor.isEnabled = true; editor.apply(on: a.id); XCTAssertNil(editor.error); XCTAssertFalse(editor.isDirty(on: a.id))
        XCTAssertTrue(editor.saved(on: a.id).isEnabled); XCTAssertEqual(editor.saved(on: a.id).options.position.x, 0)
        editor.closed(); XCTAssertEqual(editor.selectedDisplayID, a.id, "Closing the window keeps its target and draft")
    }

    func testFaceAndEditorRenderInBothAppearances() throws {
        let output = TestWorkspaceDirectory.make(".build/Module42/Snapshots")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, transparent) in [("transparent", true), ("plate", false)] {
            var options = NixieClockOptions(); options.transparentBackground = transparent
            let host = NSHostingView(rootView: NixieClockFace(options: options, digits: [nil, 9, 4, 7], separatorLit: true)
                .frame(width: 600, height: 240).background(Color(red: 0.05, green: 0.06, blue: 0.1)))
            host.frame = .init(x: 0, y: 0, width: 600, height: 240); host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("face-\(name).png"))
        }
    }
}
