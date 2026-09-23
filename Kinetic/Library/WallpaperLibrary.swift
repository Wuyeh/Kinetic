import Combine
import Foundation

enum WallpaperLibraryError: LocalizedError, Equatable {
    case duplicateIdentifier
    case notFound
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .duplicateIdentifier:
            return NSLocalizedString("library.error.duplicate", comment: "")
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

/// 磁盘格式。formatVersion 用于将来迁移；读取到更新的版本时不覆盖原文件。
private struct WallpaperLibraryDocument: Codable {
    static let currentVersion = 1
    var formatVersion: Int
    var wallpapers: [Wallpaper]
}

/// 资料库持久化。
/// 负责资料库 metadata 的持久化、查询、筛选、搜索、喜爱与移除记录。
/// 不负责 Renderer、导入文件复制或删除内容文件；不联网。
@MainActor
final class WallpaperLibrary: ObservableObject {
    /// 最新加入的在前。
    @Published private(set) var wallpapers: [Wallpaper] = []
    private(set) var loadIssue: WallpaperLibraryLoadIssue?
    let storage: LibraryStorageLocation
    private let fileManager: FileManager

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
    func search(_ query: String, in filter: LibraryFilter = .all) -> [Wallpaper] {
        wallpapers.filter { filter.includes($0) && LibrarySearch.matches($0, query: query) }
    }

    // MARK: - 修改（先写盘成功，再更新内存；失败时保持原状）

    func add(_ wallpaper: Wallpaper) throws {
        guard self.wallpaper(id: wallpaper.id) == nil else { throw WallpaperLibraryError.duplicateIdentifier }
        var next = wallpapers
        next.insert(wallpaper, at: 0)
        try commit(next)
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
        } catch {
            preserveUnreadableFile(reason: error.localizedDescription)
        }
    }

    /// 无法读取的资料库文件改名备份，之后以空资料库继续运行；绝不覆盖用户数据。
    private func preserveUnreadableFile(reason: String) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backup = storage.rootURL.appendingPathComponent(
            "library.unreadable-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8)).json")
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
            try fileManager.createDirectory(at: storage.rootURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(WallpaperLibraryDocument(
                formatVersion: WallpaperLibraryDocument.currentVersion, wallpapers: next))
            try data.write(to: storage.libraryFileURL, options: .atomic)
        } catch {
            throw WallpaperLibraryError.saveFailed(error.localizedDescription)
        }
        wallpapers = next
    }
}
