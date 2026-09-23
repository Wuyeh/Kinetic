import AppKit

/// 当前系统主显示器的快照，不缓存 NSScreen，也不使用随键盘焦点变化的 NSScreen.main。
struct DesktopDisplay: Equatable {
    let id: CGDirectDisplayID
    let frame: NSRect
    let backingScaleFactor: CGFloat

    @MainActor
    static func primary() -> DesktopDisplay? {
        // Apple 定义 screens[0] 为系统主显示器；frame 是 AppKit 点坐标，包含菜单栏和 Dock 区域。
        guard let screen = NSScreen.screens.first,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }

        return DesktopDisplay(
            id: number.uint32Value,
            frame: screen.frame,
            backingScaleFactor: screen.backingScaleFactor
        )
    }

    var hasUsableFrame: Bool {
        !frame.isEmpty && frame.origin.x.isFinite && frame.origin.y.isFinite
            && frame.width.isFinite && frame.height.isFinite
    }
}
