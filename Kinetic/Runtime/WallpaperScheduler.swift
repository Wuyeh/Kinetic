import AppKit
import Combine
import Foundation

/// Module 47：按显示器的定时切换。
///
/// 每个时段只在它开始的那一次生效：到点、睡眠唤醒、启动、重新连接、从手动暂停继续时，如果当前时段这一次还没
/// 生效过，就换成它的内容；时段中途用户手动换的壁纸在本时段内不再改回。手动暂停或停止的屏幕不切换
/// （手动暂停优先于定时），继续后补上。壁纸经过既有的显示器 Apply（参数与 Crossfade），列表交给 Module 46 的轮播。
@MainActor
final class WallpaperScheduler: ObservableObject {
    struct Entry: Codable, Equatable, Sendable {
        var schedule: DisplaySchedule
        /// 已经生效过的那一次：时段 ID + 开始时间。
        var appliedSlotID: UUID?
        var appliedOccurrence: Date?
    }

    private struct Document: Codable {
        var version = 1
        var displays: [String: Entry] = [:]
    }

    static let maximumBytes = 1_024 * 1_024

    @Published private(set) var entries: [DisplayID: Entry] = [:]
    /// 显示器页「定时」栏的草稿；点「应用」才保存并立即补到当前时段。
    @Published private(set) var drafts: [DisplayID: DisplaySchedule] = [:]
    let fileURL: URL

