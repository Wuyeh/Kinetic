import AppKit

/// 仅管理一个主显示器桌面窗口的创建、对齐、显示与释放。
/// 不管理 Wallpaper 播放状态、导入、Video/Web Renderer 或系统壁纸文件。
@MainActor
final class DesktopWindowRuntime: NSObject {
    private(set) var window: DesktopWallpaperWindow?
    private(set) var targetDisplay: DesktopDisplay?

    private let identifier: NSUserInterfaceItemIdentifier
    private let primaryDisplay: @MainActor () -> DesktopDisplay?
    private let applicationNotifications: NotificationCenter
    private let workspaceNotifications: NotificationCenter
    private var content: NSView?
    private var isObserving = false

    init(
        identifier: NSUserInterfaceItemIdentifier,
        primaryDisplay: @escaping @MainActor () -> DesktopDisplay? = { DesktopDisplay.primary() },
        applicationNotifications: NotificationCenter = .default,
        workspaceNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.identifier = identifier
        self.primaryDisplay = primaryDisplay
        self.applicationNotifications = applicationNotifications
        self.workspaceNotifications = workspaceNotifications
        super.init()
    }

    /// 返回 false 仅表示主屏暂不可用；保留内容，收到屏幕变化通知后再对齐显示。
    @discardableResult
    func present(_ contentView: NSView) -> Bool {
        content = contentView
        window?.contentView = contentView
        beginObservingIfNeeded()
        return synchronizePrimaryDisplay()
    }

    /// 幂等释放，只处理自己持有的窗口；原生静态壁纸始终在该窗口下方。
    func stop() {
        applicationNotifications.removeObserver(self)
        workspaceNotifications.removeObserver(self)
        isObserving = false
        window?.orderOut(nil)
        window?.contentView = nil
        window?.close()
        window = nil
        targetDisplay = nil
        content = nil
    }

    @discardableResult
    private func synchronizePrimaryDisplay() -> Bool {
        guard let content else { return false }
        guard let display = primaryDisplay(), display.hasUsableFrame else {
            // 拔插过程暂时无主屏时隐藏覆盖层，不任意选择副屏，也不改动系统壁纸。
            window?.orderOut(nil)
            targetDisplay = nil
            return false
        }

        if let window {
            if window.frame != display.frame {
                window.setFrame(display.frame, display: true, animate: false)
            }
        } else {
            let newWindow = DesktopWallpaperWindow(frame: display.frame, identifier: identifier)
            newWindow.contentView = content
            window = newWindow
        }
        targetDisplay = display
        // 只在当前桌面层内排序，不激活 App、不把桌面窗口变成 key/main window。
        window?.orderFrontRegardless()
        return true
    }

    private func beginObservingIfNeeded() {
        guard !isObserving else { return }
        applicationNotifications.addObserver(
            self, selector: #selector(displayEnvironmentDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        for name in [
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification
        ] {
            workspaceNotifications.addObserver(
                self, selector: #selector(displayEnvironmentDidChange(_:)), name: name, object: nil
            )
        }
        isObserving = true
    }

    @objc private func displayEnvironmentDidChange(_ notification: Notification) {
        synchronizePrimaryDisplay()
    }

    deinit {
        applicationNotifications.removeObserver(self)
        workspaceNotifications.removeObserver(self)
    }
}
