import AppKit
import SwiftUI
import XCTest
@testable import Kinetic

@MainActor private final class SetupHost: DesktopContentHost {
    var content: NSView?
    func present(_ contentView: NSView) -> Bool { content = contentView; return true }
    func stop() { content = nil }
}

@MainActor private final class SetupRenderer: WallpaperRenderer {
    let wallpaper: Wallpaper
    let configuration: StagedDisplayWallpaperConfiguration
    let displayView = NSView()
    var onFailure: (@MainActor (Error) -> Void)?
    init(_ wallpaper: Wallpaper, _ configuration: StagedDisplayWallpaperConfiguration) {
        self.wallpaper = wallpaper; self.configuration = configuration
    }
    func prepare() async throws {}
    func play() {}; func pause() {}; func resume() {}
    func setMuted(_ muted: Bool) {}; func dispose() {}
}

@MainActor
final class SetupStoreTests: XCTestCase {
    private var root: URL!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SetupStore-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    func testBookmarksAndSchemesPersistAndRejectEmptyNames() throws {
        let store = SetupStore(storage: .init(rootURL: root))
        var configuration = StagedDisplayWallpaperConfiguration(wallpaperID: UUID())
        configuration.video.speed = 1.5
        let bookmark = try store.addBookmark(name: "  慢速海浪 ", configuration: configuration)
        XCTAssertThrowsError(try store.addBookmark(name: "  ", configuration: configuration))
        XCTAssertThrowsError(try store.addBookmark(name: "空", configuration: .init()))
        try store.renameBookmark(bookmark, to: "海浪")
        let scheme = try store.addScheme(WallpaperScheme(name: "工作日", displays: ["display-A": SchemeDisplay(isStopped: true)]))
        XCTAssertThrowsError(try store.addScheme(WallpaperScheme(name: " ")))
        let reopened = SetupStore(storage: .init(rootURL: root))
        XCTAssertEqual(reopened.bookmarks.map(\.name), ["海浪"])
        XCTAssertEqual(reopened.bookmark(id: bookmark)?.configuration, configuration)
        XCTAssertEqual(reopened.scheme(id: scheme)?.displays["display-A"]?.isStopped, true)
        try reopened.deleteBookmark(bookmark); try reopened.deleteScheme(scheme)
        let emptied = SetupStore(storage: .init(rootURL: root))
        XCTAssertTrue(emptied.bookmarks.isEmpty); XCTAssertTrue(emptied.schemes.isEmpty)
    }

    func testUnreadableFilesAreSetAsideNotOverwritten() throws {
        try Data("[".utf8).write(to: root.appendingPathComponent("bookmarks.json"))
        try Data("{\"version\": 9}".utf8).write(to: root.appendingPathComponent("schemes.json"))
        let store = SetupStore(storage: .init(rootURL: root))
        XCTAssertTrue(store.bookmarks.isEmpty); XCTAssertTrue(store.schemes.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("bookmarks.unreadable-") })
    }
}

