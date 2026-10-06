import AppKit
import Combine

enum WallpaperRuntimeError: LocalizedError, Equatable {
    /// v0.1 只识别、不播放的类型（Scene）。
    case unsupportedType
    /// 类型受支持，但对应 Renderer 尚未接入（Web 需 Module 4）。
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

/// 给 UI 使用的轻量错误信息（Toast / Inline Error），不是弹窗。
struct WallpaperRuntimeFailure: Identifiable, Equatable {
    let id = UUID()
    let wallpaperID: Wallpaper.ID
    let wallpaperName: String
    /// 1.0：出错的显示器。重试必须回到同一台显示器，不能改用其他显示器。
    let displayID: DisplayID
    /// 例如：无法加载“雨夜”。
    let message: String
    let detail: String

    init(wallpaper: Wallpaper, error: Error, displayID: DisplayID) {
        wallpaperID = wallpaper.id
        wallpaperName = wallpaper.name
        self.displayID = displayID
        let format = NSLocalizedString("runtime.error.load", comment: "Cannot load wallpaper")
        message = String(format: format, wallpaper.name)
        detail = error.localizedDescription
    }
}

/// 唯一的 Runtime Manager。
///
/// Kinetic 1.0 Module 5：Runtime 由若干显示器会话（`DisplayRuntimeSession`）组成，每台显示器一个，
/// 各自拥有状态机、Renderer 与桌面宿主。状态规则仍全部来自 `WallpaperRuntimeMachine`。
/// - Apply 必须明确目标显示器（`apply(_:to:)`）；只有一个会话时，v0.1 的 `apply(_:)` 仍可使用。
/// - 暂停 / 继续 / 停止 / 重新启用可以作用于一台或全部显示器；不带参数时作用于全部（菜单栏全局控制的语义）。
/// - 智能暂停条件与全局音频作用于全部会话，新加入的会话继承当前值。
/// - 显示器的发现、稳定 ID、名称与断开重连属于 Module 16；这里只提供会话的加入与移除。
/// 不负责资料库、导入、系统状态监听或 Crossfade 动画本身。
@MainActor
final class WallpaperRuntimeManager: ObservableObject {
    enum GlobalUserCommand { case pause, resume, stop, reenable }
    /// Module 16：只广播明确的全局用户命令，断开设备用它更新下次重连的意图。
    @Published private(set) var globalUserCommand: GlobalUserCommand?

    typealias RendererFactory = @MainActor (Wallpaper) throws -> WallpaperRenderer

    /// 主会话（系统显示器顺序的第一个）的状态。v0.1 的单显示器界面使用它；
    /// 多显示器界面改用 `summary`。
    @Published private(set) var state = WallpaperRuntimeState()
    /// 全部显示器会话的汇总。
    @Published private(set) var summary = RuntimeSummary()
    @Published private(set) var lastFailure: WallpaperRuntimeFailure?
    /// 全局壁纸音频开关，作用于全部显示器。
    @Published private(set) var isAudioEnabled = false

    /// 主会话当前实际显示的壁纸模型（只读）。
    var activeWallpaper: Wallpaper? { primarySession?.activeWallpaper }
    var preparingWallpaper: Wallpaper? { primarySession?.preparingWallpaper }
    /// 主会话停止后「重新启用」使用的最后一张 Active Wallpaper。
    var lastActiveWallpaper: Wallpaper? { primarySession?.lastActiveWallpaper }
    /// 按当前系统排列顺序列出的显示器会话。
    private(set) var displayIDs: [DisplayID] = []

    private var sessions: [DisplayID: DisplayRuntimeSession] = [:]
    private var isSmartPauseConditionActive = false
    private var displaySmartPauseConditions: [DisplayID: Bool] = [:]
    private let makeRenderer: RendererFactory

    /// 没有任何显示器会话的 Runtime；由调用方用 `addDisplay` 加入。
    init(makeRenderer: @escaping RendererFactory = { try WallpaperRuntimeManager.standardRenderer(for: $0) }) {
        self.makeRenderer = makeRenderer
    }

    /// 只有一个跟随系统主显示器的会话（`.main`）。
    convenience init(desktop: DesktopContentHost, makeRenderer: @escaping RendererFactory) {
        self.init(makeRenderer: makeRenderer)
        addDisplay(.main, host: desktop)
    }

    convenience init(desktop: DesktopContentHost) {
        self.init(desktop: desktop, makeRenderer: { try WallpaperRuntimeManager.standardRenderer(for: $0) })
    }

    /// 当前版本能否播放该类型（与 standardRenderer 保持一致）。
    /// 供导入结果与界面判断；具体文件的兼容性由各 Renderer.prepare 验证。
    static func isRendererAvailable(for type: WallpaperType) -> Bool {
        type == .video || type == .web || type == .scene
    }

