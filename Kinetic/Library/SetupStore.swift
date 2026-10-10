import Combine
import Foundation

/// Module 48：书签与方案的本地数据（bookmarks.json、schemes.json），与资料库格式分开保存。
/// 写入先原子落盘再更新内存；损坏文件先改名备份，不覆盖用户资料。
@MainActor
final class SetupStore: ObservableObject {
    private struct BookmarkDocument: Codable { var version = 1; var bookmarks: [WallpaperBookmark] = [] }
    private struct SchemeDocument: Codable { var version = 1; var schemes: [WallpaperScheme] = [] }

    static let maximumBookmarks = 256
    static let maximumSchemes = 64
    static let maximumBytes = 8 * 1_024 * 1_024

    @Published private(set) var bookmarks: [WallpaperBookmark] = []
    @Published private(set) var schemes: [WallpaperScheme] = []
    let bookmarksURL: URL
    let schemesURL: URL
    private var bookmarksLocked = false
    private var schemesLocked = false

    init(storage: LibraryStorageLocation) {
        bookmarksURL = storage.rootURL.appendingPathComponent("bookmarks.json")
        schemesURL = storage.rootURL.appendingPathComponent("schemes.json")
        if let document: BookmarkDocument = Self.load(bookmarksURL, locked: &bookmarksLocked), document.version == 1 {
            bookmarks = Array(document.bookmarks.prefix(Self.maximumBookmarks))
        }
        if let document: SchemeDocument = Self.load(schemesURL, locked: &schemesLocked), document.version == 1 {
            schemes = Array(document.schemes.prefix(Self.maximumSchemes))
        }
    }

    // MARK: - 书签

    @discardableResult
    func addBookmark(name: String, configuration: StagedDisplayWallpaperConfiguration) throws -> UUID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SetupError.emptyName }
        guard configuration.wallpaperID != nil else { throw SetupError.noWallpaper }
        guard bookmarks.count < Self.maximumBookmarks else { throw SetupError.full }
        let bookmark = WallpaperBookmark(name: trimmed, configuration: configuration)
        try saveBookmarks(bookmarks + [bookmark])
        return bookmark.id
    }

    func renameBookmark(_ id: UUID, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SetupError.emptyName }
        var next = bookmarks
        guard let index = next.firstIndex(where: { $0.id == id }) else { throw SetupError.notFound }
        next[index].name = trimmed
        try saveBookmarks(next)
    }

    func deleteBookmark(_ id: UUID) throws { try saveBookmarks(bookmarks.filter { $0.id != id }) }

    func bookmark(id: UUID) -> WallpaperBookmark? { bookmarks.first { $0.id == id } }

    // MARK: - 方案

    @discardableResult
    func addScheme(_ scheme: WallpaperScheme) throws -> UUID {
        var value = scheme
        value.name = scheme.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.name.isEmpty else { throw SetupError.emptyName }
        guard schemes.count < Self.maximumSchemes else { throw SetupError.full }
        try saveSchemes(schemes + [value])
        return value.id
    }

    func deleteScheme(_ id: UUID) throws { try saveSchemes(schemes.filter { $0.id != id }) }

    func scheme(id: UUID) -> WallpaperScheme? { schemes.first { $0.id == id } }

    // MARK: - 文件

    private func saveBookmarks(_ next: [WallpaperBookmark]) throws {
        guard !bookmarksLocked else { throw SetupError.unreadable }
        try write(BookmarkDocument(bookmarks: next), to: bookmarksURL)
        bookmarks = next
    }

    private func saveSchemes(_ next: [WallpaperScheme]) throws {
        guard !schemesLocked else { throw SetupError.unreadable }
        try write(SchemeDocument(schemes: next), to: schemesURL)
        schemes = next
    }

    private func write<Document: Encodable>(_ document: Document, to url: URL) throws {
        if let info = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]), info.isSymbolicLink == true { throw SetupError.unreadable }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(document)
        guard data.count <= Self.maximumBytes else { throw SetupError.full }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private static func load<Document: Decodable>(_ url: URL, locked: inout Bool) -> Document? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let info = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true,
                  (info.fileSize ?? Int.max) <= maximumBytes else { throw SetupError.unreadable }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Document.self, from: Data(contentsOf: url))
        } catch {
            let name = url.deletingPathExtension().lastPathComponent
            let backup = url.deletingLastPathComponent().appendingPathComponent("\(name).unreadable-\(UUID().uuidString).json")
            if (try? FileManager.default.moveItem(at: url, to: backup)) == nil { locked = true }
            return nil
        }
    }
}

enum SetupError: LocalizedError {
    case emptyName, noWallpaper, full, notFound, unreadable
    var errorDescription: String? {
        switch self {
        case .emptyName: return "请输入名称。"
        case .noWallpaper: return "先选择一张壁纸。"
        case .full: return "数量已达上限，请先删除一些。"
        case .notFound: return "找不到这个书签或方案。"
        case .unreadable: return "书签或方案数据无法读取，已保留原文件。"
        }
    }
}
