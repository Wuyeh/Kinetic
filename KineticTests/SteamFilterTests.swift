import AppKit
import SwiftUI
import XCTest
@testable import Kinetic

/// R4 第 44–49 节：Steam 筛选扩展——同组单选、不同组 AND、搜索 / 分页 / 刷新共用完整条件，弹出框宽度不变、高度有上限。
final class SteamFilterTests: XCTestCase {
    private let key = "0123456789ABCDEF0123456789ABCDEF"

    func testEachGroupIsSingleChoiceAndAllClearsOnlyItsGroup() {
        var filters = SteamFilterState()
        XCTAssertTrue(filters.isDefault)
        filters.select("Anime", in: .genre)
        filters.select("Game", in: .genre)
        XCTAssertEqual(filters.tags[.genre], "Game", "Another candidate replaces the group's condition")
        filters.select("3840 x 2160", in: .resolution)
        filters.clear(.genre)
        XCTAssertNil(filters.tags[.genre])
        XCTAssertEqual(filters.tags[.resolution], "3840 x 2160", "Other groups stay")
        XCTAssertEqual(filters.summary(for: .resolution), "3840 × 2160")
        XCTAssertNil(filters.summary(for: .genre))

        // 类型组沿用原规则：具体类型可多选，四类都选中归为全部类型。
        filters.toggleType("Scene")
        filters.toggleType("Application")
        XCTAssertEqual(filters.typeTags, ["Scene", "Application"])
        XCTAssertEqual(filters.summary(for: .type), "场景、应用")
        filters.toggleType("Web"); filters.toggleType("Video")
        XCTAssertTrue(filters.showsAllTypes)
        filters.toggleType("Video"); filters.showAllTypes()
        XCTAssertTrue(filters.showsAllTypes)
    }

    func testCombinedFiltersBecomeRealTagsWithAndAcrossGroups() throws {
        var query = SteamStoreQuery()
        XCTAssertFalse(query.matchAllTags, "Default browsing is unchanged")
        XCTAssertEqual(query.requiredTags, ["Scene", "Web", "Video"])
        XCTAssertEqual(query.excludedTagList, [], "Questionable and Mature show like normal wallpapers by default")

        query.filters.toggleType("Scene")
        query.filters.select("Anime", in: .genre)
        query.filters.select("3840 x 2160", in: .resolution)
        XCTAssertTrue(query.matchAllTags)
        XCTAssertEqual(Set(query.requiredTags), ["Scene", "Anime", "3840 x 2160"], "Scene + Anime + 3840 × 2160 all required")
        let url = query.url(key: key, cursor: "*")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.first { $0.name == "match_all_tags" }?.value, "true")
        XCTAssertEqual(Set(items.filter { $0.name.hasPrefix("requiredtags[") }.compactMap(\.value)), ["Scene", "Anime", "3840 x 2160"])

        // 同组多个类型 + 其他组：排除其余类型，表达类型内的 OR。
        query.filters.toggleType("Web")
        XCTAssertEqual(Set(query.requiredTags), ["Anime", "3840 x 2160"])
        XCTAssertEqual(Set(query.excludedTagList), ["Video", "Application"])

        // 明确找预设：不再排除「应用」等类型；预设 / 素材仍走既有校验，不会变成可直接播放的壁纸。
        var presets = SteamStoreQuery()
        presets.filters.select("Preset", in: .category)
        XCTAssertEqual(presets.requiredTags, ["Preset"])
        XCTAssertEqual(presets.excludedTagList, [])

        var application = SteamStoreQuery()
        application.filters.toggleType("Application")
        XCTAssertFalse(application.matchAllTags)
        XCTAssertEqual(application.requiredTags, ["Application"], "Application is a real type candidate")

        var other = query
        other.filters.select("Game", in: .genre)
        XCTAssertNotEqual(other.cacheKey, query.cacheKey, "Every condition is part of the query key")

