import AppKit
import XCTest
@testable import Kinetic

@MainActor private final class PlaylistHost: DesktopContentHost {
    var content: NSView?
    func present(_ contentView: NSView) -> Bool { content = contentView; return true }
    func stop() { content = nil }
}

@MainActor private final class PlaylistRenderer: WallpaperRenderer {
    let wallpaper: Wallpaper
    let displayView = NSView()
    var onFailure: (@MainActor (Error) -> Void)?
    init(_ wallpaper: Wallpaper) { self.wallpaper = wallpaper }
    func prepare() async throws {}
    func play() {}; func pause() {}; func resume() {}
    func setMuted(_ muted: Bool) {}; func dispose() {}
}

/// A fixed sequence, so shuffled orders repeat between runs.
private func seededRandom(_ seed: UInt64 = 7) -> PlaylistRandom {
    var state = seed
    return PlaylistRandom {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class PlaylistCursorTests: XCTestCase {
    private let ids = (0..<5).map { _ in UUID() }

    func testSequentialStepsFollowListOrderAndWrapBothWays() {
        var random = seededRandom()
        var cursor = PlaylistCursor()
        XCTAssertEqual(cursor.start(members: ids, shuffle: false, preferred: nil, random: &random), ids[0])
        XCTAssertEqual(cursor.step(.next, members: ids, shuffle: false, random: &random), ids[1])
        XCTAssertEqual(cursor.step(.previous, members: ids, shuffle: false, random: &random), ids[0])
        XCTAssertEqual(cursor.step(.previous, members: ids, shuffle: false, random: &random), ids[4])
        XCTAssertEqual(cursor.step(.next, members: ids, shuffle: false, random: &random), ids[0])
    }

    func testStartPrefersTheWallpaperTheDisplayPageShowsWhenItIsAMember() {
        var random = seededRandom()
        var cursor = PlaylistCursor()
        XCTAssertEqual(cursor.start(members: ids, shuffle: false, preferred: ids[3], random: &random), ids[3])
        XCTAssertEqual(cursor.step(.next, members: ids, shuffle: false, random: &random), ids[4])
        var shuffled = PlaylistCursor()
        XCTAssertEqual(shuffled.start(members: ids, shuffle: true, preferred: ids[2], random: &random), ids[2])
        var outsider = PlaylistCursor()
        XCTAssertEqual(outsider.start(members: ids, shuffle: false, preferred: UUID(), random: &random), ids[0])
    }

    func testShuffleShowsEveryWallpaperOncePerRoundAndNeverRepeatsAcrossRounds() {
        var random = seededRandom()
        var cursor = PlaylistCursor()
        var played = [cursor.start(members: ids, shuffle: true, preferred: nil, random: &random)!]
        for _ in 0..<(ids.count * 6 - 1) {
            played.append(cursor.step(.next, members: ids, shuffle: true, random: &random)!)
        }
        for round in 0..<6 {
            XCTAssertEqual(Set(played[(round * ids.count)..<((round + 1) * ids.count)]), Set(ids), "round \(round)")
        }
        for index in 1..<played.count { XCTAssertNotEqual(played[index], played[index - 1]) }
        XCTAssertNotEqual(played, Array(repeating: ids, count: 6).flatMap { $0 }, "the order is shuffled")
    }

    func testShuffleKeepsTheRoundWhenTheListChanges() {
        var random = seededRandom(11)
        var cursor = PlaylistCursor()
        let first = cursor.start(members: ids, shuffle: true, preferred: ids[0], random: &random)
        XCTAssertEqual(first, ids[0])
        let round = cursor.shuffledOrder
        let added = UUID()
        let removed = round[2]
        let members = ids.filter { $0 != removed } + [added]
        var rest: [Wallpaper.ID] = []
        for _ in 0..<(members.count - 1) { rest.append(cursor.step(.next, members: members, shuffle: true, random: &random)!) }
        XCTAssertEqual(Set(rest), Set(members).subtracting([ids[0]]), "new member joins this round, the removed one is skipped")
        XCTAssertFalse(rest.contains(removed))
    }

    func testRemovingTheCurrentWallpaperContinuesFromItsPlace() {
        var random = seededRandom()
        var cursor = PlaylistCursor()
        _ = cursor.start(members: ids, shuffle: false, preferred: ids[2], random: &random)
        let members = ids.filter { $0 != ids[2] }
        var copy = cursor
        XCTAssertEqual(cursor.step(.next, members: members, shuffle: false, random: &random), ids[3])
        XCTAssertEqual(copy.step(.previous, members: members, shuffle: false, random: &random), ids[1])
        var last = PlaylistCursor()
        _ = last.start(members: ids, shuffle: false, preferred: ids[4], random: &random)
        XCTAssertEqual(last.step(.next, members: Array(ids.prefix(4)), shuffle: false, random: &random), ids[0])
    }

    func testEmptyListHasNothingToPlayAndIntervalsClamp() {
        var random = seededRandom()
        var cursor = PlaylistCursor()
        XCTAssertNil(cursor.start(members: [], shuffle: true, preferred: nil, random: &random))
        XCTAssertNil(cursor.step(.next, members: [], shuffle: false, random: &random))
        XCTAssertEqual(DisplayPlaylistConfiguration.clamped(0), 1)
        XCTAssertEqual(DisplayPlaylistConfiguration.clamped(2_000), 1_440)
        XCTAssertEqual(DisplayPlaylistConfiguration(listID: UUID(), intervalMinutes: 3).interval, 180)
        XCTAssertEqual(DisplayPlaylistConfiguration(listID: UUID()).intervalMinutes, 30)
    }
}

@MainActor
final class WallpaperPlaylistPlayerTests: XCTestCase {
    private var root: URL!
    private var library: WallpaperLibrary!
    private var lists: LocalOrganizationStore!
    private var runtime: WallpaperRuntimeManager!
    private var player: WallpaperPlaylistPlayer!
    private var clock: TimeInterval = 1_000
    private let a = DisplayID("display-A"), b = DisplayID("display-B")

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PlaylistTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        library = WallpaperLibrary(storage: .init(rootURL: root))
        lists = LocalOrganizationStore(storage: .init(rootURL: root))
        runtime = WallpaperRuntimeManager(makeRenderer: { PlaylistRenderer($0) })
        runtime.addDisplay(a, host: PlaylistHost()); runtime.addDisplay(b, host: PlaylistHost())
        player = makePlayer()
    }

    override func tearDown() async throws {
        player?.shutdown(); runtime?.shutdown()
        player = nil; runtime = nil; lists = nil; library = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func makePlayer() -> WallpaperPlaylistPlayer {
        WallpaperPlaylistPlayer(storage: .init(rootURL: root), runtime: runtime, library: library, lists: lists,
                                now: { [unowned self] in self.clock }, random: seededRandom(), schedulesTimer: false)
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
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while runtime.summary.displays.contains(where: { $0.runtime.preparingWallpaperID != nil }) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw DisplayEditingError.timedOut }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// The display page's 应用: start the list on a display and show the wallpaper it returns.
    private func start(_ listID: UUID, on display: DisplayID, minutes: Int = 1, shuffle: Bool = false) async throws -> Wallpaper.ID? {
        player.edit(on: display) { $0.listID = listID; $0.intervalMinutes = minutes; $0.shuffle = shuffle }
        let first = player.applyDraft(on: display, showing: nil)
        if let first, let wallpaper = library.wallpaper(id: first) { runtime.apply(wallpaper, to: display) }
        try await settle()
        return first
    }

    func testRotatesThroughTheListOnlyWhilePlayingUsingTheDisplaysOwnApply() async throws {
        let items = try wallpapers(3)
        let list = try lists.createList(name: "夜间", wallpaperIDs: items.map(\.id))
        let first = try await start(list, on: a)
        XCTAssertEqual(first, items[0].id)
        XCTAssertEqual(runtime.activeWallpaper(on: a)?.id, items[0].id)
        XCTAssertTrue(player.isActive(on: a)); XCTAssertFalse(player.isActive(on: b))

        clock += 59; player.advanceDue(); try await settle()
        XCTAssertEqual(runtime.activeWallpaper(on: a)?.id, items[0].id, "not yet a minute")
        clock += 1; player.advanceDue(); try await settle()
        XCTAssertEqual(runtime.activeWallpaper(on: a)?.id, items[1].id)
        XCTAssertNil(runtime.activeWallpaper(on: b), "other displays are untouched")

        runtime.pause(.display(a))
        clock += 600; player.advanceDue(); try await settle()
        XCTAssertEqual(runtime.activeWallpaper(on: a)?.id, items[1].id, "manual pause stops the countdown")
        XCTAssertEqual(player.remaining(on: a), 60)
        runtime.resume(.display(a))
        runtime.setSmartPauseActive(true)
        clock += 600; player.advanceDue(); try await settle()
        XCTAssertEqual(runtime.activeWallpaper(on: a)?.id, items[1].id, "smart pause stops the countdown")
        runtime.setSmartPauseActive(false)
        clock += 30; player.advanceDue()
        XCTAssertEqual(player.remaining(on: a), 30)
        clock += 30; player.advanceDue(); try await settle()
        XCTAssertEqual(runtime.activeWallpaper(on: a)?.id, items[2].id)
        clock += 60; player.advanceDue(); try await settle()
        XCTAssertEqual(runtime.activeWallpaper(on: a)?.id, items[0].id, "wraps to the start")
    }

    func testPreviousAndNextSwitchAtOnceAndRestartTheCountdown() async throws {
        let items = try wallpapers(3)
        let list = try lists.createList(name: "工作", wallpaperIDs: items.map(\.id))
        _ = try await start(list, on: a)
        _ = try await start(list, on: b)
        clock += 40
        player.stepAll(.next); try await settle()
        XCTAssertEqual(runtime.activeWallpaper(on: a)?.id, items[1].id)
        XCTAssertEqual(runtime.activeWallpaper(on: b)?.id, items[1].id)
        XCTAssertEqual(player.remaining(on: a), 60)
        player.step(.previous, on: a); try await settle()
        player.step(.previous, on: a); try await settle()
        XCTAssertEqual(runtime.activeWallpaper(on: a)?.id, items[2].id)
        XCTAssertEqual(runtime.activeWallpaper(on: b)?.id, items[1].id)
        XCTAssertTrue(player.hasActivePlaylist)
        runtime.stop(.display(a)); runtime.stop(.display(b))
        XCTAssertFalse(player.hasActivePlaylist, "上一张 / 下一张 only while a display shows its list")
    }

    func testChoosingAnotherWallpaperOnTheDisplayEndsItsRotationButRestoringDoesNot() async throws {
        let items = try wallpapers(3)
        let outside = try wallpapers(1)[0]
        let list = try lists.createList(name: "极光", wallpaperIDs: items.map(\.id))
        _ = try await start(list, on: a)
        _ = try await start(list, on: b)
        runtime.apply(items[0], to: a)
        XCTAssertNotNil(player.entries[a], "re-applying the wallpaper it shows changes nothing")
        runtime.apply(outside, to: a); try await settle()
        XCTAssertNil(player.entries[a])
        XCTAssertEqual(runtime.activeWallpaper(on: a)?.id, outside.id)
        XCTAssertNotNil(player.entries[b], "only that display stops")

        // A display that reconnects gets its last wallpaper back; that is not the user's choice.
        runtime.removeDisplay(b)
        runtime.addDisplay(b, host: PlaylistHost())
        runtime.apply(items[0], to: b); try await settle()
        XCTAssertNotNil(player.entries[b])
    }

    func testDeletingTheListStopsRotationAndKeepsTheWallpaper() async throws {
        let items = try wallpapers(2)
        let list = try lists.createList(name: "临时", wallpaperIDs: items.map(\.id))
        _ = try await start(list, on: a)
        player.edit(on: b) { $0.listID = list }
        try lists.deleteList(list)
        XCTAssertNil(player.entries[a]); XCTAssertNil(player.draft(on: b).listID)
        XCTAssertEqual(runtime.activeWallpaper(on: a)?.id, items[0].id)
    }

    func testStopDraftAndRestartFromTheShownWallpaper() async throws {
        let items = try wallpapers(4)
        let list = try lists.createList(name: "顺序", wallpaperIDs: items.map(\.id))
        _ = try await start(list, on: a)
        player.edit(on: a) { $0.intervalMinutes = 5 }
        XCTAssertTrue(player.isDirty(on: a))
        XCTAssertEqual(player.applyDraft(on: a, showing: items[0].id), items[0].id, "only the interval changed")
        XCTAssertEqual(player.entries[a]?.configuration.intervalMinutes, 5)
        player.edit(on: a) { $0.intervalMinutes = 0 }
        XCTAssertEqual(player.draft(on: a).intervalMinutes, 1)
        player.edit(on: a) { $0.intervalMinutes = 9_999 }
        XCTAssertEqual(player.draft(on: a).intervalMinutes, 1_440)
        XCTAssertEqual(player.applyDraft(on: a, showing: items[2].id), items[2].id, "starts from the wallpaper picked on the page")
        player.edit(on: a) { $0.listID = nil }
        XCTAssertNil(player.applyDraft(on: a, showing: items[2].id))
        XCTAssertNil(player.entries[a])
        XCTAssertEqual(runtime.activeWallpaper(on: a)?.id, items[0].id, "stopping keeps the current wallpaper")
    }

    func testUnplayableAndRemovedMembersAreSkipped() async throws {
        let items = try wallpapers(3)
        let list = try lists.createList(name: "跳过", wallpaperIDs: items.map(\.id))
        try FileManager.default.removeItem(at: items[1].resourceURL)
        try library.remove(id: items[1].id)
        XCTAssertEqual(player.members(of: list), [items[0].id, items[2].id])
        _ = try await start(list, on: a)
        player.step(.next, on: a); try await settle()
        XCTAssertEqual(runtime.activeWallpaper(on: a)?.id, items[2].id)
    }

    func testRotationAndElapsedTimeSurviveRelaunch() async throws {
        let items = try wallpapers(3)
        let list = try lists.createList(name: "保存", wallpaperIDs: items.map(\.id))
        _ = try await start(list, on: a, minutes: 10, shuffle: true)
        player.step(.next, on: a); try await settle()
        clock += 120
        let shown = runtime.activeWallpaper(on: a)?.id
        player.shutdown()
        player = makePlayer()
        XCTAssertEqual(player.entries[a]?.configuration, DisplayPlaylistConfiguration(listID: list, intervalMinutes: 10, shuffle: true))
        XCTAssertEqual(player.entries[a]?.cursor.currentWallpaperID, shown)
        XCTAssertEqual(player.remaining(on: a), 480)
    }

    func testUnreadableFileIsSetAsideNotOverwritten() throws {
        player.shutdown()
        try Data("not json".utf8).write(to: player.fileURL)
        player = makePlayer()
        XCTAssertTrue(player.entries.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("playlist-playback.unreadable-") })
    }
}

@MainActor
final class WallpaperListEditingTests: XCTestCase {
    func testRemoveAndReorderOnlyTouchThatList() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ListEditing-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalOrganizationStore(storage: .init(rootURL: root))
        let ids = (0..<4).map { _ in UUID() }
        let first = try store.createList(name: "一", wallpaperIDs: ids)
        let second = try store.createList(name: "二", wallpaperIDs: ids)
        try store.remove([ids[1]], from: first)
        XCTAssertEqual(store.lists.first { $0.id == first }?.wallpaperIDs, [ids[0], ids[2], ids[3]])
        XCTAssertNil(store.lists.first { $0.id == first }?.addedAt(ids[1]))
        XCTAssertEqual(store.lists.first { $0.id == second }?.wallpaperIDs, ids)
        try store.reorder(first, to: [ids[3], ids[0], ids[2]])
        try store.reorder(first, to: [ids[1], ids[0]])  // stale: ignored
        let reopened = LocalOrganizationStore(storage: .init(rootURL: root))
        XCTAssertEqual(reopened.lists.first { $0.id == first }?.wallpaperIDs, [ids[3], ids[0], ids[2]])
        XCTAssertEqual(reopened.lists.first { $0.id == second }?.wallpaperIDs, ids)
        XCTAssertThrowsError(try store.remove([ids[0]], from: UUID()))
    }
}

