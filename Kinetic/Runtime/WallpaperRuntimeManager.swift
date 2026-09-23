import AppKit
import Combine

enum WallpaperRuntimeError: LocalizedError, Equatable {
    /// v0.1 只识别、不播放的类型（Scene）。
    case unsupportedType
    /// 类型受支持，但对应 Renderer 尚未接入。
    case rendererUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedType:
            return NSLocalizedString("runtime.error.unsupported", comment: "Unsupported wallpaper type")
        case .rendererUnavailable:
            return NSLocalizedString("runtime.error.rendererUnavailable", comment: "Renderer not available yet")
        }
    }
}

/// 轻量错误信息（Toast / Inline Error），不是弹窗。
struct WallpaperRuntimeFailure: Identifiable, Equatable {
    let id = UUID()
    let wallpaperID: Wallpaper.ID
    let wallpaperName: String
    /// 例如：无法加载“雨夜”。
    let message: String
    let detail: String

    init(wallpaper: Wallpaper, error: Error) {
        wallpaperID = wallpaper.id
        wallpaperName = wallpaper.name
        let format = NSLocalizedString("runtime.error.load", comment: "Cannot load wallpaper")
        message = String(format: format, wallpaper.name)
        detail = error.localizedDescription
    }
}

/// 唯一的 Runtime Manager。
/// 统一管理 Active Wallpaper、Renderer 生命周期与 PlaybackState；
/// 状态规则全部来自 WallpaperRuntimeMachine，这里只执行其产生的动作。
/// 不负责资料库、导入、系统状态监听、音频设置或 Crossfade 动画。
@MainActor
final class WallpaperRuntimeManager: ObservableObject {
    typealias RendererFactory = @MainActor (Wallpaper) throws -> WallpaperRenderer

    @Published private(set) var state = WallpaperRuntimeState()
    @Published private(set) var lastFailure: WallpaperRuntimeFailure?
    /// 当前实际显示在桌面上的壁纸模型（只读）。
    private(set) var activeWallpaper: Wallpaper?
    private(set) var preparingWallpaper: Wallpaper?
    /// 停止后「重新启用」使用的最后一张 Active Wallpaper。
    private(set) var lastActiveWallpaper: Wallpaper?

    private var machine = WallpaperRuntimeMachine()
    private let desktop: DesktopContentHost
    private let makeRenderer: RendererFactory

    private var activeRenderer: WallpaperRenderer?
    private var candidateRenderer: WallpaperRenderer?
    /// Crossfade 期间仍在淡出、尚未释放的旧 Renderer。
    private var retiringRenderers: [WallpaperRenderer] = []
    private var candidateTask: Task<Void, Never>?
    private var pendingRequest: (wallpaper: Wallpaper, renderer: WallpaperRenderer)?
    private var pendingFailure: (wallpaper: Wallpaper, error: Error)?
    private var eventQueue: [WallpaperRuntimeEvent] = []
    private var isDraining = false

    init(desktop: DesktopContentHost, makeRenderer: @escaping RendererFactory) {
        self.desktop = desktop
        self.makeRenderer = makeRenderer
    }

    convenience init(desktop: DesktopContentHost) {
        self.init(desktop: desktop, makeRenderer: { try WallpaperRuntimeManager.standardRenderer(for: $0) })
    }

    /// 当前版本能否播放该类型（与 standardRenderer 保持一致）。
    /// 用于标记“暂不能播放”的类型。
    static func isRendererAvailable(for type: WallpaperType) -> Bool {
        type == .video
    }

    /// 默认的 Renderer 选择。
    static func standardRenderer(for wallpaper: Wallpaper) throws -> WallpaperRenderer {
        switch wallpaper.type {
        case .video: return VideoRenderer(wallpaper: wallpaper)
        case .web: throw WallpaperRuntimeError.rendererUnavailable
        case .scene: throw WallpaperRuntimeError.unsupportedType
        }
    }

    // MARK: - 用户命令

    /// 旧壁纸继续显示 → 准备新 Renderer → 首帧就绪 → 切换 → 释放旧 Renderer。
    /// 失败时保持旧壁纸并通过 lastFailure 报告。
    func apply(_ wallpaper: Wallpaper) {
        let renderer: WallpaperRenderer
        do {
            guard wallpaper.supportState == .supported else { throw WallpaperRuntimeError.unsupportedType }
            renderer = try makeRenderer(wallpaper)
        } catch {
            // 不能创建 Renderer 时不改变任何运行状态，也不取消正在准备的其他壁纸。
            lastFailure = WallpaperRuntimeFailure(wallpaper: wallpaper, error: error)
            return
        }
        request(wallpaper, renderer: renderer, event: .apply(wallpaper.id))
    }

    func pause() { send(.pause) }
    func resume() { send(.resume) }
    func stop() { send(.stop) }

    /// 停止后使用最后一张 Active Wallpaper 重新启用。
    func reenable() {
        guard state.playbackState == .stopped, let wallpaper = lastActiveWallpaper else { return }
        let renderer: WallpaperRenderer
        do { renderer = try makeRenderer(wallpaper) } catch {
            lastFailure = WallpaperRuntimeFailure(wallpaper: wallpaper, error: error)
            return
        }
        request(wallpaper, renderer: renderer, event: .reenable)
    }

    /// 由系统状态监听调用；此处只接收条件是否成立。
    func setSmartPauseActive(_ active: Bool) { send(.smartPauseChanged(active)) }

    /// App 退出：取消准备、恢复原生壁纸、释放所有 Renderer。
    func shutdown() {
        send(.stop)
        discardCandidate()
        desktop.stop()
        releaseRetiringRenderers()
    }

    // MARK: - 事件与动作

    private func request(_ wallpaper: Wallpaper, renderer: WallpaperRenderer, event: WallpaperRuntimeEvent) {
        pendingRequest = (wallpaper, renderer)
        send(event)
        // 状态机忽略了此请求（例如已在显示或正在准备同一张）时，释放未使用的 Renderer。
        if let unused = pendingRequest {
            pendingRequest = nil
            unused.renderer.dispose()
        }
    }

    private func send(_ event: WallpaperRuntimeEvent) {
        eventQueue.append(event)
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }
        while !eventQueue.isEmpty {
            let next = eventQueue.removeFirst()
            for effect in machine.handle(next) { perform(effect) }
            state = machine.snapshot
        }
    }

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
                lastFailure = WallpaperRuntimeFailure(wallpaper: failure.wallpaper, error: failure.error)
            }
            pendingFailure = nil
        }
    }

    private func prepareCandidate(_ id: Wallpaper.ID) {
        guard let request = pendingRequest, request.wallpaper.id == id else { return }
        pendingRequest = nil
        let renderer = request.renderer
        candidateRenderer = renderer
        preparingWallpaper = request.wallpaper
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
        // A 保持显示，B 在上方淡入；淡入完成且 A 已移出窗口后才释放 A。
        previous.onFailure = nil
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
