#if DEBUG
import AppKit
import CoreGraphics
import Foundation

/// R4 Debug 验收：不联网、不读钥匙串、不运行真实 SteamCMD 的 Steam 商店。
///
/// 启动参数 `--steam-store-demo`。使用独立验收资料库（`Kinetic-Acceptance/R4-SteamDemo`），不恢复壁纸、不改桌面。
/// - 假的 Steam Web API 按 QueryFiles 的规则处理游标、搜索词、必需 / 排除标签与 match_all_tags，返回合成项目与 Poster；
///   也支持 GetUserFiles / ResolveVanityURL / GetPlayerSummaries / GetDetails。
/// - 模拟的 SteamCMD 逐步写入暂存文件（驱动真实的进度轮询），完成后放入一个小网页壁纸，走真实的校验与入库；
///   编号能被 11 整除的项目模拟下载失败。
/// 环境变量 `KINETIC_STEAM_DEMO_FAIL_PAGE=<n>` 让第 n 页（从 1 开始）第一次请求失败，用于验证「重试」。
enum SteamStoreDemo {
    static let argument = "--steam-store-demo"
    static let libraryName = "R4-SteamDemo"
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains(argument) }
    static let apiKey = String(repeating: "0", count: 32)

    @MainActor
    static func makeStore() -> SteamStoreService {
        let feed = SteamStoreDemoFeed.shared
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("KineticSteamDemo-\(UUID().uuidString)")
        return SteamStoreService(keyStore: MemorySteamAPIKeyStore(apiKey), cacheDirectory: cache,
                                 posters: SteamPosterCache(directory: cache.appendingPathComponent("Posters"),
                                                           fetch: { try await feed.fetch($0) }),
                                 fetch: { try await feed.fetch($0) })
    }

    @MainActor
    static func makeAcquisition(library: WallpaperLibrary) -> SteamAcquisitionService {
        let root = library.storage.rootURL.appendingPathComponent("DemoSteamCMD", isDirectory: true)
        let installation = SteamCMDInstallation(rootURL: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: installation.scriptURL.path, contents: Data("#!/bin/sh\n".utf8))
        let defaults = UserDefaults(suiteName: "Kinetic.SteamDemo") ?? .standard
        defaults.set("kinetic-demo", forKey: SteamAcquisitionService.usernameKey)
        return SteamAcquisitionService(installation: installation, library: library, defaults: defaults,
                                       makeProcess: { SteamStoreDemoProcess(installation: $0, arguments: $1) })
    }
}

/// 合成的创意工坊目录。
final class SteamStoreDemoFeed: @unchecked Sendable {
    static let shared = SteamStoreDemoFeed()

    struct Item {
        let id: String
        let index: Int
        let title: String
        let creator: String
        let tags: [String]
        let created: Int
        let updated: Int
        let size: Int64
        let description: String
    }

    static let authors: [(id: String, name: String, vanity: String)] = [
        ("76561198000000101", "北境 North", "northlight"),
        ("76561198000000102", "Aurora Studio", "aurora"),
        ("76561198000000103", "像素工坊", "pixelworks"),
        ("76561198000000104", "Ocean Drift", "oceandrift"),
        ("76561198000000105", "Neon Kid", "neonkid"),
        ("76561198000000106", "山海 Atelier", "shanhai"),
    ]
    private static let words = ["极光", "Neon City", "Ocean Waves", "雨夜", "Sakura", "Cyber Street", "星河", "Forest Path",
                                "Retro Arcade", "Desert Dune", "City Lights", "雪山", "Koi Pond", "Galaxy", "Lantern",
                                "Mountain Lake", "Pixel Town", "Thunder", "Aquarium", "Autumn"]
    private static let types = ["Scene", "Video", "Web", "Scene", "Video", "Application"]
    private static let genres = ["Abstract", "Animal", "Anime", "Cartoon", "CGI", "Cyberpunk", "Fantasy", "Game", "Girls",
                                 "Guys", "Landscape", "Medieval", "Memes", "MMD", "Music", "Nature", "Pixel art", "Relaxing",
                                 "Retro", "Sci-Fi", "Sports", "Technology", "Television", "Vehicle", "Unspecified"]
    private static let resolutions = ["3840 x 2160", "1920 x 1080", "Ultrawide 2560 x 1080", "Ultrawide 3440 x 1440",
                                      "Portrait 1080 x 1920", "Dual 3840 x 1080", "2560 x 1440", "Dynamic resolution"]
    private static let misc = ["Approved", "Audio responsive", "3D", "Customizable", "Puppet Warp", "HDR",
                               "Media Integration", "User Shortcut", "Video Texture", "Asset Pack"]
    private static let assetTypes = ["Particle", "Image", "Sound", "Model", "Text", "Sprite", "Fullscreen", "Composite",
                                     "Script", "Effect", "Scripted Layer"]
    private static let assetGenres = ["Audio Visualizer", "Background", "Character", "Clock", "Fire", "Interactive",
                                      "Magic", "Post Processing", "Smoke", "Space"]
    private static let scriptTypes = ["Boolean", "Number", "Vec2", "Vec3", "Vec4", "String", "No Animation", "Oversized"]

