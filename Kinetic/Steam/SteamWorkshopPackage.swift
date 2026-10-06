import Foundation
import KineticSceneRuntime

enum SteamWorkshopPackageError: LocalizedError, Equatable {
    case missingProject
    case unreadableProject
    /// 这类创意工坊项目（例如应用程序、预设）不能作为壁纸使用。
    case unsupportedType(String)
    case missingEntry
    case invalidScene(String)
    /// 网页壁纸的入口不是 index.html（WebRenderer 只从 index.html 开始）。
    case webEntryNotIndex
    case containsSymbolicLinks
    case unplayableVideo
    case protectedVideo

    var errorDescription: String? {
        switch self {
        case .missingProject: return NSLocalizedString("steam.package.error.project", comment: "")
        case .unreadableProject: return NSLocalizedString("steam.package.error.projectUnreadable", comment: "")
        case .unsupportedType(let type):
            return String(format: NSLocalizedString("steam.package.error.type", comment: ""), type)
        case .missingEntry: return NSLocalizedString("steam.package.error.entry", comment: "")
        case .invalidScene(let reason):
            return String(format: NSLocalizedString("steam.package.error.scene", comment: ""), reason)
        case .webEntryNotIndex: return NSLocalizedString("steam.package.error.webEntry", comment: "")
        case .containsSymbolicLinks: return NSLocalizedString("import.error.symlink", comment: "")
        case .unplayableVideo: return NSLocalizedString("import.error.video", comment: "")
        case .protectedVideo: return NSLocalizedString("import.error.protected", comment: "")
        }
    }
}

/// 下载完成的 Wallpaper Engine 创意工坊项目（`project.json` + 内容文件）经过校验后的描述。
struct SteamWorkshopPackage: Equatable, Sendable {
    let folderURL: URL
    let title: String?
    let type: WallpaperType
    /// 入口文件相对于 `folderURL` 的路径（视频文件、网页的 index.html、场景的 scene 文件）。
    let entryPath: String
    /// 作者设置的 Poster 相对路径（`project.json` 的 preview）。
    let previewPath: String?
    let sizeInBytes: Int64

    /// 资料库记录的 `resourceURL` 相对于 `folderURL` 的路径：视频是视频文件；网页是 index.html 所在的文件夹；
    /// 场景是整个项目文件夹。
    var resourcePath: String {
        switch type {
        case .video: return entryPath
        case .web: return (entryPath as NSString).deletingLastPathComponent
        case .scene: return ""
        }
    }

    static let projectFileName = "project.json"

    private struct Project: Decodable {
        var title: String?
        var type: String?
        var file: String?
        var preview: String?
    }

    /// 校验下载好的项目。只读，不修改任何文件。
    static func verify(folder: URL) async throws -> SteamWorkshopPackage {
        let fileManager = FileManager.default
        let projectURL = folder.appendingPathComponent(projectFileName)
        guard fileManager.fileExists(atPath: projectURL.path) else { throw SteamWorkshopPackageError.missingProject }
        let project: Project
        do {
            project = try JSONDecoder().decode(Project.self, from: Data(contentsOf: projectURL))
        } catch {
            throw SteamWorkshopPackageError.unreadableProject
        }
        // 与网页导入相同的安全边界：符号链接可能指向项目以外的位置。
        if containsSymbolicLinks(folder) { throw SteamWorkshopPackageError.containsSymbolicLinks }

        guard let entry = project.file?.trimmingCharacters(in: .whitespacesAndNewlines), !entry.isEmpty,
              isSafeRelativePath(entry) else { throw SteamWorkshopPackageError.missingEntry }
        let typeName = (project.type ?? "").lowercased()
        let type: WallpaperType
        switch typeName {
        case "video": type = .video
        case "web": type = .web
        case "scene": type = .scene
        case "":
            // 旧项目可能没有 type：按入口文件判断。
            let ext = (entry as NSString).pathExtension.lowercased()
            if VideoFormats.fileExtensions.contains(ext) { type = .video }
            else if ["html", "htm"].contains(ext) { type = .web }
            else { throw SteamWorkshopPackageError.unsupportedType(project.type ?? "?") }
        default:
            throw SteamWorkshopPackageError.unsupportedType(project.type ?? "?")
        }

        let entryURL = folder.appendingPathComponent(entry)
        if type != .scene, !fileManager.isReadableFile(atPath: entryURL.path) { throw SteamWorkshopPackageError.missingEntry }
        switch type {
        case .video:
            guard VideoFormats.fileExtensions.contains(entryURL.pathExtension.lowercased()) else {
                throw SteamWorkshopPackageError.unplayableVideo
            }
            do { try await LocalImportService.validateVideo(at: entryURL) } catch LocalImportError.protectedVideo {
                throw SteamWorkshopPackageError.protectedVideo
            } catch {
                throw SteamWorkshopPackageError.unplayableVideo
            }
        case .web:
            guard webEntryNames.contains(entryURL.lastPathComponent.lowercased()) else {
                throw SteamWorkshopPackageError.webEntryNotIndex
            }
        case .scene:
            do { _ = try SceneImportMetadata.inspect(root: folder) }
            catch SceneRuntimeError.missingAsset(let path) where path == entry {
                throw SteamWorkshopPackageError.missingEntry
            } catch {
                throw SteamWorkshopPackageError.invalidScene(error.localizedDescription)
            }
        }

        var previewPath: String?
        if let preview = project.preview?.trimmingCharacters(in: .whitespacesAndNewlines), !preview.isEmpty,
           isSafeRelativePath(preview), fileManager.isReadableFile(atPath: folder.appendingPathComponent(preview).path) {
            previewPath = preview
        }
        let title = project.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return SteamWorkshopPackage(folderURL: folder, title: (title?.isEmpty ?? true) ? nil : title, type: type,
                                    entryPath: entry, previewPath: previewPath,
                                    sizeInBytes: LocalImportFiles.fingerprint(of: folder)?.size ?? 0)
    }

    /// 与 `LocalImportService.webEntryNames` 相同：WebRenderer 只从 index.html 开始。
    static let webEntryNames: Set<String> = ["index.html", "index.htm"]

    /// 与本地网页导入相同的检查，但可以在后台执行（下载的项目可能有很多文件）。
    static func containsSymbolicLinks(_ folder: URL) -> Bool {
        guard let enumerator = FileManager().enumerator(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
            return true
        }
        for case let item as URL in enumerator {
            if (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { return true }
        }
        return false
    }

    /// 只接受项目内部的相对路径（不能是绝对路径，也不能用 `..` 跳出项目）。
    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.hasPrefix("/"), !path.hasPrefix("~") else { return false }
        return !path.split(separator: "/").contains("..")
    }
}
