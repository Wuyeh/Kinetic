import Combine
import Foundation

/// Module 57：一台显示器上暂不恢复的壁纸（上次 Kinetic 刚把它换上不久就意外退出）。
struct HeldWallpaper: Equatable, Sendable {
    let displayID: DisplayID
    let displayName: String
    let wallpaperID: Wallpaper.ID
    let wallpaperName: String
}

/// Module 57：意外退出保护。
///
/// 每次 Kinetic 在一台显示器上应用壁纸（包括启动时恢复）都记下来；壁纸稳定运行 `settleInterval` 后删除这条记录，
/// 正常退出时整份标记为已结束。下次启动如果上次没有正常结束，还留着的记录就是「刚换上不久就出事」的壁纸：
/// 这台显示器先不恢复它（以停止状态加入，可以「重新启用」），避免一张出问题的壁纸让 Kinetic 一打开就崩。
@MainActor
final class UncleanExitGuard {
    struct Entry: Codable, Equatable {
        var wallpaperID: Wallpaper.ID
        var wallpaperName: String
        var displayName: String
        var appliedAt: Date
    }

    struct Journal: Codable, Equatable {
        var isRunning = false
        /// 键是 `DisplayID.rawValue`。
        var recent: [String: Entry] = [:]
    }

    nonisolated static let fileName = "session-journal.json"
    nonisolated static let settleInterval: TimeInterval = 30

    /// 上次没有正常结束时，这次启动先不恢复的壁纸。
    private(set) var held: [HeldWallpaper] = []
    private(set) var previousSessionEndedUncleanly = false

    private let fileURL: URL
    private let now: () -> Date
    private let settleInterval: TimeInterval
    private var journal = Journal()
    private var subscriptions = Set<AnyCancellable>()

    init(directory: URL, settleInterval: TimeInterval = UncleanExitGuard.settleInterval, now: @escaping () -> Date = Date.init) {
        fileURL = directory.appendingPathComponent(Self.fileName)
        self.settleInterval = settleInterval
        self.now = now
    }

    /// 启动时最先调用：读上次的记录，决定要暂不恢复的壁纸，然后开始这次的记录。
    func beginSession() {
        let previous = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode(Journal.self, from: $0) }
        previousSessionEndedUncleanly = previous?.isRunning == true
        if previousSessionEndedUncleanly, let previous {
            held = previous.recent.map { key, entry in
                HeldWallpaper(displayID: DisplayID(key), displayName: entry.displayName,
                              wallpaperID: entry.wallpaperID, wallpaperName: entry.wallpaperName)
            }.sorted { $0.displayID.rawValue < $1.displayID.rawValue }
        }
        journal = Journal(isRunning: true, recent: [:])
        write()
    }

    func isHeld(_ wallpaperID: Wallpaper.ID, on display: DisplayID) -> Bool {
        held.contains { $0.displayID == display && $0.wallpaperID == wallpaperID }
    }

    /// 用户「重新启用」或换了壁纸之后不再算暂不恢复。
    func release(_ display: DisplayID) {
        held.removeAll { $0.displayID == display }
    }

    /// 接上 Runtime：每次 Apply 都记一笔，稳定运行一段时间后删除。
    func observe(_ runtime: WallpaperRuntimeManager, library: WallpaperLibrary) {
        runtime.applyRequests
            .sink { [weak self, weak runtime, weak library] request in
                guard let self else { return }
                let name = library?.wallpaper(id: request.wallpaperID)?.name ?? ""
                let display = runtime?.summary.displays.first { $0.displayID == request.display }?.displayName ?? ""
                recordApply(request.wallpaperID, name: name, on: request.display, displayName: display)
            }
            .store(in: &subscriptions)
    }

    func recordApply(_ wallpaperID: Wallpaper.ID, name: String, on display: DisplayID, displayName: String) {
        let appliedAt = now()
        journal.recent[display.rawValue] = Entry(wallpaperID: wallpaperID, wallpaperName: name,
                                                 displayName: displayName, appliedAt: appliedAt)
        release(display)
        write()
        guard settleInterval > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + settleInterval) { [weak self] in
            MainActor.assumeIsolated { self?.settle(display, appliedAt: appliedAt) }
        }
    }

    /// 同一次 Apply 已经稳定运行：删除记录。期间又换过壁纸则保留新的那条。
    func settle(_ display: DisplayID, appliedAt: Date) {
        guard journal.recent[display.rawValue]?.appliedAt == appliedAt else { return }
        journal.recent[display.rawValue] = nil
        write()
    }

    /// 正常退出。
    func endSession() {
        journal.isRunning = false
        journal.recent = [:]
        write()
    }

    var currentJournal: Journal { journal }

    private func write() {
        guard let data = try? JSONEncoder().encode(journal) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Module 57：设置 › 通用「最近的问题」里的一条。
struct ProblemRecord: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// 壁纸没能在某台显示器上加载（旧壁纸保留）。
        case wallpaperFailed
        /// 上次意外退出，某台显示器暂不恢复的壁纸。
        case uncleanExit
        /// 资料库文件读不出来，已另存备份。
        case libraryUnreadable
    }

    var id = UUID()
    let date: Date
    let kind: Kind
    let displayName: String?
    let wallpaperName: String?
    let message: String

    var title: String {
        switch kind {
        case .wallpaperFailed: return "壁纸没能加载"
        case .uncleanExit: return "Kinetic 意外退出"
        case .libraryUnreadable: return "资料库读取失败"
        }
    }
}

