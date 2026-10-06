import Foundation

/// Kinetic 1.0 Module 23 — Floating Toolbar（规格 4、37：＋ / 播放暂停 / 声音；R2 已移除 Info / Inspector 入口）。
///
/// 工具条的播放 / 暂停、停止与声音作用于**全部显示器**，与菜单栏的全局控制一致（DECISIONS：不带范围的
/// 暂停 / 继续 / 停止 / 重新启用作用于全部显示器）。因此工具条的状态由全部显示器会话的汇总
/// `RuntimeSummary` 得出，而不是只看主显示器。只有一台显示器时，结果与 v0.1 单显示器工具条完全相同。
struct FloatingToolbarState: Equatable {
    /// 播放 / 暂停按钮按下时做什么。
    enum PlaybackAction: Equatable {
        /// 至少一台显示器正在播放：暂停全部。
        case pauseAll
        /// 没有显示器在播放，至少一台是手动暂停：继续全部。
        case resumeAll
        /// 全部显示器都已停止，且至少一台停止前的壁纸还在资料库中：重新启用全部。
        case reenableAll
        /// 按钮不可用（准备中、智能暂停、失败、没有壁纸，或可重新启用的壁纸已被删除）。
        case none
    }

    /// 工具条中间「正在使用」的内容。
    enum NowPlaying: Equatable {
        /// 所有正在显示壁纸的显示器都显示这一张。`display` 是第一台显示它的显示器。
        case wallpaper(Wallpaper.ID, display: DisplayID)
        /// 多台显示器显示不同的壁纸。
        case multiple(displayCount: Int)
    }

    let playbackAction: PlaybackAction
    /// 按钮图标：只有「暂停全部」时显示暂停图标，其余显示播放图标。
    var showsPauseSymbol: Bool { playbackAction == .pauseAll }
    var canTogglePlayback: Bool { playbackAction != .none }
    /// 按钮的帮助文字（本地化键）。
    let playbackHelpKey: String
    /// 至少一台显示器有壁纸在显示或准备中、且没有停止。
    let canStop: Bool
    let nowPlaying: NowPlaying?

    init(summary: RuntimeSummary, isInLibrary: (Wallpaper.ID) -> Bool) {
        let states = summary.displays.map(\.runtime)
        let playback = Set(states.map(\.playbackState))

        if playback.contains(.playing) {
            playbackAction = .pauseAll
            playbackHelpKey = "shell.toolbar.pause"
        } else if playback.contains(.manualPaused) {
            playbackAction = .resumeAll
            playbackHelpKey = "shell.toolbar.resume"
        } else if playback.contains(.smartPaused) {
            // 智能暂停由系统条件决定，工具条不能强行继续（与 v0.1 一致）。
            playbackAction = .none
            playbackHelpKey = "shell.toolbar.resume"
        } else if !playback.isEmpty, playback.isSubset(of: [.stopped, .noWallpaper]), playback.contains(.stopped) {
            let canReenable = states.contains { state in
                state.playbackState == .stopped && state.lastActiveWallpaperID.map(isInLibrary) == true
            }
            playbackAction = canReenable ? .reenableAll : .none
            playbackHelpKey = "shell.toolbar.reenable"
        } else {
            playbackAction = .none
            playbackHelpKey = "shell.toolbar.play"
        }

        canStop = states.contains { state in
            state.playbackState != .stopped && (state.activeWallpaperID != nil || state.preparingWallpaperID != nil)
        }

        let showing = summary.displays.filter {
            $0.runtime.playbackState != .stopped && $0.runtime.activeWallpaperID != nil
        }
        let distinct = Set(showing.compactMap(\.runtime.activeWallpaperID))
        if let first = showing.first, let id = first.runtime.activeWallpaperID, distinct.count == 1 {
            nowPlaying = .wallpaper(id, display: first.displayID)
        } else if distinct.count > 1 {
            nowPlaying = .multiple(displayCount: showing.count)
        } else {
            nowPlaying = nil
        }
    }

    /// 执行播放 / 暂停按钮的动作；作用于所有显示器。
    /// 重新启用只针对停止前的壁纸仍在资料库中的显示器：壁纸被删除的显示器保持停止，不会重新播放已删除的内容。
    @MainActor
    static func perform(_ action: PlaybackAction, on runtime: WallpaperRuntimeManager,
                        isInLibrary: (Wallpaper.ID) -> Bool) {
        switch action {
        case .pauseAll: runtime.pause(.allDisplays)
        case .resumeAll: runtime.resume(.allDisplays)
        case .reenableAll:
            for display in runtime.summary.displays
            where display.runtime.playbackState == .stopped
                && display.runtime.lastActiveWallpaperID.map(isInLibrary) == true {
                runtime.reenable(.display(display.displayID))
            }
        case .none: break
        }
    }
}

/// 工具条「＋」菜单的项目（规格 2：本地 = File Picker / Finder 导入；Steam 内容来自 Steam 在线商店页面）。
enum FloatingToolbarAddItem: CaseIterable, Equatable {
    /// 从 Mac 导入视频（File Picker）。
    case importVideo
    /// 导入网页壁纸文件夹。
    case importWebFolder
    /// 前往 Steam 创意工坊页面（在线商店，Module 14）；不在这里下载或导入。
    case openSteamWorkshop

    var titleKey: String {
        switch self {
        case .importVideo: return "shell.toolbar.importMac"
        case .importWebFolder: return "shell.toolbar.importWeb"
        case .openSteamWorkshop: return "shell.toolbar.openSteam"
        }
    }
}
