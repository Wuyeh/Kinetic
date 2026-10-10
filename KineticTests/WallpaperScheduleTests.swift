import AppKit
import SwiftUI
import XCTest
@testable import Kinetic

@MainActor private final class ScheduleHost: DesktopContentHost {
    var content: NSView?
    func present(_ contentView: NSView) -> Bool { content = contentView; return true }
    func stop() { content = nil }
}

@MainActor private final class ScheduleRenderer: WallpaperRenderer {
    let wallpaper: Wallpaper
    let displayView = NSView()
    var onFailure: (@MainActor (Error) -> Void)?
    init(_ wallpaper: Wallpaper) { self.wallpaper = wallpaper }
    func prepare() async throws {}
    func play() {}; func pause() {}; func resume() {}
    func setMuted(_ muted: Bool) {}; func dispose() {}
}

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    utc.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
}

final class ScheduleSlotTests: XCTestCase {
    func testNamedPeriodsAndCustomRangesCoverTheRightTimes() {
        XCTAssertEqual(ScheduleSlot(period: .morning).start, 360)
        XCTAssertEqual(ScheduleSlot(period: .night).end, 360)
        let afternoon = ScheduleSlot(period: .afternoon)
        XCTAssertEqual(afternoon.occurrenceStart(covering: at(9, 15, 30), calendar: utc), at(9, 14))
        XCTAssertNil(afternoon.occurrenceStart(covering: at(9, 18), calendar: utc), "the end is exclusive")
        let night = ScheduleSlot(period: .night)
        XCTAssertEqual(night.occurrenceStart(covering: at(9, 23), calendar: utc), at(9, 22))
        XCTAssertEqual(night.occurrenceStart(covering: at(10, 5, 59), calendar: utc), at(9, 22), "after midnight it is still last night")
        XCTAssertNil(night.occurrenceStart(covering: at(10, 6), calendar: utc))
        XCTAssertEqual(night.nextStart(after: at(10, 5), calendar: utc), at(10, 22))
        XCTAssertEqual(afternoon.nextStart(after: at(9, 15), calendar: utc), at(10, 14))
        let toMidnight = ScheduleSlot(period: .custom, start: 20 * 60, end: 0)
        XCTAssertEqual(toMidnight.occurrenceStart(covering: at(9, 23, 59), calendar: utc), at(9, 20))
        XCTAssertNil(toMidnight.occurrenceStart(covering: at(10, 0), calendar: utc))
    }

    func testOverlapsEmptyRangesAndMissingContentBlockApplying() {
        let morning = ScheduleSlot(period: .morning, content: .wallpaper(UUID()))
        let midday = ScheduleSlot(period: .midday, content: .wallpaper(UUID()))
        let night = ScheduleSlot(period: .night, content: .wallpaper(UUID()))
        XCTAssertFalse(morning.overlaps(midday), "touching periods do not overlap")
        XCTAssertFalse(night.overlaps(morning))
        let early = ScheduleSlot(period: .custom, start: 5 * 60, end: 7 * 60, content: .wallpaper(UUID()))
        XCTAssertTrue(early.overlaps(night), "a range across midnight")
        XCTAssertTrue(early.overlaps(morning))
        var schedule = DisplaySchedule(isEnabled: true, slots: [morning, midday, night])
        XCTAssertTrue(schedule.problems.isEmpty); XCTAssertTrue(schedule.canApply)
        schedule.slots.append(early)
        XCTAssertEqual(schedule.problems[early.id], .overlaps([morning.id, night.id]))
        XCTAssertEqual(Set(schedule.conflicts[early.id] ?? []), [morning.id, night.id])
        XCTAssertFalse(schedule.canApply)
        schedule.slots.removeLast()
        schedule.slots.append(ScheduleSlot(period: .custom, start: 600, end: 600))
        schedule.slots.append(ScheduleSlot(period: .custom, start: 15 * 60, end: 16 * 60))
        let problems = schedule.problems
        XCTAssertEqual(problems[schedule.slots[3].id], .emptyRange)
        XCTAssertEqual(problems[schedule.slots[4].id], .noContent)
        schedule.isEnabled = false
        XCTAssertTrue(schedule.canApply, "a schedule that is off can be saved while unfinished")
        XCTAssertNil(schedule.activeSlot(at: at(9, 7), calendar: utc))
    }
}

