import AppKit
import Combine

/// One shared editor for every display's widget layout (user, 2026-10-08). The 桌面组件 window, each display
/// page's preview and the desktop tiles edit the same per-display drafts. A draft reaches the desktop only when
/// it is applied (the window's save button or the display page's 应用); changes made on the desktop are saved at once.
@MainActor
final class WidgetBoardEditorModel: ObservableObject, WidgetDesktopEditing {
    struct Draft: Equatable { var layout = WidgetBoardLayout(); var isEnabled = false }
    /// System conditions for the display page previews.
    struct PreviewPolicy: Equatable { var isSuspended = false; var lowPowerMode = false; var reduceMotion = false }

    let manager: OverlayManager
    let repository: WidgetLayoutRepository
    let contents: WidgetContentRegistry
    private let registry: DisplayRegistry
    @Published private(set) var connectedDisplays: [DisplayDescriptor] = []
    @Published private(set) var selectedDisplayID: DisplayID?
    @Published private(set) var selectedWidgetID: UUID?
    /// Unapplied edits only; a display without an entry shows its saved layout.
    @Published private(set) var edits: [DisplayID: Draft] = [:]
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published private(set) var previewPolicy = PreviewPolicy()
    /// Failures of 应用 on a display page.
    @Published private(set) var applyErrors: [DisplayID: String] = [:]
    /// Opens the 桌面组件 window on a display with a widget selected; set by the app.
    var onEditRequest: ((DisplayID, UUID) -> Void)?
    static let fallbackCanvas = CGSize(width: 1_280, height: 800)
    private var openedEditor = false
    /// Saved revisions are immutable files; views read them on every update, so each is decoded once.
    private var savedLayouts: [UUID: WidgetBoardLayout] = [:]
    private var subscriptions = Set<AnyCancellable>()
    private var accessibilityObserver: NSObjectProtocol?
    private let readReduceMotion: @MainActor () -> Bool

