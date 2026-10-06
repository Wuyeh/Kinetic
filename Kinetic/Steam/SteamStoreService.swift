import Combine
import CryptoKit
import Foundation
import Security

// MARK: - Steam Web API Key

/// 用户自己的 Steam Web API Key（用户决定：在线商店用官方接口，Key 由用户在设置中填写一次）。
protocol SteamAPIKeyStoring: AnyObject {
    /// 只确认是否保存过 Key，不读取内容（钥匙串不会因此请求授权）。
    var hasStoredKey: Bool { get }
    func load() -> String?
    func save(_ key: String) throws
    func remove()
}

/// 保存在钥匙串中，不写入 UserDefaults、资料库或日志。
final class KeychainSteamAPIKeyStore: SteamAPIKeyStoring {
    private let service = "com.kinetic.app.steam-web-api-key"
    private let account = "default"

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// 只读属性、不读密钥内容：macOS 不会为此弹出钥匙串授权。
    var hasStoredKey: Bool {
        var query = baseQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ key: String) throws {
        remove()
        var item = baseQuery
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SteamStoreError.keychain(Int(status))
        }
    }

    func remove() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

/// 测试与没有钥匙串的环境使用。
final class MemorySteamAPIKeyStore: SteamAPIKeyStoring {
    private var key: String?
    init(_ key: String? = nil) { self.key = key }
    var hasStoredKey: Bool { key?.isEmpty == false }
    func load() -> String? { key }
    func save(_ key: String) throws { self.key = key }
    func remove() { key = nil }
}

enum SteamStoreError: LocalizedError, Equatable {
    case invalidKeyFormat
    case invalidKey
    case network
    case server(Int)
    case unreadable
    case keychain(Int)

    var errorDescription: String? {
        switch self {
        case .invalidKeyFormat: return NSLocalizedString("steam.store.error.keyFormat", comment: "")
        case .invalidKey: return NSLocalizedString("steam.store.error.invalidKey", comment: "")
        case .network: return NSLocalizedString("steam.error.network", comment: "")
        case .server(let status): return String(format: NSLocalizedString("steam.store.error.server", comment: ""), status)
        case .unreadable: return NSLocalizedString("steam.store.error.unreadable", comment: "")
        case .keychain(let status): return String(format: NSLocalizedString("steam.store.error.keychain", comment: ""), status)
        }
    }
}

// MARK: - 在线项目

/// 在线商店中的一个创意工坊项目（规格 24：远程表示，与本地 `Wallpaper` 分开，用创意工坊编号关联）。
struct SteamStoreItem: Identifiable, Equatable, Codable, Sendable {
    let workshopID: String
    let title: String
    let previewURL: URL?
    let creatorSteamID: String?
    var authorName: String?
    let timeCreated: Date?
    let timeUpdated: Date?
    let fileSize: Int64?
    let type: WallpaperType?
    let tags: [String]

    var id: String { workshopID }

    /// 交给 Module 9 下载入库的信息。
    var acquisitionInfo: SteamWorkshopItemInfo {
        SteamWorkshopItemInfo(workshopID: workshopID, title: title, authorName: authorName,
                              fileSize: fileSize, timeUpdated: timeUpdated)
    }
}

/// 卡片状态（规格 9：Remote / Downloading / In Library / Failed / Update Available）。
enum SteamStoreCardState: Equatable {
    case remote
    case downloading(progress: Double?)
    case inLibrary(Wallpaper.ID)
    case updateAvailable(Wallpaper.ID)
    case failed(String)

    static func resolve(item: SteamStoreItem, record: Wallpaper?,
                        task: SteamAcquisitionService.TaskPhase?) -> SteamStoreCardState {
        switch task {
        case .queued?: return .downloading(progress: nil)
        case .downloading(let progress)?: return .downloading(progress: progress)
        case .verifying?, .importing?: return .downloading(progress: 1)
        case .failed(let message)? where record == nil: return .failed(message)
        default: break
        }
        guard let record else { return .remote }
        if let remote = item.timeUpdated, let local = record.steamMetadata?.remoteUpdatedAt, remote > local {
            return .updateAvailable(record.id)
        }
        return .inLibrary(record.id)
    }
}

// MARK: - 查询

