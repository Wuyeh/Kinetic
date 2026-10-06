import Foundation

/// Kinetic 1.0 Module 5：一台显示器的 Wallpaper Session 的稳定标识。
/// Module 16 用 ColorSync UUID 生成持久身份；`.main` 保留给旧的单显示器接口与验收面板。
struct DisplayID: Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    /// 接入多显示器前的兼容标识；正式产品使用每台硬件的稳定 ID。
    static let main = DisplayID("main")

    var description: String { rawValue }
}

/// 命令的作用范围。Apply 必须明确一台显示器；暂停、继续、停止、重新启用可以作用于一台或全部。
enum RuntimeTarget: Equatable, Sendable {
    case display(DisplayID)
    case allDisplays
}

/// 一台显示器会话的只读快照。
struct DisplayRuntimeState: Equatable, Sendable, Identifiable {
    let displayID: DisplayID
    /// 系统提供的人类可读名称；兼容验收会话可以为空。
    var displayName: String
    var runtime: WallpaperRuntimeState
    /// 与稳定 ID 对应的当前 AppKit 点坐标；不依赖 NSScreen 数组下标。
    var frame: CGRect? = nil
    var scaleFactor: CGFloat = 1

    var id: DisplayID { displayID }
}

/// 所有显示器会话的汇总，按会话加入的顺序排列。UI 只读，不是业务真相。
struct RuntimeSummary: Equatable, Sendable {
    var displays: [DisplayRuntimeState] = []

    /// 汇总状态的优先顺序：只要有一台在播放就是播放，其次是智能暂停、准备中、手动暂停、失败、停止。
    static let aggregatePriority: [PlaybackState] = [
        .playing, .smartPaused, .preparing, .manualPaused, .failed, .stopped, .noWallpaper
    ]

    var playbackState: PlaybackState {
        let states = Set(displays.map(\.runtime.playbackState))
        return Self.aggregatePriority.first(where: states.contains) ?? .noWallpaper
    }

    /// 至少一台显示器处于启用状态（播放或智能暂停）。规格 36：菜单栏标志此时为主色。
    var hasEnabledDisplay: Bool {
        displays.contains { [.playing, .smartPaused].contains($0.runtime.playbackState) }
    }

    /// 正在播放的显示器数量，用于「2 个显示器正在播放」一类摘要。
    var playingDisplayCount: Int {
        displays.filter { $0.runtime.playbackState == .playing }.count
    }

    /// 正在显示这张壁纸的显示器（规格 22：卡片「使用中」）。
    func displays(showing id: Wallpaper.ID) -> [DisplayID] {
        displays.filter { $0.runtime.activeWallpaperID == id }.map(\.displayID)
    }

    /// 正在显示或正在准备这张壁纸的显示器（删除等需要先停止的场景）。
    func displays(involving id: Wallpaper.ID) -> [DisplayID] {
        displays.filter { $0.runtime.activeWallpaperID == id || $0.runtime.preparingWallpaperID == id }
            .map(\.displayID)
    }

    func state(of display: DisplayID) -> WallpaperRuntimeState? {
        displays.first { $0.displayID == display }?.runtime
    }
}
