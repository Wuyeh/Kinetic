import AppKit
import ColorSync
import Combine

/// Module 16：系统显示器描述。CGDirectDisplayID 只用于当前连接，持久化用 ColorSync UUID。
struct DisplayDescriptor: Equatable, Identifiable {
    let id: DisplayID
    let name: String
    let desktop: DesktopDisplay
    /// 系统无法给出硬件身份时，只保留本次进程的 assignment，不能误恢复到陌生显示器。
    let isPersistent: Bool
}

@MainActor
final class DisplayRegistry: NSObject, ObservableObject {
    @Published private(set) var displays: [DisplayDescriptor] = []
    private let discover: @MainActor () -> [DisplayDescriptor]
    private let applicationNotifications: NotificationCenter
    private let workspaceNotifications: NotificationCenter
    private var observing = false

    init(discover: @escaping @MainActor () -> [DisplayDescriptor] = { DisplayRegistry.systemDisplays() },
         applicationNotifications: NotificationCenter = .default,
         workspaceNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.discover = discover
        self.applicationNotifications = applicationNotifications
        self.workspaceNotifications = workspaceNotifications
        super.init()
    }

    func start() {
        guard !observing else { return }
        observing = true
        applicationNotifications.addObserver(self, selector: #selector(environmentChanged(_:)),
                                             name: NSApplication.didChangeScreenParametersNotification, object: nil)
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            workspaceNotifications.addObserver(self, selector: #selector(environmentChanged(_:)), name: name, object: nil)
        }
        refresh()
    }

    func stop() {
        applicationNotifications.removeObserver(self)
        workspaceNotifications.removeObserver(self)
        observing = false
    }

    func refresh() {
        var seen = Set<DisplayID>()
        let next = discover().filter { $0.desktop.hasUsableFrame && seen.insert($0.id).inserted }
        if next != displays { displays = next }
    }

    func display(_ id: DisplayID) -> DisplayDescriptor? { displays.first { $0.id == id } }

    @objc private func environmentChanged(_ notification: Notification) { refresh() }

    static func systemDisplays() -> [DisplayDescriptor] {
        // NSScreen 的桌面列表不会给镜像的两个硬件输出建立重复覆盖窗口。
        NSScreen.screens.enumerated().compactMap { index, screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let directID = number.uint32Value
            let stableID: DisplayID
            let persistent: Bool
            if let uuid = CGDisplayCreateUUIDFromDisplayID(directID)?.takeRetainedValue(),
               let string = CFUUIDCreateString(nil, uuid) {
                stableID = DisplayID("display-" + (string as String).lowercased())
                persistent = true
            } else {
                // 临时 ID 不跨进程持久化，宁可保持原生壁纸，也不能把别的设备的壁纸误应用过来。
                stableID = DisplayID("session-display-\(directID)")
                persistent = false
            }
            let fallback = String(format: NSLocalizedString("displayPicker.fallback", comment: ""), index + 1)
            return DisplayDescriptor(id: stableID, name: screen.localizedName.isEmpty ? fallback : screen.localizedName,
                                     desktop: DesktopDisplay(id: directID, frame: screen.frame,
                                                             backingScaleFactor: screen.backingScaleFactor),
                                     isPersistent: persistent)
        }
    }

    deinit {
        applicationNotifications.removeObserver(self)
        workspaceNotifications.removeObserver(self)
    }
}
