import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum LocalImportError: LocalizedError, Equatable {
    case unsupportedItem
    case unreadable
    case missingWebEntry
    case containsSymbolicLinks
    case unplayableVideo
    case copyFailed(String)
    case libraryFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedItem: return NSLocalizedString("import.error.unsupported", comment: "")
        case .unreadable: return NSLocalizedString("import.error.unreadable", comment: "")
        case .missingWebEntry: return NSLocalizedString("import.error.webEntry", comment: "")
        case .containsSymbolicLinks: return NSLocalizedString("import.error.symlink", comment: "")
        case .unplayableVideo: return NSLocalizedString("import.error.video", comment: "")
        case .copyFailed(let reason):
            return String(format: NSLocalizedString("import.error.copy", comment: ""), reason)
        case .libraryFailed(let reason):
            return String(format: NSLocalizedString("import.error.library", comment: ""), reason)
        }
    }
}

enum LocalImportKind: Equatable, Sendable {
    case video
    case webFolder
}

struct LocalImportOutcome {
    let sourceURL: URL
    let result: Result<Wallpaper, LocalImportError>
    /// 导入前后原始项目的大小与修改时间一致（Kinetic 从不写入原始文件）。
    let sourceUnchanged: Bool

    var wallpaper: Wallpaper? { try? result.get() }
}

/// 本地导入。
/// 把本地 MP4 / MOV 或网页壁纸文件夹**复制**到 Kinetic 管理的 Library Storage，再加入资料库。
/// 绝不移动、修改或删除用户的原始文件。网页壁纸照常入库，但暂不能播放。
/// 不负责界面入口。
@MainActor
final class LocalImportService {
    static let videoExtensions: Set<String> = ["mp4", "mov"]
    static let webEntryNames = ["index.html", "index.htm"]
    static let webPreviewNames = ["preview.jpg", "preview.jpeg", "preview.png", "preview.gif"]
    static let thumbnailFileName = "kinetic-preview.jpg"

    let library: WallpaperLibrary
    private(set) var isImporting = false

    init(library: WallpaperLibrary) {
        self.library = library
        // 只清理 Kinetic 自己上次中断留下的临时暂存目录；不触碰任何已导入内容。
        LocalImportFiles.removeStaleStaging(in: library.storage.wallpapersDirectoryURL)
    }

    /// 逐个导入；某一项失败不影响其余项目。结果顺序与输入一致。
    func importItems(at urls: [URL]) async -> [LocalImportOutcome] {
        isImporting = true
        defer { isImporting = false }
        var outcomes: [LocalImportOutcome] = []
        for url in urls { outcomes.append(await importItem(at: url)) }
        return outcomes
    }

    func importItem(at url: URL) async -> LocalImportOutcome {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let source = url.resolvingSymlinksInPath()
        let before = LocalImportFiles.fingerprint(of: source)
        let result: Result<Wallpaper, LocalImportError>
        do {
            result = .success(try await performImport(of: source))
        } catch let error as LocalImportError {
            result = .failure(error)
        } catch {
            result = .failure(.copyFailed(error.localizedDescription))
        }
        let after = LocalImportFiles.fingerprint(of: source)
        return LocalImportOutcome(sourceURL: url, result: result, sourceUnchanged: before != nil && before == after)
    }

    // MARK: - 流程

    private func performImport(of source: URL) async throws -> Wallpaper {
        let kind = try Self.classify(source)
        if kind == .video { try await Self.validateVideo(at: source) }

        let id = UUID()
        let directory = library.storage.wallpapersDirectoryURL
        let staged = try await Task.detached(priority: .userInitiated) {
            try LocalImportFiles.stage(source, id: id, in: directory)
        }.value

        let final: URL
        var thumbnailPath: String?
        do {
            switch kind {
            case .video:
                if await Self.writeVideoThumbnail(from: staged.contentURL,
                                                  to: staged.stagingURL.appendingPathComponent(Self.thumbnailFileName)) {
                    thumbnailPath = Self.thumbnailFileName
                }
            case .webFolder:
                thumbnailPath = Self.webPreviewName(in: staged.contentURL).map { "\(staged.contentName)/\($0)" }
            }
            final = try LocalImportFiles.finalize(staged, id: id, in: directory)
        } catch {
            LocalImportFiles.remove(staged.stagingURL)
            throw error
        }

        let wallpaper = Wallpaper(
            id: id,
            name: Self.displayName(for: source, kind: kind),
            type: kind == .video ? .video : .web,
            source: .local,
            resourceURL: final.appendingPathComponent(staged.contentName, isDirectory: kind == .webFolder),
            thumbnailURL: thumbnailPath.map { final.appendingPathComponent($0) }
        )
        do {
            try library.add(wallpaper)
        } catch {
            // 资料库写入失败：撤回刚复制的内容，避免留下没有记录的文件。
            LocalImportFiles.remove(final)
            throw LocalImportError.libraryFailed(error.localizedDescription)
        }
        return wallpaper
    }

    // MARK: - 识别与校验

