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
    /// 个人资料链接中的自定义 ID 找不到对应的 Steam 用户。
    case authorNotFound(String)
    /// 没有 Steam Web API Key，无法读取在线资料。
    case missingKey
    /// 创意工坊项目已删除或不可访问。
    case itemUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidKeyFormat: return NSLocalizedString("steam.store.error.keyFormat", comment: "")
        case .invalidKey: return NSLocalizedString("steam.store.error.invalidKey", comment: "")
        case .network: return NSLocalizedString("steam.error.network", comment: "")
        case .server(let status): return String(format: NSLocalizedString("steam.store.error.server", comment: ""), status)
        case .unreadable: return NSLocalizedString("steam.store.error.unreadable", comment: "")
        case .keychain(let status): return String(format: NSLocalizedString("steam.store.error.keychain", comment: ""), status)
        case .authorNotFound(let name): return String(format: NSLocalizedString("steam.store.error.authorNotFound", comment: ""), name)
        case .missingKey: return NSLocalizedString("steam.store.error.missingKey", comment: "")
        case .itemUnavailable: return NSLocalizedString("steam.store.error.itemUnavailable", comment: "")
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
    /// QueryFiles 原始跨页位置；重复编号保留第一次出现的位置，元数据不改排名。
    var serverRankIndex: Int? = nil

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

/// Workshop 独立于本地资料库的六种排序；顺序与用户要求一致。
enum SteamWorkshopSortMode: String, CaseIterable, Sendable {
    case mostPopular, topRatedAllTime, recentlyPublished, recentlyUpdated, searchRelevance, totalUniqueSubscribers
    var titleKey: String { "steam.sort.\(rawValue)" }
}

/// 仅 IPublishedFileService.EPublishedFileQueryType，不与 ISteamUGC 的 raw value 共用。
/// https://partner.steamgames.com/doc/webapi/IPublishedFileService#EPublishedFileQueryType
enum SteamPublishedFileQueryType: Int, Sendable {
    case rankedByVote = 0
    case rankedByPublicationDate = 1
    case rankedByTrend = 3
    case rankedByTotalUniqueSubscriptions = 9
    case rankedByTextSearch = 12
    case rankedByLastUpdatedDate = 21
}

/// 一次官方 QueryFiles 查询；服务器负责候选与排名，Kinetic 不做二次排序。
struct SteamStoreQuery: Equatable {
    var searchText: String = ""
    var typeFilter: ContentTypeFilter = .all
    var sortMode: SteamWorkshopSortMode = .recentlyPublished
    /// 保留既有 Web API 默认英语；语言是请求与缓存上下文的一部分。
    var language = 0
    static let trendDays = 7
    /// R4 第 44–49 节：九组创意工坊标签筛选（类型组优先于 typeFilter）。
    var filters = SteamFilterState()

    static let pageSize = 30
    static let pageSizeChoices = [15, 20, 30, 50, 65]
    static let maximumPage = 500
    // Numbered navigation is enabled by the Workshop page. Existing cursor consumers remain unchanged.
    var numberedPage: Int? = nil
    var resultsPerPage = Self.pageSize
    static let endpoint = URL(string: "https://api.steampowered.com/IPublishedFileService/QueryFiles/v1/")!
    static let playerSummaries = URL(string: "https://api.steampowered.com/ISteamUser/GetPlayerSummaries/v2/")!
    static let userFiles = URL(string: "https://api.steampowered.com/IPublishedFileService/GetUserFiles/v1/")!
    static let resolveVanity = URL(string: "https://api.steampowered.com/ISteamUser/ResolveVanityURL/v1/")!
    static let fileDetails = URL(string: "https://api.steampowered.com/IPublishedFileService/GetDetails/v1/")!
    static let typeTags: [(WallpaperType, String)] = [(.scene, "Scene"), (.web, "Web"), (.video, "Video")]
    /// 由现有设置提供年龄分级排除标签；查询本身不覆盖用户设置。
    var hiddenAgeRatings: [String] = []

