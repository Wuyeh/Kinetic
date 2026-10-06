import AppKit
import SwiftUI
import XCTest
@testable import Kinetic

/// Kinetic 1.0 Content Header 修订：排序与显示选项（共享的 ContentViewOptions / ContentQuery / ContentOptionsPopover）。
final class ContentOptionsTests: XCTestCase {
    private func wallpaper(_ name: String, _ type: WallpaperType, added: Date? = nil, favorited: Date? = nil,
                           id: UUID = UUID()) -> Wallpaper {
        Wallpaper(id: id, name: name, type: type, acquisitionOrigin: .localImport,
                  resourceURL: URL(fileURLWithPath: "/kinetic-content/\(name)"),
                  isFavorite: favorited != nil, favoritedAt: favorited, importedAt: added)
    }

    private func date(_ minutes: Double) -> Date { Date(timeIntervalSinceReferenceDate: 800_000_000 + minutes * 60) }

    // MARK: - 显示选项

    func testDefaultsAreDateAddedAndAllTypes() {
        let options = ContentViewOptions()
        XCTAssertEqual(options.sortMode, .dateAdded)
        XCTAssertEqual(options.typeFilter, .all)
        XCTAssertTrue(options.showsAllTypes)
        XCTAssertTrue(WallpaperType.allCases.allSatisfy { !options.isChecked($0) },
                      "With 全部类型 no specific type shows a checkmark")
        XCTAssertEqual(ContentSortMode.allCases, [.dateAdded, .name, .type])
        XCTAssertEqual(ContentViewOptions.displayedTypes, [.scene, .web, .video])
    }

    func testTypeFilterRulesFromTheSpec() {
        var options = ContentViewOptions()
        options.toggle(.scene)
        XCTAssertEqual(options.typeFilter, .only([.scene]), "A specific type cancels 全部类型")
        XCTAssertFalse(options.showsAllTypes)
        options.toggle(.web)
        XCTAssertEqual(options.typeFilter, .only([.scene, .web]), "Specific types are multi-select")
        XCTAssertTrue(options.isChecked(.scene) && options.isChecked(.web) && !options.isChecked(.video))
        options.toggle(.video)
        XCTAssertEqual(options.typeFilter, .all, "All three selected normalises to 全部类型")
        XCTAssertTrue(WallpaperType.allCases.allSatisfy { !options.isChecked($0) })

        options.toggle(.video)
        XCTAssertEqual(options.typeFilter, .only([.video]))
        options.toggle(.video)
        XCTAssertEqual(options.typeFilter, .all, "Turning off the last type restores 全部类型, never an empty filter")

        options.toggle(.web)
        options.showAllTypes()
        XCTAssertEqual(options.typeFilter, .all)
        options.showAllTypes()
        XCTAssertEqual(options.typeFilter, .all, "Clicking 全部类型 again keeps it")

        // 所有合法组合：1 或 2 种具体类型。
        for combination in [[WallpaperType.scene], [.web], [.video], [.scene, .web], [.scene, .video], [.web, .video]] {
            var state = ContentViewOptions()
            combination.forEach { state.toggle($0) }
            XCTAssertEqual(state.typeFilter, .only(Set(combination)))
        }
        XCTAssertEqual(ContentViewOptions(typeFilter: .only([])).typeFilter, .all)
        XCTAssertEqual(ContentViewOptions(typeFilter: .only(Set(WallpaperType.allCases))).typeFilter, .all)
    }

    func testSortModeIsSingleChoiceAndIndependentOfTheFilter() {
        var options = ContentViewOptions()
        options.toggle(.scene)
        options.toggle(.web)
        options.sortMode = .name
        XCTAssertEqual(options.typeFilter, .only([.scene, .web]), "Changing the sort keeps the filter")
        options.sortMode = .type
        XCTAssertEqual(options.sortMode, .type)
        XCTAssertEqual(options.typeFilter, .only([.scene, .web]))

        let items = [wallpaper("Delta", .video), wallpaper("charlie", .web), wallpaper("Bravo", .scene),
                     wallpaper("alpha", .web), wallpaper("Echo", .video)]
        var byName = options
        byName.sortMode = .name
        XCTAssertEqual(ContentQuery.apply(byName, to: items, dateAdded: { _ in nil }).map(\.name),
                       ["alpha", "Bravo", "charlie"], "Only Scene + Web, sorted by name inside the result")
    }

    // MARK: - 排序

    func testDateAddedIsNewestFirstAndUndatedItemsKeepTheirOrderAtTheEnd() {
        let items = [wallpaper("old1", .video), wallpaper("new", .video, added: date(30)),
                     wallpaper("mid", .web, added: date(10)), wallpaper("old2", .scene)]
        XCTAssertEqual(ContentQuery.apply(ContentViewOptions(), to: items, dateAdded: \.importedAt).map(\.name),
                       ["new", "mid", "old1", "old2"])
    }