    init(manager: OverlayManager, registry: DisplayRegistry, repository: WidgetLayoutRepository,
         contents: WidgetContentRegistry, monitor: SmartPauseMonitor? = nil,
         readReduceMotion: @escaping @MainActor () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        self.manager = manager; self.registry = registry; self.repository = repository; self.contents = contents; self.readReduceMotion = readReduceMotion
        previewPolicy.reduceMotion = readReduceMotion()
        registry.$displays.sink { [weak self] displays in
            guard let self else { return }; self.connectedDisplays = displays.filter(\.isPersistent)
            if self.selectedDisplayID == nil, self.openedEditor { self.selectDisplay(self.connectedDisplays.first?.id) }
        }.store(in: &subscriptions)
        manager.store.$configurations.sink { [weak self] configurations in
            guard let self else { return }
            let referenced = WidgetLayoutRepository.references(in: configurations)
            self.savedLayouts = self.savedLayouts.filter { referenced.contains($0.key) }
            self.objectWillChange.send()
        }.store(in: &subscriptions)
        if let monitor {
            monitor.$conditions.sink { [weak self] value in
                self?.previewPolicy.isSuspended = value.screenLocked || value.displayAsleep || value.systemAsleep || value.criticalMemory || value.criticalThermal
                self?.previewPolicy.lowPowerMode = value.lowPowerMode
            }.store(in: &subscriptions)
        }
        accessibilityObserver = NotificationCenter.default.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in guard let self else { return }; self.previewPolicy.reduceMotion = self.readReduceMotion() }
        }
    }

    // MARK: The 桌面组件 window: the display picked in its target picker.

    var layout: WidgetBoardLayout { selectedDisplayID.map { draft(on: $0).layout } ?? .init() }
    var isEnabled: Bool {
        get { selectedDisplayID.map { draft(on: $0).isEnabled } ?? false }
        set { guard let display = selectedDisplayID else { return }; update(display) { $0.isEnabled = newValue } }
    }
    var selectedWidget: WidgetConfiguration? { layout.widgets.first { $0.id == selectedWidgetID } }
    var canSave: Bool { selectedDisplayID.map(canSave(on:)) ?? false }
    var savedConfiguration: OverlayConfiguration? { selectedDisplayID.flatMap(base(on:)) }
    var state: OverlayState? { manager.states.first { $0.id == savedConfiguration?.id } }
    func opened() {
        guard !openedEditor else { return }; openedEditor = true
        if selectedDisplayID == nil { selectDisplay(connectedDisplays.first?.id) }
    }
    /// Closing the window keeps the drafts: they stay on the display pages until applied.
    func closed() { openedEditor = false }
    func selectDisplay(_ id: DisplayID?) {
        selectedDisplayID = id; notice = nil
        error = id.flatMap { saved(on: $0).failed ? WidgetBoardError.unreadableLayout.localizedDescription : nil }
        if let selected = selectedWidgetID, !layout.widgets.contains(where: { $0.id == selected }) { selectedWidgetID = nil }
    }
    func selectWidget(_ id: UUID?) { selectedWidgetID = id }
    func add(_ kind: WidgetKind) { if let display = selectedDisplayID { add(kind, on: display) } }
    func removeSelected() { if let display = selectedDisplayID, let id = selectedWidgetID { remove(id, on: display) } }
    func editSelected(_ edit: (inout WidgetConfiguration) -> Void) {
        if let display = selectedDisplayID, let id = selectedWidgetID { self.edit(id, on: display, edit) }
    }
    func save() {
        guard let display = selectedDisplayID else { error = OverlayError.targetUnavailable.localizedDescription; return }
        apply(on: display)
    }
    func importLayout(_ data: Data) {
        do {
            guard let display = selectedDisplayID, !saved(on: display).failed else { throw WidgetBoardError.unreadableLayout }
            var imported = try WidgetBoardLayout.decode(data)
            for index in imported.widgets.indices { imported.widgets[index].id = UUID() }
            update(display) { $0.layout = imported }; selectedWidgetID = nil; error = nil
            notice = NSLocalizedString("widgets.imported", comment: "")
        } catch { self.error = error.localizedDescription }
    }
    func exportLayout() throws -> Data { try layout.encoded() }
    func reportFileError() { error = WidgetBoardError.unreadableLayout.localizedDescription }
    func retry() { if let base = savedConfiguration { manager.retry(base.id) } }

    // MARK: Any display (window, display page preview, desktop).

    func canvasSize(on display: DisplayID) -> CGSize {
        connectedDisplays.first { $0.id == display }?.desktop.frame.size ?? Self.fallbackCanvas
    }
    func isConnected(_ display: DisplayID) -> Bool { connectedDisplays.contains { $0.id == display } }
    func base(on display: DisplayID) -> OverlayConfiguration? {
        manager.store.configurations.first { $0.kind == .widgets && $0.displayID == display }
    }
    func saved(on display: DisplayID) -> (draft: Draft, failed: Bool) {
        guard let base = base(on: display) else { return (.init(), false) }
        do {
            let id = try WidgetBoardReference(configuration: base).layoutID
            if let layout = savedLayouts[id] { return (Draft(layout: layout, isEnabled: base.isEnabled), false) }
            let layout = try repository.load(id); savedLayouts[id] = layout
            return (Draft(layout: layout, isEnabled: base.isEnabled), false)
        } catch { return (Draft(isEnabled: base.isEnabled), true) }
    }
    func draft(on display: DisplayID) -> Draft { edits[display] ?? saved(on: display).draft }
    func isDirty(on display: DisplayID) -> Bool { edits[display] != nil }
    func canSave(on display: DisplayID) -> Bool {
        manager.isStarted && manager.store.loadError == nil && !saved(on: display).failed
            && (isConnected(display) || (!draft(on: display).isEnabled && base(on: display) != nil))
    }
    func canApply(on display: DisplayID) -> Bool { isDirty(on: display) && canSave(on: display) }
    /// Room left for a small widget, so the add button can be disabled when the grid is full.
    func hasRoom(on display: DisplayID) -> Bool {
        WidgetGrid.firstFree(.small, in: draft(on: display).layout, canvas: canvasSize(on: display)) != nil
    }
    func previewContext(on display: DisplayID, visible: Bool) -> OverlayContext {
        OverlayContext(frame: .init(origin: .zero, size: canvasSize(on: display)), backingScaleFactor: 1,
            maximumFramesPerSecond: previewPolicy.lowPowerMode ? 15 : 30, allowsAnimation: !previewPolicy.reduceMotion,
            isPaused: !visible || previewPolicy.isSuspended || !isConnected(display))
    }

    func add(_ kind: WidgetKind, on display: DisplayID) {
        let current = draft(on: display).layout
        guard !saved(on: display).failed, current.widgets.count < WidgetBoardLayout.maximumWidgets else { return }
        guard let position = WidgetGrid.firstFree(.small, in: current, canvas: canvasSize(on: display)) else {
            notice = NSLocalizedString("widgets.full", comment: ""); return
        }
        var widget = WidgetConfiguration(kind: kind); widget.position = position
        update(display) { $0.layout.widgets.append(widget) }; selectedWidgetID = widget.id; notice = nil
    }
    func remove(_ id: UUID, on display: DisplayID) {
        update(display) { $0.layout.widgets.removeAll { $0.id == id } }
        if selectedWidgetID == id { selectedWidgetID = nil }; notice = nil
    }
    func edit(_ id: UUID, on display: DisplayID, _ change: (inout WidgetConfiguration) -> Void) {
        let current = draft(on: display).layout
        guard let index = current.widgets.firstIndex(where: { $0.id == id }) else { return }
        var widget = current.widgets[index]; change(&widget)
        do {
            widget = try widget.validated()
            var next = current; next.widgets[index] = widget
            if widget.size != current.widgets[index].size {
                next = try resized(id, in: current, to: widget.size, canvas: canvasSize(on: display))
                next.widgets[index] = { var value = widget; value.position = next.widgets[index].position; return value }()
            }
            update(display) { $0.layout = next }; notice = nil; error = nil
        } catch { self.error = error.localizedDescription }
    }
    /// A widget dragged on a display page preview lands on the nearest free cell (canvas points, top-left origin).
    func drop(_ id: UUID, at origin: CGPoint, on display: DisplayID) {
        let current = draft(on: display).layout, canvas = canvasSize(on: display)
        guard let cell = WidgetGrid.dropCell(for: id, at: origin, in: current, canvas: canvas) else { return }
        update(display) { $0.layout = WidgetGrid.placing(id, at: cell, in: current, canvas: canvas) }
        selectedWidgetID = id; notice = nil
    }
    func apply(on display: DisplayID) {
        guard canSave(on: display) else {
            error = OverlayError.targetUnavailable.localizedDescription; applyErrors[display] = error; return
        }
        do {
            try commit(draft(on: display), on: display); edits[display] = nil; applyErrors[display] = nil
            error = nil; notice = NSLocalizedString("widgets.saved", comment: "")
        } catch {
            self.error = (error as? WidgetBoardError)?.localizedDescription ?? OverlayError.settingsUnreadable.localizedDescription; notice = nil
            applyErrors[display] = self.error
        }
    }

    // MARK: Desktop tiles: saved immediately; an unapplied draft for the display gets the same change.

    func desktopWidget(_ id: UUID, movedTo cell: WidgetGrid.Cell, on display: DisplayID) {
        let canvas = canvasSize(on: display)
        changeDesktop(display) { layout in
            guard let metrics = WidgetGrid.Metrics(canvas: canvas), let widget = layout.widgets.first(where: { $0.id == id }),
                  let free = WidgetGrid.dropCell(for: id, at: metrics.frame(cell, widget.size).origin, in: layout, canvas: canvas) else { return layout }
            return WidgetGrid.placing(id, at: free, in: layout, canvas: canvas)
        }
    }
    func desktopWidget(_ id: UUID, resizedTo size: WidgetSize, on display: DisplayID) {
        let canvas = canvasSize(on: display)
        changeDesktop(display) { layout in
            guard let index = layout.widgets.firstIndex(where: { $0.id == id }),
                  var next = try? resized(id, in: layout, to: size, canvas: canvas) else { return layout }
            next.widgets[index].size = size; return next
        }
    }
    func desktopWidgetRemoved(_ id: UUID, on display: DisplayID) {
        changeDesktop(display) { layout in var next = layout; next.widgets.removeAll { $0.id == id }; return next }
        if selectedWidgetID == id { selectedWidgetID = nil }
    }
    func desktopWidgetEdit(_ id: UUID, on display: DisplayID) { onEditRequest?(display, id) }

    // MARK: -

    private func changeDesktop(_ display: DisplayID, _ change: (WidgetBoardLayout) -> WidgetBoardLayout) {
        let saved = saved(on: display)
        guard !saved.failed, canSave(on: display) else { return }
        var next = saved.draft; next.layout = change(saved.draft.layout)
        guard next != saved.draft else { return }
        let pending = edits[display]
        do { try commit(next, on: display) } catch {
            self.error = (error as? WidgetBoardError)?.localizedDescription ?? OverlayError.settingsUnreadable.localizedDescription; return
        }
        if var pending {
            pending.layout = change(pending.layout)
            let normalized = WidgetGrid.normalized(pending.layout, in: canvasSize(on: display))
            edits[display] = Draft(layout: normalized, isEnabled: pending.isEnabled) == next ? nil : Draft(layout: normalized, isEnabled: pending.isEnabled)
        }
    }
    /// The layout with `id` at `size`, on the nearest free cells to where it is now.
    private func resized(_ id: UUID, in layout: WidgetBoardLayout, to size: WidgetSize, canvas: CGSize) throws -> WidgetBoardLayout {
        guard let metrics = WidgetGrid.Metrics(canvas: canvas), let index = layout.widgets.firstIndex(where: { $0.id == id }) else {
            throw WidgetBoardError.noRoom
        }
        let normalized = WidgetGrid.normalized(layout, in: canvas)
        let current = metrics.desiredCell(normalized.widgets[index].position, normalized.widgets[index].size)
        guard let cell = metrics.nearestFree(to: current, size, occupied: WidgetGrid.occupied(normalized.widgets, in: metrics, excluding: id)) else {
            throw WidgetBoardError.noRoom
        }
        var next = normalized; next.widgets[index].size = size
        return WidgetGrid.placing(id, at: cell, in: next, canvas: canvas)
    }
    /// Stores an edit as the display's draft, on grid cells; a draft equal to the saved one is dropped.
    private func update(_ display: DisplayID, _ change: (inout Draft) -> Void) {
        let saved = saved(on: display)
        guard !saved.failed else { error = WidgetBoardError.unreadableLayout.localizedDescription; return }
        var next = draft(on: display); change(&next)
        next.layout = WidgetGrid.normalized(next.layout, in: canvasSize(on: display))
        edits[display] = next == saved.draft ? nil : next
    }
    private func commit(_ draft: Draft, on display: DisplayID) throws {
        var revision: UUID?
        do {
            let id = try repository.write(draft.layout, keeping: WidgetLayoutRepository.references(in: manager.store.configurations)); revision = id
            var configuration = base(on: display) ?? .init(kind: .widgets, displayID: display)
            configuration = try WidgetBoardReference.applying(id, to: configuration); configuration.isEnabled = draft.isEnabled
            if isConnected(display) { try manager.configure(configuration) } else { try manager.store.upsert(configuration) }
            revision = nil
            repository.prune(keeping: WidgetLayoutRepository.references(in: manager.store.configurations))
        } catch {
            if let revision { repository.discard(revision) }
            throw error
        }
    }
    deinit {
        if let accessibilityObserver { NotificationCenter.default.removeObserver(accessibilityObserver) }
    }
}