    /// 默认 Renderer 选择。运行时保持与具体渲染技术解耦。
    static func standardRenderer(for wallpaper: Wallpaper) throws -> WallpaperRenderer {
        switch wallpaper.type {
        case .video: return VideoRenderer(wallpaper: wallpaper)
        case .web: return WebRenderer(wallpaper: wallpaper)
        case .scene: return SceneRenderer(wallpaper: wallpaper)
        }
    }

    // MARK: - 显示器会话

    func hasDisplay(_ display: DisplayID) -> Bool { sessions[display] != nil }

    func state(of display: DisplayID) -> WallpaperRuntimeState? { sessions[display]?.state }

    func activeWallpaper(on display: DisplayID) -> Wallpaper? { sessions[display]?.activeWallpaper }

    func lastActiveWallpaper(on display: DisplayID) -> Wallpaper? { sessions[display]?.lastActiveWallpaper }

    /// 加入会话，继承智能暂停与音频；已存在时只更新显示器 metadata，不重新加载 Renderer。
    /// Module 6：每台显示器必须有自己的桌面宿主（自己的窗口与 Crossfade 舞台）。宿主已属于另一台显示器时拒绝加入，
    /// 否则一台显示器的淡入或停止会作用到另一台显示器的画面上。
    @discardableResult
    func addDisplay(_ display: DisplayID, name: String = "", host: DesktopContentHost,
                    frame: CGRect? = nil, scaleFactor: CGFloat = 1, stoppedWallpaper: Wallpaper? = nil) -> Bool {
        if let existing = sessions[display] {
            existing.displayName = name
            existing.frame = frame
            existing.scaleFactor = scaleFactor
            publish()
            return true
        }
        guard !sessions.values.contains(where: { $0.uses(host) }) else { return false }
        let session = DisplayRuntimeSession(displayID: display, displayName: name, desktop: host,
                                            frame: frame, scaleFactor: scaleFactor, stoppedWallpaper: stoppedWallpaper)
        session.onStateChange = { [weak self] in self?.publish() }
        session.onFailure = { [weak self] failure in self?.lastFailure = failure }
        session.onClearFailure = { [weak self] in
            guard let self, self.lastFailure?.displayID == display else { return }
            self.lastFailure = nil
        }
        session.setAudioEnabled(isAudioEnabled)
        sessions[display] = session
        displayIDs.append(display)
        if isSmartPauseConditionActive || displaySmartPauseConditions[display] == true { session.send(.smartPauseChanged(true)) }
        publish()
        return true
    }

    /// 移除一台显示器的会话：取消准备、恢复它的原生壁纸、释放 Renderer。
    /// 其他显示器不受影响，也不会接管它的壁纸。返回移除前的状态，供 Module 16 保存 assignment。
    @discardableResult
    func removeDisplay(_ display: DisplayID) -> DisplayRuntimeState? {
        guard let session = sessions[display] else { return nil }
        let last = session.snapshot
        session.onStateChange = nil
        session.onFailure = nil
        session.onClearFailure = nil
        session.shutdown()
        sessions[display] = nil
        displaySmartPauseConditions[display] = nil
        displayIDs.removeAll { $0 == display }
        if lastFailure?.displayID == display { lastFailure = nil }
        publish()
        return last
    }

    /// 系统主屏排列变化只更改汇总顺序，既有会话及 Renderer 保持原实例。
    func updateDisplayOrder(_ ordered: [DisplayID]) {
        let next = ordered.filter { sessions[$0] != nil }
        guard Set(next) == Set(displayIDs), next.count == displayIDs.count else { return }
        if displayIDs != next { displayIDs = next; publish() }
    }

    func manualPauseRequested(on display: DisplayID) -> Bool { sessions[display]?.manualPauseRequested ?? false }

    // MARK: - 用户命令

    /// 在目标显示器上：旧壁纸继续显示 → 准备新 Renderer → 首帧就绪 → 切换 → 释放旧 Renderer。
    /// 失败时保持该显示器的旧壁纸并通过 lastFailure 报告；其他显示器不变。目标不存在时不做任何事。
    func apply(_ wallpaper: Wallpaper, to display: DisplayID) {
        guard let session = sessions[display] else { return }
        let renderer: WallpaperRenderer
        do {
            guard wallpaper.supportState == .supported else { throw WallpaperRuntimeError.unsupportedType }
            renderer = try makeRenderer(wallpaper)
        } catch {
            // 不能创建 Renderer 时不改变任何运行状态，也不取消正在准备的其他壁纸。
            lastFailure = WallpaperRuntimeFailure(wallpaper: wallpaper, error: error, displayID: display)
            return
        }
        session.request(wallpaper, renderer: renderer, event: .apply(wallpaper.id))
    }