    var trimmedSearch: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 空文字不能发 RankedByTextSearch；沿用原页面的最近发行默认值。
    var effectiveSortMode: SteamWorkshopSortMode {
        sortMode == .searchRelevance && trimmedSearch.isEmpty ? .recentlyPublished : sortMode
    }
    var publishedFileQueryType: SteamPublishedFileQueryType {
        switch effectiveSortMode {
        case .mostPopular: return .rankedByTrend
        case .topRatedAllTime: return .rankedByVote
        case .recentlyPublished: return .rankedByPublicationDate
        case .recentlyUpdated: return .rankedByLastUpdatedDate
        case .searchRelevance: return .rankedByTextSearch
        case .totalUniqueSubscribers: return .rankedByTotalUniqueSubscriptions
        }
    }
    var queryType: Int { publishedFileQueryType.rawValue }

    /// 搜索词是个人资料链接或 SteamID64 时，列出这位作者的壁纸（Steam 的 search_text 不匹配作者）。
    var explicitAuthor: SteamAuthorReference? { SteamAuthorReference.explicit(in: trimmedSearch) }

    /// 明确选择的类型标签：R4 类型组（可含「应用」）优先，其次是原来的 Scene / Web / 视频筛选；空 = 全部类型。
    var explicitTypeTags: [String] {
        if !filters.types.isEmpty { return filters.typeTags }
        if case .only(let types) = typeFilter { return Self.typeTags.filter { types.contains($0.0) }.map(\.1) }
        return []
    }

    /// 不同组共同生效（AND）时为 true。只有类型条件时沿用原来的「至少一个类型」（OR）查询。
    var matchAllTags: Bool { !filters.groupTags.isEmpty }

    /// - 没有其他组条件：原查询不变——全部类型 = 至少是 Scene / Web / 视频之一，具体类型 = 其中任意一个。
    /// - 有其他组条件：match_all_tags，每组一个必需标签；单个类型也是必需标签。
    var requiredTags: [String] {
        let types = explicitTypeTags
        guard matchAllTags else { return types.isEmpty ? Self.typeTags.map(\.1) : types }
        return filters.groupTags + (types.count == 1 ? types : [])
    }

    /// 设置中隐藏的年龄分级（在筛选器中明确选择的分级不排除）。有其他组条件时，多个类型用「排除其余类型」
    /// 表达同组 OR；全部类型时与默认浏览一致地排除「应用」，除非明确在找预设 / 素材。
    var excludedTagList: [String] {
        let chosenRating = filters.tags[.ageRating]?.lowercased()
        var tags = hiddenAgeRatings.filter { $0.lowercased() != chosenRating }
        guard matchAllTags else { return tags }
        let types = explicitTypeTags
        let allTypes = SteamTagGroup.type.tags.map(\.value)
        if types.count > 1 {
            tags += allTypes.filter { !types.contains($0) }
        } else if types.isEmpty, !filters.selectsNonWallpaperCategory {
            tags.append("Application")
        }
        return tags
    }

    /// 缓存键：不包含 API Key。查询类型、搜索词与完整的标签条件任何一项不同都是不同的查询。
    var cacheKey: String {
        "workshop-rank-v2|\(queryType)|\(effectiveSortMode.rawValue)|\(trimmedSearch.lowercased())|"
            + "language=\(language)|days=\(effectiveSortMode == .mostPopular ? Self.trendDays : 0)|"
            + "\(requiredTags.joined(separator: ","))|"
            + "\(excludedTagList.joined(separator: ","))|\(matchAllTags ? "all" : "any")"
            + (numberedPage.map { "|page=\($0)|size=\(resultsPerPage)" } ?? "")
    }

    /// 与服务器查询相同的规则，用于没有服务器筛选的结果（作者的壁纸、按作者名匹配的已加载结果）。
    func locallyMatches(_ item: SteamStoreItem) -> Bool {
        let tags = Set(item.tags.map { $0.lowercased() })
        if excludedTagList.contains(where: { tags.contains($0.lowercased()) }) { return false }
        let required = requiredTags.map { $0.lowercased() }
        if required.isEmpty { return true }
        return matchAllTags ? required.allSatisfy(tags.contains) : required.contains(where: tags.contains)
    }

