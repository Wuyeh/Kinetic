import AppKit
import ServiceManagement

/// Module 19：「登录 Mac 时启动 Kinetic」在系统中的实际状态。
enum LoginItemStatus: Equatable, Sendable {
    /// 未登记。
    case disabled
    case enabled
    /// 已登记，但用户在「系统设置 > 通用 > 登录项」中关掉了，需要在那里重新允许。
    case requiresApproval

    /// 设置开关显示为打开：已启用，或已登记但等待用户在系统设置中允许。
    var isOn: Bool { self == .enabled || self == .requiresApproval }
}

/// 登录项的系统接口；真实实现为 `SMAppService.mainApp`，测试注入替身。
@MainActor
protocol LoginItemService: AnyObject {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

@MainActor
final class MainAppLoginItemService: LoginItemService {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        // 从未登记过时系统报告 `.notFound`（验收确认，此时登记可以成功），按未登记处理；
        // 登记真的失败时由 `register()` 抛出错误说明原因。
        case .notRegistered, .notFound: .disabled
        @unknown default: .disabled
        }
    }

    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// Module 19：登录时启动。默认关闭，只由设置中的开关控制。
/// 系统状态是唯一事实来源（用户可能在系统设置中改过），设置中保存的值始终与之同步。
@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var status: LoginItemStatus
    /// 最近一次更改失败的原因；成功或重新刷新后清除。
    @Published private(set) var lastError: String?

    private let service: LoginItemService
    private let settings: SettingsStore
    private var activationObserver: NSObjectProtocol?

    init(service: LoginItemService, settings: SettingsStore) {
        self.service = service
        self.settings = settings
        status = service.status
    }

    deinit {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }

    /// 启动时：旧版本只保存了偏好、系统里还没有登记时，按用户偏好登记一次；随后以系统状态为准。
    /// App 每次回到前台时重新读取（用户可能刚在系统设置里改过）。
    func start(applicationNotifications: NotificationCenter = .default) {
        if settings.state.launchAtLoginEnabled, service.status == .disabled {
            perform { try service.register() }
        }
        refresh()
        guard activationObserver == nil else { return }
        activationObserver = applicationNotifications.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        status = service.status
        settings.set(\.launchAtLoginEnabled, to: status.isOn)
    }

    /// 设置开关调用。失败时开关回到系统实际状态，并给出原因。
    func setEnabled(_ enabled: Bool) {
        lastError = nil
        let current = service.status
        if enabled, current != .enabled {
            perform { try service.register() }
        } else if !enabled, current != .disabled {
            perform { try service.unregister() }
        }
        refresh()
    }

    func openSystemSettings() {
        service.openSystemSettings()
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            lastError = error.localizedDescription
        }
    }
}