    private let runtime: WallpaperRuntimeManager
    private let library: WallpaperLibrary
    private let playlist: WallpaperPlaylistPlayer
    /// Module 48: bookmark slots apply a wallpaper with its saved parameters through the display editor.
    private let bookmarks: SetupStore?
    private weak var editor: DisplayWallpaperEditor?
    private let now: () -> Date
    private let calendar: () -> Calendar
    private let schedulesTimer: Bool
    private var timer: Timer?
    private var cannotPersist = false
    private var subscriptions = Set<AnyCancellable>()
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(storage: LibraryStorageLocation, runtime: WallpaperRuntimeManager, library: WallpaperLibrary,
         playlist: WallpaperPlaylistPlayer, bookmarks: SetupStore? = nil, editor: DisplayWallpaperEditor? = nil,
         now: @escaping () -> Date = Date.init,
         calendar: @escaping () -> Calendar = { Calendar.current }, schedulesTimer: Bool = true) {
        self.runtime = runtime; self.library = library; self.playlist = playlist
        self.bookmarks = bookmarks; self.editor = editor
        self.now = now; self.calendar = calendar; self.schedulesTimer = schedulesTimer
        fileURL = storage.rootURL.appendingPathComponent("schedule.json")
        load()
        // 继续、重新连接、启动恢复都会改变汇总；补上是幂等的，同一次只生效一回。
        runtime.$summary.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.reconcileAll() }
        }.store(in: &subscriptions)
        guard schedulesTimer else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.reconcileAll() }
        }))
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange, .NSCalendarDayChanged] {
            observers.append((NotificationCenter.default, NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.reconcileAll() }
            }))
        }
        DispatchQueue.main.async { [weak self] in self?.reconcileAll() }
    }

    // MARK: - 显示器页草稿

    func schedule(on display: DisplayID) -> DisplaySchedule { entries[display]?.schedule ?? DisplaySchedule() }
    func draft(on display: DisplayID) -> DisplaySchedule { drafts[display] ?? schedule(on: display) }
    func isDirty(on display: DisplayID) -> Bool { draft(on: display) != schedule(on: display) }
    func canApplyDraft(on display: DisplayID) -> Bool { isDirty(on: display) && draft(on: display).canApply }

    func edit(on display: DisplayID, _ change: (inout DisplaySchedule) -> Void) {
        var value = draft(on: display)
        change(&value)
        drafts[display] = value
    }

    /// 「应用」：保存这块屏幕的定时，并立即补到当前时段（当前时段的内容现在就生效）。
    func applyDraft(on display: DisplayID) {
        let value = draft(on: display)
        guard value.canApply else { return }
        drafts[display] = nil
        let previous = entries[display]
        if value.slots.isEmpty, !value.isEnabled { entries[display] = nil }
        else {
            var entry = Entry(schedule: value)
            // 只改了别的时段：当前这次已经生效（或被手动换掉）的时段不重来。
            if value.isEnabled, previous?.schedule.isEnabled == true, let id = previous?.appliedSlotID,
               value.slots.first(where: { $0.id == id }) == previous?.schedule.slots.first(where: { $0.id == id }) {
                entry.appliedSlotID = id
                entry.appliedOccurrence = previous?.appliedOccurrence
            }
            entries[display] = entry
        }
        persist()
        reconcile(display)
        reschedule()
    }

    /// Module 48 方案：直接换成保存的定时。当前时段这一次记为已经生效，方案里的壁纸不会马上被它改掉；下个时段照常。
    func setSchedule(_ schedule: DisplaySchedule?, on display: DisplayID) {
        drafts[display] = nil
        guard let schedule, schedule.isEnabled || !schedule.slots.isEmpty else {
            entries[display] = nil
            persist(); reschedule()
            return
        }
        var entry = Entry(schedule: schedule)
        if let active = schedule.activeSlot(at: now(), calendar: calendar()) {
            entry.appliedSlotID = active.slot.id
            entry.appliedOccurrence = active.began
        }
        entries[display] = entry
        persist(); reschedule()
    }

    /// 这块屏幕现在所在的时段（只看已经应用的定时）。
    func activeSlot(on display: DisplayID) -> ScheduleSlot? {
        entries[display]?.schedule.activeSlot(at: now(), calendar: calendar())?.slot
    }

    // MARK: - 补上

    /// 到点、唤醒、启动、继续、重新连接后调用；每台显示器的当前时段这一次只生效一回。
    func reconcileAll() {
        for display in entries.keys { reconcile(display) }
        reschedule()
    }

    private func reconcile(_ display: DisplayID) {
        guard var entry = entries[display], let state = runtime.state(of: display) else { return }
        // 手动暂停 / 停止优先：不切换，继续后再补上。
        guard state.playbackState != .stopped, !runtime.manualPauseRequested(on: display) else { return }
        guard let active = entry.schedule.activeSlot(at: now(), calendar: calendar()),
              entry.appliedSlotID != active.slot.id || entry.appliedOccurrence != active.began else { return }
        entry.appliedSlotID = active.slot.id
        entry.appliedOccurrence = active.began
        entries[display] = entry
        persist()
        show(active.slot.content, on: display)
    }

    private func show(_ content: ScheduleContent?, on display: DisplayID) {
        switch content {
        case .wallpaper(let id):
            guard let wallpaper = library.wallpaper(id: id), wallpaper.resourceURL.isFileURL,
                  WallpaperCardVisualState.isPlayable(wallpaper) else { return }
            // 换成一张壁纸就结束这块屏幕原来的轮播。
            playlist.stop(on: display)
            runtime.apply(wallpaper, to: display)
        case .list(let listID, let minutes, let shuffle):
            playlist.start(DisplayPlaylistConfiguration(listID: listID, intervalMinutes: minutes, shuffle: shuffle), on: display)
        case .bookmark(let id):
            guard let bookmark = bookmarks?.bookmark(id: id), let editor else { return }
            playlist.stop(on: display)
            Task { await editor.apply(bookmark.configuration, on: display) }
        case nil:
            break
        }
    }

    private func reschedule() {
        timer?.invalidate(); timer = nil
        guard schedulesTimer else { return }
        let date = now(), calendar = calendar()
        let starts = entries.values.filter(\.schedule.isEnabled).flatMap(\.schedule.slots)
            .compactMap { $0.nextStart(after: date, calendar: calendar) }
        guard let soonest = starts.min() else { return }
        let next = Timer(fire: soonest.addingTimeInterval(0.5), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcileAll() }
        }
        next.tolerance = 1
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }

    func shutdown() {
        timer?.invalidate(); timer = nil
        subscriptions.removeAll()
        for (center, observer) in observers { center.removeObserver(observer) }
        observers = []
    }

    // MARK: - 保存

    private func persist() {
        guard !cannotPersist else { return }
        var document = Document()
        for (display, entry) in entries where !display.rawValue.hasPrefix("session-display-") {
            document.displays[display.rawValue] = entry
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(document)
            guard data.count <= Self.maximumBytes else { return }
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // 保存失败不影响已经生效的定时；下次改动再试。
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let info = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true,
                  (info.fileSize ?? Int.max) <= Self.maximumBytes else { throw LocalOrganizationError.unreadableData }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let document = try decoder.decode(Document.self, from: Data(contentsOf: fileURL))
            guard document.version == 1, document.displays.count <= 256 else { throw LocalOrganizationError.unreadableData }
            for (key, entry) in document.displays where !key.isEmpty && entry.schedule.slots.count <= DisplaySchedule.maximumSlots {
                entries[DisplayID(key)] = entry
            }
        } catch {
            // 损坏的文件先备份，不覆盖用户资料；备份失败就不再写入。
            let backup = fileURL.deletingLastPathComponent().appendingPathComponent("schedule.unreadable-\(UUID().uuidString).json")
            if (try? FileManager.default.moveItem(at: fileURL, to: backup)) == nil { cannotPersist = true }
        }
    }
}