    /// v0.1 单显示器入口：只有一个显示器会话时应用到它。
    /// 有多个会话时不猜测目标、不回退到主显示器，也不做任何事；多显示器界面必须使用 `apply(_:to:)`。
    func apply(_ wallpaper: Wallpaper) {
        guard displayIDs.count == 1, let only = displayIDs.first else { return }
        apply(wallpaper, to: only)
    }

    func pause(_ target: RuntimeTarget = .allDisplays) {
        if target == .allDisplays { globalUserCommand = .pause }
        send(.pause, to: target)
    }
    func resume(_ target: RuntimeTarget = .allDisplays) {
        if target == .allDisplays { globalUserCommand = .resume }
        send(.resume, to: target)
    }
    func stop(_ target: RuntimeTarget = .allDisplays) {
        if target == .allDisplays { globalUserCommand = .stop }
        send(.stop, to: target)
    }

    /// 停止正在显示或准备这张壁纸的所有显示器（例如删除壁纸前）；其他显示器不变。
    func stop(displaysInvolving id: Wallpaper.ID) {
        for display in displayIDs where sessions[display]?.isUsing(id) == true {
            sessions[display]?.send(.stop)
        }
    }

    /// 任一显示器是否正在显示或准备这张壁纸。
    func isUsing(_ id: Wallpaper.ID) -> Bool {
        sessions.values.contains { $0.isUsing(id) }
    }

    /// 关闭轻量错误提示，不改变任何壁纸或播放状态。
    func dismissFailure() { lastFailure = nil }

    /// 由全局入口调用；候选渲染器准备完成时也会继承此状态。
    func setAudioEnabled(_ enabled: Bool) {
        guard isAudioEnabled != enabled else { return }
        isAudioEnabled = enabled
        for display in displayIDs { sessions[display]?.setAudioEnabled(enabled) }
    }

    /// 停止后使用该显示器最后一张 Active Wallpaper 重新启用。
    func reenable(_ target: RuntimeTarget = .allDisplays, isInLibrary: (Wallpaper.ID) -> Bool = { _ in true }) {
        if target == .allDisplays { globalUserCommand = .reenable }
        for display in displays(for: target) {
            guard let session = sessions[display], session.state.playbackState == .stopped,
                  let wallpaper = session.lastActiveWallpaper, isInLibrary(wallpaper.id) else { continue }
            let renderer: WallpaperRenderer
            do { renderer = try makeRenderer(wallpaper) } catch {
                lastFailure = WallpaperRuntimeFailure(wallpaper: wallpaper, error: error, displayID: display)
                continue
            }
            session.request(wallpaper, renderer: renderer, event: .reenable)
        }
    }

    /// 由系统监听调用；此处只接收条件是否成立。作用于全部显示器。
    func setSmartPauseActive(_ active: Bool) {
        setSmartPausePolicy(global: active, displays: displaySmartPauseConditions)
    }

    /// One policy snapshot avoids a transient resume when safety ends but local coverage still applies.
    /// Manual Pause / Stop remain exclusively governed by the existing state machine.
    func setSmartPausePolicy(global: Bool, displays: [DisplayID: Bool]) {
        let previousGlobal = isSmartPauseConditionActive
        let previousDisplays = displaySmartPauseConditions
        isSmartPauseConditionActive = global
        displaySmartPauseConditions = displays.filter { sessions[$0.key] != nil }
        for id in displayIDs {
            let before = previousGlobal || previousDisplays[id] == true
            let after = global || displaySmartPauseConditions[id] == true
            if before != after { sessions[id]?.send(.smartPauseChanged(after)) }
        }
    }

    /// App 退出：每台显示器取消准备、恢复原生壁纸、释放所有 Renderer。
    func shutdown() {
        for display in displayIDs { sessions[display]?.shutdown() }
    }

    // MARK: - 内部

    private var primarySession: DisplayRuntimeSession? {
        displayIDs.first.flatMap { sessions[$0] }
    }

    private func displays(for target: RuntimeTarget) -> [DisplayID] {
        switch target {
        case .allDisplays: return displayIDs
        case .display(let display): return sessions[display] == nil ? [] : [display]
        }
    }

    private func send(_ event: WallpaperRuntimeEvent, to target: RuntimeTarget) {
        for display in displays(for: target) { sessions[display]?.send(event) }
    }

    private func publish() {
        state = primarySession?.state ?? WallpaperRuntimeState()
        summary = RuntimeSummary(displays: displayIDs.compactMap { sessions[$0]?.snapshot })
    }
}