@MainActor
final class WallpaperSchedulerTests: XCTestCase {
    private var root: URL!
    private var library: WallpaperLibrary!
    private var lists: LocalOrganizationStore!
    private var runtime: WallpaperRuntimeManager!
    private var player: WallpaperPlaylistPlayer!
    private var scheduler: WallpaperScheduler!
    private var clock = at(9, 7)
    private let a = DisplayID("display-A"), b = DisplayID("display-B")

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ScheduleTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        library = WallpaperLibrary(storage: .init(rootURL: root))
        lists = LocalOrganizationStore(storage: .init(rootURL: root))
        runtime = WallpaperRuntimeManager(makeRenderer: { ScheduleRenderer($0) })
        runtime.addDisplay(a, host: ScheduleHost()); runtime.addDisplay(b, host: ScheduleHost())
        player = WallpaperPlaylistPlayer(storage: .init(rootURL: root), runtime: runtime, library: library, lists: lists,
                                         now: { 0 }, schedulesTimer: false)
        scheduler = makeScheduler()
    }

    override func tearDown() async throws {
        scheduler?.shutdown(); player?.shutdown(); runtime?.shutdown()
        scheduler = nil; player = nil; runtime = nil; lists = nil; library = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func makeScheduler() -> WallpaperScheduler {
        WallpaperScheduler(storage: .init(rootURL: root), runtime: runtime, library: library, playlist: player,
                           now: { [unowned self] in self.clock }, calendar: { utc }, schedulesTimer: false)
    }

    private func wallpapers(_ count: Int) throws -> [Wallpaper] {
        try (0..<count).map { index in
            let value = Wallpaper(name: "壁纸\(index)", type: .video, source: .local,
                                  resourceURL: root.appendingPathComponent(UUID().uuidString + ".mp4"))
            try Data("video".utf8).write(to: value.resourceURL)
            try library.add(value)
            return value
        }
    }

    private func settle() async throws {
        // Let the scheduler's deferred reconcile run, then wait for any preparation.
        try await Task.sleep(nanoseconds: 20_000_000)
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while runtime.summary.displays.contains(where: { $0.runtime.preparingWallpaperID != nil }) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw DisplayEditingError.timedOut }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func shown(_ display: DisplayID) -> Wallpaper.ID? { runtime.activeWallpaper(on: display)?.id }

    func testEachSlotTakesOverOnceWhenItBeginsAndManualChoicesHoldForTheRestOfIt() async throws {
        let items = try wallpapers(4)
        let list = try lists.createList(name: "下午", wallpaperIDs: [items[2].id, items[3].id])
        scheduler.edit(on: a) {
            $0.isEnabled = true
            $0.slots = [ScheduleSlot(period: .morning, content: .wallpaper(items[0].id)),
                        ScheduleSlot(period: .afternoon, content: .list(list, intervalMinutes: 15, shuffle: false))]
        }
        XCTAssertTrue(scheduler.canApplyDraft(on: a))
        XCTAssertNil(shown(a), "nothing changes before 应用")
        scheduler.applyDraft(on: a); try await settle()
        XCTAssertEqual(shown(a), items[0].id, "the slot covering now shows at once")
        XCTAssertEqual(scheduler.activeSlot(on: a)?.period, .morning)
        XCTAssertNil(shown(b), "other displays are untouched")

        runtime.apply(items[1], to: a); try await settle()
        clock = at(9, 10); scheduler.reconcileAll(); try await settle()
        XCTAssertEqual(shown(a), items[1].id, "a manual choice holds for the rest of the slot")

        clock = at(9, 12); scheduler.reconcileAll(); try await settle()
        XCTAssertEqual(shown(a), items[1].id, "outside every slot nothing changes")

        clock = at(9, 14, 1); scheduler.reconcileAll(); try await settle()
        XCTAssertEqual(shown(a), items[2].id, "a list slot starts its rotation")
        XCTAssertEqual(player.entries[a]?.configuration, DisplayPlaylistConfiguration(listID: list, intervalMinutes: 15, shuffle: false))

        clock = at(10, 6, 30); scheduler.reconcileAll(); try await settle()
        XCTAssertEqual(shown(a), items[0].id, "next morning")
        XCTAssertNil(player.entries[a], "a wallpaper slot ends the rotation")
    }

    func testManualPauseAndStopWinUntilResumed() async throws {
        let items = try wallpapers(2)
        scheduler.edit(on: a) {
            $0.isEnabled = true
            $0.slots = [ScheduleSlot(period: .morning, content: .wallpaper(items[0].id)),
                        ScheduleSlot(period: .midday, content: .wallpaper(items[1].id))]
        }
        scheduler.applyDraft(on: a); try await settle()
        runtime.pause(.display(a))
        clock = at(9, 11, 5); scheduler.reconcileAll(); try await settle()
        XCTAssertEqual(shown(a), items[0].id, "manual pause wins over the schedule")
        runtime.resume(.display(a)); try await settle()
        scheduler.reconcileAll(); try await settle()
        XCTAssertEqual(shown(a), items[1].id, "after resuming it catches up with the current slot")

        runtime.stop(.display(a)); try await settle()
        clock = at(10, 6, 5); scheduler.reconcileAll(); try await settle()
        XCTAssertEqual(runtime.state(of: a)?.playbackState, .stopped, "a stopped display stays stopped")
    }

    func testWakeOrRelaunchCatchesUpOnlyWithASlotNotYetApplied() async throws {
        let items = try wallpapers(3)
        scheduler.edit(on: a) {
            $0.isEnabled = true
            $0.slots = [ScheduleSlot(period: .morning, content: .wallpaper(items[0].id)),
                        ScheduleSlot(period: .evening, content: .wallpaper(items[1].id))]
        }
        scheduler.applyDraft(on: a); try await settle()
        runtime.apply(items[2], to: a); try await settle()
        scheduler.shutdown()
        scheduler = makeScheduler(); scheduler.reconcileAll(); try await settle()
        XCTAssertEqual(shown(a), items[2].id, "relaunching within the same slot keeps the manual choice")
        XCTAssertEqual(scheduler.schedule(on: a).slots.count, 2)
        clock = at(9, 20); scheduler.reconcileAll(); try await settle()   // e.g. woke up in the evening
        XCTAssertEqual(shown(a), items[1].id)
    }

    func testEditingAnotherSlotKeepsTheCurrentOneButTurningOnAgainReapplies() async throws {
        let items = try wallpapers(3)
        scheduler.edit(on: a) {
            $0.isEnabled = true
            $0.slots = [ScheduleSlot(period: .morning, content: .wallpaper(items[0].id))]
        }
        scheduler.applyDraft(on: a); try await settle()
        runtime.apply(items[2], to: a); try await settle()
        scheduler.edit(on: a) { $0.slots.append(ScheduleSlot(period: .night, content: .wallpaper(items[1].id))) }
        scheduler.applyDraft(on: a); try await settle()
        XCTAssertEqual(shown(a), items[2].id, "adding the night slot leaves the morning choice alone")
        scheduler.edit(on: a) { $0.isEnabled = false }
        scheduler.applyDraft(on: a)
        scheduler.edit(on: a) { $0.isEnabled = true }
        scheduler.applyDraft(on: a); try await settle()
        XCTAssertEqual(shown(a), items[0].id)
    }

    func testConflictingOrUnfinishedDraftsCannotBeApplied() throws {
        let items = try wallpapers(1)
        scheduler.edit(on: a) {
            $0.isEnabled = true
            $0.slots = [ScheduleSlot(period: .night, content: .wallpaper(items[0].id)),
                        ScheduleSlot(period: .custom, start: 300, end: 420, content: .wallpaper(items[0].id))]
        }
        XCTAssertFalse(scheduler.canApplyDraft(on: a))
        scheduler.applyDraft(on: a)
        XCTAssertTrue(scheduler.schedule(on: a).slots.isEmpty, "nothing was saved")
        scheduler.edit(on: a) { $0.slots[1].start = 360; $0.slots[1].end = 420 }
        XCTAssertTrue(scheduler.canApplyDraft(on: a))
    }

    func testUnreadableFileIsSetAsideNotOverwritten() throws {
        scheduler.shutdown()
        try Data("{".utf8).write(to: scheduler.fileURL)
        scheduler = makeScheduler()
        XCTAssertTrue(scheduler.entries.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("schedule.unreadable-") })
    }
}

