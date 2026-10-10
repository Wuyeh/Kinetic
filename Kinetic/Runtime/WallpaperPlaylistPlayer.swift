import Combine
import Foundation

/// Module 46：按显示器轮播一个壁纸列表。
///
/// 切换只经过既有的 `WallpaperRuntimeManager.apply(_:to:)`，所以沿用每台显示器的参数与 Crossfade；
/// 这里不拥有窗口、Renderer 或播放状态机。计时只在这块屏幕「播放中」时走（手动暂停、智能暂停、
/// 停止都不计时）。在这块屏幕上手动换成别的壁纸，就停止它的轮播；删除列表也停止，壁纸保持不变。
@MainActor
final class WallpaperPlaylistPlayer: ObservableObject {
    struct Entry: Codable, Equatable, Sendable {
        var configuration: DisplayPlaylistConfiguration
        var cursor = PlaylistCursor()
        /// 这一张已经显示的秒数，只算播放中的时间。
        var elapsed: TimeInterval = 0
    }

    /// 显示器页「轮播」栏的草稿：点「应用」才开始、更新或停止。`listID == nil` 表示不轮播。
    struct Draft: Equatable, Sendable {
        var listID: UUID?
        var intervalMinutes = DisplayPlaylistConfiguration.defaultIntervalMinutes
        var shuffle = false

        init(listID: UUID? = nil, intervalMinutes: Int = DisplayPlaylistConfiguration.defaultIntervalMinutes,
             shuffle: Bool = false) {
            self.listID = listID; self.intervalMinutes = intervalMinutes; self.shuffle = shuffle
        }
        init(_ entry: Entry?) {
            self.init(listID: entry?.configuration.listID,
                      intervalMinutes: entry?.configuration.intervalMinutes ?? DisplayPlaylistConfiguration.defaultIntervalMinutes,
                      shuffle: entry?.configuration.shuffle ?? false)
        }
    }

    private struct Document: Codable {
        var version = 1
        var displays: [String: Entry] = [:]
    }

    static let maximumBytes = 1_024 * 1_024

    @Published private(set) var entries: [DisplayID: Entry] = [:]
    @Published private(set) var drafts: [DisplayID: Draft] = [:]
    let fileURL: URL

    private let runtime: WallpaperRuntimeManager
    private let library: WallpaperLibrary
    private let lists: LocalOrganizationStore
    private let now: () -> TimeInterval
    private var random: PlaylistRandom
    private let schedulesTimer: Bool
    /// 这块屏幕从什么时候开始连续播放（系统运行时间）；不在播放时没有。
    private var runningSince: [DisplayID: TimeInterval] = [:]
    private var timer: Timer?
    /// 自己发出的 Apply 不算「手动换壁纸」。
    private var isRequesting = false
    private var cannotPersist = false
    private var subscriptions = Set<AnyCancellable>()

    init(storage: LibraryStorageLocation, runtime: WallpaperRuntimeManager, library: WallpaperLibrary,
         lists: LocalOrganizationStore, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         random: PlaylistRandom = .system, schedulesTimer: Bool = true) {
        self.runtime = runtime; self.library = library; self.lists = lists
        self.now = now; self.random = random; self.schedulesTimer = schedulesTimer
        fileURL = storage.rootURL.appendingPathComponent("playlist-playback.json")
        load()
        runtime.applyRequests.sink { [weak self] in self?.observeApply(on: $0.display, wallpaperID: $0.wallpaperID) }
            .store(in: &subscriptions)
        runtime.$summary.sink { [weak self] in self?.synchronize($0) }.store(in: &subscriptions)
        lists.$lists.sink { [weak self] in self?.listsChanged($0) }.store(in: &subscriptions)
    }

    // MARK: - 查询

    /// 列表里现在能播放的壁纸，按列表顺序（与显示器页的壁纸选择器同一条件）。
    func members(of listID: UUID) -> [Wallpaper.ID] {
        guard let list = lists.lists.first(where: { $0.id == listID }) else { return [] }
        return list.wallpaperIDs.filter { id in
            guard let wallpaper = library.wallpaper(id: id) else { return false }
            return wallpaper.resourceURL.isFileURL && WallpaperCardVisualState.isPlayable(wallpaper)
        }
    }

    /// 这块屏幕有轮播且正在显示壁纸（停止时不算）：显示器页与菜单栏的「上一张 / 下一张」只在这时可用。
    func isActive(on display: DisplayID) -> Bool {
        guard entries[display] != nil, let state = runtime.state(of: display) else { return false }
        return state.activeWallpaperID != nil && state.playbackState != .stopped
    }

    var hasActivePlaylist: Bool { entries.keys.contains { isActive(on: $0) } }

    /// 距离下一张还有多少秒；不在播放时计时停住。
    func remaining(on display: DisplayID) -> TimeInterval? {
        guard let entry = entries[display] else { return nil }
        return max(0, entry.configuration.interval - elapsed(on: display))
    }

