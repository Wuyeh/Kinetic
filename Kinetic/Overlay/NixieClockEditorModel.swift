import AppKit
import Combine

/// Drafts never write storage. Only save() submits an explicit display assignment.
/// Shared by the window and the display page, whose preview draws and drags the clock (user, 2026-10-08):
/// the window has no preview of its own, and closing it keeps the draft.
@MainActor
final class NixieClockEditorModel: ObservableObject {
    @Published private(set) var selectedDisplayID: DisplayID?
    @Published var options = NixieClockOptions() { didSet { notice = nil } }
    @Published var isEnabled = false { didSet { notice = nil } }
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    let manager: OverlayManager
    let registry: DisplayRegistry
    private var base: OverlayConfiguration?
    private var isOpen = false
    private var subscription: AnyCancellable?

    init(manager: OverlayManager, registry: DisplayRegistry) {
        self.manager = manager; self.registry = registry
        subscription = manager.store.$configurations.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var connectedDisplays: [DisplayDescriptor] { registry.displays.filter(\.isPersistent) }
    var canSave: Bool {
        manager.isStarted && manager.store.loadError == nil && selectedDisplayID != nil
            && (connectedDisplays.contains { $0.id == selectedDisplayID } || (!isEnabled && base != nil))
    }
    var state: OverlayState? { manager.states.first { $0.id == base?.id } }
    var savedConfiguration: OverlayConfiguration? { base }
    /// The selected display's size in points.
    var displaySize: CGSize { selectedDisplayID.map(displaySize(on:)) ?? .init(width: 1_600, height: 1_000) }
    func displaySize(on display: DisplayID) -> CGSize {
        let size = connectedDisplays.first { $0.id == display }?.desktop.frame.size
        guard let size, size.width > 0, size.height > 0 else { return .init(width: 1_600, height: 1_000) }
        return size
    }

    func opened() {
        guard !isOpen else { return }; isOpen = true
        if selectedDisplayID == nil { selectDisplay(connectedDisplays.first?.id) }
    }
    func closed() { isOpen = false }
    func selectDisplay(_ id: DisplayID?) {
        selectedDisplayID = id; error = nil; notice = nil
        base = manager.store.configurations.first { $0.kind == .clock && $0.displayID == id }
        do { options = try base.map(NixieClockOptions.init(configuration:)) ?? .init(); isEnabled = base?.isEnabled ?? false }
        catch { options = .init(); self.error = error.localizedDescription; isEnabled = base?.isEnabled ?? false }
    }
    /// Preview drags arrive in display points.
    func move(by translation: CGSize) { options = options.moved(by: translation, in: displaySize) }
    /// A drag on a display page preview edits that display's draft (and targets the window there).
    func move(from start: NixieClockOptions, by translation: CGSize, on display: DisplayID) {
        if selectedDisplayID != display { selectDisplay(display) }
        options = start.moved(by: translation, in: displaySize(on: display))
    }
    func restoreDefaults() { options = .init(); error = nil; notice = nil }
    func save() {
        error = nil; notice = nil
        guard canSave, let id = selectedDisplayID else { error = OverlayError.targetUnavailable.localizedDescription; return }
        do {
            var value = base ?? OverlayConfiguration(kind: .clock, displayID: id, maximumFramesPerSecond: 1)
            value = try options.applying(to: value); value.isEnabled = isEnabled
            if connectedDisplays.contains(where: { $0.id == id }) { try manager.configure(value) }
            else { try manager.store.upsert(value) } // Explicitly disabling a disconnected target is safe.
            base = value
            notice = NSLocalizedString(isEnabled ? "clock.saved" : "clock.disabled", comment: "")
        } catch { self.error = error.localizedDescription }
    }
    func retry() { if let base { manager.retry(base.id) } }

    // MARK: Display page

    func saved(on display: DisplayID) -> (options: NixieClockOptions, isEnabled: Bool) {
        guard let value = manager.store.configurations.first(where: { $0.kind == .clock && $0.displayID == display }),
              let options = try? NixieClockOptions(configuration: value) else { return (.init(), false) }
        return (options, value.isEnabled)
    }
    func draft(on display: DisplayID) -> (options: NixieClockOptions, isEnabled: Bool) {
        selectedDisplayID == display ? (options, isEnabled) : saved(on: display)
    }
    func isDirty(on display: DisplayID) -> Bool {
        guard selectedDisplayID == display else { return false }
        let saved = saved(on: display); return saved.options != options || saved.isEnabled != isEnabled
    }
    func canApply(on display: DisplayID) -> Bool { isDirty(on: display) && canSave }
    func apply(on display: DisplayID) { if selectedDisplayID == display { save() } }
}
