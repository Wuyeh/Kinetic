import Foundation
import KineticSceneRuntime

/// Module 28：Scene 壁纸在 `project.json` 的 `dependencies` 里列出的创意工坊素材包（通常是其他作者的资源）。
///
/// - 从 Steam 获取 Scene 壁纸时，Kinetic 用同一个账号把缺少的依赖项一起下载，复制到
///   `<资料库>/WorkshopDependencies/<创意工坊编号>/`。它们不是资料库里的壁纸：不显示、不能应用，只给场景引擎挂载读取。
/// - 播放时按编号查找：先找这里，再找资料库中同编号的 Scene 壁纸（它的项目文件夹）。找不到时场景明确报告缺少哪个依赖，
///   不会绕开它渲染。
/// - 不再被资料库中任何 Scene 引用的依赖项在启动时删除。
@MainActor
struct WorkshopDependencyStore {
    static let folderName = "WorkshopDependencies"
    let rootURL: URL

    init(storage: LibraryStorageLocation) {
        rootURL = storage.rootURL.appendingPathComponent(Self.folderName, isDirectory: true)
    }

    /// 创意工坊编号：只有数字（防止路径注入）。
    nonisolated static func isWorkshopID(_ id: String) -> Bool {
        (1...20).contains(id.count) && id.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
    }

    /// 有 `scene.pkg` 或 `project.json` 的文件夹才算一个创意工坊项目。
    nonisolated static func isWorkshopItem(_ folder: URL) -> Bool {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
        return ["scene.pkg", "project.json"].contains { name in
            var isFolder: ObjCBool = false
            return fileManager.fileExists(atPath: folder.appendingPathComponent(name).path, isDirectory: &isFolder)
                && !isFolder.boolValue
        }
    }

    /// 本机上的依赖项文件夹；没有时为 nil。
    func folder(for id: String, library: WallpaperLibrary?) -> URL? {
        guard Self.isWorkshopID(id) else { return nil }
        let stored = rootURL.appendingPathComponent(id, isDirectory: true)
        if Self.isWorkshopItem(stored) { return stored }
        if let wallpaper = library?.wallpaper(workshopID: id), wallpaper.type == .scene,
           Self.isWorkshopItem(wallpaper.resourceURL) {
            return wallpaper.resourceURL
        }
        return nil
    }

    /// 这个 Scene 需要、而本机还没有的依赖项（按 `project.json` 中的顺序，去重）。
    func missingDependencies(of wallpaper: Wallpaper, library: WallpaperLibrary?) -> [String] {
        guard wallpaper.type == .scene else { return [] }
        var seen = Set<String>()
        return KineticSceneRuntime.workshopDependencies(of: wallpaper.resourceURL).filter { id in
            guard Self.isWorkshopID(id), seen.insert(id).inserted else { return false }
            return folder(for: id, library: library) == nil
        }
    }

    /// 把 SteamCMD 下载的依赖项复制进来：先复制到暂存目录，再一次性换成正式目录（替换旧版本）。
    /// 不是创意工坊项目或包含符号链接的文件夹不会被收下。
    @discardableResult
    func install(_ downloaded: URL, workshopID: String) async throws -> URL {
        guard Self.isWorkshopID(workshopID) else { throw LocalImportError.copyFailed(workshopID) }
        guard Self.isWorkshopItem(downloaded) else { throw SteamWorkshopPackageError.missingProject }
        guard !SteamWorkshopPackage.containsSymbolicLinks(downloaded) else { throw SteamWorkshopPackageError.containsSymbolicLinks }
        let root = rootURL
        let target = root.appendingPathComponent(workshopID, isDirectory: true)
        let staging = root.appendingPathComponent(LocalImportFiles.stagingPrefix + UUID().uuidString, isDirectory: true)
        do {
            try await Task.detached(priority: .userInitiated) {
                let fileManager = FileManager()
                try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
                try fileManager.copyItem(at: downloaded, to: staging)
                if fileManager.fileExists(atPath: target.path) {
                    _ = try fileManager.replaceItemAt(target, withItemAt: staging)
                } else {
                    try fileManager.moveItem(at: staging, to: target)
                }
            }.value
        } catch {
            LocalImportFiles.remove(staging)
            throw LocalImportError.copyFailed(error.localizedDescription)
        }
        return target
    }

    /// 删除资料库中已没有 Scene 引用的依赖项，以及中断留下的暂存目录。只在没有壁纸播放时（启动时）调用。
    func removeUnreferenced(library: WallpaperLibrary) {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: rootURL.path) else { return }
        var referenced = Set<String>()
        for wallpaper in library.wallpapers where wallpaper.type == .scene {
            referenced.formUnion(KineticSceneRuntime.workshopDependencies(of: wallpaper.resourceURL))
        }
        for name in names where name.hasPrefix(LocalImportFiles.stagingPrefix) || (Self.isWorkshopID(name) && !referenced.contains(name)) {
            try? fileManager.removeItem(at: rootURL.appendingPathComponent(name, isDirectory: true))
        }
    }
}