    func testNameSortIsLocalisedAndReadable() throws {
        let items = [wallpaper("壁纸10", .video), wallpaper("壁纸2", .video), wallpaper("banana", .video),
                     wallpaper("Apple", .video)]
        let options = ContentViewOptions(sortMode: .name)
        let names = ContentQuery.apply(options, to: items, dateAdded: { _ in nil }).map(\.name)
        // 中文与拉丁字母谁在前由当前语言的排序规则决定；这里只检查用户可读的规则。
        XCTAssertLessThan(try XCTUnwrap(names.firstIndex(of: "壁纸2")), try XCTUnwrap(names.firstIndex(of: "壁纸10")),
                          "Numbers compare by value")
        XCTAssertLessThan(try XCTUnwrap(names.firstIndex(of: "Apple")), try XCTUnwrap(names.firstIndex(of: "banana")),
                          "Case does not split names")
        XCTAssertEqual(ContentQuery.apply(options, to: items.reversed(), dateAdded: { _ in nil }).map(\.name), names,
                       "Result does not depend on the input order")
    }

    func testTypeSortUsesAFixedStableOrder() {
        let items = [wallpaper("b", .video), wallpaper("a", .web), wallpaper("c", .scene),
                     wallpaper("a", .video), wallpaper("b", .scene)]
        let options = ContentViewOptions(sortMode: .type)
        let first = ContentQuery.apply(options, to: items, dateAdded: { _ in nil })
        XCTAssertEqual(first.map { "\($0.type.rawValue)-\($0.name)" },
                       ["scene-b", "scene-c", "web-a", "video-a", "video-b"])
        for _ in 0..<5 {
            XCTAssertEqual(ContentQuery.apply(options, to: items, dateAdded: { _ in nil }).map(\.id), first.map(\.id),
                           "Same order on every refresh")
        }
        XCTAssertEqual(ContentQuery.apply(options, to: items, dateAdded: { _ in nil }).count, items.count,
                       "Type sort never hides anything")
    }

    /// 本地页面：置顶组始终在前，排序只在组内进行（规格示例：Pinned A C Z / Normal A B D）。
    func testPinnedGroupStaysFirstAndSortsOnlyInsideEachGroup() {
        let names = ["Z", "B", "A", "D", "C", "A"]
        let pinnedNames: Set<Int> = [0, 4, 5]
        let items = names.map { wallpaper($0, .video) }
        let pinned = Set(pinnedNames.map { items[$0].id })
        let result = ContentQuery.apply(ContentViewOptions(sortMode: .name), to: items, dateAdded: { _ in nil },
                                        isPinned: { pinned.contains($0) })
        XCTAssertEqual(result.map(\.name), ["A", "C", "Z", "A", "B", "D"])
        XCTAssertEqual(Set(result.prefix(3).map(\.id)), pinned)
    }

    // MARK: - 选择

    func testSortKeepsSelectionByIDAndFilterDropsHiddenSelections() {
        let videos = (0..<3).map { wallpaper("视频\($0)", .video) }
        let others = (0..<5).map { wallpaper("网页\($0)", .web) }
        let items = videos + others
        var selection = StableCardSelection<Wallpaper.ID>()
        selection.replace(with: Set(items.map(\.id)))
        XCTAssertEqual(selection.count, 8)

        var options = ContentViewOptions(sortMode: .name)
        let sorted = ContentQuery.apply(options, to: items, dateAdded: { _ in nil })
        selection.retain(Set(sorted.map(\.id)))
        XCTAssertEqual(selection.ids, Set(items.map(\.id)), "Sorting moves cards but keeps the same selected IDs")

        options.toggle(.web)
        options.toggle(.scene)
        let visible = ContentQuery.apply(options, to: items, dateAdded: { _ in nil })
        selection.retain(Set(visible.map(\.id)))
        XCTAssertEqual(selection.count, 5, "Hidden video selections are removed: 8 → 5")
        XCTAssertTrue(videos.allSatisfy { !selection.contains($0.id) })
    }

    // MARK: - 各页面的「添加时间」

    @MainActor
    func testFavoritesRecordWhenTheyWereFavorited() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KineticFavorites-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = LibraryStorageLocation(rootURL: root)
        let library = WallpaperLibrary(storage: storage)
        let first = wallpaper("先喜爱", .video), second = wallpaper("后喜爱", .web)
        try library.add(first)
        try library.add(second)
        try library.setFavorite(true, for: first.id)
        let firstTime = try XCTUnwrap(library.wallpaper(id: first.id)?.favoritedAt)
        Thread.sleep(forTimeInterval: 0.01)
        try library.setFavorite(true, for: second.id)

