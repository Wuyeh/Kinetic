import AppKit

/// Changes made directly on the desktop. The editor saves each one at once, like Apple's desktop widgets.
@MainActor
protocol WidgetDesktopEditing: AnyObject {
    func desktopWidget(_ id: UUID, movedTo cell: WidgetGrid.Cell, on display: DisplayID)
    func desktopWidget(_ id: UUID, resizedTo size: WidgetSize, on display: DisplayID)
    func desktopWidgetRemoved(_ id: UUID, on display: DisplayID)
    func desktopWidgetEdit(_ id: UUID, on display: DisplayID)
}

/// Desktop tiles sit just above Finder's desktop icons so they can be dragged and right-clicked (user, 2026-10-08).
/// Each tile has its own small window, so clicks anywhere else still reach the desktop and its icons.
@MainActor
final class WidgetDesktopTiles {
    static let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
    static let identifierPrefix = "Kinetic.DesktopWidget."
    let displayID: DisplayID
    weak var editor: WidgetDesktopEditing?
    /// Where a tile dropped at a canvas origin lands, from the overlay's current layout.
    var dropCell: (UUID, CGPoint) -> WidgetGrid.Cell? = { _, _ in nil }
    var cellFrame: (UUID, WidgetGrid.Cell) -> CGRect? = { _, _ in nil }
    private var panels: [UUID: WidgetDesktopPanel] = [:]
    private var sizes: [UUID: WidgetSize] = [:]
    private var displayFrame: CGRect = .zero

    init(displayID: DisplayID, editor: WidgetDesktopEditing?) { self.displayID = displayID; self.editor = editor }

    var panelIDs: Set<UUID> { Set(panels.keys) }
    func panel(_ id: UUID) -> NSWindow? { panels[id] }

    func setDisplayFrame(_ frame: CGRect) { displayFrame = frame }
    /// `frame` is in canvas points (top-left origin); nil hides a tile that has no free room.
    func place(_ id: UUID, host: NSView, size: WidgetSize, frame: CGRect?) {
        sizes[id] = size
        let panel = panels[id] ?? makePanel(id)
        if panel.tile.host !== host { panel.tile.embed(host) }
        guard let frame, !panel.tile.isDragging else { if frame == nil { panel.orderOut(nil) }; return }
        // A snap animation already heading to this frame keeps running.
        let target = global(frame)
        if panel.placedFrame != target { panel.placedFrame = target; panel.setFrame(target, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }
    func remove(_ id: UUID) { sizes[id] = nil; panels.removeValue(forKey: id).map(close) }
    func close() { panels.values.forEach(close); panels = [:]; sizes = [:] }

    private func makePanel(_ id: UUID) -> WidgetDesktopPanel {
        let panel = WidgetDesktopPanel(identifier: Self.identifierPrefix + id.uuidString)
        panel.tile.onDragEnded = { [weak self, weak panel] start in
            guard let self, let panel else { return }; self.dropped(id, panel: panel, start: start)
        }
        panel.tile.makeMenu = { [weak self] in self?.menu(for: id) }
        panels[id] = panel
        return panel
    }
    private func close(_ panel: WidgetDesktopPanel) {
        panel.tile.onDragEnded = nil; panel.tile.makeMenu = nil; panel.orderOut(nil); panel.contentView = nil; panel.close()
    }
    private func global(_ frame: CGRect) -> CGRect {
        CGRect(x: displayFrame.minX + frame.minX, y: displayFrame.maxY - frame.maxY, width: frame.width, height: frame.height)
    }
    private func dropped(_ id: UUID, panel: WidgetDesktopPanel, start: CGRect) {
        let origin = CGPoint(x: panel.frame.minX - displayFrame.minX, y: displayFrame.maxY - panel.frame.maxY)
        guard let cell = dropCell(id, origin), let target = cellFrame(id, cell) else { animate(panel, to: start); return }
        animate(panel, to: global(target))
        if global(target) != start { editor?.desktopWidget(id, movedTo: cell, on: displayID) }
    }
    private func animate(_ panel: WidgetDesktopPanel, to frame: CGRect) {
        panel.placedFrame = frame
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18; context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        }
    }
    private func menu(for id: UUID) -> NSMenu {
        let menu = NSMenu()
        for size in WidgetSize.allCases {
            let item = WidgetMenuItem(title: size.title) { [weak self] in
                guard let self else { return }; self.editor?.desktopWidget(id, resizedTo: size, on: self.displayID)
            }
            item.state = sizes[id] == size ? .on : .off; menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(WidgetMenuItem(title: NSLocalizedString("widgets.menu.edit", comment: "")) { [weak self] in
            guard let self else { return }; self.editor?.desktopWidgetEdit(id, on: self.displayID)
        })
        menu.addItem(WidgetMenuItem(title: NSLocalizedString("widgets.remove", comment: "")) { [weak self] in
            guard let self else { return }; self.editor?.desktopWidgetRemoved(id, on: self.displayID)
        })
        return menu
    }
}

@MainActor
final class WidgetMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: ""); target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func run() { handler() }
}