/// Module 57：最近的问题（最多 20 条，新的在前），存在资料库目录里。
@MainActor
final class ProblemLog: ObservableObject {
    nonisolated static let fileName = "recent-problems.json"
    nonisolated static let limit = 20

    @Published private(set) var records: [ProblemRecord] = []
    private let fileURL: URL
    private var subscriptions = Set<AnyCancellable>()

    init(directory: URL) {
        fileURL = directory.appendingPathComponent(Self.fileName)
        records = (try? Data(contentsOf: fileURL)).flatMap { try? Self.decoder.decode([ProblemRecord].self, from: $0) } ?? []
    }

    func add(_ record: ProblemRecord) {
        records = Array(([record] + records).prefix(Self.limit))
        save()
    }

    func clear() {
        records = []
        save()
    }

    /// 接上 Runtime 的加载失败（同一台显示器同一张壁纸连续失败只记一次）。
    func observe(_ runtime: WallpaperRuntimeManager) {
        runtime.$lastFailure.compactMap { $0 }
            .sink { [weak self, weak runtime] failure in
                guard let self else { return }
                let display = runtime?.summary.displays.first { $0.displayID == failure.displayID }?.displayName
                let last = records.first
                if let last, last.kind == .wallpaperFailed, last.wallpaperName == failure.wallpaperName,
                   last.displayName == display, last.message == failure.message,
                   Date().timeIntervalSince(last.date) < 60 { return }
                add(ProblemRecord(date: Date(), kind: .wallpaperFailed, displayName: display,
                                  wallpaperName: failure.wallpaperName, message: failure.message))
            }
            .store(in: &subscriptions)
    }

    private func save() {
        guard let data = try? Self.encoder.encode(records) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    private static var encoder: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
    private static var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}

/// Module 57：「复制诊断信息」的文本。只有版本、系统、显示器数量和最近的问题；文件路径一律去掉。
enum DiagnosticsReport {
    static func text(records: [ProblemRecord], appVersion: String, build: String, systemVersion: String,
                     displayCount: Int, homeDirectory: String = NSHomeDirectory(), now: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        var lines = [
            "Kinetic \(appVersion) (\(build))",
            "macOS \(systemVersion)",
            "显示器：\(displayCount) 台",
            "生成时间：\(formatter.string(from: now))",
            "",
            records.isEmpty ? "最近没有问题记录。" : "最近的问题（\(records.count) 条，新的在前）：",
        ]
        for record in records {
            var line = "- \(formatter.string(from: record.date)) \(record.title)"
            if let display = record.displayName, !display.isEmpty { line += " · 显示器：\(display)" }
            if let wallpaper = record.wallpaperName, !wallpaper.isEmpty { line += " · 壁纸：\(wallpaper)" }
            line += " · \(scrubPaths(record.message, homeDirectory: homeDirectory))"
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// 去掉文本里的文件路径：主目录下的、以及其他绝对路径和 file:// 地址。
    static func scrubPaths(_ text: String, homeDirectory: String = NSHomeDirectory()) -> String {
        var result = text
        if !homeDirectory.isEmpty { result = result.replacingOccurrences(of: homeDirectory, with: "~") }
        let patterns = [#"file://[^\s"“”'）)]+"#, #"~?/(?:[^\s/"“”'）)]+/)+[^\s"“”'）)]*"#]
        for pattern in patterns {
            result = result.replacingOccurrences(of: pattern, with: "〈路径〉", options: .regularExpression)
        }
        return result
    }
}

/// Module 57：主窗口里「上次意外退出、暂不恢复」的提示与操作。
@MainActor
final class LaunchRecovery: ObservableObject {
    @Published private(set) var held: [HeldWallpaper]
    private let exitGuard: UncleanExitGuard
    private weak var runtime: WallpaperRuntimeManager?
    private weak var library: WallpaperLibrary?

    init(exitGuard: UncleanExitGuard, runtime: WallpaperRuntimeManager, library: WallpaperLibrary) {
        self.exitGuard = exitGuard
        self.runtime = runtime
        self.library = library
        held = exitGuard.held
    }

    /// 「重新启用」：在这台显示器上恢复那张壁纸。
    func reenable(_ item: HeldWallpaper) {
        exitGuard.release(item.displayID)
        held.removeAll { $0.displayID == item.displayID }
        runtime?.reenable(.display(item.displayID), isInLibrary: { [weak library] in library?.wallpaper(id: $0) != nil })
    }

    /// 关闭提示：这台显示器保持停止（之后的启动也是），可以在显示器页或菜单栏重新启用。
    func dismiss(_ item: HeldWallpaper) {
        held.removeAll { $0.displayID == item.displayID }
    }
}
