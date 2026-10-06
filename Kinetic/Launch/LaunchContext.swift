import AppKit

/// Module 19：本次启动是否来自「登录时启动」。登录启动时不弹出主窗口，只在菜单栏运行（用户决定）。
enum LaunchContext {
    #if DEBUG
    /// 仅用于验收：在 scheme 的环境变量里设为 1，模拟一次登录启动。
    /// 不用启动参数：落单的 `--xxx` 参数会让 SwiftUI 启动时不创建主窗口，模拟就不准确了（验收时观察到）。
    static let simulatedLoginLaunchEnvironmentKey = "KINETIC_SIMULATE_LOGIN_LAUNCH"
    #endif

    /// 在 `applicationWillFinishLaunching` 中读取当前启动事件。
    @MainActor
    static func detectCurrentLaunch() -> Bool {
        isLoginLaunch(event: NSAppleEventManager.shared().currentAppleEvent,
                      environment: ProcessInfo.processInfo.environment)
    }

    /// 登录项启动时，打开 App 的 Apple 事件带有 `keyAELaunchedAsLogInItem`。
    static func isLoginLaunch(event: NSAppleEventDescriptor?, environment: [String: String]) -> Bool {
        #if DEBUG
        if environment[simulatedLoginLaunchEnvironmentKey] == "1" { return true }
        #endif
        guard let event,
              event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEOpenApplication)
        else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
            == OSType(keyAELaunchedAsLogInItem)
    }
}

/// Module 19：登录启动时隐藏启动阶段出现的主窗口，只在菜单栏运行。
///
/// SwiftUI 创建主窗口后要稍晚才把它显示出来，所以只隐藏一次不够：启动阶段内它每次出现都立即隐藏，
/// 期间保持完全透明，不会闪现。用户主动打开（菜单栏「打开 Kinetic」、点按 Dock 图标）或启动阶段结束后
/// 恢复正常，之后打开主窗口一律显示；系统这次没有在启动时创建主窗口时，用户第一次打开也照常显示。
@MainActor
final class MainWindowLaunchSuppression {
    /// 启动阶段的时长：主窗口在启动后很快出现，留足余量。
    static let launchPhase: TimeInterval = 5

    private(set) var isActive: Bool
    private weak var hiddenWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private let notificationCenter: NotificationCenter

    init(isLoginLaunch: Bool, notificationCenter: NotificationCenter = .default) {
        isActive = isLoginLaunch
        self.notificationCenter = notificationCenter
    }

    /// 主窗口出现时调用。登录启动的启动阶段内接管并隐藏这个窗口，返回 true；否则不做任何事。
    @discardableResult
    func hide(_ window: NSWindow) -> Bool {
        guard isActive, hiddenWindow == nil else { return false }
        hiddenWindow = window
        window.alphaValue = 0
        let names = [NSWindow.didUpdateNotification, NSWindow.didChangeOcclusionStateNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification]
        observers = names.map { name in
            notificationCenter.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.orderOutHiddenWindow() }
            }
        }
        DispatchQueue.main.async { [weak self] in self?.orderOutHiddenWindow() }
        return true
    }

    /// 启动阶段结束，或用户主动打开主窗口：窗口保持隐藏但恢复不透明，下次打开时正常显示。
    func end() {
        guard isActive else { return }
        isActive = false
        observers.forEach(notificationCenter.removeObserver)
        observers = []
        if let window = hiddenWindow {
            if window.isVisible { window.orderOut(nil) }
            window.alphaValue = 1
        }
        hiddenWindow = nil
    }

    private func orderOutHiddenWindow() {
        guard isActive, let window = hiddenWindow, window.isVisible else { return }
        window.orderOut(nil)
    }
}