    func url(key: String, cursor: String) -> URL {
        var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "appid", value: SteamWorkshop.wallpaperEngineAppID),
            URLQueryItem(name: "query_type", value: String(queryType)),
            URLQueryItem(name: "language", value: String(language)),
            URLQueryItem(name: "cursor", value: cursor),
            URLQueryItem(name: "numperpage", value: String(Self.pageSize)),
            URLQueryItem(name: "return_tags", value: "true"),
            URLQueryItem(name: "return_metadata", value: "false"),
            URLQueryItem(name: "match_all_tags", value: matchAllTags ? "true" : "false"),
        ]
        if effectiveSortMode == .mostPopular {
            items.append(URLQueryItem(name: "days", value: String(Self.trendDays)))
            items.append(URLQueryItem(name: "include_recent_votes_only", value: "false"))
        }
        if !trimmedSearch.isEmpty { items.append(URLQueryItem(name: "search_text", value: trimmedSearch)) }
        for (index, tag) in requiredTags.enumerated() {
            items.append(URLQueryItem(name: "requiredtags[\(index)]", value: tag))
        }
        for (index, tag) in excludedTagList.enumerated() {
            items.append(URLQueryItem(name: "excludedtags[\(index)]", value: tag))
        }
        if let numberedPage {
            // Steam ignores page when cursor is present: NEVER send both.
            items.removeAll { $0.name == "cursor" || $0.name == "numperpage" }
            items.append(URLQueryItem(name: "page", value: String(numberedPage)))
            items.append(URLQueryItem(name: "numperpage", value: String(resultsPerPage)))
        }
        components.queryItems = items
        return components.url!
    }

    /// 一位作者发布到 Wallpaper Engine 的项目（`IPublishedFileService/GetUserFiles`，页码从 1 开始）。
    static func userFilesURL(key: String, steamID: String, page: Int, resultsPerPage: Int = pageSize) -> URL {
        var components = URLComponents(url: userFiles, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "key", value: key),
                                 URLQueryItem(name: "steamid", value: steamID),
                                 URLQueryItem(name: "appid", value: SteamWorkshop.wallpaperEngineAppID),
                                 URLQueryItem(name: "page", value: String(page)),
                                 URLQueryItem(name: "numperpage", value: String(resultsPerPage)),
                                 URLQueryItem(name: "return_tags", value: "true")]
        return components.url!
    }

    /// R4 第 51 节：一个项目的完整详情（标签、大小、时间与作者原始描述，保留 BBCode）。
    static func detailsURL(key: String, workshopID: String) -> URL {
        var components = URLComponents(url: fileDetails, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "key", value: key),
                                 URLQueryItem(name: "publishedfileids[0]", value: workshopID),
                                 URLQueryItem(name: "includetags", value: "true"),
                                 URLQueryItem(name: "short_description", value: "false"),
                                 URLQueryItem(name: "strip_description_bbcode", value: "false"),
                                 URLQueryItem(name: "appid", value: SteamWorkshop.wallpaperEngineAppID)]
        return components.url!
    }

    /// 自定义个人资料 ID（steamcommunity.com/id/<ID>）→ SteamID64。
    static func resolveVanityURL(key: String, vanity: String) -> URL {
        var components = URLComponents(url: resolveVanity, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "key", value: key),
                                 URLQueryItem(name: "vanityurl", value: vanity),
                                 URLQueryItem(name: "url_type", value: "1")]
        return components.url!
    }

    static func playerSummariesURL(key: String, steamIDs: [String]) -> URL {
        var components = URLComponents(url: playerSummaries, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "key", value: key),
                                 URLQueryItem(name: "steamids", value: steamIDs.joined(separator: ","))]
        return components.url!
    }
}

/// R4 第 51 节：详情窗口使用的完整资料（来自 `GetDetails`；作者名来自 `GetPlayerSummaries`）。
struct SteamItemDetails: Equatable, Sendable {
    var item: SteamStoreItem
    /// 作者原始描述（BBCode 原文，不翻译、不摘要）；Steam 返回空时为 nil。
    var description: String?

    init(item: SteamStoreItem, description: String?) {
        self.item = item
        self.description = description?.isEmpty == true ? nil : description
    }
}

/// R4：搜索词指向的作者。Steam 的 search_text 只匹配标题与描述，作者需要另外查找。
enum SteamAuthorReference: Equatable {
    case steamID(String)
    case vanity(String)