        let reopened = WallpaperLibrary(storage: storage)
        XCTAssertEqual(reopened.wallpaper(id: first.id)?.favoritedAt, firstTime, "favoritedAt is persisted")
        let favorites = ContentQuery.apply(ContentViewOptions(), to: reopened.wallpapers(in: .favorites),
                                           dateAdded: \.favoritedAt)
        XCTAssertEqual(favorites.map(\.name), ["后喜爱", "先喜爱"], "Newest favourite first")

        try reopened.setFavorite(false, for: first.id)
        XCTAssertNil(reopened.wallpaper(id: first.id)?.favoritedAt, "Unfavouriting clears the time")
        let json = try String(contentsOf: storage.libraryFileURL, encoding: .utf8)
        XCTAssertTrue(json.contains("\"formatVersion\" : 2"), "Optional field, library format unchanged")
    }

    @MainActor
    func testListsRecordWhenEachWallpaperWasAddedToTheList() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KineticListDates-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = LibraryStorageLocation(rootURL: root)
        let early = UUID(), late = UUID(), gone = UUID()
        let store = LocalOrganizationStore(storage: storage)
        let listID = try store.createList(name: "晚上", wallpaperIDs: [early, gone])
        Thread.sleep(forTimeInterval: 0.01)
        try store.add([late, early], to: listID)
        let list = try XCTUnwrap(store.lists.first { $0.id == listID })
        let earlyDate = try XCTUnwrap(list.addedAt(early))
        XCTAssertGreaterThan(try XCTUnwrap(list.addedAt(late)), earlyDate, "Re-adding keeps the first time")
        XCTAssertEqual(list.items.map(\.wallpaperID), [early, gone, late])

        let copyID = try store.duplicateList(listID)
        XCTAssertEqual(store.lists.first { $0.id == copyID }?.addedAt(early), earlyDate)
        try store.removeMissingReferences(validIDs: [early, late])
        let reopened = LocalOrganizationStore(storage: storage)
        let pruned = try XCTUnwrap(reopened.lists.first { $0.id == listID })
        XCTAssertNil(pruned.addedAt(gone))
        XCTAssertEqual(pruned.addedAt(early), earlyDate)

        let items = [wallpaper("早", .video, id: early), wallpaper("晚", .video, id: late)]
        XCTAssertEqual(ContentQuery.apply(ContentViewOptions(), to: items, dateAdded: { pruned.addedAt($0.id) }).map(\.name),
                       ["晚", "早"], "List 添加时间 = time added to the list, not import time")
    }

    @MainActor
    func testListsSavedBeforeAddedDatesStillLoad() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KineticListLegacy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let member = UUID(), listID = UUID()
        let json = """
        {"version": 1, "pinnedIDs": [], "lists": [{"id": "\(listID.uuidString)", "name": "旧列表",
          "wallpaperIDs": ["\(member.uuidString)"], "createdAt": 800000000, "updatedAt": 800000000}]}
        """
        try Data(json.utf8).write(to: root.appendingPathComponent("organization.json"))
        let store = LocalOrganizationStore(storage: LibraryStorageLocation(rootURL: root))
        let list = try XCTUnwrap(store.lists.first)
        XCTAssertEqual(list.wallpaperIDs, [member])
        XCTAssertNil(list.addedAt(member))
    }

    // MARK: - 界面

    func testLabelsMatchTheSpec() {
        let expected = ["content.section.sort": "排序选项", "content.section.display": "显示选项",
                        "content.sort.dateAdded": "添加时间", "content.sort.name": "名称", "content.sort.type": "类型",
                        "content.type.all": "全部类型", "content.type.scene": "Scene", "content.type.web": "Web",
                        "content.type.video": "视频"]
        for (key, value) in expected {
            XCTAssertEqual(NSLocalizedString(key, comment: ""), value, key)
        }
        XCTAssertEqual(ContentSortMode.dateAdded.titleKey, "content.sort.dateAdded")
    }

    @MainActor
    func testHeaderAndPopoverLayOut() {
        var options = ContentViewOptions()
        let binding = Binding(get: { options }, set: { options = $0 })
        let header = NSHostingView(rootView: ContentHeader(title: "本地", options: binding).frame(width: 600))
        XCTAssertEqual(header.fittingSize.width, 600, accuracy: 0.5)
        XCTAssertLessThan(header.fittingSize.height, 60, "Small, quiet header")
        let popover = NSHostingView(rootView: ContentOptionsPopover(options: binding))
        XCTAssertEqual(popover.fittingSize.width, ContentHeaderMetrics.popoverWidth, accuracy: 0.5)
        XCTAssertGreaterThan(popover.fittingSize.height, 8 * 26, "Two sections, eight rows")
    }
}
