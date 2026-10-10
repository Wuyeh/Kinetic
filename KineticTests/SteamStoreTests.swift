import Foundation
import XCTest
@testable import Kinetic

/// 1.0 Module 14 — Steam Store Browser：查询、解析、翻页、缓存、API Key、卡片状态、Poster 缓存。
final class SteamStoreTests: XCTestCase {
    private let key = "0123456789ABCDEF0123456789ABCDEF"
    private var temporaryRoots: [URL] = []

    override func tearDown() {
        for root in temporaryRoots { try? FileManager.default.removeItem(at: root) }
        super.tearDown()
    }

    private func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KineticStore-\(UUID().uuidString)",
                                                                                  isDirectory: true)
        temporaryRoots.append(root)
        return root
    }

    /// 假的 Steam：按请求的游标返回预先准备的页面；记录每个请求。
    private final class FakeSteam {
        private let lock = NSLock()
        private var recorded: [URL] = []
        var requests: [URL] {
            lock.withLock { recorded }
        }

        private func record(_ url: URL) {
            lock.withLock { recorded.append(url) }
        }
        var pages: [String: [[String: Any]]] = [:]
        var popularPages: [String: [[String: Any]]] = [:]
        var queryPages: [String: [[String: Any]]] = [:]
        var cursors: [String: String] = [:]
        var status = 200
        var offline = false
        var players: [String: String] = [:]
        /// 自定义个人资料 ID → SteamID64。
        var vanity: [String: String] = [:]
        /// SteamID64 → 这位作者的全部项目（GetUserFiles 按页切分）。
        var userFiles: [String: [[String: Any]]] = [:]

        func fetch(_ url: URL) async throws -> (Data, Int) {
            record(url)
            if offline { throw URLError(.notConnectedToInternet) }
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
            if url.path.contains("ResolveVanityURL") {
                let response: [String: Any] = vanity[value("vanityurl") ?? ""].map { ["steamid": $0, "success": 1] }
                    ?? ["success": 42, "message": "No match"]
                return (try JSONSerialization.data(withJSONObject: ["response": response]), 200)
            }
            if url.path.contains("GetUserFiles") {
                let all = userFiles[value("steamid") ?? ""] ?? []
                let page = Int(value("page") ?? "1") ?? 1, size = Int(value("numperpage") ?? "30") ?? 30
                let slice = Array(all.dropFirst((page - 1) * size).prefix(size))
                return (try JSONSerialization.data(withJSONObject: ["response": ["total": all.count,
                                                                                 "publishedfiledetails": slice]]), 200)
            }
            if url.path.contains("GetPlayerSummaries") {
                let ids = items.first { $0.name == "steamids" }?.value?.split(separator: ",").map(String.init) ?? []
                let list = ids.compactMap { id in players[id].map { ["steamid": id, "personaname": $0] } }
                return (try JSONSerialization.data(withJSONObject: ["response": ["players": list]]), 200)
            }
            let cursor = items.first { $0.name == "cursor" }?.value ?? "*"
            let context = "\(value("query_type") ?? "")|\(value("search_text") ?? "")|\(cursor)"
            let body: [String: Any] = ["response": ["total": 99,
                                                    "publishedfiledetails": queryPages[context]
                                                        ?? (value("query_type") == "0" ? popularPages[cursor] : pages[cursor]) ?? [],
                                                    "next_cursor": cursors[cursor] ?? cursor]]
            return (try JSONSerialization.data(withJSONObject: body), status)
        }

        func query(_ url: URL, _ name: String) -> [String] {
            (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .filter { $0.name == name || $0.name.hasPrefix(name + "[") }.compactMap(\.value)
        }
    }

    private func detail(_ id: String, title: String, tag: String?, created: Int, updated: Int? = nil,
                        creator: String = "76561190000000001") -> [String: Any] {
        var detail: [String: Any] = ["publishedfileid": id, "result": 1, "title": title,
                                     "preview_url": "https://images.example/\(id).gif", "creator": creator,
                                     "time_created": created, "time_updated": updated ?? created,
                                     "file_size": "\(1000 + created)"]
        if let tag { detail["tags"] = [["tag": tag], ["tag": "Everyone"], ["tag": "Abstract"]] }
        return detail
    }

    // MARK: - 查询与解析

    func testQueryUsesTheOfficialWorkshopAPIWithoutLeakingTheKeyIntoCaches() throws {
        var query = SteamStoreQuery()
        let latest = query.url(key: key, cursor: "*")
        let items = URLComponents(url: latest, resolvingAgainstBaseURL: false)!.queryItems!
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        XCTAssertEqual(latest.host, "api.steampowered.com")
        XCTAssertTrue(latest.absoluteString.hasPrefix("https://api.steampowered.com/IPublishedFileService/QueryFiles/v1/?"),
                      latest.absoluteString)
        XCTAssertEqual(value("appid"), "431960")
        XCTAssertEqual(value("query_type"), "1", "Newest publications first (the Steam page's date added)")
        XCTAssertEqual(value("numperpage"), "30")
        XCTAssertEqual(value("cursor"), "*")
        XCTAssertEqual(value("match_all_tags"), "false")
        XCTAssertNil(value("search_text"))
        XCTAssertEqual(items.filter { $0.name.hasPrefix("requiredtags[") }.map(\.value), ["Scene", "Web", "Video"])
        XCTAssertEqual(items.filter { $0.name.hasPrefix("excludedtags[") }.map(\.value), [],
                       "User decision 2026-10-06: every age rating shows by default")

        query.searchText = "  极光  "
        query.sortMode = .searchRelevance
        query.typeFilter = .only([.video])
        let search = query.url(key: key, cursor: "abc")
        let searchItems = URLComponents(url: search, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(searchItems.first { $0.name == "query_type" }?.value, "12",
                       "R4: searching ranks by text relevance (11 is RankedByVotesUp)")
        XCTAssertEqual(searchItems.first { $0.name == "search_text" }?.value, "极光")
        XCTAssertEqual(searchItems.filter { $0.name.hasPrefix("requiredtags[") }.map(\.value), ["Video"])
        XCTAssertFalse(query.cacheKey.contains(key))
        XCTAssertTrue(SteamStoreService.isValidKeyFormat(key))
        XCTAssertFalse(SteamStoreService.isValidKeyFormat("not-a-key"))
    }

    /// R4：文字搜索使用 RankedByTextSearch（12）；缓存键随查询类型变化，旧的「11」缓存不会被当作新结果。
    func testTextSearchUsesRankedByTextSearchAndCacheKeysFollowTheQueryType() {
        var query = SteamStoreQuery()
        XCTAssertEqual(query.queryType, 1)
        XCTAssertTrue(query.cacheKey.hasPrefix("workshop-rank-v2|1|recentlyPublished|"))
        query.searchText = "Aurora"
        query.sortMode = .searchRelevance
        XCTAssertEqual(query.queryType, 12)
        XCTAssertTrue(query.cacheKey.hasPrefix("workshop-rank-v2|12|searchRelevance|aurora|"), query.cacheKey)
        var other = query
        other.searchText = " aurora "
        XCTAssertEqual(other.cacheKey, query.cacheKey, "Same search, same cache entry")
    }

    func testAuthorReferencesAreRecognized() {
        typealias A = SteamAuthorReference
        XCTAssertEqual(A.explicit(in: "https://steamcommunity.com/profiles/76561198000000001/"), .steamID("76561198000000001"))
        XCTAssertEqual(A.explicit(in: "steamcommunity.com/profiles/76561198000000001/myworkshopfiles/?appid=431960"),
                       .steamID("76561198000000001"))
        XCTAssertEqual(A.explicit(in: " https://steamcommunity.com/id/Aurora_Studio "), .vanity("Aurora_Studio"))
        XCTAssertEqual(A.explicit(in: "76561198000000001"), .steamID("76561198000000001"))
        XCTAssertNil(A.explicit(in: "https://steamcommunity.com/sharedfiles/filedetails/?id=123"))
        XCTAssertNil(A.explicit(in: "aurora borealis"))
        XCTAssertNil(A.explicit(in: "12345"))
        XCTAssertEqual(A.vanityCandidate(in: "aurora-studio"), "aurora-studio")
        XCTAssertNil(A.vanityCandidate(in: "aurora borealis"), "Several words are a title search only")
        XCTAssertNil(A.vanityCandidate(in: "极光"), "Custom profile IDs are ASCII")
        XCTAssertNil(A.vanityCandidate(in: "a"))
    }

    func testPopularityUsesOfficialRankingAndKeepsSearchFiltersAndSeparateCache() {
        var query = SteamStoreQuery()
        query.searchText = "  white smoke  "
        query.filters.select("Anime", in: .genre)
        query.typeFilter = .only([.scene])
        let ordinaryCache = query.cacheKey
        query.sortMode = .topRatedAllTime
        let url = query.url(key: key, cursor: "rank-page2")
        let fake = FakeSteam()
        XCTAssertEqual(fake.query(url, "query_type"), ["0"])
        XCTAssertEqual(fake.query(url, "search_text"), ["white smoke"])
        XCTAssertEqual(fake.query(url, "cursor"), ["rank-page2"])
        XCTAssertEqual(fake.query(url, "requiredtags"), ["Anime", "Scene"])
        XCTAssertEqual(fake.query(url, "match_all_tags"), ["true"])
        XCTAssertNotEqual(query.cacheKey, ordinaryCache)
        XCTAssertTrue(query.cacheKey.hasPrefix("workshop-rank-v2|0|topRatedAllTime|"))
        XCTAssertFalse(query.cacheKey.contains(key))
    }

    func testResponsesAreParsedLeniently() throws {
        let body: [String: Any] = ["response": [
            "total": "2",
            "next_cursor": "*",
            "publishedfiledetails": [
                detail("1", title: " 极光 ", tag: "Video", created: 1_700_000_000, updated: 1_700_000_500),
                ["publishedfileid": 2, "result": 9, "title": "被删除"],
                ["publishedfileid": "3", "result": 1, "title": "", "tags": [["tag": "web"]], "file_size": 42],
            ],
        ]]
        let page = try SteamStoreResponse.page(from: JSONSerialization.data(withJSONObject: body), requestedCursor: "*")
        XCTAssertEqual(page.items.map(\.workshopID), ["1", "3"], "Unavailable items are skipped")
        XCTAssertNil(page.nextCursor, "The same cursor means there is nothing more")
        XCTAssertEqual(page.total, 2)
        let first = page.items[0]
        XCTAssertEqual(first.title, "极光")
        XCTAssertEqual(first.type, .video)
        XCTAssertEqual(first.fileSize, 1_700_001_000, "String sizes are read")
        XCTAssertEqual(first.timeUpdated, Date(timeIntervalSince1970: 1_700_000_500))
        XCTAssertEqual(first.previewURL?.absoluteString, "https://images.example/1.gif")
        XCTAssertEqual(first.acquisitionInfo, SteamWorkshopItemInfo(workshopID: "1", title: "极光", authorName: nil,
                                                                    fileSize: first.fileSize,
                                                                    timeUpdated: first.timeUpdated))
        XCTAssertEqual(page.items[1].type, .web, "Tags are matched case-insensitively")
        XCTAssertEqual(page.items[1].title, "创意工坊 3")
        XCTAssertEqual(page.items[1].fileSize, 42)
        XCTAssertThrowsError(try SteamStoreResponse.page(from: Data("oops".utf8), requestedCursor: "*"))
    }

    // MARK: - 服务

    @MainActor
    private func makeService(_ fake: FakeSteam, key: String? = nil, cache: URL? = nil) -> SteamStoreService {
        let root = cache ?? makeRoot()
        return SteamStoreService(keyStore: MemorySteamAPIKeyStore(key), cacheDirectory: root,
                                 posters: SteamPosterCache(directory: root.appendingPathComponent("Posters"),
                                                           fetch: { try await fake.fetch($0) }),
                                 fetch: { try await fake.fetch($0) })
    }

    @MainActor
    private func waitFor(_ predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !predicate() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { XCTFail("Timed out"); throw CancellationError() }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @MainActor
    func testPopularitySwitchResetsPagingPreservesRankAndUsesSeparateCaches() async throws {
        let fake = FakeSteam()
        fake.pages["*"] = [detail("1", title: "A latest", tag: "Video", created: 300)]
        fake.popularPages["*"] = [detail("3", title: "Z first", tag: "Web", created: 100),
                                  detail("2", title: "A second", tag: "Scene", created: 200)]
        fake.popularPages["next"] = [detail("4", title: "B third", tag: "Video", created: 400)]
        fake.cursors["*"] = "next"
        let store = makeService(fake, key: key)
        store.update()
        try await waitFor { store.phase == .loaded }
        XCTAssertEqual(store.items.map(\.workshopID), ["1"])
        store.update(sortMode: .topRatedAllTime)
        try await waitFor { store.phase == .loaded }
        let popular = ContentViewOptions(sortMode: .popularity)
        XCTAssertEqual(store.displayedItems(options: popular).map(\.workshopID), ["3", "2"],
                       "Neither title nor publication date can overwrite server rank")
        store.loadMore()
        try await waitFor { store.items.count == 3 && !store.isLoadingMore }
        XCTAssertEqual(store.displayedItems(options: popular).map(\.workshopID), ["3", "2", "4"])
        let queryRequests = fake.requests.filter { $0.path.contains("QueryFiles") }
        XCTAssertEqual(queryRequests.map { fake.query($0, "query_type") }, [["1"], ["0"], ["0"]])
        XCTAssertEqual(queryRequests.map { fake.query($0, "cursor") }, [["*"], ["*"], ["next"]])

        store.update(sortMode: .recentlyPublished)
        XCTAssertEqual(store.phase, .loaded, "The original first page is a separate cached query")
        XCTAssertEqual(store.items.map(\.workshopID), ["1"])
        store.update(sortMode: .topRatedAllTime)
        XCTAssertEqual(store.items.map(\.workshopID), ["3", "2"])
        XCTAssertEqual(fake.requests.filter { $0.path.contains("QueryFiles") }.count, 3,
                       "Fresh first-page caches for different official modes remain separate")
    }

    @MainActor
    func testPopularSearchDoesNotPrependKnownAuthorsAndKeepsItsModeOnFilterChanges() async throws {
        let fake = FakeSteam()
        fake.players = ["76561190000000001": "Aurora"]
        fake.vanity["aurora"] = "76561190000000001"
        fake.pages["*"] = [detail("1", title: "known author", tag: "Scene", created: 300)]
        fake.userFiles["76561190000000001"] = fake.pages["*"]
        fake.popularPages["*"] = [detail("2", title: "popular match", tag: "Scene", created: 100)]
        let store = makeService(fake, key: key)
        store.update()
        try await waitFor { store.phase == .loaded && store.items.first?.authorName == "Aurora" }
        let authorRequests = fake.requests.filter { $0.path.contains("GetUserFiles") }.count
        store.update(searchText: "aurora", sortMode: .topRatedAllTime)
        try await waitFor { store.phase == .loaded }
        XCTAssertEqual(store.items.map(\.workshopID), ["2"])
        XCTAssertEqual(fake.requests.filter { $0.path.contains("GetUserFiles") }.count, authorRequests)
        store.update(typeFilter: .only([.scene]))
        try await waitFor { store.phase == .loaded }
        let last = try XCTUnwrap(fake.requests.last { $0.path.contains("QueryFiles") })
        XCTAssertEqual(fake.query(last, "query_type"), ["0"])
        XCTAssertEqual(fake.query(last, "search_text"), ["aurora"])
        XCTAssertEqual(fake.query(last, "requiredtags"), ["Scene"])
        store.update(searchText: "")
        try await waitFor { store.phase == .loaded }
        XCTAssertEqual(store.query.queryType, 0, "Clearing search keeps the user's popular sort")
    }

    @MainActor
    func testWithoutAKeyNothingIsRequestedAndAValidKeyStartsBrowsing() async throws {
        let fake = FakeSteam()
        fake.pages["*"] = [detail("10", title: "Sea", tag: "Video", created: 300),
                           detail("11", title: "Aurora", tag: "Web", created: 200, creator: "76561190000000002")]
        fake.cursors["*"] = "page2"
        fake.pages["page2"] = [detail("12", title: "Scene", tag: "Scene", created: 100),
                               detail("10", title: "Sea", tag: "Video", created: 300)]
        fake.cursors["page2"] = "page2"
        fake.players = ["76561190000000001": "北境", "76561190000000002": "Studio"]

        let store = makeService(fake)
        XCTAssertEqual(store.phase, .needsAPIKey)
        store.reload()
        XCTAssertEqual(store.phase, .needsAPIKey)
        XCTAssertTrue(fake.requests.isEmpty, "No key, no request")
        XCTAssertThrowsError(try store.saveAPIKey("short")) { XCTAssertEqual($0 as? SteamStoreError, .invalidKeyFormat) }

        try store.saveAPIKey(" \(key) ")
        XCTAssertTrue(store.hasAPIKey)
        try await waitFor { store.phase == .loaded && store.items.allSatisfy { $0.authorName != nil } }
        XCTAssertEqual(store.items.map(\.workshopID), ["10", "11"])
        XCTAssertEqual(store.items.map(\.authorName), ["北境", "Studio"])
        XCTAssertTrue(store.canLoadMore)

        store.loadMore()
        try await waitFor { !store.isLoadingMore && store.items.count == 3 }
        XCTAssertEqual(store.items.map(\.workshopID), ["10", "11", "12"], "Pages are appended without duplicates")
        XCTAssertFalse(store.canLoadMore, "The last page ends paging")

        // 旧本地排序选项不能覆盖 Steam 服务器的顺序。
        let requestCount = fake.requests.count
        var options = ContentViewOptions()
        XCTAssertEqual(store.displayedItems(options: options).map(\.workshopID), ["10", "11", "12"])
        options.sortMode = .name
        XCTAssertEqual(store.displayedItems(options: options).map(\.title), ["Sea", "Aurora", "Scene"])
        options.sortMode = .type
        XCTAssertEqual(store.displayedItems(options: options).map(\.type), [.video, .web, .scene])
        XCTAssertEqual(fake.requests.count, requestCount)

        // 类型筛选与搜索会重新查询。
        store.update(typeFilter: .only([.web]))
        try await waitFor { store.phase == .loaded && fake.requests.count > requestCount }
        let last = try XCTUnwrap(fake.requests.last { $0.path.contains("QueryFiles") })
        XCTAssertEqual(fake.query(last, "requiredtags"), ["Web"])
        store.update(searchText: "sea")
        try await waitFor { fake.requests.last { $0.path.contains("QueryFiles") }.map { fake.query($0, "search_text") } == ["sea"] }

        store.removeAPIKey()
        XCTAssertEqual(store.phase, .needsAPIKey)
        XCTAssertTrue(store.items.isEmpty)
    }

    @MainActor
    func testWorkshopDisplayKeepsServerOrderEvenWhenTitlesAndDatesDisagree() async throws {
        let fake = FakeSteam()
        fake.pages["*"] = [detail("3", title: "Z first", tag: "Video", created: 100),
                           detail("2", title: "A second", tag: "Web", created: 300),
                           detail("1", title: "B third", tag: "Scene", created: 200)]
        let store = makeService(fake, key: key)
        store.update(searchText: "囍")
        try await waitFor { store.phase == .loaded }
        XCTAssertEqual(store.displayedItems(options: ContentViewOptions()).map(\.workshopID), ["3", "2", "1"],
                       "The old default publication sort must not overwrite search relevance")
    }

    @MainActor
    func testDuplicateIDsWithinAnAppendedPageKeepTheFirstServerOccurrence() async throws {
        let fake = FakeSteam()
        fake.pages["*"] = [detail("1", title: "First", tag: "Video", created: 100)]
        fake.cursors["*"] = "next"
        fake.pages["next"] = [detail("2", title: "First appearance", tag: "Scene", created: 200),
                              detail("2", title: "Later appearance", tag: "Scene", created: 300),
                              detail("1", title: "Previously seen", tag: "Video", created: 400)]
        let store = makeService(fake, key: key)
        store.update()
        try await waitFor { store.phase == .loaded }
        store.loadMore()
        try await waitFor { !store.isLoadingMore }
        XCTAssertEqual(store.items.map(\.workshopID), ["1", "2"])
        XCTAssertEqual(store.items.last?.title, "First appearance")
    }

    /// 钥匙串授权：启动时只确认 Key 存在（不读内容，不会请求授权）；之后整个运行期间最多读取一次，
    /// 搜索、筛选、翻页都不再访问钥匙串。
    @MainActor
    func testTheKeyIsReadFromItsStoreAtMostOncePerLaunch() async throws {
        let fake = FakeSteam()
        fake.pages["*"] = [detail("10", title: "Sea", tag: "Video", created: 300)]
        fake.cursors["*"] = "page2"
        fake.pages["page2"] = [detail("12", title: "Scene", tag: "Scene", created: 100)]
        fake.cursors["page2"] = "page2"
        let keys = CountingSteamAPIKeyStore(key)
        let root = makeRoot()
        let store = SteamStoreService(keyStore: keys, cacheDirectory: root,
                                      posters: SteamPosterCache(directory: root.appendingPathComponent("Posters"),
                                                                fetch: { try await fake.fetch($0) }),
                                      fetch: { try await fake.fetch($0) })
        XCTAssertTrue(store.hasAPIKey)
        XCTAssertEqual(store.phase, .loading)
        XCTAssertEqual(keys.loads, 0, "Launch only checks that a key exists")

        store.reload()
        try await waitFor { store.phase == .loaded }
        store.loadMore()
        try await waitFor { !store.isLoadingMore && store.items.count == 2 }
        store.update(searchText: "sea")
        try await waitFor { store.phase == .loaded }
        store.update(typeFilter: .only([.web]))
        try await waitFor { store.phase == .loaded }
        XCTAssertEqual(keys.loads, 1, "One read for the whole session")

        store.removeAPIKey()
        store.reload()
        XCTAssertEqual(store.phase, .needsAPIKey, "A removed key is not served from memory")
        try store.saveAPIKey(key)
        try await waitFor { store.phase == .loaded }
        XCTAssertEqual(keys.loads, 2, "Only the check after removal read the store again")
    }

    @MainActor
    func testFailuresInvalidKeysAndOfflineCache() async throws {
        let fake = FakeSteam()
        fake.pages["*"] = [detail("20", title: "缓存", tag: "Video", created: 1)]
        let cache = makeRoot()
        let store = makeService(fake, key: key, cache: cache)
        XCTAssertEqual(store.phase, .loading)
        store.reload()
        try await waitFor { store.phase == .loaded }
        XCTAssertFalse(store.isShowingCachedResults)

        // 离线：新的服务（没有内存缓存）显示磁盘上的第一页，并说明。
        fake.offline = true
        let offline = makeService(fake, key: key, cache: cache)
        offline.reload()
        try await waitFor { offline.phase == .loaded }
        XCTAssertTrue(offline.isShowingCachedResults)
        XCTAssertEqual(offline.items.map(\.workshopID), ["20"])
        XCTAssertFalse(offline.canLoadMore)

        let empty = makeService(fake, key: key)
        empty.reload()
        try await waitFor { if case .failed = empty.phase { return true } else { return false } }
        XCTAssertEqual(empty.phase, .failed(SteamStoreError.network.localizedDescription))

        fake.offline = false
        fake.status = 403
        let rejected = makeService(fake, key: key)
        rejected.reload()
        try await waitFor { rejected.phase == .invalidKey }

        // 磁盘缓存不包含 API Key。
        let files = try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "json" {
            XCTAssertFalse(try String(contentsOf: file).contains(key))
        }
    }

    // MARK: - R4 作者搜索与翻页保护

    @MainActor
    func testProfileLinksListTheAuthorsWallpapersWithTheSameContentRules() async throws {
        let fake = FakeSteam()
        let author = "76561198000000009"
        var works: [[String: Any]] = (0..<31).map { detail("9\($0)", title: "作品 \($0)", tag: "Video", created: 500 - $0, creator: author) }
        var adult = detail("8001", title: "成人", tag: "Video", created: 600, creator: author)
        adult["tags"] = [["tag": "Video"], ["tag": "Mature"]]
        works.insert(adult, at: 0)
        works.insert(detail("8002", title: "应用", tag: "Application", created: 601, creator: author), at: 0)
        fake.userFiles[author] = works
        fake.players = [author: "北境"]
        let store = makeService(fake, key: key)
        store.setHiddenAgeRatings(["Mature"])   // 设置中开启「隐藏成人」时，作者的壁纸同样遵守
        store.update(searchText: "https://steamcommunity.com/profiles/\(author)/")
        try await waitFor { store.phase == .loaded }
        let request = try XCTUnwrap(fake.requests.first { $0.path.contains("GetUserFiles") })
        XCTAssertEqual(fake.query(request, "steamid"), [author])
        XCTAssertEqual(fake.query(request, "appid"), ["431960"])
        XCTAssertEqual(fake.query(request, "page"), ["1"])
        XCTAssertFalse(fake.requests.contains { $0.path.contains("QueryFiles") }, "A profile link is not a title search")
        XCTAssertFalse(store.items.contains { $0.workshopID == "8001" }, "Hidden by the user's setting, like the normal query")
        XCTAssertFalse(store.items.contains { $0.workshopID == "8002" }, "Only playable types, like the normal query")
        XCTAssertEqual(store.items.count, 28)
        XCTAssertEqual(store.loadMoreState, .idle)

        store.loadMore()
        try await waitFor { store.loadMoreState == .exhausted }
        XCTAssertEqual(fake.query(try XCTUnwrap(fake.requests.last { $0.path.contains("GetUserFiles") }), "page"), ["2"])
        XCTAssertEqual(store.items.count, 31, "All of the author's wallpapers, no duplicates")
    }

    @MainActor
    func testCustomProfileLinksResolveAndUnknownOnesSayWhy() async throws {
        let fake = FakeSteam()
        fake.vanity = ["aurora": "76561198000000010"]
        fake.userFiles["76561198000000010"] = [detail("70", title: "极光", tag: "Web", created: 1, creator: "76561198000000010")]
        let store = makeService(fake, key: key)
        store.update(searchText: "https://steamcommunity.com/id/aurora/")
        try await waitFor { store.phase == .loaded }
        XCTAssertEqual(store.items.map(\.workshopID), ["70"])

        store.update(searchText: "https://steamcommunity.com/id/nobody/")
        try await waitFor { if case .failed = store.phase { return true } else { return false } }
        XCTAssertEqual(store.phase, .failed(SteamStoreError.authorNotFound("nobody").localizedDescription))
    }

    @MainActor
    func testKeywordsUseOnlyServerCandidatesRatherThanKnownAuthors() async throws {
        let fake = FakeSteam()
        let north = "76561190000000001", studio = "76561190000000002"
        fake.pages["*"] = [detail("10", title: "Sea", tag: "Video", created: 300, creator: north),
                           detail("11", title: "Aurora", tag: "Web", created: 200, creator: studio)]
        fake.players = [north: "北境 North", studio: "Studio"]
        fake.vanity = ["studio": studio]
        fake.userFiles[studio] = [detail("11", title: "Aurora", tag: "Web", created: 200, creator: studio),
                                  detail("12", title: "Nebula", tag: "Scene", created: 100, creator: studio)]
        let store = makeService(fake, key: key)
        store.reload()
        try await waitFor { store.phase == .loaded && store.items.allSatisfy { $0.authorName != nil } }

        // 本机已知的作者名包含 north，不能注入关键词候选。
        fake.pages["*"] = [detail("30", title: "North wind", tag: "Video", created: 50, creator: studio)]
        store.update(searchText: "north")
        try await waitFor { store.phase == .loaded }
        XCTAssertEqual(store.items.map(\.workshopID), ["30"], "Keyword candidates must come only from Steam text search")

        // 单个词碰巧也是作者自定义 ID，仍是普通服务器文字搜索。
        fake.pages["*"] = [detail("31", title: "Studio lights", tag: "Video", created: 40, creator: north),
                           detail("12", title: "Nebula", tag: "Scene", created: 100, creator: studio)]
        store.update(searchText: "studio")
        try await waitFor { store.phase == .loaded }
        XCTAssertEqual(store.items.map(\.workshopID), ["31", "12"],
                       "A keyword matching a vanity ID must not prepend an unrelated author list")
        let search = try XCTUnwrap(fake.requests.last { $0.path.contains("QueryFiles") })
        XCTAssertEqual(fake.query(search, "query_type"), ["12"])
        XCTAssertEqual(fake.query(search, "search_text"), ["studio"])
    }

    @MainActor
    func testRepeatedCursorsAndDuplicatePagesNeverLoopForever() async throws {
        let fake = FakeSteam()
        fake.pages["*"] = [detail("1", title: "A", tag: "Video", created: 3)]
        fake.cursors["*"] = "a"
        fake.pages["a"] = [detail("2", title: "B", tag: "Video", created: 2)]
        fake.cursors["a"] = "*"   // 后端回到已请求过的游标
        let store = makeService(fake, key: key)
        store.reload()
        try await waitFor { store.phase == .loaded }
        store.loadMore()
        try await waitFor { store.loadMoreState != .loading }
        XCTAssertEqual(store.items.map(\.workshopID), ["1", "2"])
        XCTAssertEqual(store.loadMoreState, .exhausted, "A cursor that was already requested ends paging")

        // 游标一直前进，但每页只有重复项目：几页之后报告无法继续，而不是一直请求。
        let dupes = FakeSteam()
        dupes.pages["*"] = [detail("1", title: "A", tag: "Video", created: 3)]
        dupes.cursors["*"] = "c1"
        for index in 1...5 {
            dupes.pages["c\(index)"] = [detail("1", title: "A", tag: "Video", created: 3)]
            dupes.cursors["c\(index)"] = "c\(index + 1)"
        }
        let stalled = makeService(dupes, key: key)
        stalled.reload()
        try await waitFor { stalled.phase == .loaded }
        for _ in 0..<SteamStoreService.maximumStalledPages {
            stalled.loadMore()
            try await waitFor { stalled.loadMoreState != .loading }
        }
        XCTAssertEqual(stalled.loadMoreState, .failed(NSLocalizedString("steam.store.loadMore.noProgress", comment: "")))
        let before = dupes.requests.count
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(dupes.requests.count, before, "No request loop")
    }

    @MainActor
    func testAStaleResponseNeitherAppendsNorEndsTheNewQuerysLoading() async throws {
        let fake = FakeSteam()
        fake.pages["*"] = [detail("1", title: "A", tag: "Video", created: 3)]
        fake.cursors["*"] = "next"
        fake.pages["next"] = [detail("2", title: "B", tag: "Video", created: 2)]
        let store = makeService(fake, key: key)
        store.reload()
        try await waitFor { store.phase == .loaded }
        store.loadMore()
        XCTAssertEqual(store.loadMoreState, .loading)
        store.update(searchText: "other words")   // 查询改变：旧的下一页不能追加到新结果
        try await waitFor { store.phase == .loaded }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(store.items.contains { $0.workshopID == "2" }, "The old page is ignored")
        XCTAssertEqual(store.items.map(\.workshopID), ["1"])
    }

    // MARK: - Workshop Search & Sorting Revision

    func testSixWorkshopModesUseTheirOwnPublishedFileBackendEnumAndLabels() throws {
        let expected: [(SteamWorkshopSortMode, Int, String)] = [
            (.mostPopular, 3, "最热门"), (.topRatedAllTime, 0, "最受好评（发布至今）"),
            (.recentlyPublished, 1, "最近发行"), (.recentlyUpdated, 21, "最新更新"),
            (.searchRelevance, 12, "搜索相关度"), (.totalUniqueSubscribers, 9, "不重复订阅者总计")
        ]
        XCTAssertEqual(SteamWorkshopSortMode.allCases, expected.map(\.0))
        XCTAssertEqual(Set(SteamWorkshopSortMode.allCases).count, 6)
        XCTAssertEqual(ContentSortMode.available(inSteamStore: false), [.dateAdded, .name, .type],
                       "Local/favorites/list sorting stays exactly as before")
        for (mode, raw, title) in expected {
            var query = SteamStoreQuery()
            query.searchText = "囍"; query.sortMode = mode
            XCTAssertEqual(query.publishedFileQueryType.rawValue, raw)
            XCTAssertEqual(NSLocalizedString(mode.titleKey, comment: ""), title)
            let url = query.url(key: key, cursor: "official-page")
            let values = FakeSteam()
            XCTAssertEqual(values.query(url, "query_type"), [String(raw)])
            XCTAssertEqual(values.query(url, "search_text"), ["囍"])
            XCTAssertEqual(values.query(url, "language"), ["0"])
            XCTAssertEqual(values.query(url, "days"), mode == .mostPopular ? ["7"] : [])
            XCTAssertEqual(values.query(url, "include_recent_votes_only"), mode == .mostPopular ? ["false"] : [])
        }
        XCTAssertEqual(SteamPublishedFileQueryType.rankedByTextSearch.rawValue, 12,
                       "11 in this API is votes-up; ISteamUGC's text search is a different enum")
        XCTAssertEqual(SteamPublishedFileQueryType.rankedByLastUpdatedDate.rawValue, 21)
        XCTAssertEqual(SteamPublishedFileQueryType.rankedByTotalUniqueSubscriptions.rawValue, 9)
    }

    func testCacheIncludesOfficialModeLanguageTrendAndFiltersAndInvalidatesOldRankCaches() {
        var query = SteamStoreQuery(); query.searchText = "囍"
        let modes = SteamWorkshopSortMode.allCases.map { mode -> String in
            var value = query; value.sortMode = mode; return value.cacheKey
        }
        XCTAssertEqual(Set(modes).count, 6)
        let original = query.cacheKey
        query.language = 6
        XCTAssertNotEqual(query.cacheKey, original)
        let translated = query.cacheKey
        query.filters.select("Anime", in: .genre)
        XCTAssertNotEqual(query.cacheKey, translated)
        let filtered = query.cacheKey
        query.hiddenAgeRatings = ["Mature"]
        XCTAssertNotEqual(query.cacheKey, filtered)
        XCTAssertTrue(query.cacheKey.hasPrefix("workshop-rank-v2|"), "Old author-boost caches cannot be reused")
        XCTAssertFalse(query.cacheKey.contains(key))
    }

    @MainActor
    func testNewKeywordDefaultsToRelevanceManualSortAndClearingQueryStayCoherent() async throws {
        let fake = FakeSteam(); let store = makeService(fake, key: key)
        store.update()
        try await waitFor { store.phase == .loaded }
        XCTAssertEqual(store.query.effectiveSortMode, .recentlyPublished, "Retain the previous empty-page default")
        store.update(sortMode: .mostPopular)
        try await waitFor { store.phase == .loaded }
        store.update(searchText: "囍")
        try await waitFor { store.phase == .loaded }
        XCTAssertEqual(store.query.effectiveSortMode, .searchRelevance)
        store.update(sortMode: .totalUniqueSubscribers)
        try await waitFor { store.phase == .loaded }
        store.update(filters: SteamFilterState())
        store.update(searchText: " 囍 ")
        XCTAssertEqual(store.query.effectiveSortMode, .totalUniqueSubscribers, "Editing only whitespace does not erase manual choice")
        store.update(typeFilter: .only([.scene]))
        try await waitFor { store.phase == .loaded }
        XCTAssertEqual(store.query.queryType, 9)
        store.update(searchText: "赛博朋克")
        try await waitFor { store.phase == .loaded }
        XCTAssertEqual(store.query.queryType, 12, "A new submitted keyword resets to relevance")
        store.update(searchText: "")
        try await waitFor { store.phase == .loaded }
        XCTAssertEqual(store.query.sortMode, .recentlyPublished)
        store.update(sortMode: .searchRelevance)
        XCTAssertEqual(store.query.sortMode, .recentlyPublished, "No empty RankedByTextSearch is sent or checked")
        XCTAssertFalse(fake.requests.contains { fake.query($0, "query_type") == ["12"] && fake.query($0, "search_text").isEmpty })
    }

    @MainActor
    func testSixKeywordsBySixModesKeepOfficialQueryPaginationRankAndIdentity() async throws {
        let terms = ["囍", "赛博朋克", "Aurora", "Cyberpunk 2077", "no-such-kinetic-fixture-93d2", "spongebob"]
        let mappings: [(SteamWorkshopSortMode, String)] = [(.mostPopular, "3"), (.topRatedAllTime, "0"),
            (.recentlyPublished, "1"), (.recentlyUpdated, "21"), (.searchRelevance, "12"), (.totalUniqueSubscribers, "9")]
        let fake = FakeSteam(); let store = makeService(fake, key: key)
        fake.players = ["76561190000000001": "Known metadata"]
        var index = 0
        for term in terms {
            for (mode, raw) in mappings {
                index += 1
                let first = String(10000 + index * 10), second = String(10001 + index * 10)
                let third = String(10002 + index * 10), fourth = String(10003 + index * 10)
                let cursor = "matrix-\(index)"
                let noResults = term.hasPrefix("no-such-")
                fake.queryPages["\(raw)|\(term)|*"] = noResults ? [] : [
                    detail(first, title: "Z highest server rank", tag: "Scene", created: 100),
                    detail(second, title: "A lower server rank", tag: "Scene", created: 300),
                    detail(first, title: "duplicate later", tag: "Scene", created: 500)]
                fake.cursors["*"] = noResults ? "*" : cursor
                fake.queryPages["\(raw)|\(term)|\(cursor)"] = [
                    detail(second, title: "previous page duplicate", tag: "Scene", created: 600),
                    detail(third, title: "A lower server rank", tag: "Scene", created: 700),
                    detail(third, title: "duplicate within page", tag: "Scene", created: 800),
                    detail(fourth, title: "Z highest server rank", tag: "Scene", created: 900)]
                fake.cursors[cursor] = cursor
                var filters = SteamFilterState(); filters.toggleType("Scene"); filters.select("Anime", in: .genre)
                store.update(searchText: term, filters: filters, sortMode: mode)
                try await waitFor { store.phase == .loaded }
                let firstRequest = try XCTUnwrap(fake.requests.last { $0.path.contains("QueryFiles") })
                XCTAssertEqual(fake.query(firstRequest, "query_type"), [raw])
                XCTAssertEqual(fake.query(firstRequest, "search_text"), [term])
                XCTAssertEqual(fake.query(firstRequest, "cursor"), ["*"])
                XCTAssertEqual(fake.query(firstRequest, "requiredtags"), ["Anime", "Scene"])
                XCTAssertEqual(store.items.map(\.workshopID), noResults ? [] : [first, second])
                if noResults { XCTAssertFalse(store.canLoadMore); continue }
                XCTAssertEqual(store.items.map(\.serverRankIndex), [0, 1])
                store.loadMore()
                try await waitFor { !store.isLoadingMore }
                let nextRequest = try XCTUnwrap(fake.requests.last { $0.path.contains("QueryFiles") })
                XCTAssertEqual(fake.query(nextRequest, "query_type"), [raw])
                XCTAssertEqual(fake.query(nextRequest, "search_text"), [term])
                XCTAssertEqual(fake.query(nextRequest, "cursor"), [cursor])
                XCTAssertEqual(fake.query(nextRequest, "requiredtags"), fake.query(firstRequest, "requiredtags"))
                XCTAssertEqual(fake.query(nextRequest, "language"), fake.query(firstRequest, "language"))
                XCTAssertEqual(store.items.map(\.workshopID), [first, second, third, fourth])
                XCTAssertEqual(store.items.map(\.serverRankIndex), [0, 1, 4, 6])
                XCTAssertEqual(store.items.first?.title, "Z highest server rank")
                XCTAssertEqual(store.items[1].title, store.items[2].title, "Equal titles with different IDs remain distinct")
                XCTAssertEqual(store.displayedItems(options: ContentViewOptions(sortMode: .name)).map(\.workshopID),
                               [first, second, third, fourth], "No local secondary ranking")
                XCTAssertFalse(store.canLoadMore)
            }
        }
        XCTAssertFalse(fake.requests.contains { $0.path.contains("GetUserFiles") || $0.path.contains("ResolveVanityURL") })
    }

    @MainActor
    func testLateOldFirstPageAndMetadataCannotMoveNewResults() async throws {
        let old = [detail("1", title: "old", tag: "Video", created: 100)]
        let current = [detail("3", title: "Z", tag: "Video", created: 100, creator: "76561190000000003"),
                       detail("2", title: "A", tag: "Video", created: 900, creator: "76561190000000002")]
        var held: CheckedContinuation<(Data, Int), Error>?
        var metadata: CheckedContinuation<(Data, Int), Error>?
        let root = makeRoot()
        let store = SteamStoreService(keyStore: MemorySteamAPIKeyStore(key), cacheDirectory: root,
            posters: SteamPosterCache(directory: nil), fetch: { url in
                let args = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                if url.path.contains("GetPlayerSummaries") {
                    return try await withCheckedThrowingContinuation { metadata = $0 }
                }
                if args.first(where: { $0.name == "search_text" })?.value == "old" {
                    return try await withCheckedThrowingContinuation { held = $0 }
                }
                return (try JSONSerialization.data(withJSONObject: ["response": ["publishedfiledetails": current]]), 200)
            })
        store.update(searchText: "old")
        try await waitFor { held != nil }
        store.update(searchText: "囍", sortMode: .recentlyUpdated)
        try await waitFor { store.phase == .loaded && metadata != nil }
        XCTAssertEqual(store.items.map(\.workshopID), ["3", "2"])
        let initialRanks = store.items.map(\.serverRankIndex)
        held?.resume(returning: (try JSONSerialization.data(withJSONObject: ["response": ["publishedfiledetails": old]]), 200))
        held = nil
        metadata?.resume(returning: (try JSONSerialization.data(withJSONObject: ["response": ["players": [
            ["steamid": "76561190000000002", "personaname": "A metadata arrived first"],
            ["steamid": "76561190000000003", "personaname": "Z metadata arrived later"]]]]), 200))
        metadata = nil
        try await waitFor { store.items.allSatisfy { $0.authorName != nil } }
        XCTAssertEqual(store.items.map(\.workshopID), ["3", "2"])
        XCTAssertEqual(store.items.map(\.serverRankIndex), initialRanks)
        XCTAssertEqual(store.query.queryType, 21)
        XCTAssertEqual(store.query.trimmedSearch, "囍")
    }

    func testDebugSearchDiagnosticContainsThirtyServerRanksButNoCredentials() throws {
        #if DEBUG
        var query = SteamStoreQuery(); query.searchText = "Cyberpunk 2077"; query.sortMode = .searchRelevance
        let items = (0..<40).map { index -> SteamStoreItem in
            var item = SteamStoreResponse.item(from: detail(String(index + 1), title: "Item \(index)", tag: "Video", created: index))!
            item.serverRankIndex = index; return item
        }
        let text = SteamSearchDiagnostics.snapshot(query: query, cursor: "next", source: "server", server: items, display: items)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual((body["SERVER"] as? [[String: Any]])?.count, 30)
        XCTAssertEqual((body["DISPLAY"] as? [[String: Any]])?.count, 30)
        XCTAssertEqual(body["steamQueryType"] as? Int, 12)
        XCTAssertEqual(body["backend"] as? String, "IPublishedFileService.QueryFiles")
        XCTAssertEqual(body["cursorOrPage"] as? String, "next")
        XCTAssertFalse(text.contains(key)); XCTAssertFalse(text.contains("api.steampowered.com"))
        XCTAssertNil(body["key"]); XCTAssertNil(body["session"]); XCTAssertNil(body["password"])
        #endif
    }

    // MARK: - 卡片状态与 Poster

    @MainActor
    func testCardStatesFollowTheLocalLibraryAndDownloads() throws {
        let item = SteamStoreItem(workshopID: "30", title: "极光", previewURL: nil, creatorSteamID: nil, authorName: nil,
                                  timeCreated: nil, timeUpdated: Date(timeIntervalSince1970: 200), fileSize: nil,
                                  type: .web, tags: [])
        typealias S = SteamStoreCardState
        XCTAssertEqual(S.resolve(item: item, record: nil, task: nil), .remote)
        XCTAssertEqual(S.resolve(item: item, record: nil, task: .queued), .downloading(progress: nil))
        XCTAssertEqual(S.resolve(item: item, record: nil, task: .downloading(progress: 0.4)), .downloading(progress: 0.4))
        XCTAssertEqual(S.resolve(item: item, record: nil, task: .failed("x")), .failed("x"))

        let record = Wallpaper(name: "极光", type: .web, acquisitionOrigin: .steamWorkshop,
                               resourceURL: URL(fileURLWithPath: "/tmp/30"),
                               steamMetadata: SteamMetadata(workshopID: "30", remoteUpdatedAt: Date(timeIntervalSince1970: 200)))
        XCTAssertEqual(S.resolve(item: item, record: record, task: .finished(record.id)), .inLibrary(record.id))
        XCTAssertEqual(S.resolve(item: item, record: record, task: .failed("x")), .inLibrary(record.id),
                       "A failed update keeps the card in the library")
        var older = record
        older.steamMetadata = SteamMetadata(workshopID: "30", remoteUpdatedAt: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(S.resolve(item: item, record: older, task: nil), .updateAvailable(record.id))
        var unknown = record
        unknown.steamMetadata = SteamMetadata(workshopID: "30")
        XCTAssertEqual(S.resolve(item: item, record: unknown, task: nil), .inLibrary(record.id))
        XCTAssertEqual(SteamStoreCard.metadataText(for: item), "网页")
        var named = item
        named.authorName = "北境"
        XCTAssertEqual(SteamStoreCard.metadataText(for: named), "网页 · 北境")
    }

    @MainActor
    func testPostersAreCachedOnDisk() async throws {
        var downloads = 0
        let root = makeRoot()
        let cache = SteamPosterCache(directory: root, fetch: { url in
            downloads += 1
            return url.lastPathComponent == "broken.gif" ? (Data(), 404) : (Data("GIF89a".utf8), 200)
        })
        let item = SteamStoreItem(workshopID: "40", title: "t", previewURL: URL(string: "https://images.example/a.gif"),
                                  creatorSteamID: nil, authorName: nil, timeCreated: nil, timeUpdated: nil,
                                  fileSize: nil, type: .video, tags: [])
        XCTAssertNil(cache.cachedURL(for: item))
        let loaded = await cache.load(item)
        let file = try XCTUnwrap(loaded)
        XCTAssertEqual(try Data(contentsOf: file), Data("GIF89a".utf8))
        XCTAssertEqual(cache.cachedURL(for: item), file)
        _ = await cache.load(item)
        XCTAssertEqual(downloads, 1, "Scrolling back never downloads the poster again")

        let changed = SteamStoreItem(workshopID: "40", title: "t", previewURL: URL(string: "https://images.example/b.gif"),
                                     creatorSteamID: nil, authorName: nil, timeCreated: nil, timeUpdated: nil,
                                     fileSize: nil, type: .video, tags: [])
        XCTAssertNotEqual(cache.fileURL(for: changed), file, "A new author poster gets a new cache file")
        let broken = SteamStoreItem(workshopID: "41", title: "t", previewURL: URL(string: "https://images.example/broken.gif"),
                                    creatorSteamID: nil, authorName: nil, timeCreated: nil, timeUpdated: nil,
                                    fileSize: nil, type: nil, tags: [])
        let missing = await cache.load(broken)
        XCTAssertNil(missing)
    }

    @MainActor
    func testBrowsingNeverWritesToTheLocalLibrary() async throws {
        let root = makeRoot()
        let library = WallpaperLibrary(storage: LibraryStorageLocation(rootURL: root.appendingPathComponent("Library")))
        let fake = FakeSteam()
        fake.pages["*"] = [detail("50", title: "海浪", tag: "Video", created: 1)]
        let store = makeService(fake, key: key)
        store.reload()
        try await waitFor { store.phase == .loaded }
        XCTAssertTrue(library.wallpapers.isEmpty)
        XCTAssertNil(library.wallpaper(workshopID: "50"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.storage.libraryFileURL.path))
    }
}

/// 记录读取 Key 内容的次数（真实钥匙串每次读取都可能请求授权）。
private final class CountingSteamAPIKeyStore: SteamAPIKeyStoring {
    private var key: String?
    private(set) var loads = 0
    init(_ key: String?) { self.key = key }
    var hasStoredKey: Bool { key?.isEmpty == false }
    func load() -> String? { loads += 1; return key }
    func save(_ key: String) throws { self.key = key }
    func remove() { key = nil }
}