    /// 个人资料链接（/profiles/<SteamID64> 或 /id/<自定义 ID>）或单独的 SteamID64。
    static func explicit(in text: String) -> SteamAuthorReference? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isSteamID64(trimmed) { return .steamID(trimmed) }
        let lower = trimmed.lowercased()
        guard let host = lower.range(of: "steamcommunity.com/") else { return nil }
        let path = trimmed[host.upperBound...].split(separator: "/").map(String.init)
        guard path.count >= 2 else { return nil }
        switch path[0].lowercased() {
        case "profiles": return isSteamID64(path[1]) ? .steamID(path[1]) : nil
        case "id": return isVanity(path[1]) ? .vanity(path[1]) : nil
        default: return nil
        }
    }

    /// 普通关键词中可能是自定义个人资料 ID 的单个词（字母、数字、下划线、连字符，2–32 个字符）。
    static func vanityCandidate(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return isVanity(trimmed) && !isSteamID64(trimmed) ? trimmed : nil
    }

    static func isSteamID64(_ text: String) -> Bool {
        text.count == 17 && text.hasPrefix("7656119") && text.allSatisfy(\.isASCIIDigit)
    }

    static func isVanity(_ text: String) -> Bool {
        (2...32).contains(text.count) && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

/// 一页结果。
struct SteamStorePage: Equatable, Codable {
    var items: [SteamStoreItem]
    var nextCursor: String?
    var total: Int?
    /// 作者的壁纸在本地筛选前的数量（用于判断翻页是否前进）。
    var rawCount: Int? = nil
}

#if DEBUG
/// 仅输出搜索上下文与前 30 个编号 / 标题 / 位置。接口不接受 Key、请求 URL 或会话信息。
enum SteamSearchDiagnostics {
    static func snapshot(query: SteamStoreQuery, cursor: String, source: String,
                         server: [SteamStoreItem], display: [SteamStoreItem]) -> String {
        func rows(_ items: [SteamStoreItem]) -> [[String: Any]] {
            items.prefix(30).map { ["serverRankIndex": $0.serverRankIndex ?? -1,
                                    "publishedFileID": $0.workshopID, "title": $0.title] }
        }
        let body: [String: Any] = [
            "event": "SteamSearch", "query": query.trimmedSearch, "searchText": query.trimmedSearch,
            "backend": query.explicitAuthor == nil ? "IPublishedFileService.QueryFiles" : "IPublishedFileService.GetUserFiles",
            "sortMode": query.effectiveSortMode.rawValue,
            "steamQueryType": query.publishedFileQueryType.rawValue,
            "steamQueryName": String(describing: query.publishedFileQueryType),
            "cursorOrPage": cursor, "language": query.language,
            "trendDays": query.effectiveSortMode == .mostPopular ? SteamStoreQuery.trendDays : 0,
            "requiredTags": query.requiredTags, "excludedTags": query.excludedTagList,
            "matchAllTags": query.matchAllTags, "source": source,
            "sortAppliedByBackend": query.explicitAuthor == nil,
            "resultCount": server.count, "displayCount": display.count,
            "SERVER": rows(server), "DISPLAY": rows(display)
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "SteamSearch diagnostic unavailable" }
        return text
    }
}
#endif

/// 解析官方接口的 JSON。数字字段有时是字符串，都按宽松方式读取。
enum SteamStoreResponse {
    static func page(from data: Data, requestedCursor: String) throws -> SteamStorePage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = root["response"] as? [String: Any] else { throw SteamStoreError.unreadable }
        let details = response["publishedfiledetails"] as? [[String: Any]] ?? []
        let items = details.enumerated().compactMap { offset, detail -> SteamStoreItem? in
            guard var item = item(from: detail) else { return nil }
            item.serverRankIndex = offset
            return item
        }
        var next = response["next_cursor"] as? String
        // 没有更多结果时 Steam 会返回同一个游标或空列表。
        if next == requestedCursor || details.isEmpty { next = nil }
        return SteamStorePage(items: items, nextCursor: next, total: int(response["total"]), rawCount: details.count)
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

    /// `GetUserFiles` 的一页：页码从 1 开始，按总数判断是否还有下一页。
    static func userPage(from data: Data, page: Int, resultsPerPage: Int = SteamStoreQuery.pageSize) throws -> SteamStorePage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = root["response"] as? [String: Any] else { throw SteamStoreError.unreadable }
        let details = response["publishedfiledetails"] as? [[String: Any]] ?? []
        let total = int(response["total"])
        let loaded = (page - 1) * resultsPerPage + details.count
        let hasMore = !details.isEmpty && total.map { loaded < $0 } ?? (details.count == resultsPerPage)
        let items = details.enumerated().compactMap { offset, detail -> SteamStoreItem? in
            guard var item = item(from: detail) else { return nil }
            item.serverRankIndex = offset
            return item
        }
        return SteamStorePage(items: items, nextCursor: hasMore ? String(page + 1) : nil,
                              total: total, rawCount: details.count)
    }

    /// `GetDetails` 的第一个项目；已删除 / 不可访问时报告不可用。
    static func details(from data: Data) throws -> SteamItemDetails {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = root["response"] as? [String: Any] else { throw SteamStoreError.unreadable }
        guard let detail = (response["publishedfiledetails"] as? [[String: Any]])?.first,
              let item = item(from: detail) else { throw SteamStoreError.itemUnavailable }
        let description = (detail["file_description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return SteamItemDetails(item: item, description: description)
    }

    /// `ResolveVanityURL`：success = 1 时返回 SteamID64。
    static func resolvedSteamID(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = root["response"] as? [String: Any], int(response["success"]) == 1,
              let id = string(response["steamid"]), SteamAuthorReference.isSteamID64(id) else { return nil }
        return id
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
/// - R4 BUG-S1：「加载更多」有明确的 加载中 / 失败可重试 / 已到末尾 状态；同一查询同一页只有一个在途请求，
///   只有请求成功才前进游标；查询改变后旧响应既不追加也不结束新请求的加载状态。
/// - 关键词只用服务器候选与排名；个人资料链接 / SteamID64 仍列出该作者的壁纸；
///   普通词不解析自定义个人资料 ID，也不加入已知作者候选。
@MainActor
final class SteamStoreService: ObservableObject {
    enum Phase: Equatable {
        case needsAPIKey
        case loading
        case loaded
        case failed(String)
        case invalidKey
    }

    /// 底部「加载更多」的状态。
    enum LoadMoreState: Equatable {
        /// 还有下一页，等待滚动到底部。
        case idle
        /// 正在请求下一页（只在真实请求进行时）。
        case loading
        /// 请求失败或无法继续前进：保留已加载的内容与待重试的页。
        case failed(String)
        /// 没有更多结果（或当前没有可翻页的结果）。
        case exhausted
    }

    @Published private(set) var phase: Phase
    @Published private(set) var items: [SteamStoreItem] = []
    @Published private(set) var loadMoreState: LoadMoreState = .exhausted
    /// 网络不可用，显示的是之前缓存的结果。
    @Published private(set) var isShowingCachedResults = false
    @Published private(set) var hasAPIKey: Bool
    @Published private(set) var query = SteamStoreQuery()
    /// Workshop 两指滑动（用户 2026-10-08，参考 Safari）：停留过的页。后退栈的最后一项是上一页，
    /// 前进栈的最后一项是下一页；跳到新的页会清空前进栈。只在本次运行中保留。
    @Published private(set) var backHistory: [SteamStoreQuery] = []
    @Published private(set) var forwardHistory: [SteamStoreQuery] = []
    static let maximumHistory = 100
    var canGoBack: Bool { !backHistory.isEmpty }
    var canGoForward: Bool { !forwardHistory.isEmpty }

    var isLoadingMore: Bool { loadMoreState == .loading }
    /// 还有可以请求的下一页（失败后可重试也算）。
    var canLoadMore: Bool {
        switch loadMoreState {
        case .idle, .loading, .failed: return true
        case .exhausted: return false
        }
    }

    let posters: SteamPosterCache
    private let keyStore: SteamAPIKeyStoring
    private let fetch: SteamStoreFetch
    private let cacheDirectory: URL?
    private let now: () -> Date
    /// 第一页缓存多久后需要重新请求。
    static let cacheLifetime: TimeInterval = 30 * 60
    /// 连续几页没有任何新项目时停止自动加载，报告无法继续。
    static let maximumStalledPages = 3

    private var nextCursor: String?
    /// 本次查询已经成功请求过的游标：后端返回已请求过的游标时视为结束，不进入循环。
    private var requestedCursors: Set<String> = []
    private var stalledPages = 0
    /// 当前查询列出的是哪位作者的壁纸（个人资料链接 / SteamID64）；nil = 普通创意工坊查询。
    private var authorSteamID: String?
    private var generation = 0
    /// 页面第一次出现时才开始请求；之后回到页面保留已加载的结果。
    private var hasStarted = false
    private var memoryCache: [String: (page: SteamStorePage, date: Date, author: String?)] = [:]
    private var authorNames: [String: String] = [:]
    /// 包括重复 / 不可见项目的服务器位置；跨页连续，不以元数据到达顺序计算。
    private var nextServerRank = 0
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
        resetPaging()
        phase = .needsAPIKey
    }

    private func currentKey() -> String? {
        if let sessionKey { return sessionKey }
        guard let key = keyStore.load(), !key.isEmpty else { return nil }
        sessionKey = key
        return key
    }

    // MARK: - 查询

    /// 设置 › Steam 的「隐藏年龄分级」改变时调用。商店还没有开始浏览时只记下条件，不提前请求（不提前读取钥匙串）。
    func setHiddenAgeRatings(_ ratings: [String]) {
        guard query.hiddenAgeRatings != ratings else { return }
        query.hiddenAgeRatings = ratings
        if query.numberedPage != nil { query.numberedPage = 1 }
        if hasStarted { reload() }
    }

    /// 新关键词默认相关度；明确手选排序优先，筛选 / 翻页保持该排序。空相关度回到既有最近发行。
    func update(searchText: String? = nil, typeFilter: ContentTypeFilter? = nil, filters: SteamFilterState? = nil,
                sortMode: SteamWorkshopSortMode? = nil,
                numberedPages: Bool = false) {
        var next = query
        if let searchText {
            next.searchText = searchText
            if next.trimmedSearch != query.trimmedSearch, !next.trimmedSearch.isEmpty {
                next.sortMode = .searchRelevance
            }
        }
        if let typeFilter { next.typeFilter = typeFilter }
        if let filters { next.filters = filters }
        if let sortMode { next.sortMode = sortMode }
        next.sortMode = next.effectiveSortMode
        if numberedPages, next.numberedPage == nil { next.numberedPage = 1 }
        guard next != query || !hasStarted else { return }
        if next.numberedPage != nil { next.numberedPage = 1 }
        recordVisit(leaving: query, for: next)
        query = next
        reload()
    }

    func goToPage(_ page: Int) {
        let page = min(SteamStoreQuery.maximumPage, max(1, page))
        guard query.numberedPage != page else { return }
        var next = query
        next.numberedPage = page
        recordVisit(leaving: query, for: next)
        query = next
        reload()
    }

    func setResultsPerPage(_ count: Int) {
        guard SteamStoreQuery.pageSizeChoices.contains(count), query.resultsPerPage != count else { return }
        var next = query
        next.resultsPerPage = count
        next.numberedPage = 1
        recordVisit(leaving: query, for: next)
        query = next
        reload()
    }

    /// 回到上一张停留过的页（连同当时的搜索、排序、筛选与每页数量）。没有可回的页时不做任何事。
    func goBack() {
        guard let previous = backHistory.popLast() else { return }
        forwardHistory.append(query)
        show(previous)
    }

    /// 回到后退之前停留的那一页。没有时不做任何事。
    func goForward() {
        guard let next = forwardHistory.popLast() else { return }
        backHistory.append(query)
        show(next)
    }

    /// 已经显示过的 Workshop 页才算停留过；第一次进入页面不算。
    private func recordVisit(leaving current: SteamStoreQuery, for next: SteamStoreQuery) {
        guard hasStarted, current.numberedPage != nil, next.numberedPage != nil, current != next else { return }
        backHistory.append(current)
        if backHistory.count > Self.maximumHistory { backHistory.removeFirst(backHistory.count - Self.maximumHistory) }
        forwardHistory.removeAll()
    }

    /// 年龄分级与语言来自设置，不随历史回退。
    private func show(_ entry: SteamStoreQuery) {
        var next = entry
        next.hiddenAgeRatings = query.hiddenAgeRatings
        next.language = query.language
        query = next
        reload()
    }

    /// 仅筛选，不排序：服务器数组就是展示顺序，元数据与本地下载状态不能改变它。
    func displayedItems(options: ContentViewOptions) -> [SteamStoreItem] {
        let displayed = items.filter { item in
            options.showsAllTypes || item.type.map(options.typeFilter.includes) == true
        }
        #if DEBUG
        let ranks = displayed.compactMap(\.serverRankIndex)
        assert(zip(ranks, ranks.dropFirst()).allSatisfy { $0 < $1 }, "Steam result order modified by client")
        #endif
        return displayed
    }

    func reload() {
        hasStarted = true
        generation += 1
        let current = generation
        resetPaging()
        guard let key = currentKey() else {
            hasAPIKey = false
            items = []
            phase = .needsAPIKey
            return
        }
        hasAPIKey = true
        let query = query
        if let cached = memoryCache[query.cacheKey], now().timeIntervalSince(cached.date) < Self.cacheLifetime {
            authorSteamID = cached.author
            requestedCursors = [cached.author == nil ? "*" : "1"]
            apply(cached.page, replacing: true, source: "memory-cache")
            isShowingCachedResults = false
            phase = .loaded
            return
        }
        items = []
        phase = .loading
        Task { await loadFirstPage(query: query, key: key, generation: current) }
    }

    /// 滚动到底部（或点按「重试」）时加载下一页。同一查询同一时间只有一个请求。
    func loadMore() {
        guard query.numberedPage == nil else { return }
        guard phase == .loaded, let cursor = nextCursor else { return }
        switch loadMoreState {
        case .idle, .failed: break
        case .loading, .exhausted: return
        }
        guard let key = currentKey() else { return }
        loadMoreState = .loading
        let current = generation
        let query = query
        let author = authorSteamID
        Task {
            do {
                let page = try await request(query: query, author: author, key: key, cursor: cursor)
                guard current == generation else { return }
                append(page, requestedCursor: cursor)
                await resolveAuthors(key: key, generation: current)
            } catch {
                guard current == generation else { return }
                if (error as? SteamStoreError) == .invalidKey {
                    loadMoreState = .exhausted
                    phase = .invalidKey
                } else {
                    // 保留游标，原位重试同一页。
                    loadMoreState = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func resetPaging() {
        nextCursor = nil
        requestedCursors = []
        stalledPages = 0
        authorSteamID = nil
        nextServerRank = 0
        loadMoreState = .exhausted
    }

    private func loadFirstPage(query: SteamStoreQuery, key: String, generation current: Int) async {
        do {
            let (page, author) = try await firstPage(query: query, key: key)
            guard current == generation else { return }
            memoryCache[query.cacheKey] = (page, now(), author)
            if query.numberedPage != nil, memoryCache.count > 32,
               let oldest = memoryCache.min(by: { $0.value.date < $1.value.date })?.key {
                memoryCache.removeValue(forKey: oldest)
            }
            writeDiskCache(page, for: query)
            isShowingCachedResults = false
            authorSteamID = author
            requestedCursors = [author == nil ? "*" : "1"]
            apply(page, replacing: true)
            phase = .loaded
            await resolveAuthors(key: key, generation: current)
        } catch {
            guard current == generation else { return }
            if (error as? SteamStoreError) == .invalidKey {
                phase = .invalidKey
            } else if let cached = readDiskCache(for: query) {
                // 离线：显示之前的结果，并说明。离线时不翻页。
                apply(cached, replacing: true, source: "offline-first-page-cache")
                nextCursor = nil
                loadMoreState = .exhausted
                isShowingCachedResults = true
                phase = .loaded
            } else {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// 第一页：
    /// - 个人资料链接 / SteamID64：这位作者的壁纸（找不到这个用户时报告）。
    /// - 普通关键词：完全使用 QueryFiles 候选 / 排名，不加入本地作者候选或猜测自定义 ID。
    private func firstPage(query: SteamStoreQuery, key: String) async throws -> (SteamStorePage, String?) {
        switch query.explicitAuthor {
        case .steamID(let id)?:
            return (try await request(query: query, author: id, key: key, cursor: String(query.numberedPage ?? 1)), id)
        case .vanity(let vanity)?:
            guard let id = try await resolveVanity(vanity, key: key) else {
                throw SteamStoreError.authorNotFound(vanity)
            }
            return (try await request(query: query, author: id, key: key, cursor: String(query.numberedPage ?? 1)), id)
        case nil:
            break
        }
        return (try await request(query: query, author: nil, key: key, cursor: "*"), nil)
    }

    private func resolveVanity(_ vanity: String, key: String) async throws -> String? {
        let response: (Data, Int)
        do { response = try await fetch(SteamStoreQuery.resolveVanityURL(key: key, vanity: vanity)) }
        catch { throw SteamStoreError.network }
        switch response.1 {
        case 200: return SteamStoreResponse.resolvedSteamID(from: response.0)
        case 401, 403: throw SteamStoreError.invalidKey
        default: throw SteamStoreError.server(response.1)
        }
    }

    /// 普通查询用游标；作者的壁纸用页码（游标字符串即页码）。作者的结果在本地按查询规则筛选。
    private func request(query: SteamStoreQuery, author: String?, key: String, cursor: String) async throws -> SteamStorePage {
        let url = author.map { SteamStoreQuery.userFilesURL(key: key, steamID: $0, page: query.numberedPage ?? Int(cursor) ?? 1, resultsPerPage: query.resultsPerPage) }
            ?? query.url(key: key, cursor: cursor)
        let data: Data
        let status: Int
        do {
            (data, status) = try await fetch(url)
        } catch {
            throw SteamStoreError.network
        }
        switch status {
        case 200:
            guard author != nil else { return try SteamStoreResponse.page(from: data, requestedCursor: cursor) }
            var page = try SteamStoreResponse.userPage(from: data, page: query.numberedPage ?? Int(cursor) ?? 1, resultsPerPage: query.resultsPerPage)
            page.items = page.items.filter(query.locallyMatches)
            return page
        case 401, 403: throw SteamStoreError.invalidKey
        default: throw SteamStoreError.server(status)
        }
    }

    private func apply(_ page: SteamStorePage, replacing: Bool, cursor: String = "*", source: String = "server") {
        if replacing { nextServerRank = query.numberedPage.map { ($0 - 1) * query.resultsPerPage } ?? 0 }
        let incoming = page.items.enumerated().map { offset, item -> SteamStoreItem in
            var named = item
            if let id = item.creatorSteamID, let name = authorNames[id] { named.authorName = name }
            named.serverRankIndex = nextServerRank + (item.serverRankIndex ?? offset)
            return named
        }
        nextServerRank += page.rawCount ?? page.items.count
        if replacing {
            var seen = Set<String>()
            items = incoming.filter { seen.insert($0.workshopID).inserted }
        } else {
            var seen = Set(items.map(\.workshopID))
            items += incoming.filter { seen.insert($0.workshopID).inserted }
        }
        nextCursor = query.numberedPage == nil ? page.nextCursor.flatMap { requestedCursors.contains($0) ? nil : $0 } : nil
        loadMoreState = nextCursor == nil ? .exhausted : .idle
        #if DEBUG
        print(SteamSearchDiagnostics.snapshot(query: query, cursor: cursor, source: source,
                                             server: incoming, display: items))
        #endif
    }

    /// 追加下一页并判断能否继续：游标回到已请求过的位置 = 结束；连续几页只有重复项目 = 无法继续。
    private func append(_ page: SteamStorePage, requestedCursor: String) {
        requestedCursors.insert(requestedCursor)
        let before = items.count
        apply(page, replacing: false, cursor: requestedCursor)
        // 作者的壁纸在本地筛选后可能整页都不显示，只要服务器返回了项目就算前进。
        let advancedAuthorPage = authorSteamID != nil && (page.rawCount ?? page.items.count) > 0
        let progressed = items.count > before || advancedAuthorPage
        stalledPages = progressed ? 0 : stalledPages + 1
        if nextCursor != nil, stalledPages >= Self.maximumStalledPages {
            loadMoreState = .failed(NSLocalizedString("steam.store.loadMore.noProgress", comment: ""))
        }
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

    // MARK: - R4 详情

    private var detailsCache: [String: SteamItemDetails] = [:]

    /// R4 第 51 节：按稳定的创意工坊编号读取完整详情。不创建下载任务、不写资料库；同一次运行中缓存。
    func details(workshopID: String) async throws -> SteamItemDetails {
        if let cached = detailsCache[workshopID] { return cached }
        guard let key = currentKey() else { throw SteamStoreError.missingKey }
        let response: (Data, Int)
        do { response = try await fetch(SteamStoreQuery.detailsURL(key: key, workshopID: workshopID)) }
        catch { throw SteamStoreError.network }
        switch response.1 {
        case 200: break
        case 401, 403: throw SteamStoreError.invalidKey
        default: throw SteamStoreError.server(response.1)
        }
        var details = try SteamStoreResponse.details(from: response.0)
        if let creator = details.item.creatorSteamID {
            if authorNames[creator] == nil,
               let players = try? await fetch(SteamStoreQuery.playerSummariesURL(key: key, steamIDs: [creator])),
               players.1 == 200 {
                authorNames.merge(SteamStoreResponse.authorNames(from: players.0)) { _, new in new }
            }
            details.item.authorName = authorNames[creator]
        }
        detailsCache[workshopID] = details
        return details
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