    // MARK: - 显示器页草稿

    func draft(on display: DisplayID) -> Draft { drafts[display] ?? Draft(entries[display]) }
    func isDirty(on display: DisplayID) -> Bool { draft(on: display) != Draft(entries[display]) }
    /// 草稿有改动，且选中的列表里有能播放的壁纸（选「不轮播」总可以应用）。
    func canApplyDraft(on display: DisplayID) -> Bool {
        guard isDirty(on: display), runtime.hasDisplay(display) else { return false }
        return draft(on: display).listID.map { !members(of: $0).isEmpty } ?? true
    }

    func edit(on display: DisplayID, _ change: (inout Draft) -> Void) {
        var value = draft(on: display)
        change(&value)
        value.intervalMinutes = DisplayPlaylistConfiguration.clamped(value.intervalMinutes)
        drafts[display] = value
    }

    /// 选中列表时缩略图先显示的那一张：顺序播放是第一张，随机是随机一张。
    func previewWallpaper(for draft: Draft) -> Wallpaper.ID? {
        guard let listID = draft.listID else { return nil }
        let members = members(of: listID)
        return draft.shuffle ? members.randomElement(using: &random) : members.first
    }

    /// 「应用」：按草稿开始、更新或停止这块屏幕的轮播，返回这块屏幕接下来应显示的壁纸
    /// （调用方把它交给既有的显示器 Apply；与草稿里已经选中的壁纸相同时就是那一张）。
    /// `showing` 是显示器页当前选中的壁纸：它在列表里时从它开始。
    @discardableResult
    func applyDraft(on display: DisplayID, showing: Wallpaper.ID?) -> Wallpaper.ID? {
        let value = draft(on: display)
        drafts[display] = nil
        guard let listID = value.listID, lists.lists.contains(where: { $0.id == listID }) else {
            stop(on: display)
            return nil
        }
        let configuration = DisplayPlaylistConfiguration(listID: listID, intervalMinutes: value.intervalMinutes, shuffle: value.shuffle)
        let members = members(of: listID)
        var entry = entries[display] ?? Entry(configuration: configuration)
        let restart = entries[display] == nil || entry.configuration.listID != listID
            || entry.configuration.shuffle != value.shuffle
            || !(showing.map { $0 == entry.cursor.currentWallpaperID } ?? true)
        entry.configuration = configuration
        if restart {
            entry.cursor = PlaylistCursor()
            _ = entry.cursor.start(members: members, shuffle: value.shuffle, preferred: showing, random: &random)
        }
        entry.elapsed = 0
        entries[display] = entry
        runningSince[display] = isPlaying(display) ? now() : nil
        persist(); reschedule()
        return entry.cursor.currentWallpaperID
    }

    // MARK: - 命令

    /// Module 47 定时 / 48 方案：直接在这块屏幕从头开始轮播这个列表，并立即显示第一张（`preferred` 在列表里时从它开始）。
    /// 返回那一张；列表里没有能播放的就不改动。
    @discardableResult
    func start(_ configuration: DisplayPlaylistConfiguration, on display: DisplayID, preferred: Wallpaper.ID? = nil) -> Wallpaper.ID? {
        guard runtime.hasDisplay(display), lists.lists.contains(where: { $0.id == configuration.listID }) else { return nil }
        var entry = Entry(configuration: configuration)
        entry.configuration.intervalMinutes = DisplayPlaylistConfiguration.clamped(configuration.intervalMinutes)
        guard let first = entry.cursor.start(members: members(of: configuration.listID), shuffle: configuration.shuffle,
                                             preferred: preferred, random: &random) else { return nil }
        entries[display] = entry
        drafts[display] = nil
        runningSince[display] = isPlaying(display) ? now() : nil
        persist(); reschedule()
        request(first, on: display)
        return first
    }

    /// 上一张 / 下一张：立即切换并重新计时。
    func step(_ step: PlaylistStep, on display: DisplayID) {
        guard var entry = entries[display], runtime.hasDisplay(display) else { return }
        let members = members(of: entry.configuration.listID)
        guard let id = entry.cursor.step(step, members: members, shuffle: entry.configuration.shuffle, random: &random) else { return }
        entry.elapsed = 0
        entries[display] = entry
        runningSince[display] = isPlaying(display) ? now() : nil
        persist(); reschedule()
        request(id, on: display)
    }

    /// 菜单栏：所有正在轮播的显示器一起切换。
    func stepAll(_ step: PlaylistStep) {
        for display in runtime.displayIDs where isActive(on: display) { self.step(step, on: display) }
    }

    /// 停止这块屏幕的轮播；当前壁纸保持不变。
    func stop(on display: DisplayID) {
        guard entries[display] != nil else { return }
        entries[display] = nil
        runningSince[display] = nil
        drafts[display] = nil
        persist(); reschedule()
    }