    let items: [Item]
    private let lock = NSLock()
    private var failedPages: Set<Int> = []
    private let failPage = ProcessInfo.processInfo.environment["KINETIC_STEAM_DEMO_FAIL_PAGE"].flatMap(Int.init)

    private init() {
        var list: [Item] = []
        for index in 0..<240 {
            let author = Self.authors[index % Self.authors.count]
            var tags = [Self.types[index % Self.types.count]]
            tags.append(index % 29 == 0 ? "Mature" : index % 17 == 0 ? "Questionable" : "Everyone")
            tags.append(Self.genres[(index * 7) % Self.genres.count])
            tags.append(Self.resolutions[(index * 3) % Self.resolutions.count])
            tags.append(Self.misc[index % Self.misc.count])
            if index % 4 == 0 { tags.append(Self.misc[(index / 4 + 3) % Self.misc.count]) }
            switch index % 12 {
            case 5:
                tags.append("Preset")
            case 7:
                tags.append("Asset")
                tags.append(Self.assetTypes[(index / 12) % Self.assetTypes.count])
                tags.append(Self.assetGenres[(index / 12) % Self.assetGenres.count])
                tags.append(Self.scriptTypes[(index / 12) % Self.scriptTypes.count])
            default:
                tags.append("Wallpaper")
            }
            let created = 1_790_000_000 - index * 3_600
            let title = "\(Self.words[index % Self.words.count]) \(String(format: "%03d", index + 1))"
            let description = """
            [h1]\(title)[/h1]
            作者 \(author.name) 的演示壁纸（Kinetic Debug 验收数据，不来自 Steam）。

            [b]特点[/b]
            [list]
            [*] 第 \(index + 1) 张合成项目
            [*] 支持 [i]音频响应[/i] 与自定义颜色
            [/list]
            Visit [url=https://example.com/kinetic-demo]the demo page[/url].
            """
            list.append(Item(id: String(3_900_000_000 + index), index: index, title: title, creator: author.id,
                             tags: tags, created: created, updated: created + (index % 3) * 86_400,
                             size: Int64(1_800_000 + index * 37_000), description: description))
        }
        items = list
    }

    func item(_ id: String) -> Item? { items.first { $0.id == id } }