/// A borderless, non-activating window the size of one tile. Interacting with it never activates Kinetic.
@MainActor
final class WidgetDesktopPanel: NSPanel {
    let tile = WidgetDesktopTileView(frame: .zero)
    var placedFrame: CGRect?
    init(identifier: String) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.identifier = .init(identifier)
        level = WidgetDesktopTiles.level
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone, .fullScreenDisallowsTiling]
        backgroundColor = .clear; isOpaque = false; hasShadow = false
        isMovable = false; hidesOnDeactivate = false; canHide = false; isExcludedFromWindowsMenu = true
        isRestorable = false; isReleasedWhenClosed = false; tabbingMode = .disallowed; animationBehavior = .none
        becomesKeyOnlyIfNeeded = true
        contentView = tile
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Takes every click on the tile: drag moves the window, release snaps it; right-click shows the menu.
@MainActor
final class WidgetDesktopTileView: NSView {
    private(set) weak var host: NSView?
    var onDragEnded: ((CGRect) -> Void)?
    var makeMenu: (() -> NSMenu?)?
    private var dragStart: (mouse: CGPoint, frame: CGRect)?
    private(set) var isDragging = false

    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true; layer?.backgroundColor = NSColor.clear.cgColor
    }
    required init?(coder: NSCoder) { nil }
    override var isOpaque: Bool { false }
    func embed(_ view: NSView) {
        host?.removeFromSuperview(); host = view
        view.frame = bounds; view.autoresizingMask = [.width, .height]; addSubview(view)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { showMenu(event); return }
        guard let window else { return }
        dragStart = (NSEvent.mouseLocation, window.frame); isDragging = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let window, let start = dragStart else { return }
        let mouse = NSEvent.mouseLocation, dx = mouse.x - start.mouse.x, dy = mouse.y - start.mouse.y
        if !isDragging, dx * dx + dy * dy < 9 { return }
        if !isDragging { isDragging = true; window.orderFrontRegardless() }
        var origin = CGPoint(x: start.frame.minX + dx, y: start.frame.minY + dy)
        if let screen = window.screen ?? NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            origin.x = max(screen.frame.minX, min(screen.frame.maxX - start.frame.width, origin.x))
            origin.y = max(screen.frame.minY, min(screen.frame.maxY - start.frame.height, origin.y))
        }
        window.setFrameOrigin(origin)
    }
    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil; isDragging = false }
        guard isDragging, let start = dragStart else { return }
        isDragging = false; onDragEnded?(start.frame)
    }
    override func rightMouseDown(with event: NSEvent) { showMenu(event) }
    private func showMenu(_ event: NSEvent) {
        guard let menu = makeMenu?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}
