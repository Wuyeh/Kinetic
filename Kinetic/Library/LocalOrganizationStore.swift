import Combine
import Foundation

/// R2：列表只引用本地 Wallpaper ID，不复制或移动壁纸资源。
struct WallpaperList: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var description: String?
    var coverImageURL: URL?
    var wallpaperIDs: [Wallpaper.ID]
    let createdAt: Date
    var updatedAt: Date
    /// Content Header：每张壁纸被加入这个列表的时间（列表页面的「添加时间」）。
    /// 只做最小扩展：成员与顺序仍由 `wallpaperIDs` 决定；这个字段出现之前加入的成员没有时间。
    var itemAddedAt: [Wallpaper.ID: Date]?

    /// 列表成员与加入时间（规格：WallpaperListItem）。
    var items: [WallpaperListItem] {
        wallpaperIDs.map { WallpaperListItem(wallpaperID: $0, addedAt: itemAddedAt?[$0]) }
    }

    func addedAt(_ id: Wallpaper.ID) -> Date? { itemAddedAt?[id] }
}

/// 列表中的一张壁纸：只引用本地 Wallpaper ID，外加加入列表的时间。
struct WallpaperListItem: Equatable {
    let wallpaperID: Wallpaper.ID
    let addedAt: Date?
}

enum LocalOrganizationError: LocalizedError {
    case emptyName
    case listNotFound
    case unreadableData

    var errorDescription: String? {
        switch self {
        case .emptyName: return NSLocalizedString("lists.error.emptyName", comment: "")
        case .listNotFound: return NSLocalizedString("lists.error.notFound", comment: "")
        case .unreadableData: return NSLocalizedString("lists.error.unreadable", comment: "")
        }
    }
}

private struct LocalOrganizationDocument: Codable {
    var version = 1
    var pinnedIDs: Set<Wallpaper.ID> = []
    var lists: [WallpaperList] = []
}

/// 1.0 R2 本地整理数据，与已锁定的 library.json 格式 2 分开保存。
/// 所有写入先原子落盘再更新内存；损坏文件先备份，不覆盖用户资料。
@MainActor
final class LocalOrganizationStore: ObservableObject {
    @Published private(set) var pinnedIDs: Set<Wallpaper.ID> = []
    @Published private(set) var lists: [WallpaperList] = []

    let storage: LibraryStorageLocation
    private let fileManager: FileManager
    private var cannotOverwriteUnreadable = false

    private var fileURL: URL { storage.rootURL.appendingPathComponent("organization.json") }

    init(storage: LibraryStorageLocation, fileManager: FileManager = .default) {
        self.storage = storage
        self.fileManager = fileManager
        load()
    }

    func isPinned(_ id: Wallpaper.ID) -> Bool { pinnedIDs.contains(id) }

    func setPinned(_ pinned: Bool, for ids: Set<Wallpaper.ID>) throws {
        var document = snapshot
        if pinned { document.pinnedIDs.formUnion(ids) }
        else { document.pinnedIDs.subtract(ids) }
        try commit(document)
    }

