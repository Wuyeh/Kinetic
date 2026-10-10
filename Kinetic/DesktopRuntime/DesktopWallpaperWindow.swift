import AppKit

/// 仅负责桌面层窗口的系统行为；内容由上层注入，不创建任何播放器。
@MainActor
final class DesktopWallpaperWindow: NSWindow {
    /// 与 Finder 桌面图标窗口同一层，排在该层最后面（图标之下）。用户 2026-10-09 反馈：打开“编辑小组件”时
    /// 系统会把除这一层以外的桌面级窗口全部藏起，原来的 desktop + 1 因此在编辑期间消失（实测见
    /// EDIT_WIDGETS_WALLPAPER_QA.md）。同层内的先后由 `DesktopLayerOrdering` 维持：壁纸 < 叠加层 < 图标。
    static let wallpaperLevel = DesktopLayerOrdering.level

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

/// Kinetic's desktop windows share Finder's desktop-icon level, the only desktop level macOS keeps on screen
/// in Edit Widgets mode. Within that level the wallpaper stays at the back and overlays go directly under
/// Finder's icon window on their display, so icons always draw on top. Reads only window-list metadata
/// (owner, level, bounds): no Screen Recording or Accessibility permission.
@MainActor
enum DesktopLayerOrdering {
    static let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)))

    /// Wallpaper: back of the level, behind Finder's icons and any overlay.
    static func placeWallpaper(_ window: NSWindow) { window.orderBack(nil) }
    /// Overlay: just under Finder's icon window on the same display; with no desktop icons, front of the level.
    static func placeOverlay(_ window: NSWindow, on frame: CGRect) {
        if let icons = finderDesktopWindow(covering: frame) { window.order(.below, relativeTo: icons) }
        else { window.orderFrontRegardless() }
    }
    /// Finder's desktop window for a display frame in AppKit coordinates, if desktop icons are shown.
    static func finderDesktopWindow(covering frame: CGRect) -> Int? {
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let target = quartzFrame(frame)
        return list.first { window in
            guard (window[kCGWindowOwnerPID as String] as? Int32) == finder,
                  (window[kCGWindowLayer as String] as? Int) == level.rawValue,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
            return rect.intersects(target)
        }.flatMap { $0[kCGWindowNumber as String] as? Int }
    }
    /// AppKit's bottom-left origin to the window list's top-left origin of the primary display.
    static func quartzFrame(_ frame: CGRect) -> CGRect {
        let height = NSScreen.screens.first?.frame.height ?? CGDisplayBounds(CGMainDisplayID()).height
        return CGRect(x: frame.minX, y: height - frame.maxY, width: frame.width, height: frame.height)
    }
}
