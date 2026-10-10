import AppKit

/// One transparent, click-through surface per assigned display, separate from wallpaper windows.
@MainActor
final class OverlayWindowOwner: OverlaySurface {
    static let identifierPrefix = "Kinetic.DesktopOverlay."
    /// Same level as the wallpaper and Finder's icons (kept on screen in Edit Widgets mode, 2026-10-09);
    /// ordered between them by `DesktopLayerOrdering`.
    static let overlayLevel = DesktopLayerOrdering.level
    let displayID: DisplayID
    private(set) var window: NSWindow?
    private let stage = OverlayStage(frame: .zero)
    private var views: [UUID: NSView] = [:]
    init(displayID: DisplayID) { self.displayID = displayID }

    func present(_ view: NSView, for id: UUID, display: DesktopDisplay) throws {
        guard display.hasUsableFrame, Self.overlayLevel == DesktopWallpaperWindow.wallpaperLevel,
              Self.overlayLevel.rawValue < NSWindow.Level.normal.rawValue else { throw OverlayError.invalidWindowLevel }
        if window == nil {
            let window = OverlayWindow(frame: display.frame, displayID: displayID)
            window.contentView = stage; self.window = window
        }
        realign(display)
        view.frame = stage.bounds; view.autoresizingMask = [.width, .height]
        let old = views.updateValue(view, forKey: id)
        stage.addSubview(view)
        if old !== view { old?.removeFromSuperview() }
        if let window { DesktopLayerOrdering.placeOverlay(window, on: display.frame) }
    }
    func remove(_ id: UUID) {
        views.removeValue(forKey: id)?.removeFromSuperview()
        if views.isEmpty { close() }
    }
    func realign(_ display: DesktopDisplay) {
        guard display.hasUsableFrame else { return }
        window?.setFrame(display.frame, display: true)
        stage.frame = NSRect(origin: .zero, size: display.frame.size)
        for view in views.values { view.frame = stage.bounds }
    }
    func setOrder(_ ids: [UUID]) {
        for id in ids { if let view = views[id] { stage.addSubview(view, positioned: .above, relativeTo: nil) } }
    }
    func close() {
        views.values.forEach { $0.removeFromSuperview() }; views.removeAll()
        window?.orderOut(nil); window?.contentView = nil; window?.close(); window = nil
    }
    static func closeOrphanedWindows(in windows: [NSWindow]) {
        for window in windows where window is OverlayWindow && window.identifier?.rawValue.hasPrefix(identifierPrefix) == true {
            window.orderOut(nil); window.contentView = nil; window.close()
        }
    }
}

@MainActor
private final class OverlayStage: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor; layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { nil }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
private final class OverlayWindow: NSWindow {
    init(frame: NSRect, displayID: DisplayID) {
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        identifier = .init(OverlayWindowOwner.identifierPrefix + displayID.rawValue)
        level = OverlayWindowOwner.overlayLevel
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone, .fullScreenDisallowsTiling]
        backgroundColor = .clear; isOpaque = false; hasShadow = false
        ignoresMouseEvents = true; acceptsMouseMovedEvents = false; isMovable = false
        hidesOnDeactivate = false; canHide = false; isExcludedFromWindowsMenu = true
        isRestorable = false; isReleasedWhenClosed = false; tabbingMode = .disallowed; animationBehavior = .none
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