/// 一次在线查询（`IPublishedFileService/QueryFiles`）。排序选项来自 Content Header：
/// - 没有搜索词时按发布时间（= Steam 页面的「添加时间」）从新到旧；有搜索词时按相关度。
/// - 「名称」「类型」排序作用于已经加载的结果（官方接口没有按名称排序）。
/// - 类型筛选转换为 Wallpaper Engine 的类型标签；默认排除成人内容标签。
struct SteamStoreQuery: Equatable {
    var searchText: String = ""
    var typeFilter: ContentTypeFilter = .all

    static let pageSize = 30
    static let endpoint = URL(string: "https://api.steampowered.com/IPublishedFileService/QueryFiles/v1/")!
    static let playerSummaries = URL(string: "https://api.steampowered.com/ISteamUser/GetPlayerSummaries/v2/")!
    static let typeTags: [(WallpaperType, String)] = [(.scene, "Scene"), (.web, "Web"), (.video, "Video")]
    /// 默认不显示成人与可疑内容。
    static let excludedTags = ["Mature", "Questionable"]

    var trimmedSearch: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// EPublishedFileQueryType：1 = 按发布时间，11 = 按文字搜索相关度。
    var queryType: Int { trimmedSearch.isEmpty ? 1 : 11 }

    var requiredTags: [String] {
        Self.typeTags.filter { typeFilter.includes($0.0) }.map(\.1)
    }

    /// 缓存键：不包含 API Key。
    var cacheKey: String { "\(queryType)|\(trimmedSearch.lowercased())|\(requiredTags.joined(separator: ","))" }

    func url(key: String, cursor: String) -> URL {
        var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "appid", value: SteamWorkshop.wallpaperEngineAppID),
            URLQueryItem(name: "query_type", value: String(queryType)),
            URLQueryItem(name: "cursor", value: cursor),
            URLQueryItem(name: "numperpage", value: String(Self.pageSize)),
            URLQueryItem(name: "return_tags", value: "true"),
            URLQueryItem(name: "return_metadata", value: "false"),
            URLQueryItem(name: "match_all_tags", value: "false"),
        ]
        if !trimmedSearch.isEmpty { items.append(URLQueryItem(name: "search_text", value: trimmedSearch)) }
        for (index, tag) in requiredTags.enumerated() {
            items.append(URLQueryItem(name: "requiredtags[\(index)]", value: tag))
        }
        for (index, tag) in Self.excludedTags.enumerated() {
            items.append(URLQueryItem(name: "excludedtags[\(index)]", value: tag))
        }
        components.queryItems = items
        return components.url!
    }

    static func playerSummariesURL(key: String, steamIDs: [String]) -> URL {
        var components = URLComponents(url: playerSummaries, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "key", value: key),
                                 URLQueryItem(name: "steamids", value: steamIDs.joined(separator: ","))]
        return components.url!
    }
}

/// 一页结果。
struct SteamStorePage: Equatable, Codable {
    var items: [SteamStoreItem]
    var nextCursor: String?
    var total: Int?
}

/// 解析官方接口的 JSON。数字字段有时是字符串，都按宽松方式读取。
enum SteamStoreResponse {
    static func page(from data: Data, requestedCursor: String) throws -> SteamStorePage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = root["response"] as? [String: Any] else { throw SteamStoreError.unreadable }
        let details = response["publishedfiledetails"] as? [[String: Any]] ?? []
        let items = details.compactMap(item(from:))
        var next = response["next_cursor"] as? String
        // 没有更多结果时 Steam 会返回同一个游标或空列表。
        if next == requestedCursor || details.isEmpty { next = nil }
        return SteamStorePage(items: items, nextCursor: next, total: int(response["total"]))
    }

    static func item(from detail: [String: Any]) -> SteamStoreItem? {
        guard let id = string(detail["publishedfileid"]), !id.isEmpty else { return nil }
        if let result = int(detail["result"]), result != 1 { return nil }
        let tags = (detail["tags"] as? [[String: Any]] ?? []).compactMap { $0["tag"] as? String }
        let lowerTags = Set(tags.map { $0.lowercased() })
        let type = SteamStoreQuery.typeTags.first { lowerTags.contains($0.1.lowercased()) }?.0
        let title = (detail["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return SteamStoreItem(
            workshopID: id,
            title: title.isEmpty ? String(format: NSLocalizedString("steam.item.untitled", comment: ""), id) : title,
            previewURL: (detail["preview_url"] as? String).flatMap { URL(string: $0) },
            creatorSteamID: string(detail["creator"]),
            authorName: nil,
            timeCreated: int(detail["time_created"]).map { Date(timeIntervalSince1970: TimeInterval($0)) },
            timeUpdated: int(detail["time_updated"]).map { Date(timeIntervalSince1970: TimeInterval($0)) },
            fileSize: int64(detail["file_size"]),
            type: type,
            tags: tags
        )
    }

    static func authorNames(from data: Data) -> [String: String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = root["response"] as? [String: Any],
              let players = response["players"] as? [[String: Any]] else { return [:] }
        var names: [String: String] = [:]
        for player in players {
            if let id = string(player["steamid"]), let name = player["personaname"] as? String { names[id] = name }
        }
        return names
    }

    private static func string(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let text = value as? String { return Int64(text) }
        return nil
    }
}

