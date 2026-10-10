import Foundation

/// Module 50：带版本的 Kinetic 配置备份（规格 35）。一个 JSON 文件，包含设置、资料库记录（含喜爱）、壁纸列表、
/// 显示器分配与参数、书签、方案、叠加层与组件布局、轮播与定时。不含壁纸文件本身，也不含钥匙串里的密码 / API Key。
struct KineticBackup: Codable, Equatable {
    static let format = "com.kinetic.backup"
    static let currentVersion = 1
    static let fileExtension = "kineticbackup"

    var format = KineticBackup.format
    var version = KineticBackup.currentVersion
    var createdAt: Date
    var appVersion: String
    /// The stored settings (UserDefaults `Kinetic.Settings.v1`).
    var settings: Data?
    /// This library's display assignments (UserDefaults `Kinetic.DisplayAssignments.v1`).
    var displayAssignments: Data?
    /// Library-relative path → contents.
    var files: [String: Data] = [:]
}

enum KineticBackupError: LocalizedError, Equatable {
    case unreadable, wrongFormat, newerVersion, tooLarge, invalidEntry(String)
    var errorDescription: String? {
        switch self {
        case .unreadable: return "无法读取这个备份文件。"
        case .wrongFormat: return "这不是 Kinetic 的备份文件。"
        case .newerVersion: return "这个备份来自更新版本的 Kinetic，请先更新 Kinetic。"
        case .tooLarge: return "备份太大，超出可以恢复的上限。"
        case .invalidEntry(let path): return "备份中的「\(path)」无效，未做任何更改。"
        }
    }
}

/// Builds, checks, stages and applies backups. Restoring never writes over live data while Kinetic runs:
/// the backup is staged, and applied at the next launch before anything reads the library.
@MainActor
enum KineticBackupService {
    static let configurationFiles = [
        "library.json", "organization.json", "display-wallpaper-settings.json", "video-settings.json", "web-settings.json",
        "scene-properties.json", "overlays.json", "weather.json", "weather-response.json", "bookmarks.json", "schemes.json",
        "playlist-playback.json", "schedule.json",
    ]
    static let layoutFolder = "WidgetBoardLayouts"
    static let coverFolder = "ListCovers"
    static let pendingFolder = "PendingRestore"
    static let safetyFolder = "RestoreSafety"
    static let maximumFileBytes = 16 * 1_024 * 1_024
    static let maximumTotalBytes = 64 * 1_024 * 1_024
    static let maximumEncodedBytes = 96 * 1_024 * 1_024
    static let keptSafetyCopies = 3

