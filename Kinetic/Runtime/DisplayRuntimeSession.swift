import AppKit

/// Kinetic 1.0 Module 5：一台显示器的 Wallpaper Session。
///
/// 每个会话有自己的状态机、桌面宿主（其中的 Crossfade 只作用于这台显示器）和 Renderer，
/// 与其他显示器完全独立：A 切换、失败或停止时，B 不暂停、不黑屏、不重载。
/// Renderer 生命周期规则与 v0.1 的唯一 Runtime 相同（从 `WallpaperRuntimeManager` 原样移入）：
/// 旧壁纸继续显示 → 准备新 Renderer → 首帧就绪 → 切换 → 释放旧 Renderer；失败时保留旧壁纸。
/// 只由 `WallpaperRuntimeManager` 创建和驱动。
@MainActor
final class DisplayRuntimeSession {
    let displayID: DisplayID
    var displayName: String
    var frame: CGRect?
    var scaleFactor: CGFloat
    var manualPauseRequested: Bool { machine.isManualPauseRequested }

    private(set) var state = WallpaperRuntimeState()
    /// 当前实际显示在这台显示器上的壁纸模型（只读）。
    private(set) var activeWallpaper: Wallpaper?
    private(set) var preparingWallpaper: Wallpaper?
    /// 停止后「重新启用」使用的最后一张 Active Wallpaper。
    private(set) var lastActiveWallpaper: Wallpaper?
    private(set) var isAudioEnabled = false

    /// 每处理完一个事件调用一次（状态已更新）。
    var onStateChange: (@MainActor () -> Void)?
    /// 准备失败或运行中失败。
    var onFailure: (@MainActor (WallpaperRuntimeFailure) -> Void)?
    /// 开始准备或新壁纸显示成功时，清除这台显示器的旧错误提示。
    var onClearFailure: (@MainActor () -> Void)?

    private var machine = WallpaperRuntimeMachine()
    private let desktop: DesktopContentHost

    private var activeRenderer: WallpaperRenderer?
    private var candidateRenderer: WallpaperRenderer?
    /// Crossfade 期间仍在淡出、尚未释放的旧 Renderer。
    private var retiringRenderers: [WallpaperRenderer] = []
    private var candidateTask: Task<Void, Never>?
    private var pendingRequest: (wallpaper: Wallpaper, renderer: WallpaperRenderer)?
    private var pendingFailure: (wallpaper: Wallpaper, error: Error)?
    private var eventQueue: [WallpaperRuntimeEvent] = []
    private var isDraining = false

    init(displayID: DisplayID, displayName: String, desktop: DesktopContentHost,
         frame: CGRect? = nil, scaleFactor: CGFloat = 1, stoppedWallpaper: Wallpaper? = nil) {
        self.displayID = displayID
        self.displayName = displayName
        self.desktop = desktop
        self.frame = frame
        self.scaleFactor = scaleFactor
        // 停止过的 assignment 只恢复重新启用记忆，不创建或播放 Renderer。状态规则仍来自同一状态机。
        if let stoppedWallpaper {
            machine = WallpaperRuntimeMachine(lastActiveWallpaperID: stoppedWallpaper.id, isStopped: true)
            lastActiveWallpaper = stoppedWallpaper
            state = machine.snapshot
        }
    }

    var snapshot: DisplayRuntimeState {
        DisplayRuntimeState(displayID: displayID, displayName: displayName, runtime: state, frame: frame, scaleFactor: scaleFactor)
    }

    /// 这个会话是否使用该桌面宿主（Module 6：一个宿主只能属于一台显示器）。
    func uses(_ host: DesktopContentHost) -> Bool { desktop === host }

    /// Configuration may update an active renderer in place without issuing a playback event.
    /// The operation remains renderer-agnostic; failures only report and retain the active surface.
    func configureActive(_ id: Wallpaper.ID,
        configure: (WallpaperRenderer, @escaping @MainActor (Error) -> Void) -> Bool) -> Bool {
        guard activeWallpaper?.id == id, state.preparingWallpaperID == nil,
              [.playing, .manualPaused, .smartPaused].contains(state.playbackState),
              let renderer = activeRenderer else { return false }
        let accepted = configure(renderer) { [weak self, weak renderer] error in
            guard let self, let renderer, self.activeRenderer === renderer else { return }
            self.onFailure?(WallpaperRuntimeFailure(wallpaper: renderer.wallpaper, error: error, displayID: self.displayID))
        }
        if accepted { onClearFailure?() }
        return accepted
    }

    /// 这台显示器是否正在显示或准备这张壁纸（包括壁纸模型本身）。
    func isUsing(_ id: Wallpaper.ID) -> Bool {
        state.activeWallpaperID == id || state.preparingWallpaperID == id
            || activeWallpaper?.id == id || preparingWallpaper?.id == id
    }

    // MARK: - 命令（由 Manager 调用）

    /// 以一个新 Renderer 请求 Apply 或重新启用。状态机忽略时释放未使用的 Renderer。
    func request(_ wallpaper: Wallpaper, renderer: WallpaperRenderer, event: WallpaperRuntimeEvent) {
        pendingRequest = (wallpaper, renderer)
        send(event)
        // 状态机忽略了此请求（例如已在显示或正在准备同一张）时，释放未使用的 Renderer。
        if let unused = pendingRequest {
            pendingRequest = nil
            unused.renderer.dispose()
        }
    }

