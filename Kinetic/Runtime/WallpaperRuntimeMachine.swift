import Foundation

/// Runtime 的输入事件。只携带壁纸标识，不携带 Renderer 或 UI 对象。
enum WallpaperRuntimeEvent: Equatable, Sendable {
    /// 用户明确应用一张壁纸（双击、Hover「应用」、Onboarding 等最终都走这里）。
    case apply(Wallpaper.ID)
    case preparationSucceeded(Wallpaper.ID)
    case preparationFailed(Wallpaper.ID)
    /// 当前 Active Renderer 运行中失败；Renderer 自己负责保留静态画面。
    case activeFailed(Wallpaper.ID)
    case pause
    case resume
    /// 系统条件（全屏、锁屏、休眠、低电量等）是否成立。
    case smartPauseChanged(Bool)
    case stop
    case reenable
}

/// 状态机要求执行者完成的动作。执行顺序即数组顺序。
enum WallpaperRuntimeEffect: Equatable, Sendable {
    /// 开始准备候选壁纸；准备期间旧壁纸保持显示。
    case prepareCandidate(Wallpaper.ID)
    /// 取消并释放候选 Renderer（被新的 Apply 取代、准备失败或 Stop）。
    case discardCandidate
    /// 候选首帧已就绪：先把候选内容放上桌面，再释放旧 Active Renderer。
    case promoteCandidate
    /// 首次开始播放 Active Renderer。
    case playActive
    case pauseActive
    /// 从暂停处继续，不重建、不回到开头。
    case resumeActive
    /// 移除桌面窗口内容，露出用户原本的 macOS 静态壁纸。
    case removeDesktopContent
    case disposeActive
    case reportFailure(Wallpaper.ID)
}

/// 唯一的播放状态规则。纯值类型，不持有 Renderer、窗口或 UI，便于逐条测试。
/// 任何 Renderer 都不能自行决定 App 状态；它们只接收由这里推导出的动作。
struct WallpaperRuntimeMachine: Equatable, Sendable {
    private(set) var activeWallpaperID: Wallpaper.ID?
    private(set) var candidateWallpaperID: Wallpaper.ID?
    private(set) var lastActiveWallpaperID: Wallpaper.ID?
    /// 用户选择了「停止壁纸」且存在可重新启用的壁纸。
    private(set) var isStopped = false
    /// 用户意图：“Kinetic 当前不要播放动画”。只有用户 Resume 才能清除。
    private(set) var isManualPauseRequested = false
    /// 系统条件：只描述条件是否成立，不代表用户意图。
    private(set) var isSmartPauseConditionActive = false
    private(set) var isActiveFailed = false
    /// Active Renderer 是否已经开始过播放，用于区分 play 与 resume。
    private(set) var hasActiveStarted = false

    var playbackState: PlaybackState {
        guard activeWallpaperID != nil else {
            if candidateWallpaperID != nil { return .preparing }
            return isStopped ? .stopped : .noWallpaper
        }
        if isActiveFailed { return .failed }
        // Manual Pause 优先于 Smart Pause。
        if isManualPauseRequested { return .manualPaused }
        if isSmartPauseConditionActive { return .smartPaused }
        return .playing
    }

    var snapshot: WallpaperRuntimeState {
        var state = WallpaperRuntimeState()
        state.playbackState = playbackState
        state.activeWallpaperID = activeWallpaperID
        state.preparingWallpaperID = candidateWallpaperID
        state.lastActiveWallpaperID = lastActiveWallpaperID
        return state
    }

    private var shouldActiveRun: Bool {
        activeWallpaperID != nil && !isActiveFailed
            && !isManualPauseRequested && !isSmartPauseConditionActive
    }