@MainActor
final class PlaylistInterfaceTests: XCTestCase {
    func testListOrderSortIsOfferedOnlyOnListPagesAndKeepsTheListsOrder() {
        XCTAssertEqual(ContentSortMode.available(inSteamStore: false), [.dateAdded, .name, .type])
        XCTAssertEqual(ContentSortMode.available(inSteamStore: false, inList: true), [.dateAdded, .name, .type, .listOrder])
        XCTAssertEqual(ContentSortMode.available(inSteamStore: true, inList: true), [.dateAdded, .popularity, .name, .type])
        XCTAssertEqual(NSLocalizedString("content.sort.listOrder", comment: ""), "列表顺序")
        let root = URL(fileURLWithPath: "/tmp")
        let items = ["丙", "甲", "乙"].map { Wallpaper(name: $0, type: .video, source: .local, resourceURL: root.appendingPathComponent($0)) }
        let ordered = ContentQuery.apply(ContentViewOptions(sortMode: .listOrder), to: items, dateAdded: { _ in Date() })
        XCTAssertEqual(ordered.map(\.name), ["丙", "甲", "乙"])
        let videoOnly = ContentQuery.apply(ContentViewOptions(sortMode: .listOrder, typeFilter: .only([.web])), to: items, dateAdded: { _ in nil })
        XCTAssertTrue(videoOnly.isEmpty, "type filter still applies")
    }