@MainActor
final class ScheduleInterfaceTests: XCTestCase {
    /// Offscreen PNGs of the display page's 定时切换 section with a list slot and an overlap, light and dark.
    func testScheduleSectionSnapshots() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ScheduleSnapshot-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = LibraryStorageLocation(rootURL: root)
        let library = WallpaperLibrary(storage: storage)
        let lists = LocalOrganizationStore(storage: storage)
        let runtime = WallpaperRuntimeManager(makeRenderer: { ScheduleRenderer($0) })
        let display = DisplayID("display-A")
        runtime.addDisplay(display, host: ScheduleHost())
        defer { runtime.shutdown() }
        let items = try ["晨光海岸", "城市夜景"].map { name -> Wallpaper in
            let value = Wallpaper(name: name, type: .video, source: .local, resourceURL: root.appendingPathComponent(UUID().uuidString + ".mp4"))
            try Data("video".utf8).write(to: value.resourceURL); try library.add(value); return value
        }
        let list = try lists.createList(name: "工作", wallpaperIDs: items.map(\.id))
        let player = WallpaperPlaylistPlayer(storage: storage, runtime: runtime, library: library, lists: lists, schedulesTimer: false)
        let scheduler = WallpaperScheduler(storage: storage, runtime: runtime, library: library, playlist: player, schedulesTimer: false)
        defer { scheduler.shutdown(); player.shutdown() }
        scheduler.edit(on: display) {
            $0.isEnabled = true
            $0.slots = [ScheduleSlot(period: .morning, content: .wallpaper(items[0].id)),
                        ScheduleSlot(period: .afternoon, content: .list(list, intervalMinutes: 20, shuffle: true)),
                        ScheduleSlot(period: .custom, start: 21 * 60, end: 23 * 60, content: .wallpaper(items[1].id)),
                        ScheduleSlot(period: .night, content: nil)]
        }
        XCTAssertFalse(scheduler.canApplyDraft(on: display))
        let section = DisplayScheduleSection(displayID: display, scheduler: scheduler, lists: lists, library: library,
                                             bookmarks: SetupStore(storage: storage)).padding(20)
        let size = CGSize(width: 360, height: 640)
        try R4SnapshotTests.render(section, size: size, name: "module47-schedule-section")
        try R4SnapshotTests.render(section, size: size, name: "module47-schedule-section-dark", appearance: .darkAqua)
        // Control: the console's existing glass button, to tell offscreen glass rendering from this section's own colours.
        try R4SnapshotTests.render(Button("恢复默认预设") {}.kineticGlassButton().padding(20), size: CGSize(width: 200, height: 70),
                                   name: "module47-control-glass-button-dark", appearance: .darkAqua)
    }
}