    @discardableResult
    func createList(name: String, description: String? = nil, coverSourceURL: URL? = nil,
                    wallpaperIDs: [Wallpaper.ID] = []) throws -> UUID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LocalOrganizationError.emptyName }
        let id = UUID()
        let cover = try coverSourceURL.map { try copyCover($0, id: id) }
        let now = Date()
        var seen = Set<Wallpaper.ID>()
        let uniqueIDs = wallpaperIDs.filter { seen.insert($0).inserted }
        var document = snapshot
        document.lists.append(WallpaperList(id: id, name: trimmed,
                                            description: description?.trimmingCharacters(in: .whitespacesAndNewlines),
                                            coverImageURL: cover, wallpaperIDs: uniqueIDs,
                                            createdAt: now, updatedAt: now,
                                            itemAddedAt: Dictionary(uniqueKeysWithValues: uniqueIDs.map { ($0, now) })))
        do { try commit(document) }
        catch {
            if let cover { try? fileManager.removeItem(at: cover) }
            throw error
        }
        return id
    }

    func renameList(_ id: UUID, name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LocalOrganizationError.emptyName }
        var document = snapshot
        guard let index = document.lists.firstIndex(where: { $0.id == id }) else { throw LocalOrganizationError.listNotFound }
        document.lists[index].name = trimmed
        document.lists[index].updatedAt = Date()
        try commit(document)
    }

    @discardableResult
    func duplicateList(_ id: UUID) throws -> UUID {
        var document = snapshot
        guard let source = document.lists.first(where: { $0.id == id }) else { throw LocalOrganizationError.listNotFound }
        let newID = UUID()
        let now = Date()
        document.lists.append(WallpaperList(id: newID, name: source.name + NSLocalizedString("lists.copySuffix", comment: ""), description: source.description,
                                            coverImageURL: source.coverImageURL, wallpaperIDs: source.wallpaperIDs,
                                            createdAt: now, updatedAt: now, itemAddedAt: source.itemAddedAt))
        try commit(document)
        return newID
    }

    func deleteList(_ id: UUID) throws {
        var document = snapshot
        guard document.lists.contains(where: { $0.id == id }) else { throw LocalOrganizationError.listNotFound }
        document.lists.removeAll { $0.id == id }
        try commit(document)
    }

    func add(_ ids: [Wallpaper.ID], to listID: UUID) throws {
        var document = snapshot
        guard let index = document.lists.firstIndex(where: { $0.id == listID }) else {
            throw LocalOrganizationError.listNotFound
        }
        var seen = Set(document.lists[index].wallpaperIDs)
        let now = Date()
        var addedAt = document.lists[index].itemAddedAt ?? [:]
        for id in ids where seen.insert(id).inserted {
            document.lists[index].wallpaperIDs.append(id)
            addedAt[id] = now
        }
        document.lists[index].itemAddedAt = addedAt
        document.lists[index].updatedAt = now
        try commit(document)
    }

    func removeMissingReferences(validIDs: Set<Wallpaper.ID>) throws {
        var document = snapshot
        document.pinnedIDs.formIntersection(validIDs)
        for index in document.lists.indices {
            document.lists[index].wallpaperIDs.removeAll { !validIDs.contains($0) }
            document.lists[index].itemAddedAt = document.lists[index].itemAddedAt?.filter { validIDs.contains($0.key) }
        }
        if document.pinnedIDs != pinnedIDs || document.lists != lists { try commit(document) }
    }

    private var snapshot: LocalOrganizationDocument {
        LocalOrganizationDocument(pinnedIDs: pinnedIDs, lists: lists)
    }

    private func load() {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        do {
            let document = try JSONDecoder().decode(LocalOrganizationDocument.self, from: Data(contentsOf: fileURL))
            guard document.version == 1 else { throw LocalOrganizationError.unreadableData }
            pinnedIDs = document.pinnedIDs
            lists = document.lists
        } catch {
            let backup = storage.rootURL.appendingPathComponent("organization.unreadable-\(UUID().uuidString).json")
            do { try fileManager.moveItem(at: fileURL, to: backup) }
            catch { cannotOverwriteUnreadable = true }
        }
    }

    private func commit(_ document: LocalOrganizationDocument) throws {
        guard !cannotOverwriteUnreadable else { throw LocalOrganizationError.unreadableData }
        try fileManager.createDirectory(at: storage.rootURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: fileURL, options: .atomic)
        pinnedIDs = document.pinnedIDs
        lists = document.lists
    }

    private func copyCover(_ source: URL, id: UUID) throws -> URL {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        let directory = storage.rootURL.appendingPathComponent("ListCovers", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("\(id.uuidString).\(source.pathExtension.lowercased())")
        try fileManager.copyItem(at: source, to: target)
        return target
    }
}
