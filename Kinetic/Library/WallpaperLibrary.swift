import Combine
import Foundation

enum WallpaperLibraryError: LocalizedError, Equatable {
    case duplicateIdentifier
    /// 同一个 Steam 创意工坊项目已有本地记录（规格 3：不能重复创建）；附带已有记录的标识。
    case duplicateWorkshopItem(Wallpaper.ID)
    /// 期望 Steam 创意工坊记录，但来源或工坊信息不符。
    case notWorkshopItem
    case notFound
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .duplicateIdentifier:
            return NSLocalizedString("library.error.duplicate", comment: "")
        case .duplicateWorkshopItem:
            return NSLocalizedString("library.error.duplicateWorkshopItem", comment: "")
        case .notWorkshopItem:
            return NSLocalizedString("library.error.notWorkshopItem", comment: "")
        case .notFound:
            return NSLocalizedString("library.error.notFound", comment: "")
        case .saveFailed(let reason):
            return String(format: NSLocalizedString("library.error.save", comment: ""), reason)
        }
    }
}

/// 启动时资料库文件无法读取：原文件已原样备份，不会被覆盖或删除。
struct WallpaperLibraryLoadIssue: Equatable {
    let backupURL: URL?
    let reason: String
}

/// 磁盘格式。formatVersion 用于迁移；读取到更新的版本时不覆盖原文件。
/// - 1：v0.1，记录带 `source`（local / steam）。
/// - 2：Kinetic 1.0，记录带 `acquisitionOrigin`、`importedAt`、`updatedAt`、`settings`。
private struct WallpaperLibraryDocument: Codable {
    static let currentVersion = 2
    var formatVersion: Int
    var wallpapers: [Wallpaper]
}

/// Kinetic 1.0 Module 7 — Local Library Persistence。
/// 只维护本地资料库：所有已经保存到本机的壁纸都在这里，来源只记录在 `acquisitionOrigin`。
/// 负责 metadata 的持久化与 v0.1 数据迁移、查询、本地搜索、喜爱、移除记录，以及同一 Steam 创意工坊项目不重复入库。
/// 不负责 Renderer、导入文件复制（Module 8）、Steam 下载（Module 9）或删除内容文件（Module 13）；不联网。
@MainActor
final class WallpaperLibrary: ObservableObject {
    /// 最新加入的在前。
    @Published private(set) var wallpapers: [Wallpaper] = []
    private(set) var loadIssue: WallpaperLibraryLoadIssue?
    /// v0.1 资料库在本次启动时迁移到 1.0 格式后，原文件的备份位置。
    private(set) var migrationBackupURL: URL?
    let storage: LibraryStorageLocation
    private let fileManager: FileManager
    /// 本机资源是否还在；读取与修改时更新，不写入记录。
    private var availabilityCache: [Wallpaper.ID: WallpaperAvailability] = [:]

    init(storage: LibraryStorageLocation, fileManager: FileManager = .default) {
        self.storage = storage
        self.fileManager = fileManager
        load()
    }

    // MARK: - 查询

    func wallpaper(id: Wallpaper.ID) -> Wallpaper? {
        wallpapers.first { $0.id == id }
    }

    func wallpapers(in filter: LibraryFilter) -> [Wallpaper] {
        wallpapers.filter(filter.includes)
    }

    /// 本地即时搜索：只匹配已存储的 metadata。
    func search(_ query: String, in filter: LibraryFilter = .local) -> [Wallpaper] {
        wallpapers.filter { filter.includes($0) && LibrarySearch.matches($0, query: query) }
    }

    /// 已下载的 Steam 创意工坊项目对应的本地记录（Steam 在线页面据此显示「已在资料库」）。
    func wallpaper(workshopID: String) -> Wallpaper? {
        wallpapers.first { $0.steamMetadata?.workshopID == workshopID }
    }

    /// 本机资源是否还在。
    func availability(of id: Wallpaper.ID) -> WallpaperAvailability {
        if let cached = availabilityCache[id] { return cached }
        guard let wallpaper = wallpaper(id: id) else { return .missing }
        return checkAvailability(of: wallpaper)
    }

    /// 重新检查全部记录的本机资源（例如 App 回到前台时）。
    func refreshAvailability() {
        availabilityCache = Dictionary(uniqueKeysWithValues: wallpapers.map { ($0.id, checkAvailability(of: $0)) })
    }

    // MARK: - 修改（先写盘成功，再更新内存；失败时保持原状）

    func add(_ wallpaper: Wallpaper) throws {
        guard self.wallpaper(id: wallpaper.id) == nil else { throw WallpaperLibraryError.duplicateIdentifier }
        // 同一个 Steam 创意工坊项目只能有一条本地记录（规格 3、24）。
        if let workshopID = wallpaper.steamMetadata?.workshopID, let existing = self.wallpaper(workshopID: workshopID) {
            throw WallpaperLibraryError.duplicateWorkshopItem(existing.id)
        }
        var next = wallpapers
        next.insert(wallpaper, at: 0)
        try commit(next)
    }