@MainActor
final class WallpaperSchemeTests: XCTestCase {
    private var root: URL!
    private var library: WallpaperLibrary!
    private var lists: LocalOrganizationStore!
    private var runtime: WallpaperRuntimeManager!
    private var editor: DisplayWallpaperEditor!
    private var player: WallpaperPlaylistPlayer!
    private var scheduler: WallpaperScheduler!
    private var setup: SetupStore!
    private var overlays: OverlayStore!
    private var layouts: WidgetLayoutRepository!
    private var coordinator: WallpaperSchemeCoordinator!
    private var suite = ""
    private var clock: Date = {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 7))!
    }()
    private let a = DisplayID("display-A"), b = DisplayID("display-B")

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Schemes-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = LibraryStorageLocation(rootURL: root)
        library = WallpaperLibrary(storage: storage)
        lists = LocalOrganizationStore(storage: storage)
        setup = SetupStore(storage: storage)
        overlays = OverlayStore(storage: storage)
        layouts = WidgetLayoutRepository(storage: storage)
        runtime = WallpaperRuntimeManager()
        suite = "Kinetic.Schemes.Tests." + UUID().uuidString
        editor = DisplayWallpaperEditor(storage: storage, library: library, runtime: runtime,
            sceneStore: ScenePropertyStore(storage: storage), videoStore: VideoPlaybackStore(storage: storage),
            webStore: WebPlaybackStore(storage: storage), settings: SettingsStore(defaults: UserDefaults(suiteName: suite)!)) {
                SetupRenderer($0, $1)
            }
        runtime.displayRendererFactory = { [unowned self] wallpaper, display in try self.editor.makeRenderer(wallpaper, on: display) }
        runtime.addDisplay(a, host: SetupHost()); runtime.addDisplay(b, host: SetupHost())
        player = WallpaperPlaylistPlayer(storage: storage, runtime: runtime, library: library, lists: lists, now: { 0 }, schedulesTimer: false)
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        scheduler = WallpaperScheduler(storage: storage, runtime: runtime, library: library, playlist: player,
                                       bookmarks: setup, editor: editor,
                                       now: { [unowned self] in self.clock }, calendar: { utc }, schedulesTimer: false)
        coordinator = WallpaperSchemeCoordinator(store: setup, runtime: runtime, library: library, editor: editor,
                                                 playlist: player, scheduler: scheduler, overlays: overlays, layouts: layouts)
    }

    override func tearDown() async throws {
        scheduler?.shutdown(); player?.shutdown(); runtime?.shutdown(); runtime?.displayRendererFactory = nil
        coordinator = nil; scheduler = nil; player = nil; editor = nil; runtime = nil
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
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
        try await Task.sleep(nanoseconds: 30_000_000)
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while runtime.summary.displays.contains(where: { $0.runtime.preparingWallpaperID != nil }) || !editor.applying.isEmpty {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw DisplayEditingError.timedOut }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func configuration(_ wallpaper: Wallpaper, speed: Double) -> StagedDisplayWallpaperConfiguration {
        var value = editor.configuration(for: wallpaper, on: a)
        value.video.speed = speed
        return value
    }

    func testABookmarkStagesItsWallpaperAndParametersAndAppliesThroughTheEditor() async throws {
        let items = try wallpapers(2)
        let bookmark = try setup.addBookmark(name: "慢速", configuration: configuration(items[1], speed: 0.5))
        let saved = try XCTUnwrap(setup.bookmark(id: bookmark))
        XCTAssertTrue(editor.stage(saved.configuration, on: a))
        XCTAssertEqual(editor.draft(on: a).video.speed, 0.5)
        XCTAssertNil(runtime.activeWallpaper(on: a), "staging only changes the draft")
        await editor.apply(saved.configuration, on: a); try await settle()
        XCTAssertEqual(runtime.activeWallpaper(on: a)?.id, items[1].id)
        XCTAssertEqual(editor.configuration(for: items[1], on: a).video.speed, 0.5, "saved for this display")
        XCTAssertEqual(editor.configuration(for: items[1], on: b).video.speed, 1, "other displays keep their own")
        try FileManager.default.removeItem(at: items[0].resourceURL); try library.remove(id: items[0].id)
        XCTAssertFalse(editor.stage(StagedDisplayWallpaperConfiguration(wallpaperID: items[0].id), on: b))
    }

    func testAScheduledBookmarkShowsItsWallpaperWithItsParameters() async throws {
        let items = try wallpapers(1)
        let bookmark = try setup.addBookmark(name: "早晨", configuration: configuration(items[0], speed: 2))
        scheduler.edit(on: a) { $0.isEnabled = true; $0.slots = [ScheduleSlot(period: .morning, content: .bookmark(bookmark))] }
        scheduler.applyDraft(on: a); try await settle()
        XCTAssertEqual(runtime.activeWallpaper(on: a)?.id, items[0].id)
        XCTAssertEqual(editor.configuration(for: items[0], on: a).video.speed, 2)
    }

    func testASchemeRestoresEachConnectedDisplaysWholeSetup() async throws {
        let items = try wallpapers(4)
        let list = try lists.createList(name: "轮播", wallpaperIDs: [items[2].id, items[3].id])
        await editor.apply(configuration(items[0], speed: 1.75), on: a); try await settle()
        player.start(DisplayPlaylistConfiguration(listID: list, intervalMinutes: 12, shuffle: false), on: b); try await settle()
        runtime.pause(.display(b))
        runtime.setAudioEnabled(true, on: a)
        scheduler.edit(on: a) { $0.isEnabled = true; $0.slots = [ScheduleSlot(period: .morning, content: .wallpaper(items[1].id))] }
        scheduler.applyDraft(on: a); try await settle()
        // The morning slot just took over; show the scheme's own wallpaper again before saving.
        await editor.apply(configuration(items[0], speed: 1.75), on: a); try await settle()
        let layout = WidgetBoardLayout(widgets: [WidgetConfiguration(kind: .cpu, position: .init(x: 0.5, y: 0.25))])
        let layoutID = try layouts.write(layout, keeping: [])
        try overlays.upsert(OverlayConfiguration(kind: .clock, displayID: a, isEnabled: true, parameters: ["scale": .number(1.5)]))
        try overlays.upsert(OverlayConfiguration(kind: .widgets, displayID: a, isEnabled: true,
            parameters: ["widgetLayout": .text(layoutID.uuidString), "widgetVersion": .number(1)]))
        let schemeID = try coordinator.saveCurrent(name: "工作日")
        let scheme = try XCTUnwrap(setup.scheme(id: schemeID))
        XCTAssertEqual(Set(scheme.displays.keys), [a.rawValue, b.rawValue])

        // Change everything.
        await editor.apply(configuration(items[1], speed: 1), on: a); try await settle()
        player.stop(on: b); runtime.resume(.display(b))
        runtime.apply(items[0], to: b); try await settle()
        runtime.setAudioEnabled(false, on: a)
        scheduler.setSchedule(nil, on: a)
        try overlays.replaceConfigurations(on: a, with: [])
        layouts.prune(keeping: [])
        XCTAssertThrowsError(try layouts.load(layoutID), "the old layout file is gone")

        XCTAssertEqual(coordinator.reach(of: scheme).connected, 2)
        let failures = await coordinator.apply(scheme); try await settle()
        XCTAssertEqual(failures, [])
        XCTAssertEqual(runtime.activeWallpaper(on: a)?.id, items[0].id)
        XCTAssertEqual(editor.configuration(for: items[0], on: a).video.speed, 1.75)
        XCTAssertTrue(runtime.isAudioEnabled(on: a))
        XCTAssertEqual(scheduler.schedule(on: a).slots.map(\.content), [.wallpaper(items[1].id)])
        scheduler.reconcileAll(); try await settle()
        XCTAssertEqual(runtime.activeWallpaper(on: a)?.id, items[0].id, "the restored schedule does not override the scheme now")
        XCTAssertEqual(player.entries[b]?.configuration, DisplayPlaylistConfiguration(listID: list, intervalMinutes: 12, shuffle: false))
        XCTAssertEqual(runtime.activeWallpaper(on: b)?.id, items[2].id)
        XCTAssertTrue(runtime.manualPauseRequested(on: b))
        let restored = overlays.configurations.filter { $0.displayID == a }
        XCTAssertEqual(Set(restored.map(\.kind)), [.clock, .widgets])
        XCTAssertEqual(restored.first { $0.kind == .clock }?.parameters["scale"], .number(1.5))
        guard case .text(let newLayout)? = restored.first(where: { $0.kind == .widgets })?.parameters["widgetLayout"],
              let newID = UUID(uuidString: newLayout) else { return XCTFail("widget board without layout") }
        XCTAssertEqual(try layouts.load(newID), layout)
    }

    func testDisconnectedDisplaysAreSkippedAndCounted() async throws {
        let items = try wallpapers(1)
        let scheme = WallpaperScheme(name: "外接", displays: [
            a.rawValue: SchemeDisplay(configuration: StagedDisplayWallpaperConfiguration(wallpaperID: items[0].id)),
            "display-gone": SchemeDisplay(configuration: StagedDisplayWallpaperConfiguration(wallpaperID: items[0].id))])
        XCTAssertEqual(coordinator.reach(of: scheme).connected, 1)
        XCTAssertEqual(coordinator.reach(of: scheme).skipped, 1)
        _ = await coordinator.apply(scheme); try await settle()
        XCTAssertEqual(runtime.activeWallpaper(on: a)?.id, items[0].id)
        XCTAssertNil(runtime.activeWallpaper(on: b))
    }

    /// Offscreen PNGs of the bookmark rows at the top of the display page's wallpaper selector, light and dark.
    func testBookmarkListSnapshots() throws {
        let items = try wallpapers(2)
        try setup.addBookmark(name: "慢速海浪", configuration: configuration(items[0], speed: 0.5))
        let staged = try setup.addBookmark(name: "很长很长的书签名称用来检查截断效果是否正常", configuration: configuration(items[1], speed: 2))
        try setup.addBookmark(name: "旧书签", configuration: StagedDisplayWallpaperConfiguration(wallpaperID: UUID()))
        editor.stage(try XCTUnwrap(setup.bookmark(id: staged)).configuration, on: a)
        let list = DisplayBookmarkList(displayID: a, store: setup, library: library, editor: editor) {}
            .frame(width: 290).padding(8)
        try R4SnapshotTests.render(list, size: CGSize(width: 306, height: 220), name: "module48-bookmarks")
        try R4SnapshotTests.render(list, size: CGSize(width: 306, height: 220), name: "module48-bookmarks-dark", appearance: .darkAqua)
    }

    func testAMissingWallpaperIsReportedAndTheDisplayKeepsItsOwn() async throws {
        let items = try wallpapers(2)
        runtime.apply(items[0], to: a); try await settle()
        let scheme = WallpaperScheme(name: "旧", displays: [a.rawValue: SchemeDisplay(configuration: StagedDisplayWallpaperConfiguration(wallpaperID: UUID()))])
        let failures = await coordinator.apply(scheme); try await settle()
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(runtime.activeWallpaper(on: a)?.id, items[0].id)
    }
}