    /// Only configuration files, referenced widget layouts and list covers, by plain name; never a path that leaves the library.
    static func isAllowed(_ path: String) -> Bool {
        if configurationFiles.contains(path) { return true }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, let name = parts.last, !name.isEmpty, !name.hasPrefix("."), name.count <= 80,
              !name.contains("\\"), name != "..", name.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F }) else { return false }
        let stem = (name as NSString).deletingPathExtension
        switch parts[0] {
        case layoutFolder: return name.hasSuffix(".json") && UUID(uuidString: stem) != nil
        case coverFolder: return UUID(uuidString: stem) != nil
        default: return false
        }
    }

    // MARK: - 导出

    static func make(storage: LibraryStorageLocation, defaults: UserDefaults, appVersion: String,
                     now: Date = Date()) throws -> KineticBackup {
        var backup = KineticBackup(createdAt: now, appVersion: appVersion)
        backup.settings = defaults.data(forKey: SettingsStore.storageKey)
        backup.displayAssignments = defaults.dictionary(forKey: DisplayAssignmentStore.storageKey)?[storage.rootURL.path] as? Data
        var paths = configurationFiles
        paths += referencedLayouts(in: storage).map { "\(layoutFolder)/\($0.uuidString).json" }
        paths += referencedCovers(in: storage).map { "\(coverFolder)/\($0)" }
        var total = 0
        for path in paths where isAllowed(path) {
            guard let data = try readRegularFile(storage.rootURL.appendingPathComponent(path)) else { continue }
            total += data.count
            guard total <= maximumTotalBytes else { throw KineticBackupError.tooLarge }
            backup.files[path] = data
        }
        return backup
    }

    static func encode(_ backup: KineticBackup) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(backup)
    }

    // MARK: - 检查

    static func decode(_ data: Data) throws -> KineticBackup {
        guard data.count <= maximumEncodedBytes else { throw KineticBackupError.tooLarge }
        struct Header: Decodable { var format: String?; var version: Int? }
        guard let header = try? JSONDecoder().decode(Header.self, from: data) else { throw KineticBackupError.unreadable }
        guard header.format == KineticBackup.format else { throw KineticBackupError.wrongFormat }
        guard let version = header.version, version <= KineticBackup.currentVersion else { throw KineticBackupError.newerVersion }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let backup = try? decoder.decode(KineticBackup.self, from: data) else { throw KineticBackupError.unreadable }
        try validate(backup)
        return backup
    }

    static func validate(_ backup: KineticBackup) throws {
        guard backup.format == KineticBackup.format, backup.version == KineticBackup.currentVersion else {
            throw KineticBackupError.wrongFormat
        }
        var total = 0
        for (path, data) in backup.files {
            guard isAllowed(path), data.count <= maximumFileBytes else { throw KineticBackupError.invalidEntry(path) }
            total += data.count
            if path.hasSuffix(".json"), (try? JSONSerialization.jsonObject(with: data)) == nil {
                throw KineticBackupError.invalidEntry(path)
            }
        }
        guard total <= maximumTotalBytes else { throw KineticBackupError.tooLarge }
        if let settings = backup.settings, (try? JSONDecoder().decode(SettingsState.self, from: settings)) == nil {
            throw KineticBackupError.invalidEntry("设置")
        }
        if let assignments = backup.displayAssignments,
           (try? JSONDecoder().decode(DisplayAssignmentDocument.self, from: assignments)) == nil {
            throw KineticBackupError.invalidEntry("显示器分配")
        }
    }

    // MARK: - 恢复

    private static func pendingURL(_ storage: LibraryStorageLocation) -> URL {
        storage.rootURL.appendingPathComponent(pendingFolder, isDirectory: true).appendingPathComponent("backup.json")
    }

    /// The staged backup, if a restore is waiting for the next launch.
    static func pendingRestore(in storage: LibraryStorageLocation) -> KineticBackup? {
        guard let data = try? readRegularFile(pendingURL(storage)) else { return nil }
        return try? decode(data)
    }

    static func stageRestore(_ backup: KineticBackup, in storage: LibraryStorageLocation) throws {
        try validate(backup)
        let url = pendingURL(storage)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encode(backup).write(to: url, options: .atomic)
    }

    static func cancelPendingRestore(in storage: LibraryStorageLocation) {
        try? FileManager.default.removeItem(at: storage.rootURL.appendingPathComponent(pendingFolder, isDirectory: true))
    }

    /// At launch, before anything reads the library: move today's configuration into RestoreSafety/<time>/,
    /// write the backup's files and defaults, and drop the staged copy. Returns the restored settings, if any.
    @discardableResult
    static func applyPendingRestore(in storage: LibraryStorageLocation, defaults: UserDefaults,
                                    now: Date = Date()) throws -> KineticBackup? {
        guard let backup = pendingRestore(in: storage) else {
            cancelPendingRestore(in: storage)
            return nil
        }
        let manager = FileManager.default
        let root = storage.rootURL
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
        let safety = root.appendingPathComponent(safetyFolder, isDirectory: true).appendingPathComponent(stamp, isDirectory: true)
        try manager.createDirectory(at: safety, withIntermediateDirectories: true)
        do {
            // 1. Keep what is there now.
            for name in configurationFiles where manager.fileExists(atPath: root.appendingPathComponent(name).path) {
                try manager.moveItem(at: root.appendingPathComponent(name), to: safety.appendingPathComponent(name))
            }
            for folder in [layoutFolder, coverFolder] {
                let source = root.appendingPathComponent(folder, isDirectory: true)
                if manager.fileExists(atPath: source.path) {
                    try manager.copyItem(at: source, to: safety.appendingPathComponent(folder, isDirectory: true))
                }
            }
            if let settings = defaults.data(forKey: SettingsStore.storageKey) {
                try settings.write(to: safety.appendingPathComponent("settings.json"))
            }
            if let assignments = defaults.dictionary(forKey: DisplayAssignmentStore.storageKey)?[root.path] as? Data {
                try assignments.write(to: safety.appendingPathComponent("display-assignments.json"))
            }
            // 2. Write the backup's files.
            for (path, data) in backup.files {
                let target = root.appendingPathComponent(path)
                try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target, options: .atomic)
            }
        } catch {
            // Put today's configuration files back and drop the staged restore, so the next launch starts normally.
            for name in configurationFiles {
                let kept = safety.appendingPathComponent(name), live = root.appendingPathComponent(name)
                guard manager.fileExists(atPath: kept.path) else { continue }
                try? manager.removeItem(at: live)
                try? manager.copyItem(at: kept, to: live)
            }
            cancelPendingRestore(in: storage)
            throw error
        }
        if let settings = backup.settings { defaults.set(settings, forKey: SettingsStore.storageKey) }
        var entries = defaults.dictionary(forKey: DisplayAssignmentStore.storageKey) ?? [:]
        entries[root.path] = backup.displayAssignments
        defaults.set(entries, forKey: DisplayAssignmentStore.storageKey)
        cancelPendingRestore(in: storage)
        pruneSafetyCopies(in: storage)
        return backup
    }

    private static func pruneSafetyCopies(in storage: LibraryStorageLocation) {
        let folder = storage.rootURL.appendingPathComponent(safetyFolder, isDirectory: true)
        guard let copies = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for old in copies.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).dropFirst(keptSafetyCopies) {
            try? FileManager.default.removeItem(at: old)
        }
    }

    // MARK: - 文件

    private static func readRegularFile(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true else { return nil }
        guard (info.fileSize ?? Int.max) <= maximumFileBytes else { throw KineticBackupError.tooLarge }
        return try Data(contentsOf: url)
    }

    private static func referencedLayouts(in storage: LibraryStorageLocation) -> [UUID] {
        struct Document: Decodable { var configurations: [OverlayConfiguration] }
        guard let data = try? readRegularFile(storage.rootURL.appendingPathComponent("overlays.json")),
              let document = try? JSONDecoder().decode(Document.self, from: data) else { return [] }
        return WidgetLayoutRepository.references(in: document.configurations).sorted { $0.uuidString < $1.uuidString }
    }

    private static func referencedCovers(in storage: LibraryStorageLocation) -> [String] {
        struct Document: Decodable { var lists: [WallpaperList] }
        guard let data = try? readRegularFile(storage.rootURL.appendingPathComponent("organization.json")),
              let document = try? JSONDecoder().decode(Document.self, from: data) else { return [] }
        let folder = storage.rootURL.appendingPathComponent(coverFolder, isDirectory: true).standardizedFileURL
        return Array(Set(document.lists.compactMap { list in
            list.coverImageURL.flatMap { $0.deletingLastPathComponent().standardizedFileURL == folder ? $0.lastPathComponent : nil }
        })).sorted()
    }
}