    /// Steam 创意工坊项目下载或更新完成后入库（规格 24）：
    /// 已有本地记录时更新它的内容信息并保留原标识、喜爱、加入时间与每张壁纸的设置，不创建重复记录；
    /// 没有时作为新记录加入。返回本地记录的标识。
    @discardableResult
    func addOrUpdateWorkshopItem(_ incoming: Wallpaper) throws -> Wallpaper.ID {
        guard incoming.acquisitionOrigin == .steamWorkshop, let workshopID = incoming.steamMetadata?.workshopID else {
            throw WallpaperLibraryError.notWorkshopItem
        }
        guard let existing = wallpaper(workshopID: workshopID) else {
            try add(incoming)
            return incoming.id
        }
        let merged = Wallpaper(
            id: existing.id,
            name: incoming.name,
            type: incoming.type,
            acquisitionOrigin: .steamWorkshop,
            resourceURL: incoming.resourceURL,
            thumbnailURL: incoming.thumbnailURL,
            isFavorite: existing.isFavorite,
            favoritedAt: existing.favoritedAt,
            steamMetadata: incoming.steamMetadata,
            importedAt: existing.importedAt ?? incoming.importedAt,
            updatedAt: incoming.updatedAt,
            settings: existing.settings
        )
        try update(merged)
        return existing.id
    }

    /// 按标识替换，保留原位置。
    func update(_ wallpaper: Wallpaper) throws {
        guard let index = wallpapers.firstIndex(where: { $0.id == wallpaper.id }) else {
            throw WallpaperLibraryError.notFound
        }
        var next = wallpapers
        next[index] = wallpaper
        try commit(next)
    }

    /// 只移除资料库记录，不删除任何文件。
    @discardableResult
    func remove(id: Wallpaper.ID) throws -> Wallpaper {
        guard let index = wallpapers.firstIndex(where: { $0.id == id }) else {
            throw WallpaperLibraryError.notFound
        }
        var next = wallpapers
        let removed = next.remove(at: index)
        try commit(next)
        return removed
    }

    func setFavorite(_ isFavorite: Bool, for id: Wallpaper.ID) throws {
        guard var wallpaper = self.wallpaper(id: id) else { throw WallpaperLibraryError.notFound }
        guard wallpaper.isFavorite != isFavorite else { return }
        wallpaper.isFavorite = isFavorite
        // Content Header：喜爱页面按加入喜爱的时间排序。
        wallpaper.favoritedAt = isFavorite ? Date() : nil
        try update(wallpaper)
    }

    // MARK: - 持久化

    private func load() {
        let url = storage.libraryFileURL
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let document = try JSONDecoder().decode(WallpaperLibraryDocument.self, from: data)
            guard document.formatVersion <= WallpaperLibraryDocument.currentVersion else {
                preserveUnreadableFile(reason: "formatVersion \(document.formatVersion)")
                return
            }
            // 重复标识只保留第一条，避免界面出现同一张壁纸两次。
            var seen = Set<Wallpaper.ID>()
            wallpapers = document.wallpapers.filter { seen.insert($0.id).inserted }
            if document.formatVersion < WallpaperLibraryDocument.currentVersion {
                migrate(from: document.formatVersion, originalData: data)
            }
        } catch {
            preserveUnreadableFile(reason: error.localizedDescription)
        }
        refreshAvailability()
    }

    /// 旧格式（v0.1）读取成功后：先原样备份旧文件，再写成 1.0 格式。记录、顺序、喜爱全部保留。
    /// 写入失败时继续使用内存中的记录，旧文件保持原样，下一次修改时再写。
    /// 已有同名备份且内容不同（例如回到旧版后又产生了新的旧格式文件）时另存一份带时间的备份，不覆盖旧备份。
    private func migrate(from version: Int, originalData: Data) {
        var backup = storage.rootURL.appendingPathComponent("library.v\(version)-backup.json")
        do {
            if fileManager.fileExists(atPath: backup.path), (try? Data(contentsOf: backup)) != originalData {
                backup = storage.rootURL.appendingPathComponent(
                    "library.v\(version)-backup-\(Self.backupTimestamp())-\(UUID().uuidString.prefix(8)).json")
            }
            if !fileManager.fileExists(atPath: backup.path) {
                try originalData.write(to: backup, options: .atomic)
            }
            migrationBackupURL = backup
            try write(wallpapers)
        } catch {
            // 保持旧文件；不影响本次使用。
        }
    }

    private static func backupTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    /// 无法读取的资料库文件改名备份，之后以空资料库继续运行；绝不覆盖用户数据。
    private func preserveUnreadableFile(reason: String) {
        let backup = storage.rootURL.appendingPathComponent(
            "library.unreadable-\(Self.backupTimestamp())-\(UUID().uuidString.prefix(8)).json")
        do {
            try fileManager.moveItem(at: storage.libraryFileURL, to: backup)
            loadIssue = WallpaperLibraryLoadIssue(backupURL: backup, reason: reason)
        } catch {
            loadIssue = WallpaperLibraryLoadIssue(backupURL: nil, reason: reason)
        }
        wallpapers = []
    }

    private func commit(_ next: [Wallpaper]) throws {
        // 读取失败且备份也失败时，原文件仍在原位：拒绝写入，避免覆盖用户数据。
        if let issue = loadIssue, issue.backupURL == nil {
            throw WallpaperLibraryError.saveFailed(issue.reason)
        }
        do {
            try write(next)
        } catch {
            throw WallpaperLibraryError.saveFailed(error.localizedDescription)
        }
        wallpapers = next
        refreshAvailability()
    }

    private func write(_ records: [Wallpaper]) throws {
        try fileManager.createDirectory(at: storage.rootURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(WallpaperLibraryDocument(
            formatVersion: WallpaperLibraryDocument.currentVersion, wallpapers: records))
        try data.write(to: storage.libraryFileURL, options: .atomic)
    }

    /// 只检查本机文件是否存在；非本机地址视为不可用，绝不发起网络请求。
    private func checkAvailability(of wallpaper: Wallpaper) -> WallpaperAvailability {
        let url = wallpaper.resourceURL
        guard url.isFileURL else { return .missing }
        return fileManager.fileExists(atPath: url.path) ? .available : .missing
    }
}