    /// 到时间的显示器切到下一张（计时器调用；测试可以直接调用）。
    func advanceDue() {
        let time = now()
        for display in runtime.displayIDs {
            guard let entry = entries[display], runningSince[display] != nil else { continue }
            if entry.configuration.interval - elapsed(on: display, at: time) <= 0.5 { step(.next, on: display) }
        }
        reschedule()
    }

    /// App 退出：保存已经显示的时间，下次启动接着计时。
    func shutdown() {
        timer?.invalidate(); timer = nil
        persist()
        subscriptions.removeAll()
    }

    // MARK: - 内部

    private func request(_ id: Wallpaper.ID, on display: DisplayID) {
        guard let wallpaper = library.wallpaper(id: id) else { return }
        isRequesting = true
        defer { isRequesting = false }
        runtime.apply(wallpaper, to: display)
    }

    private func isPlaying(_ display: DisplayID) -> Bool {
        runtime.state(of: display)?.playbackState == .playing
    }

    private func elapsed(on display: DisplayID, at time: TimeInterval? = nil) -> TimeInterval {
        let base = entries[display]?.elapsed ?? 0
        guard let since = runningSince[display] else { return base }
        return base + max(0, (time ?? now()) - since)
    }

    /// 别处对这块屏幕的 Apply：换成列表外或别的壁纸就是用户手动选择，停止轮播。
    /// 刚接入（重新连接 / 启动恢复）的屏幕恢复的是它上次的壁纸，不算手动选择。
    private func observeApply(on display: DisplayID, wallpaperID: Wallpaper.ID) {
        guard !isRequesting, var entry = entries[display], entry.cursor.currentWallpaperID != wallpaperID else { return }
        let state = runtime.state(of: display)
        let restoring = state.map { $0.activeWallpaperID == nil && $0.preparingWallpaperID == nil && $0.playbackState != .stopped } ?? true
        if restoring, members(of: entry.configuration.listID).contains(wallpaperID) {
            entry.cursor.currentWallpaperID = wallpaperID
            entries[display] = entry
            persist()
        } else if !restoring {
            stop(on: display)
        }
    }

    private func synchronize(_ summary: RuntimeSummary) {
        let time = now()
        var changed = false
        for display in entries.keys {
            let playing = summary.state(of: display)?.playbackState == .playing
            if playing, runningSince[display] == nil {
                runningSince[display] = time
                changed = true
            } else if !playing, let since = runningSince[display] {
                entries[display]?.elapsed += max(0, time - since)
                runningSince[display] = nil
                changed = true
            }
        }
        if changed { persist(); reschedule() }
    }

    private func listsChanged(_ value: [WallpaperList]) {
        let ids = Set(value.map(\.id))
        for (display, entry) in entries where !ids.contains(entry.configuration.listID) { stop(on: display) }
        for (display, draft) in drafts where draft.listID.map({ !ids.contains($0) }) ?? false { drafts[display] = nil }
    }

    private func reschedule() {
        timer?.invalidate(); timer = nil
        guard schedulesTimer else { return }
        let time = now()
        let deadlines = runningSince.keys.compactMap { display -> TimeInterval? in
            guard let entry = entries[display] else { return nil }
            return entry.configuration.interval - elapsed(on: display, at: time)
        }
        guard let soonest = deadlines.min() else { return }
        let next = Timer(timeInterval: max(0.5, soonest), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceDue() }
        }
        next.tolerance = 1
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }

    private func persist() {
        guard !cannotPersist else { return }
        let time = now()
        var document = Document()
        for (display, entry) in entries where !display.rawValue.hasPrefix("session-display-") {
            var saved = entry
            saved.elapsed = elapsed(on: display, at: time)
            document.displays[display.rawValue] = saved
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(document)
            guard data.count <= Self.maximumBytes else { return }
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // 保存失败不影响正在进行的轮播；下次改动再试。
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let info = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true,
                  (info.fileSize ?? Int.max) <= Self.maximumBytes else { throw LocalOrganizationError.unreadableData }
            let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: fileURL))
            guard document.version == 1, document.displays.count <= 256 else { throw LocalOrganizationError.unreadableData }
            let listIDs = Set(lists.lists.map(\.id))
            for (key, var entry) in document.displays where !key.isEmpty && listIDs.contains(entry.configuration.listID) {
                entry.configuration.intervalMinutes = DisplayPlaylistConfiguration.clamped(entry.configuration.intervalMinutes)
                entry.elapsed = min(max(0, entry.elapsed.isFinite ? entry.elapsed : 0), entry.configuration.interval)
                entries[DisplayID(key)] = entry
            }
        } catch {
            // 损坏的文件先备份，不覆盖用户资料；备份失败就不再写入。
            let backup = fileURL.deletingLastPathComponent()
                .appendingPathComponent("playlist-playback.unreadable-\(UUID().uuidString).json")
            if (try? FileManager.default.moveItem(at: fileURL, to: backup)) == nil { cannotPersist = true }
        }
    }
}