    func fetch(_ url: URL) async throws -> (Data, Int) {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        func values(_ name: String) -> [String] { query.filter { $0.name.hasPrefix(name + "[") }.compactMap(\.value) }
        if url.host == "kinetic-demo.invalid" {
            let id = url.deletingPathExtension().lastPathComponent
            return (Self.poster(index: item(id)?.index ?? 0), 200)
        }
        try await Task.sleep(nanoseconds: 450_000_000)
        if url.path.contains("GetPlayerSummaries") {
            let ids = Set((value("steamids") ?? "").split(separator: ",").map(String.init))
            let players = Self.authors.filter { ids.contains($0.id) }.map { ["steamid": $0.id, "personaname": $0.name] }
            return (try JSONSerialization.data(withJSONObject: ["response": ["players": players]]), 200)
        }
        if url.path.contains("ResolveVanityURL") {
            let match = Self.authors.first { $0.vanity.caseInsensitiveCompare(value("vanityurl") ?? "") == .orderedSame }
            let response: [String: Any] = match.map { ["steamid": $0.id, "success": 1] } ?? ["success": 42]
            return (try JSONSerialization.data(withJSONObject: ["response": response]), 200)
        }
        if url.path.contains("GetUserFiles") {
            let all = items.filter { $0.creator == value("steamid") }
            let page = Int(value("page") ?? "1") ?? 1
            let slice = Array(all.dropFirst((page - 1) * SteamStoreQuery.pageSize).prefix(SteamStoreQuery.pageSize))
            return (try JSONSerialization.data(withJSONObject: ["response": ["total": all.count,
                                                                             "publishedfiledetails": slice.map(details)]]), 200)
        }
        if url.path.contains("GetDetails") {
            let ids = values("publishedfileids")
            return (try JSONSerialization.data(withJSONObject: ["response": ["publishedfiledetails":
                ids.compactMap { item($0) }.map { details($0, full: true) }]]), 200)
        }
        // QueryFiles
        let required = values("requiredtags").map { $0.lowercased() }
        let excluded = Set(values("excludedtags").map { $0.lowercased() })
        let matchAll = value("match_all_tags") == "true"
        let search = (value("search_text") ?? "").lowercased()
        var matches = items.filter { item in
            let tags = Set(item.tags.map { $0.lowercased() })
            if !tags.isDisjoint(with: excluded) { return false }
            if !required.isEmpty {
                if matchAll { if !required.allSatisfy(tags.contains) { return false } }
                else if !required.contains(where: tags.contains) { return false }
            }
            return search.isEmpty || item.title.lowercased().contains(search) || item.description.lowercased().contains(search)
        }
        if value("query_type") == "0" {
            // 合成热度，故意与时间 / 名称不同；仅用于无需真实 Key 的 Debug 验收。
            matches.sort { ($0.index * 37) % 241 > ($1.index * 37) % 241 }
        } else if !search.isEmpty {
            matches.sort { ($0.title.lowercased().contains(search) ? 0 : 1, $0.index) < ($1.title.lowercased().contains(search) ? 0 : 1, $1.index) }
        }
        let cursor = value("cursor") ?? "*"
        let offset = cursor == "*" ? 0 : Int(cursor.dropFirst()) ?? 0
        let pageNumber = offset / SteamStoreQuery.pageSize + 1
        let shouldFail = lock.withLock { () -> Bool in
            guard pageNumber == failPage, !failedPages.contains(pageNumber) else { return false }
            failedPages.insert(pageNumber)
            return true
        }
        if shouldFail { throw URLError(.timedOut) }
        let slice = Array(matches.dropFirst(offset).prefix(SteamStoreQuery.pageSize))
        let nextOffset = offset + slice.count
        let next = nextOffset < matches.count ? "c\(nextOffset)" : cursor
        let body: [String: Any] = ["response": ["total": matches.count, "next_cursor": next,
                                                "publishedfiledetails": slice.map(details)]]
        return (try JSONSerialization.data(withJSONObject: body), 200)
    }

    private func details(_ item: Item) -> [String: Any] { details(item, full: false) }

    private func details(_ item: Item, full: Bool) -> [String: Any] {
        var details: [String: Any] = [
            "publishedfileid": item.id, "result": 1, "title": item.title, "creator": item.creator,
            "preview_url": "https://kinetic-demo.invalid/poster/\(item.id).png",
            "time_created": item.created, "time_updated": item.updated, "file_size": String(item.size),
            "tags": item.tags.map { ["tag": $0] },
        ]
        if full {
            details["file_description"] = item.description
            details["num_children"] = 0
            if item.index % 3 == 0 { details["num_comments_public"] = item.index }
        }
        return details
    }

