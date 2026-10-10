import Combine
import Foundation

/// Module 51：自适应帧率。使用电池、低电量模式或系统温度偏高（serious 及以上）时，桌面场景壁纸减半到 15 帧、
/// 网页壁纸的脚本动画限制到 30 帧；条件解除后恢复。只读公开的系统状态（智能暂停监视器与 ProcessInfo），
/// 不改变暂停意图：电池 / 低电量时暂停等规则照旧优先。视频壁纸不变。
@MainActor
final class AdaptiveFrameRateController: ObservableObject {
    enum Reason: Equatable, Sendable {
        case lowPowerMode, battery, thermal
        var title: String {
            switch self {
            case .lowPowerMode: return "低电量模式"
            case .battery: return "使用电池"
            case .thermal: return "机器温度偏高"
            }
        }
    }

    static let sceneFramesPerSecond = 15
    static let webFramesPerSecond = 30

    /// Why frame rates are lowered right now; nil means full rate.
    @Published private(set) var reason: Reason?
    private let apply: @MainActor (Bool) -> Void
    private let thermalState: () -> ProcessInfo.ThermalState
    private var enabled: Bool
    private var conditions = SmartPauseConditions()
    private var subscriptions = Set<AnyCancellable>()
    private var thermalObserver: NSObjectProtocol?

    /// `apply(true)` lowers every scene and web wallpaper; `apply(false)` restores them.
    init(settings: SettingsStore, monitor: SmartPauseMonitor?,
         thermalState: @escaping () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState },
         apply: @escaping @MainActor (Bool) -> Void = AdaptiveFrameRateController.applyToRenderers) {
        self.apply = apply
        self.thermalState = thermalState
        enabled = settings.state.adaptiveFrameRateEnabled
        settings.$state.map(\.adaptiveFrameRateEnabled).removeDuplicates().dropFirst().sink { [weak self] value in
            self?.enabled = value; self?.update()
        }.store(in: &subscriptions)
        monitor?.$conditions.sink { [weak self] value in self?.conditions = value; self?.update() }.store(in: &subscriptions)
        thermalObserver = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                                                 object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        update()
    }

    deinit { if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) } }

    static func reason(enabled: Bool, conditions: SmartPauseConditions, thermal: ProcessInfo.ThermalState) -> Reason? {
        guard enabled else { return nil }
        if conditions.lowPowerMode { return .lowPowerMode }
        if conditions.onBatteryPower { return .battery }
        if thermal == .serious || thermal == .critical { return .thermal }
        return nil
    }

    func update() {
        let next = Self.reason(enabled: enabled, conditions: conditions, thermal: thermalState())
        let changed = (next != nil) != (reason != nil)
        if next != reason { reason = next }
        if changed { apply(next != nil) }
    }

    func shutdown() {
        subscriptions.removeAll()
        if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) }
        thermalObserver = nil
        if reason != nil { reason = nil; apply(false) }
    }

    static func applyToRenderers(_ throttled: Bool) {
        SceneRenderer.applyAdaptiveFrameRateThrottle(throttled)
        WebRenderer.applyAdaptiveFrameRateLimit(throttled ? webFramesPerSecond : nil)
    }
}