    func testDraggingTheOrderKeepsReferencesThatAreNotShown() {
        let ids = (0..<5).map { _ in UUID() }
        let visible = [ids[0], ids[2], ids[3], ids[4]]  // ids[1] is no longer in the library
        let moved = DisplayPlaylistOrder.moving(IndexSet(integer: 3), to: 0, visible: visible, in: ids)
        XCTAssertEqual(moved, [ids[4], ids[1], ids[0], ids[2], ids[3]])
        XCTAssertEqual(DisplayPlaylistOrder.moving(IndexSet(integer: 0), to: 5, visible: ids, in: ids),
                       [ids[1], ids[2], ids[3], ids[4], ids[0]], "dropped after the last row")
    }

    /// Offscreen PNGs of the display page's 轮播 section (playing, order expanded), light and dark, for review.
    func testPlaylistSectionSnapshots() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PlaylistSnapshot-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = LibraryStorageLocation(rootURL: root)
        let library = WallpaperLibrary(storage: storage)
        let lists = LocalOrganizationStore(storage: storage)
        let runtime = WallpaperRuntimeManager(makeRenderer: { PlaylistRenderer($0) })
        let display = DisplayID("display-A")
        runtime.addDisplay(display, host: PlaylistHost())
        let suite = "Kinetic.Playlist.Snapshot." + UUID().uuidString
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite); runtime.shutdown() }
        let settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        let editor = DisplayWallpaperEditor(storage: storage, library: library, runtime: runtime,
            sceneStore: ScenePropertyStore(storage: storage), videoStore: VideoPlaybackStore(storage: storage),
            webStore: WebPlaybackStore(storage: storage), settings: settings) { wallpaper, _ in PlaylistRenderer(wallpaper) }
        let items = try ["极光", "雨夜的城市街道与很长很长的壁纸名称", "海浪"].map { name -> Wallpaper in
            let value = Wallpaper(name: name, type: .video, source: .local, resourceURL: root.appendingPathComponent(UUID().uuidString + ".mp4"))
            try Data("video".utf8).write(to: value.resourceURL); try library.add(value); return value
        }
        _ = try lists.createList(name: "工作", wallpaperIDs: [])
        let list = try lists.createList(name: "夜间", wallpaperIDs: items.map(\.id))
        let player = WallpaperPlaylistPlayer(storage: storage, runtime: runtime, library: library, lists: lists,
                                             now: { 100 }, schedulesTimer: false)
        defer { player.shutdown() }
        player.edit(on: display) { $0.listID = list; $0.intervalMinutes = 30; $0.shuffle = true }
        let first = try XCTUnwrap(player.applyDraft(on: display, showing: items[0].id))
        runtime.apply(try XCTUnwrap(library.wallpaper(id: first)), to: display)
        let deadline = Date().addingTimeInterval(3)
        while runtime.state(of: display)?.activeWallpaperID == nil, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(player.isActive(on: display))
        let section = DisplayPlaylistSection(displayID: display, player: player, lists: lists, editor: editor,
                                             library: library, runtime: runtime, showsOrder: true)
            .padding(20)
        let size = CGSize(width: 360, height: 420)
        try R4SnapshotTests.render(section, size: size, name: "module46-playlist-section")
        try R4SnapshotTests.render(section, size: size, name: "module46-playlist-section-dark", appearance: .darkAqua)
    }

    func testMenuAndCardLabels() {
        XCTAssertEqual(NSLocalizedString("menu.playlist.previous", comment: ""), "上一张壁纸")
        XCTAssertEqual(NSLocalizedString("menu.playlist.next", comment: ""), "下一张壁纸")
        XCTAssertEqual(NSLocalizedString("lists.removeFromList", comment: ""), "从壁纸列表中移除")
    }
}