// MARK: - 服务

/// 网络请求：返回数据与 HTTP 状态码。测试注入替身。
typealias SteamStoreFetch = (URL) async throws -> (Data, Int)

/// Kinetic 1.0 Module 14 — Steam Store Browser 的数据层（规格 9、27；视图不做网络逻辑）。
///
/// - 只浏览在线商店，结果不会写进本地资料库（规格 38：Steam Search 不自动写入 Local）。
/// - 翻页用游标；第一页同时缓存在内存与磁盘（不含 API Key），短时间内重开或离线时直接显示。
/// - Poster 由 `SteamPosterCache` 下载到磁盘缓存，卡片离开屏幕时取消。
@MainActor
final class SteamStoreService: ObservableObject {
    enum Phase: Equatable {
        case needsAPIKey
        case loading
        case loaded
        case failed(String)
        case invalidKey
    }

    @Published private(set) var phase: Phase
    @Published private(set) var items: [SteamStoreItem] = []
    @Published private(set) var isLoadingMore = false
    @Published private(set) var canLoadMore = false
    /// 网络不可用，显示的是之前缓存的结果。
    @Published private(set) var isShowingCachedResults = false
    @Published private(set) var hasAPIKey: Bool
    @Published private(set) var query = SteamStoreQuery()

    let posters: SteamPosterCache
    private let keyStore: SteamAPIKeyStoring
    private let fetch: SteamStoreFetch
    private let cacheDirectory: URL?
    private let now: () -> Date
    /// 第一页缓存多久后需要重新请求。
    static let cacheLifetime: TimeInterval = 30 * 60

    private var nextCursor: String?
    private var generation = 0
    /// 页面第一次出现时才开始请求；之后回到页面保留已加载的结果。
    private var hasStarted = false
    private var memoryCache: [String: (page: SteamStorePage, date: Date)] = [:]
    private var authorNames: [String: String] = [:]
    /// 本次运行中已读到的 Key。钥匙串内容在第一次真正请求商店时才读取，之后不再读取，
    /// 避免每次搜索、筛选、翻页都触发 macOS 的钥匙串授权。
    private var sessionKey: String?

    init(keyStore: SteamAPIKeyStoring,
         cacheDirectory: URL? = SteamStoreService.defaultCacheDirectory(),
         posters: SteamPosterCache? = nil,
         now: @escaping () -> Date = Date.init,
         fetch: @escaping SteamStoreFetch = SteamStoreService.urlSessionFetch) {
        self.keyStore = keyStore
        self.cacheDirectory = cacheDirectory
        self.posters = posters ?? SteamPosterCache(directory: cacheDirectory?.appendingPathComponent("Posters", isDirectory: true))
        self.now = now
        self.fetch = fetch
        let hasKey = keyStore.hasStoredKey
        hasAPIKey = hasKey
        phase = hasKey ? .loading : .needsAPIKey
    }