    func send(_ event: WallpaperRuntimeEvent) {
        eventQueue.append(event)
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }
        while !eventQueue.isEmpty {
            let next = eventQueue.removeFirst()
            for effect in machine.handle(next) { perform(effect) }
            state = machine.snapshot
            onStateChange?()
        }
    }

    func setAudioEnabled(_ enabled: Bool) {
        guard isAudioEnabled != enabled else { return }
        isAudioEnabled = enabled
        activeRenderer?.setMuted(!enabled)
        // 淡出的旧壁纸不能在新壁纸开始发声后继续输出声音。
        retiringRenderers.forEach { $0.setMuted(true) }
    }

    /// 取消准备、恢复这台显示器的原生壁纸、释放所有 Renderer（App 退出或显示器移除）。
    func shutdown() {
        send(.stop)
        discardCandidate()
        desktop.stop()
        releaseRetiringRenderers()
    }

    // MARK: - 动作

    private func perform(_ effect: WallpaperRuntimeEffect) {
        switch effect {
        case .prepareCandidate(let id):
            prepareCandidate(id)
        case .discardCandidate:
            discardCandidate()
        case .promoteCandidate:
            promoteCandidate()
        case .playActive:
            activeRenderer?.play()
        case .pauseActive:
            activeRenderer?.pause()
            // 淡出中的旧壁纸同样停止推进。
            retiringRenderers.forEach { $0.pause() }
        case .resumeActive:
            activeRenderer?.resume()
        case .removeDesktopContent:
            // 先移出内容、恢复原生壁纸；淡出中的旧壁纸随后释放。
            desktop.stop()
            releaseRetiringRenderers()
        case .disposeActive:
            activeRenderer?.onFailure = nil
            activeRenderer?.dispose()
            activeRenderer = nil
            activeWallpaper = nil
        case .reportFailure(let id):
            if let failure = pendingFailure, failure.wallpaper.id == id {
                onFailure?(WallpaperRuntimeFailure(wallpaper: failure.wallpaper, error: failure.error,
                                                   displayID: displayID))
            }
            pendingFailure = nil
        }
    }

    private func prepareCandidate(_ id: Wallpaper.ID) {
        guard let request = pendingRequest, request.wallpaper.id == id else { return }
        onClearFailure?()
        pendingRequest = nil
        let renderer = request.renderer
        candidateRenderer = renderer
        preparingWallpaper = request.wallpaper
        // A renderer prepares before it is on the desktop. Give an unsized view this display's shape first:
        // a scene otherwise prepares at the main screen's size and stays squeezed on a display shaped differently.
        if let size = frame?.size, size.width >= 1, size.height >= 1,
           renderer.displayView.bounds.width < 1 || renderer.displayView.bounds.height < 1 {
            renderer.displayView.frame = CGRect(origin: .zero, size: size)
        }
        candidateTask = Task { @MainActor [weak self] in
            do {
                try await renderer.prepare()
                self?.candidateDidFinish(renderer, error: nil)
            } catch {
                self?.candidateDidFinish(renderer, error: error)
            }
        }
    }

    private func candidateDidFinish(_ renderer: WallpaperRenderer, error: Error?) {
        // 已被取代或已取消的候选，结果一律忽略。
        guard candidateRenderer === renderer, let wallpaper = preparingWallpaper else { return }
        candidateTask = nil
        if let error {
            pendingFailure = (wallpaper, error)
            send(.preparationFailed(wallpaper.id))
        } else {
            // Renderer 默认静音；只有用户开启全局音频时才解除静音。
            if isAudioEnabled { renderer.setMuted(false) }
            send(.preparationSucceeded(wallpaper.id))
        }
    }

    private func discardCandidate() {
        candidateTask?.cancel()
        candidateTask = nil
        candidateRenderer?.dispose()
        candidateRenderer = nil
        preparingWallpaper = nil
    }

    private func promoteCandidate() {
        guard let renderer = candidateRenderer, let wallpaper = preparingWallpaper else { return }
        onClearFailure?()
        let previous = activeRenderer
        candidateRenderer = nil
        preparingWallpaper = nil
        activeRenderer = renderer
        activeWallpaper = wallpaper
        lastActiveWallpaper = wallpaper
        let id = wallpaper.id
        renderer.onFailure = { [weak self, weak renderer] error in
            guard let self, let renderer, self.activeRenderer === renderer else { return }
            self.pendingFailure = (renderer.wallpaper, error)
            self.send(.activeFailed(id))
        }
        guard let previous else {
            // 没有旧内容（首次应用、重新启用）：直接显示。
            desktop.present(renderer.displayView)
            return
        }
        // A 保持显示，B 在上方淡入；淡入完成且 A 已移出窗口后才释放 A。只作用于这台显示器的宿主。
        previous.onFailure = nil
        if isAudioEnabled { previous.setMuted(true) }
        retiringRenderers.append(previous)
        desktop.transition(to: renderer.displayView) { [weak self, weak previous] in
            guard let self, let previous else { return }
            self.retire(previous)
        }
    }

    private func retire(_ renderer: WallpaperRenderer) {
        guard let index = retiringRenderers.firstIndex(where: { $0 === renderer }) else { return }
        retiringRenderers.remove(at: index)
        renderer.dispose()
    }

    private func releaseRetiringRenderers() {
        let retiring = retiringRenderers
        retiringRenderers.removeAll()
        retiring.forEach { $0.dispose() }
    }
}
