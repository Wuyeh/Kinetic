import Combine
import Foundation

/// Module 19（用户决定）：每次启动都恢复上次正在使用的壁纸。
/// 退出前已「停止壁纸」则不恢复；手动暂停的壁纸恢复后仍保持暂停。
struct WallpaperRestorationRecord: Codable, Equatable, Sendable {
    var wallpaperID: Wallpaper.ID
    var isStopped: Bool
    var isManuallyPaused: Bool

    init(wallpaperID: Wallpaper.ID, isStopped: Bool, isManuallyPaused: Bool) {
        self.wallpaperID = wallpaperID
        self.isStopped = isStopped
        self.isManuallyPaused = isManuallyPaused
    }

    /// 从 Runtime 状态得到要记住的内容；还没有任何壁纸（包括首次准备中）时返回 nil，保留原有记录。
    init?(state: WallpaperRuntimeState) {
        if state.playbackState == .stopped {
            guard let id = state.lastActiveWallpaperID else { return nil }
            self.init(wallpaperID: id, isStopped: true, isManuallyPaused: false)
        } else {
            guard let id = state.activeWallpaperID else { return nil }
            self.init(wallpaperID: id, isStopped: false, isManuallyPaused: state.playbackState == .manualPaused)
        }
    }
}

/// 按资料库分别保存（正式资料库与 Debug 演示资料库互不影响）。
@MainActor
final class WallpaperRestorationStore {
    static let storageKey = "Kinetic.WallpaperRestoration.v1"

    private let defaults: UserDefaults
    private let libraryKey: String

    init(defaults: UserDefaults = .standard, library: LibraryStorageLocation) {
        self.defaults = defaults
        libraryKey = library.rootURL.path
    }

    func load() -> WallpaperRestorationRecord? {
        guard let entries = defaults.dictionary(forKey: Self.storageKey),
              let data = entries[libraryKey] as? Data
        else { return nil }
        return try? JSONDecoder().decode(WallpaperRestorationRecord.self, from: data)
    }

    func save(_ record: WallpaperRestorationRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        var entries = defaults.dictionary(forKey: Self.storageKey) ?? [:]
        entries[libraryKey] = data
        defaults.set(entries, forKey: Self.storageKey)
    }
}

/// 启动时恢复上次的壁纸，之后持续记录 Runtime 状态。只调用 Runtime 的公开接口。
@MainActor
final class WallpaperRestorer {
    private let store: WallpaperRestorationStore
    private let runtime: WallpaperRuntimeManager
    private let library: WallpaperLibrary
    private var recording: AnyCancellable?

    init(store: WallpaperRestorationStore, runtime: WallpaperRuntimeManager, library: WallpaperLibrary) {
        self.store = store
        self.runtime = runtime
        self.library = library
    }

    /// 返回恢复的壁纸；没有记录、已停止、壁纸已删除或当前无法播放时返回 nil。
    @discardableResult
    func restore() -> Wallpaper? {
        guard let record = store.load(), !record.isStopped,
              let wallpaper = library.wallpaper(id: record.wallpaperID),
              wallpaper.supportState == .supported,
              WallpaperRuntimeManager.isRendererAvailable(for: wallpaper.type)
        else { return nil }
        runtime.apply(wallpaper)
        // Runtime 允许在首次准备期间记录暂停意图：准备完成后直接停在第一帧。
        if record.isManuallyPaused { runtime.pause() }
        return wallpaper
    }

    func startRecording() {
        recording = runtime.$state
            .compactMap(WallpaperRestorationRecord.init(state:))
            .removeDuplicates()
            .sink { [store] record in store.save(record) }
    }

    /// 退出时先停止记录：退出会停止 Runtime，这个“停止”不能被记成用户停止了壁纸。
    func stopRecording() {
        recording = nil
    }
}
