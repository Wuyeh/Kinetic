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
        var cursors: [String: String] = [:]
        var status = 200
        var offline = false
        var players: [String: String] = [:]

        func fetch(_ url: URL) async throws -> (Data, Int) {
            record(url)
            if offline { throw URLError(.notConnectedToInternet) }
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if url.path.contains("GetPlayerSummaries") {
                let ids = items.first { $0.name == "steamids" }?.value?.split(separator: ",").map(String.init) ?? []
                let list = ids.compactMap { id in players[id].map { ["steamid": id, "personaname": $0] } }
                return (try JSONSerialization.data(withJSONObject: ["response": ["players": list]]), 200)
            }
            let cursor = items.first { $0.name == "cursor" }?.value ?? "*"
            let body: [String: Any] = ["response": ["total": 99,
                                                    "publishedfiledetails": pages[cursor] ?? [],
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
        XCTAssertEqual(items.filter { $0.name.hasPrefix("excludedtags[") }.map(\.value), ["Mature", "Questionable"])

        query.searchText = "  极光  "
        query.typeFilter = .only([.video])
        let search = query.url(key: key, cursor: "abc")
        let searchItems = URLComponents(url: search, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(searchItems.first { $0.name == "query_type" }?.value, "11", "Searching ranks by relevance")
        XCTAssertEqual(searchItems.first { $0.name == "search_text" }?.value, "极光")
        XCTAssertEqual(searchItems.filter { $0.name.hasPrefix("requiredtags[") }.map(\.value), ["Video"])
        XCTAssertFalse(query.cacheKey.contains(key))
        XCTAssertTrue(SteamStoreService.isValidKeyFormat(key))
        XCTAssertFalse(SteamStoreService.isValidKeyFormat("not-a-key"))
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

        // 排序只在已加载的结果上进行，不重新请求。
        let requestCount = fake.requests.count
        var options = ContentViewOptions()
        XCTAssertEqual(store.displayedItems(options: options).map(\.workshopID), ["10", "11", "12"])
        options.sortMode = .name
        XCTAssertEqual(store.displayedItems(options: options).map(\.title), ["Aurora", "Scene", "Sea"])
        options.sortMode = .type
        XCTAssertEqual(store.displayedItems(options: options).map(\.type), [.scene, .web, .video])
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