    /// 不同比例的合成 Poster（横屏 16:9、竖屏、超宽），颜色随编号变化。
    static func poster(index: Int) -> Data {
        let sizes = [CGSize(width: 640, height: 360), CGSize(width: 360, height: 640), CGSize(width: 840, height: 360),
                     CGSize(width: 640, height: 400)]
        let size = sizes[index % sizes.count]
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return Data() }
        let hue = CGFloat(index % 24) / 24
        let top = NSColor(hue: hue, saturation: 0.65, brightness: 0.95, alpha: 1).cgColor
        let bottom = NSColor(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.8, brightness: 0.35, alpha: 1).cgColor
        if let gradient = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        }
        context.setFillColor(NSColor.white.withAlphaComponent(0.35).cgColor)
        for ring in 0..<3 {
            let radius = CGFloat(30 + ring * 26 + index % 20)
            context.fillEllipse(in: CGRect(x: size.width * CGFloat(0.25 + 0.25 * Double(ring)) - radius / 2,
                                           y: size.height * 0.5 - radius / 2, width: radius, height: radius))
        }
        guard let image = context.makeImage() else { return Data() }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) ?? Data()
    }
}

/// 模拟一次 SteamCMD：只理解 `+workshop_download_item`，其余命令（安装检查等）直接成功退出。
@MainActor
final class SteamStoreDemoProcess: SteamCMDProcess {
    var onOutput: (@MainActor (String) -> Void)?
    var onExit: (@MainActor (Int32) -> Void)?
    private let installation: SteamCMDInstallation
    private let arguments: [String]
    private var task: Task<Void, Never>?
    private var exited = false

    init(installation: SteamCMDInstallation, arguments: [String]) {
        self.installation = installation
        self.arguments = arguments
    }

    func start() throws {
        guard let index = arguments.firstIndex(of: "+workshop_download_item"), arguments.count > index + 2 else {
            DispatchQueue.main.async { self.finish(0) }
            return
        }
        let id = arguments[index + 2]
        let installation = installation
        task = Task { [weak self] in
            let item = SteamStoreDemoFeed.shared.item(id)
            let total = item?.size ?? 2_000_000
            let partial = installation.partialDownloadURL(for: id)
            try? FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
            let steps = 10 + (item?.index ?? 0) % 8
            let chunk = Int(total) / steps
            let file = partial.appendingPathComponent("download.part")
            FileManager.default.createFile(atPath: file.path, contents: nil)
            for _ in 0..<steps {
                try? await Task.sleep(nanoseconds: 450_000_000)
                guard !Task.isCancelled else { return }
                if let handle = try? FileHandle(forWritingTo: file) {
                    handle.seekToEndOfFile()
                    handle.write(Data(count: chunk))
                    try? handle.close()
                }
            }
            try? FileManager.default.removeItem(at: partial)
            guard let self else { return }
            if (Int(id) ?? 0) % 11 == 0 {
                self.onOutput?("ERROR! Download item \(id) failed (Timeout).\n")
                self.finish(1)
                return
            }
            let content = installation.contentURL(for: id)
            try? FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
            let title = item?.title ?? id
            let project = ["type": "web", "file": "index.html", "title": title]
            try? JSONSerialization.data(withJSONObject: project).write(to: content.appendingPathComponent("project.json"))
            let hue = (item?.index ?? 0) % 24 * 15
            let html = """
            <!doctype html><html><body style="margin:0;height:100vh;background:linear-gradient(135deg,hsl(\(hue),70%,60%),hsl(\(hue + 40),70%,25%));\
            display:flex;align-items:center;justify-content:center;font:600 6vw -apple-system;color:white">\(title)</body></html>
            """
            try? Data(html.utf8).write(to: content.appendingPathComponent("index.html"))
            if let poster = item.map({ SteamStoreDemoFeed.poster(index: $0.index) }) {
                try? poster.write(to: content.appendingPathComponent("preview.png"))
            }
            self.onOutput?("Success. Downloaded item \(id) to \"\(content.path)\" (\(total) bytes)\n")
            self.finish(0)
        }
    }

    func writeLine(_ line: String) {}

    func terminate() {
        task?.cancel()
        DispatchQueue.main.async { self.finish(143) }
    }

    private func finish(_ status: Int32) {
        guard !exited else { return }
        exited = true
        onExit?(status)
    }
}
#endif