    nonisolated static func defaultCacheDirectory() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Kinetic/SteamStore", isDirectory: true)
    }

    nonisolated static func urlSessionFetch(_ url: URL) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(from: url)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    // MARK: - API Key

    /// Steam Web API Key 是 32 位十六进制字符。
    nonisolated static func isValidKeyFormat(_ key: String) -> Bool {
        key.count == 32 && key.allSatisfy(\.isHexDigit)
    }

    func saveAPIKey(_ rawKey: String) throws {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidKeyFormat(key) else { throw SteamStoreError.invalidKeyFormat }
        try keyStore.save(key)
        sessionKey = key
        hasAPIKey = true
        memoryCache.removeAll()
        reload()
    }

    func removeAPIKey() {
        keyStore.remove()
        sessionKey = nil
        hasAPIKey = false
        generation += 1
        items = []
        canLoadMore = false
        phase = .needsAPIKey
    }

    private func currentKey() -> String? {
        if let sessionKey { return sessionKey }
        guard let key = keyStore.load(), !key.isEmpty else { return nil }
        sessionKey = key
        return key
    }

    // MARK: - 查询

    /// 页面的搜索词或类型筛选改变时重新查询；只改排序不需要请求（排序在已加载的结果上进行）。
    func update(searchText: String? = nil, typeFilter: ContentTypeFilter? = nil) {
        var next = query
        if let searchText { next.searchText = searchText }
        if let typeFilter { next.typeFilter = typeFilter }
        guard next != query || !hasStarted else { return }
        query = next
        reload()
    }

    /// 按页面的排序选项排列已加载的结果（规格：Steam 的「添加时间」= 创意工坊发布时间）。
    func displayedItems(options: ContentViewOptions) -> [SteamStoreItem] {
        ContentQuery.apply(options, to: items, name: \.title, type: \.type, dateAdded: \.timeCreated)
    }

    func reload() {
        hasStarted = true
        generation += 1
        let current = generation
        nextCursor = nil
        canLoadMore = false
        isLoadingMore = false
        guard let key = currentKey() else {
            hasAPIKey = false
            items = []
            phase = .needsAPIKey
            return
        }
        hasAPIKey = true
        let query = query
        if let cached = memoryCache[query.cacheKey], now().timeIntervalSince(cached.date) < Self.cacheLifetime {
            apply(cached.page, replacing: true)
            isShowingCachedResults = false
            phase = .loaded
            return
        }
        items = []
        phase = .loading
        Task { await loadFirstPage(query: query, key: key, generation: current) }
    }

    /// 滚动到底部时加载下一页。
    func loadMore() {
        guard phase == .loaded, canLoadMore, !isLoadingMore, let cursor = nextCursor,
              let key = currentKey() else { return }
        isLoadingMore = true
        let current = generation
        let query = query
        Task {
            defer { if current == self.generation { self.isLoadingMore = false } }
            do {
                let page = try await request(query: query, key: key, cursor: cursor)
                guard current == generation else { return }
                apply(page, replacing: false)
                await resolveAuthors(key: key, generation: current)
            } catch {
                guard current == generation else { return }
                canLoadMore = false
                if (error as? SteamStoreError) == .invalidKey { phase = .invalidKey }
            }
        }
    }

    private func loadFirstPage(query: SteamStoreQuery, key: String, generation current: Int) async {
        do {
            let page = try await request(query: query, key: key, cursor: "*")
            guard current == generation else { return }
            memoryCache[query.cacheKey] = (page, now())
            writeDiskCache(page, for: query)
            isShowingCachedResults = false
            apply(page, replacing: true)
            phase = .loaded
            await resolveAuthors(key: key, generation: current)
        } catch {
            guard current == generation else { return }
            if (error as? SteamStoreError) == .invalidKey {
                phase = .invalidKey
            } else if let cached = readDiskCache(for: query) {
                // 离线：显示之前的结果，并说明。
                apply(cached, replacing: true)
                canLoadMore = false
                isShowingCachedResults = true
                phase = .loaded
            } else {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func request(query: SteamStoreQuery, key: String, cursor: String) async throws -> SteamStorePage {
        let data: Data
        let status: Int
        do {
            (data, status) = try await fetch(query.url(key: key, cursor: cursor))
        } catch {
            throw SteamStoreError.network
        }
        switch status {
        case 200: return try SteamStoreResponse.page(from: data, requestedCursor: cursor)
        case 401, 403: throw SteamStoreError.invalidKey
        default: throw SteamStoreError.server(status)
        }
    }

    private func apply(_ page: SteamStorePage, replacing: Bool) {
        var incoming = page.items.map { item -> SteamStoreItem in
            var named = item
            if let id = item.creatorSteamID, let name = authorNames[id] { named.authorName = name }
            return named
        }
        if replacing {
            items = incoming
        } else {
            let known = Set(items.map(\.workshopID))
            incoming.removeAll { known.contains($0.workshopID) }
            items += incoming
        }
        nextCursor = page.nextCursor
        canLoadMore = page.nextCursor != nil
    }

    /// 作者名称来自 `ISteamUser/GetPlayerSummaries`；失败不影响浏览。
    private func resolveAuthors(key: String, generation current: Int) async {
        let missing = Array(Set(items.compactMap { $0.authorName == nil ? $0.creatorSteamID : nil })
            .subtracting(authorNames.keys)).sorted()
        guard !missing.isEmpty else { return }
        for batch in stride(from: 0, to: missing.count, by: 100).map({ Array(missing[$0..<min($0 + 100, missing.count)]) }) {
            guard let response = try? await fetch(SteamStoreQuery.playerSummariesURL(key: key, steamIDs: batch)),
                  response.1 == 200 else { return }
            authorNames.merge(SteamStoreResponse.authorNames(from: response.0)) { _, new in new }
        }
        guard current == generation else { return }
        items = items.map { item in
            var named = item
            if named.authorName == nil, let id = item.creatorSteamID { named.authorName = authorNames[id] }
            return named
        }
    }

    // MARK: - 磁盘缓存（第一页）

    private func cacheFile(for query: SteamStoreQuery) -> URL? {
        let digest = SHA256.hash(data: Data(query.cacheKey.utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory?.appendingPathComponent("page-\(digest.prefix(24)).json")
    }

    private func writeDiskCache(_ page: SteamStorePage, for query: SteamStoreQuery) {
        guard let file = cacheFile(for: query), let data = try? JSONEncoder().encode(page) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    private func readDiskCache(for query: SteamStoreQuery) -> SteamStorePage? {
        guard let file = cacheFile(for: query), let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(SteamStorePage.self, from: data)
    }
}

// MARK: - Poster 缓存

/// 在线商店卡片的 Poster（作者设置的预览图）。下载到磁盘缓存；解码由 `PosterArtworkCache` 负责，只解码一次。
/// 卡片离开屏幕时 SwiftUI 取消它的任务，下载随之取消（规格 27：离屏取消解码与网络工作）。
@MainActor
final class SteamPosterCache {
    let directory: URL?
    /// 缓存的 Poster 保留多久。
    static let lifetime: TimeInterval = 7 * 24 * 60 * 60
    private let fetch: SteamStoreFetch

    init(directory: URL?, fetch: @escaping SteamStoreFetch = SteamStoreService.urlSessionFetch) {
        self.directory = directory
        self.fetch = fetch
    }

    /// 缓存文件名只由创意工坊编号与 Poster 地址决定；作者更换 Poster 后地址变化，会下载新的。
    func fileURL(for item: SteamStoreItem) -> URL? {
        guard let directory, let preview = item.previewURL else { return nil }
        let digest = SHA256.hash(data: Data(preview.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(item.workshopID)-\(digest.prefix(16))")
    }

    /// 已缓存且未过期时直接返回。
    func cachedURL(for item: SteamStoreItem) -> URL? {
        guard let file = fileURL(for: item),
              let values = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
              let modified = values.contentModificationDate,
              Date().timeIntervalSince(modified) < Self.lifetime else { return nil }
        return file
    }

    /// 需要时下载。任务被取消（卡片离开屏幕）时放弃，不写入半个文件。
    func load(_ item: SteamStoreItem) async -> URL? {
        if let cached = cachedURL(for: item) { return cached }
        guard let file = fileURL(for: item), let preview = item.previewURL else { return nil }
        guard let response = try? await fetch(preview), response.1 == 200, !response.0.isEmpty,
              !Task.isCancelled else { return nil }
        let data = response.0
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? data.write(to: file, options: .atomic)) != nil else { return nil }
        return file
    }
}
