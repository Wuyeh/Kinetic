import Foundation
import os

enum WallpaperDeletionError: LocalizedError, Equatable {
    case notFound
    /// Runtime 或悬停预览仍持有这张壁纸，不能删除。
    case stillInUse
    case storage

    var errorDescription: String? {
        switch self {
        case .notFound: return NSLocalizedString("delete.error.notFound", comment: "")
        case .stillInUse: return NSLocalizedString("delete.error.inUse", comment: "")
        case .storage: return NSLocalizedString("delete.error.storage", comment: "")
        }
    }
}

/// 删除壁纸的唯一流程。右键菜单与 Backspace 在用户确认后都调用这里。
///
/// 顺序：
/// 1. 停止这张壁纸的悬停预览；
/// 2. 若它正在桌面上使用或正在准备：停止 Runtime，恢复 macOS 原始壁纸并释放 Renderer；
/// 3. 确认 Runtime 与预览都不再持有它；
/// 4. 把 Kinetic 为它管理的目录移到待删除位置，再移除资料库记录（失败时把目录移回原处）；
/// 5. 稍后彻底删除移走的目录。
///
/// 只删除 Library Storage 中 `Wallpapers/<id>` 这一个目录；用户的原始文件和 Steam 管理的内容一律不动。
@MainActor
struct WallpaperDeletionService {
    /// 已移出、等待彻底删除的目录名前缀。App 下次启动时会清理残留。
    nonisolated static let pendingRemovalPrefix = ".deleting-"

    let library: WallpaperLibrary
    let runtime: WallpaperRuntimeManager
    let previewCoordinator: WallpaperPreviewCoordinator
    /// 移出目录后等待多久再彻底删除（覆盖 Crossfade 中正在淡出的旧画面）。
    var fileRemovalDelay: TimeInterval = 1

    private static let log = Logger(subsystem: "com.kinetic.app", category: "Delete")

    func delete(_ id: Wallpaper.ID) throws {
        guard let wallpaper = library.wallpaper(id: id) else { throw WallpaperDeletionError.notFound }

        previewCoordinator.hoverEnded(id)
        // 1.0：只停止正在显示或准备这张壁纸的显示器，其他显示器不变。
        if runtime.isUsing(id) {
            runtime.stop(displaysInvolving: id)
        }
        guard !runtime.isUsing(id), previewCoordinator.activePreviewWallpaperID != id else {
            throw WallpaperDeletionError.stillInUse
        }

        let staged = try stageManagedFolder(of: wallpaper)
        do {
            _ = try library.remove(id: id)
        } catch {
            if let staged {
                do { try FileManager.default.moveItem(at: staged.pending, to: staged.original) } catch {
                    Self.log.error("Could not restore wallpaper files after a failed deletion")
                }
            }
            throw error
        }
        if let staged { Self.scheduleRemoval(of: staged.pending, after: fileRemovalDelay) }
    }

    /// Kinetic 为这张壁纸管理的目录；资源不在其中（Steam 管理的内容、异常记录）时返回 nil。
    func managedFolder(for wallpaper: Wallpaper) -> URL? {
        let folder = library.storage.wallpapersDirectoryURL
            .appendingPathComponent(wallpaper.id.uuidString, isDirectory: true)
        guard wallpaper.resourceURL.isFileURL, Self.isInside(wallpaper.resourceURL, folder: folder) else { return nil }
        return folder
    }

    private func stageManagedFolder(of wallpaper: Wallpaper) throws -> (original: URL, pending: URL)? {
        guard let folder = managedFolder(for: wallpaper),
              FileManager.default.fileExists(atPath: folder.path) else { return nil }
        let pending = library.storage.wallpapersDirectoryURL.appendingPathComponent(
            "\(Self.pendingRemovalPrefix)\(wallpaper.id.uuidString)-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.moveItem(at: folder, to: pending)
        } catch {
            Self.log.error("Could not move wallpaper files for deletion")
            throw WallpaperDeletionError.storage
        }
        return (folder, pending)
    }

    nonisolated static func isInside(_ url: URL, folder: URL) -> Bool {
        let folderPath = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix(folderPath.hasSuffix("/") ? folderPath : folderPath + "/")
    }

    nonisolated static func scheduleRemoval(of url: URL, after delay: TimeInterval) {
        Task.detached(priority: .utility) {
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            try? FileManager().removeItem(at: url)
        }
    }

    /// 启动时清理上次未完成的彻底删除；只处理带待删除前缀的目录。
    nonisolated static func removeLeftovers(in storage: LibraryStorageLocation) {
        let fileManager = FileManager()
        let directory = storage.wallpapersDirectoryURL
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(pendingRemovalPrefix) {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
