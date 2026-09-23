import AppKit

/// 仅负责桌面层窗口的系统行为；内容由上层注入，不创建任何播放器。
@MainActor
final class DesktopWallpaperWindow: NSWindow {
    static let wallpaperLevel = NSWindow.Level(
        rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1
    )

    init(frame: NSRect, identifier: NSUserInterfaceItemIdentifier) {
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        self.identifier = identifier
        level = Self.wallpaperLevel
        collectionBehavior = [
            .canJoinAllSpaces, .stationary, .ignoresCycle,
            .fullScreenNone, .fullScreenDisallowsTiling
        ]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = false
        isMovable = false
        hidesOnDeactivate = false
        canHide = false
        isExcludedFromWindowsMenu = true
        isRestorable = false
        isReleasedWhenClosed = false
        tabbingMode = .disallowed
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // 桌面必须覆盖完整 frame，不能被 AppKit 收缩到排除了菜单栏/Dock 的 visibleFrame。
        frameRect
    }
}