    /// 识别可导入的项目：MP4 / MOV 文件，或根目录含 index.html 的网页壁纸文件夹。
    static func classify(_ url: URL) throws -> LocalImportKind {
        guard url.isFileURL else { throw LocalImportError.unsupportedItem }
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]) else {
            throw LocalImportError.unreadable
        }
        if values.isDirectory == true {
            guard webEntryName(in: url) != nil else { throw LocalImportError.missingWebEntry }
            // 符号链接可能指向文件夹以外的位置，违背网页壁纸不得读取任意文件的安全边界。
            if containsSymbolicLinks(url) { throw LocalImportError.containsSymbolicLinks }
            return .webFolder
        }
        guard values.isRegularFile == true, videoExtensions.contains(url.pathExtension.lowercased()) else {
            throw LocalImportError.unsupportedItem
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw LocalImportError.unreadable }
        return .video
    }

    static func webEntryName(in folder: URL) -> String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for wanted in webEntryNames {
            if let match = names.first(where: { $0.lowercased() == wanted }) { return match }
        }
        return nil
    }

    static func webPreviewName(in folder: URL) -> String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for wanted in webPreviewNames {
            if let match = names.first(where: { $0.lowercased() == wanted }) { return match }
        }
        return nil
    }

    static func containsSymbolicLinks(_ folder: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
            return true
        }
        for case let item as URL in enumerator {
            if (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { return true }
        }
        return false
    }

    /// 与 VideoRenderer 的准备条件一致：可播放、时长有效、有视频轨道。
    static func validateVideo(at url: URL) async throws {
        let asset = AVURLAsset(url: url)
        do {
            let playable = try await asset.load(.isPlayable)
            let duration = try await asset.load(.duration)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard playable, duration.isNumeric, duration.seconds.isFinite, duration.seconds > 0, !tracks.isEmpty else {
                throw LocalImportError.unplayableVideo
            }
        } catch {
            throw LocalImportError.unplayableVideo
        }
    }

    static func displayName(for source: URL, kind: LocalImportKind) -> String {
        let name = kind == .video ? source.deletingPathExtension().lastPathComponent : source.lastPathComponent
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? NSLocalizedString("import.untitled", comment: "") : trimmed
    }

    /// 预览图取 min(1 秒, 时长 10%) 处的一帧，避免片头黑场；失败不影响导入。
    static func writeVideoThumbnail(from video: URL, to destination: URL) async -> Bool {
        let asset = AVURLAsset(url: video)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 960)
        do {
            let duration = try await asset.load(.duration)
            let seconds = duration.isNumeric ? min(1.0, max(0, duration.seconds * 0.1)) : 0
            let (image, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
            guard let target = CGImageDestinationCreateWithURL(destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
                return false
            }
            CGImageDestinationAddImage(target, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            return CGImageDestinationFinalize(target)
        } catch {
            return false
        }
    }
}

/// 文件操作。可在后台线程执行；只写入 Library Storage，从不写入原始位置。
enum LocalImportFiles {
    static let stagingPrefix = ".staging-"

    struct Staged: Sendable {
        let stagingURL: URL
        let contentURL: URL
        let contentName: String
    }

    struct Fingerprint: Equatable {
        let size: Int64
        let modified: Date?
        let itemCount: Int
    }

    /// 复制到临时暂存目录；成功后由 finalize 一次性改名为正式目录，避免出现半成品。
    static func stage(_ source: URL, id: UUID, in directory: URL) throws -> Staged {
        let fileManager = FileManager.default
        let staging = directory.appendingPathComponent(stagingPrefix + id.uuidString, isDirectory: true)
        let name = source.lastPathComponent
        let content = staging.appendingPathComponent(name)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
            try fileManager.copyItem(at: source, to: content)
        } catch {
            remove(staging)
            throw LocalImportError.copyFailed(error.localizedDescription)
        }
        return Staged(stagingURL: staging, contentURL: content, contentName: name)
    }

    static func finalize(_ staged: Staged, id: UUID, in directory: URL) throws -> URL {
        let final = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        do {
            try FileManager.default.moveItem(at: staged.stagingURL, to: final)
        } catch {
            throw LocalImportError.copyFailed(error.localizedDescription)
        }
        return final
    }

    static func removeStaleStaging(in directory: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(stagingPrefix) {
            remove(directory.appendingPathComponent(name, isDirectory: true))
        }
    }

    /// 只用于 Library Storage 内部的路径。
    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func fingerprint(of url: URL) -> Fingerprint? {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        guard values.isDirectory == true else {
            return Fingerprint(size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate, itemCount: 1)
        }
        var size: Int64 = 0, count = 0
        var latest = values.contentModificationDate
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys))
        while let item = enumerator?.nextObject() as? URL {
            let itemValues = try? item.resourceValues(forKeys: keys)
            size += Int64(itemValues?.fileSize ?? 0)
            count += 1
            if let date = itemValues?.contentModificationDate, date > (latest ?? .distantPast) { latest = date }
        }
        return Fingerprint(size: size, modified: latest, itemCount: count)
    }
}