    mutating func handle(_ event: WallpaperRuntimeEvent) -> [WallpaperRuntimeEffect] {
        switch event {
        case .apply(let id):
            return apply(id)
        case .reenable:
            guard isStopped, candidateWallpaperID == nil, let last = lastActiveWallpaperID else { return [] }
            candidateWallpaperID = last
            return [.prepareCandidate(last)]
        case .preparationSucceeded(let id):
            return promote(id)
        case .preparationFailed(let id):
            guard candidateWallpaperID == id else { return [] }
            candidateWallpaperID = nil
            // 旧壁纸、停止状态与暂停意图全部保持不变。
            return [.reportFailure(id), .discardCandidate]
        case .activeFailed(let id):
            guard activeWallpaperID == id, !isActiveFailed else { return [] }
            isActiveFailed = true
            return [.reportFailure(id)]
        case .pause:
            return pause()
        case .resume:
            guard isManualPauseRequested else { return [] }
            return transition { $0.isManualPauseRequested = false }
        case .smartPauseChanged(let active):
            guard isSmartPauseConditionActive != active else { return [] }
            return transition { $0.isSmartPauseConditionActive = active }
        case .stop:
            return stop()
        }
    }

    private mutating func apply(_ id: Wallpaper.ID) -> [WallpaperRuntimeEffect] {
        if candidateWallpaperID == id { return [] }
        if activeWallpaperID == id, !isActiveFailed { return [] }
        var effects: [WallpaperRuntimeEffect] = []
        // 最新一次 Apply 生效；较早的候选直接取消，当前 Active 继续显示。
        if candidateWallpaperID != nil { effects.append(.discardCandidate) }
        candidateWallpaperID = id
        effects.append(.prepareCandidate(id))
        return effects
    }

    private mutating func promote(_ id: Wallpaper.ID) -> [WallpaperRuntimeEffect] {
        guard candidateWallpaperID == id else { return [] }
        candidateWallpaperID = nil
        activeWallpaperID = id
        lastActiveWallpaperID = id
        isStopped = false
        isActiveFailed = false
        hasActiveStarted = false
        var effects: [WallpaperRuntimeEffect] = [.promoteCandidate]
        // Manual Pause 或 Smart Pause 下切换：新壁纸成为 Active，但保持暂停。
        if shouldActiveRun {
            hasActiveStarted = true
            effects.append(.playActive)
        }
        return effects
    }

    private mutating func pause() -> [WallpaperRuntimeEffect] {
        guard !isManualPauseRequested, !isActiveFailed else { return [] }
        // 可以在首次准备期间记录暂停意图；停止或无壁纸时忽略。
        guard activeWallpaperID != nil || candidateWallpaperID != nil else { return [] }
        return transition { $0.isManualPauseRequested = true }
    }

    private mutating func stop() -> [WallpaperRuntimeEffect] {
        guard activeWallpaperID != nil || candidateWallpaperID != nil else { return [] }
        var effects: [WallpaperRuntimeEffect] = []
        if candidateWallpaperID != nil { effects.append(.discardCandidate) }
        if activeWallpaperID != nil {
            // 先恢复原生壁纸（移除内容），再释放 Renderer。
            effects.append(.removeDesktopContent)
            effects.append(.disposeActive)
        }
        lastActiveWallpaperID = activeWallpaperID ?? lastActiveWallpaperID
        activeWallpaperID = nil
        candidateWallpaperID = nil
        isActiveFailed = false
        hasActiveStarted = false
        // Stop 与 Pause 是不同语义：重新启用或在停止后 Apply 都应直接播放。
        isManualPauseRequested = false
        isStopped = lastActiveWallpaperID != nil
        return effects
    }

    /// 修改意图或系统条件后，只根据 Active 是否应运行的变化产生 play/pause/resume。
    private mutating func transition(_ change: (inout WallpaperRuntimeMachine) -> Void) -> [WallpaperRuntimeEffect] {
        let wasRunning = shouldActiveRun
        change(&self)
        let isRunning = shouldActiveRun
        if wasRunning, !isRunning { return [.pauseActive] }
        if !wasRunning, isRunning {
            if hasActiveStarted { return [.resumeActive] }
            hasActiveStarted = true
            return [.playActive]
        }
        return []
    }
}