        // 本地规则与服务器一致（作者的壁纸在本地筛选）。
        let item = SteamStoreItem(workshopID: "1", title: "t", previewURL: nil, creatorSteamID: nil, authorName: nil,
                                  timeCreated: nil, timeUpdated: nil, fileSize: nil, type: .scene,
                                  tags: ["Scene", "Anime", "3840 x 2160", "Everyone"])
        XCTAssertTrue(query.locallyMatches(item))
        XCTAssertFalse(other.locallyMatches(item), "Game is required too")
    }

    /// 用户决定（2026-10-07）：两个设置默认开启，其余筛选器显式例外保持不变。
    /// 在筛选器中明确选择某个分级时，即使设置隐藏也会显示。
    func testAgeRatingsShowByDefaultAndCanBeHiddenInSettings() throws {
        let defaults = SettingsState()
        XCTAssertTrue(defaults.steamHideQuestionable)
        XCTAssertTrue(defaults.steamHideMature)
        XCTAssertEqual(defaults.steamHiddenAgeRatings, ["Questionable", "Mature"])
        let old = try JSONDecoder().decode(SettingsState.self, from: Data(#"{"appearance":"dark"}"#.utf8))
        XCTAssertEqual(old.steamHiddenAgeRatings, ["Questionable", "Mature"], "Missing keys use the new defaults; an explicit saved false is tested separately")

        var mature = SteamStoreQuery()
        mature.filters.select("Mature", in: .ageRating)
        XCTAssertEqual(mature.requiredTags, ["Mature"], "Selecting 成人 filters for it")
        XCTAssertEqual(mature.excludedTagList, ["Application"], "No age rating is excluded; only the unplayable type, as with any filter")
        let adult = SteamStoreItem(workshopID: "1", title: "t", previewURL: nil, creatorSteamID: nil, authorName: nil,
                                   timeCreated: nil, timeUpdated: nil, fileSize: nil, type: .video, tags: ["Video", "Mature"])
        XCTAssertTrue(SteamStoreQuery().locallyMatches(adult), "Shown with nothing selected")
        XCTAssertTrue(mature.locallyMatches(adult))

        var settings = SettingsState()
        settings.steamHideQuestionable = true
        settings.steamHideMature = true
        var hidden = SteamStoreQuery()
        hidden.hiddenAgeRatings = settings.steamHiddenAgeRatings
        XCTAssertEqual(hidden.excludedTagList, ["Questionable", "Mature"])
        XCTAssertFalse(hidden.locallyMatches(adult))
        XCTAssertNotEqual(hidden.cacheKey, SteamStoreQuery().cacheKey)
        hidden.filters.select("Mature", in: .ageRating)
        XCTAssertEqual(hidden.excludedTagList, ["Questionable", "Application"], "An explicit filter choice still shows that rating")
        XCTAssertTrue(hidden.locallyMatches(adult))
    }

    @MainActor
    func testChangingTheHideSettingReloadsOnlyAfterBrowsingStarted() async throws {
        var requests: [URL] = []
        let store = SteamStoreService(keyStore: MemorySteamAPIKeyStore(key), cacheDirectory: nil,
                                      posters: SteamPosterCache(directory: nil), fetch: { url in
            requests.append(url)
            return (Data(#"{"response":{"total":0,"publishedfiledetails":[]}}"#.utf8), 200)
        })
        store.setHiddenAgeRatings(["Mature"])
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(requests.isEmpty, "No request (and no Keychain read) before the Steam page is opened")
        store.reload()
        let deadline = Date().addingTimeInterval(2)
        while store.phase != .loaded, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        store.setHiddenAgeRatings([])
        while requests.count < 2, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        let excluded = requests.map { url in
            (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).filter { $0.name.hasPrefix("excludedtags[") }.compactMap(\.value)
        }
        XCTAssertEqual(excluded, [["Mature"], []], "Turning the setting off reloads with nothing hidden")
    }

    @MainActor
    func testSearchPagingAndRefreshKeepTheWholeFilter() async throws {
        var requests: [URL] = []
        let store = SteamStoreService(keyStore: MemorySteamAPIKeyStore(key), cacheDirectory: nil,
                                      posters: SteamPosterCache(directory: nil), fetch: { url in
            requests.append(url)
            let cursor = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "cursor" }?.value ?? "*"
            let id = cursor == "*" ? "1" : "2"
            let body: [String: Any] = ["response": ["total": 2, "next_cursor": cursor == "*" ? "next" : cursor,
                                                    "publishedfiledetails": [["publishedfileid": id, "result": 1, "title": id,
                                                                              "tags": [["tag": "Anime"]]]]]]
            return (try JSONSerialization.data(withJSONObject: body), 200)
        })
        var filters = SteamFilterState()
        filters.select("Anime", in: .genre)
        filters.select("Everyone", in: .ageRating)
        store.update(searchText: "sky", filters: filters)
        let deadline = Date().addingTimeInterval(3)
        while store.phase != .loaded, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        store.loadMore()
        while store.loadMoreState == .loading, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        let queries = requests.filter { $0.path.contains("QueryFiles") }
        XCTAssertEqual(queries.count, 2)
        for url in queries {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(items.first { $0.name == "search_text" }?.value, "sky")
            XCTAssertEqual(items.first { $0.name == "match_all_tags" }?.value, "true")
            XCTAssertEqual(Set(items.filter { $0.name.hasPrefix("requiredtags[") }.compactMap(\.value)), ["Anime", "Everyone"],
                           "The next page uses the same complete filter")
        }
        XCTAssertEqual(store.items.map(\.workshopID), ["1", "2"])
    }

    @MainActor
    func testThePopoverKeepsItsWidthAndStaysWithinTheHeightLimit() throws {
        var options = ContentViewOptions()
        var filters = SteamFilterState()
        var expanded = Set(SteamTagGroup.allCases.filter(\.isExpandedByDefault))
        let optionsBinding = Binding(get: { options }, set: { options = $0 })
        let filtersBinding = Binding(get: { filters }, set: { filters = $0 })
        let expandedBinding = Binding(get: { expanded }, set: { expanded = $0 })
        func measure(availableHeight: CGFloat) -> NSSize {
            let host = NSHostingView(rootView: ContentOptionsPopover(options: optionsBinding, steamFilters: filtersBinding,
                                                                    steamExpandedGroups: expandedBinding,
                                                                    availableHeight: availableHeight))
            let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 400, height: 800), styleMask: .borderless,
                                  backing: .buffered, defer: false)
            window.contentView = host
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            for _ in 0..<20 { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
            return host.fittingSize
        }
        let plain = NSHostingView(rootView: ContentOptionsPopover(options: optionsBinding)).fittingSize
        let regular = measure(availableHeight: 760)
        XCTAssertEqual(regular.width, plain.width, accuracy: 0.5, "Exactly the current popover width")
        XCTAssertEqual(regular.width, ContentHeaderMetrics.popoverWidth, accuracy: 0.5)
        XCTAssertEqual(regular.height, SteamFilterPopoverMetrics.totalHeightLimit(availableHeight: 760), accuracy: 1,
                       "The extended filter ends at the toolbar lower-edge budget")
        let small = measure(availableHeight: 420)
        XCTAssertEqual(small.height, SteamFilterPopoverMetrics.totalHeightLimit(availableHeight: 420), accuracy: 1)
        XCTAssertEqual(small.width, ContentHeaderMetrics.popoverWidth, accuracy: 0.5)

        // 全部收起：内容较少时自然缩短，不留大片空白。
        expanded = []
        let collapsed = measure(availableHeight: 760)
        XCTAssertEqual(collapsed.height, regular.height, accuracy: 1, "The requested lower edge stays aligned even with collapsed groups")
        XCTAssertEqual(collapsed.width, ContentHeaderMetrics.popoverWidth, accuracy: 0.5)
        filters.select("Anime", in: .genre)
        XCTAssertEqual(filters.tags[.genre], "Anime", "Collapsing never clears a condition")

        expanded = Set(SteamTagGroup.allCases.filter(\.isExpandedByDefault))
        filters.select("3840 x 2160", in: .resolution)
        try R4SnapshotTests.render(ContentOptionsPopover(options: optionsBinding, steamFilters: filtersBinding,
                                                         steamExpandedGroups: expandedBinding, availableHeight: 760),
                                   size: CGSize(width: ContentHeaderMetrics.popoverWidth, height: regular.height),
                                   name: "steam-filter-popover")
    }
}
