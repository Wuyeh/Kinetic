import Foundation

/// 创意工坊项目的在线信息（来自 Steam 在线商店，Module 14）。入库时写进 `SteamMetadata`。
struct SteamWorkshopItemInfo: Equatable, Sendable {
    let workshopID: String
    var title: String?
    var authorName: String?
    var fileSize: Int64?
    var timeUpdated: Date?

    init(workshopID: String, title: String? = nil, authorName: String? = nil, fileSize: Int64? = nil,
         timeUpdated: Date? = nil) {
        self.workshopID = workshopID
        self.title = title
        self.authorName = authorName
        self.fileSize = fileSize
        self.timeUpdated = timeUpdated
    }
}

/// 1.0 Module 9：把校验通过的创意工坊项目复制进本地资料库（规格 11、24）。
///
/// - 内容放在 `Wallpapers/<记录标识>/<版本>/<创意工坊编号>/`。整个 `Wallpapers/<记录标识>` 仍是删除流程管理的目录。
/// - 同一创意工坊项目只有一条记录（`addOrUpdateWorkshopItem`）：更新时保留原标识、喜爱、加入时间与设置。
/// - 更新时新内容放进新的版本目录，记录指向新版本；旧版本只在没有显示器使用它时立即删除，
///   正在使用时保留（规格 24：默认不强制热切），下次启动时清理（`removeStaleVersions`）。
/// - 只入库：不应用、不改变任何显示器。
@MainActor
struct SteamWorkshopImporter {
    let library: WallpaperLibrary

    func importPackage(_ package: SteamWorkshopPackage, item: SteamWorkshopItemInfo,
                       isInUse: @MainActor (Wallpaper.ID) -> Bool) async throws -> Wallpaper {
        let existing = library.wallpaper(workshopID: item.workshopID)
        let recordID = existing?.id ?? UUID()
        let recordFolder = library.storage.wallpapersDirectoryURL.appendingPathComponent(recordID.uuidString,
                                                                                         isDirectory: true)
        let version = "v-\(UUID().uuidString)"
        let versionFolder = recordFolder.appendingPathComponent(version, isDirectory: true)
        let source = package.folderURL
        let workshopID = item.workshopID

        // 先复制到暂存目录，再一次性改名为正式的版本目录，不会留下半成品。
        let staging = recordFolder.appendingPathComponent(LocalImportFiles.stagingPrefix + version, isDirectory: true)
        let content = staging.appendingPathComponent(workshopID, isDirectory: true)
        do {
            try await Task.detached(priority: .userInitiated) {
                let fileManager = FileManager()
                try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
                try fileManager.copyItem(at: source, to: content)
            }.value
        } catch {
            LocalImportFiles.remove(staging)
            if existing == nil { Self.removeIfEmpty(recordFolder) }
            throw LocalImportError.copyFailed(error.localizedDescription)
        }

        // 没有作者 Poster 的视频：从合适的时间点抽一帧（与本地导入相同，避开黑色片头）。
        var previewPath = package.previewPath
        if previewPath == nil, package.type == .video {
            if await LocalImportService.writeVideoThumbnail(
                from: content.appendingPathComponent(package.entryPath),
                to: content.appendingPathComponent(LocalImportService.thumbnailFileName)) {
                previewPath = LocalImportService.thumbnailFileName
            }
        }

        do {
            try FileManager.default.moveItem(at: staging, to: versionFolder)
        } catch {
            LocalImportFiles.remove(staging)
            if existing == nil { Self.removeIfEmpty(recordFolder) }
            throw LocalImportError.copyFailed(error.localizedDescription)
        }

        let finalContent = versionFolder.appendingPathComponent(workshopID, isDirectory: true)
        let resource = package.resourcePath.isEmpty
            ? finalContent
            : finalContent.appendingPathComponent(package.resourcePath, isDirectory: package.type != .video)
        let now = Date()
        let name = [item.title, package.title].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
            ?? String(format: NSLocalizedString("steam.item.untitled", comment: ""), workshopID)
        let record = Wallpaper(
            id: recordID,
            name: name,
            type: package.type,
            acquisitionOrigin: .steamWorkshop,
            resourceURL: resource,
            thumbnailURL: previewPath.map { finalContent.appendingPathComponent($0) },
            steamMetadata: SteamMetadata(workshopID: workshopID,
                                         author: item.authorName ?? existing?.steamMetadata?.author,
                                         sizeInBytes: item.fileSize ?? package.sizeInBytes,
                                         remoteUpdatedAt: item.timeUpdated),
            importedAt: now,
            updatedAt: now
        )
        let savedID: Wallpaper.ID
        do {
            savedID = try library.addOrUpdateWorkshopItem(record)
        } catch {
            LocalImportFiles.remove(versionFolder)
            if existing == nil { Self.removeIfEmpty(recordFolder) }
            throw LocalImportError.libraryFailed(error.localizedDescription)
        }
        guard let saved = library.wallpaper(id: savedID) else { throw LocalImportError.libraryFailed("") }

        // 旧版本：没有显示器在使用时立即删除；正在使用时保留到下次启动。
        if !isInUse(savedID) { Self.removeStaleVersions(of: saved, in: library.storage) }
        return saved
    }

    /// 删除这条 Steam 记录不再使用的旧版本目录。只处理 `Wallpapers/<记录标识>/` 中以 `v-` 开头的目录。
    nonisolated static func removeStaleVersions(of wallpaper: Wallpaper, in storage: LibraryStorageLocation) {
        guard wallpaper.acquisitionOrigin == .steamWorkshop else { return }
        let fileManager = FileManager()
        let recordFolder = storage.wallpapersDirectoryURL.appendingPathComponent(wallpaper.id.uuidString,
                                                                                 isDirectory: true)
        guard WallpaperDeletionService.isInside(wallpaper.resourceURL, folder: recordFolder) else { return }
        let names = (try? fileManager.contentsOfDirectory(atPath: recordFolder.path)) ?? []
        for name in names where name.hasPrefix("v-") || name.hasPrefix(LocalImportFiles.stagingPrefix) {
            let folder = recordFolder.appendingPathComponent(name, isDirectory: true)
            if !WallpaperDeletionService.isInside(wallpaper.resourceURL, folder: folder)
                && wallpaper.resourceURL.standardizedFileURL != folder.standardizedFileURL {
                try? fileManager.removeItem(at: folder)
            }
        }
    }

    /// 启动时（还没有任何壁纸在播放）清理全部 Steam 记录的旧版本。
    static func removeStaleVersions(in library: WallpaperLibrary) {
        for wallpaper in library.wallpapers where wallpaper.acquisitionOrigin == .steamWorkshop {
            removeStaleVersions(of: wallpaper, in: library.storage)
        }
    }

    private static func removeIfEmpty(_ folder: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        if names.isEmpty { try? FileManager.default.removeItem(at: folder) }
    }
}
