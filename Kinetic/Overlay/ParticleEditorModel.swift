import AppKit
import Combine

/// Drafts never write storage. Only save() submits an explicit display assignment.
/// Shared by the window and the display page, whose preview draws the draft (user, 2026-10-08): the window
/// has no preview of its own, and closing it keeps the draft until it is applied or another display is picked.
@MainActor
final class ParticleEditorModel: ObservableObject {
    /// System conditions for the display page preview.
    struct PreviewPolicy: Equatable { var isSuspended = false; var lowPowerMode = false; var reduceMotion = false }
    @Published private(set) var selectedDisplayID: DisplayID?
    @Published var options = ParticleOptions() { didSet { notice = nil } }
    @Published var isEnabled = false { didSet { notice = nil } }
    @Published private(set) var previewPolicy = PreviewPolicy()
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    let manager: OverlayManager
    let registry: DisplayRegistry
    private let readReduceMotion: @MainActor () -> Bool
    private var subscriptions = Set<AnyCancellable>()
    private var accessibilityObserver: NSObjectProtocol?
    private var base: OverlayConfiguration?
    private var isOpen = false

    init(manager: OverlayManager, registry: DisplayRegistry, monitor: SmartPauseMonitor? = nil,
         readReduceMotion: @escaping @MainActor () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        self.manager = manager; self.registry = registry; self.readReduceMotion = readReduceMotion
        previewPolicy.reduceMotion = readReduceMotion()
        if let monitor {
            previewPolicy.isSuspended = Self.suspended(monitor.conditions)
            previewPolicy.lowPowerMode = monitor.conditions.lowPowerMode
            monitor.$conditions.sink { [weak self] conditions in
                self?.previewPolicy.isSuspended = Self.suspended(conditions)
                self?.previewPolicy.lowPowerMode = conditions.lowPowerMode
            }.store(in: &subscriptions)
        }
        manager.store.$configurations.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        accessibilityObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in guard let self else { return }; self.previewPolicy.reduceMotion = self.readReduceMotion() }
            }
    }
    private static func suspended(_ value: SmartPauseConditions) -> Bool {
        value.screenLocked || value.displayAsleep || value.systemAsleep || value.criticalThermal || value.criticalMemory
    }
    var connectedDisplays: [DisplayDescriptor] { registry.displays.filter(\.isPersistent) }
    var canSave: Bool {
        manager.isStarted && manager.store.loadError == nil && selectedDisplayID != nil
            && (connectedDisplays.contains { $0.id == selectedDisplayID } || (!isEnabled && base != nil))
    }
    var state: OverlayState? { manager.states.first { $0.id == base?.id } }
    var savedConfiguration: OverlayConfiguration? { base }

    func opened() {
        guard !isOpen else { return }; isOpen = true
        if selectedDisplayID == nil { selectDisplay(connectedDisplays.first?.id) }
    }
    func closed() { isOpen = false }
    func selectDisplay(_ id: DisplayID?) {
        selectedDisplayID = id; error = nil; notice = nil
        base = manager.store.configurations.first { $0.kind == .particles && $0.displayID == id }
        do { options = try base.map(ParticleOptions.init(configuration:)) ?? .init(); isEnabled = base?.isEnabled ?? false }
        catch { options = .init(); self.error = error.localizedDescription; isEnabled = base?.isEnabled ?? false }
    }
    func restoreDefaults() { options = .init(); error = nil; notice = nil }
    func save() {
        error = nil; notice = nil
        guard canSave, let id = selectedDisplayID else { error = OverlayError.targetUnavailable.localizedDescription; return }
        do {
            var value = base ?? OverlayConfiguration(kind: .particles, displayID: id)
            value = try options.applying(to: value); value.isEnabled = isEnabled
            if connectedDisplays.contains(where: { $0.id == id }) { try manager.configure(value) }
            else { try manager.store.upsert(value) } // Explicitly disabling a disconnected target is safe.
            base = value
            notice = NSLocalizedString(isEnabled ? "particles.saved" : "particles.disabled", comment: "")
        } catch { self.error = error.localizedDescription }
    }
    func retry() { if let base { manager.retry(base.id) } }

    // MARK: Display page

    /// What the display's desktop shows now; an unreadable saved effect counts as off.
    func saved(on display: DisplayID) -> (options: ParticleOptions, isEnabled: Bool) {
        guard let value = manager.store.configurations.first(where: { $0.kind == .particles && $0.displayID == display }),
              let options = try? ParticleOptions(configuration: value) else { return (.init(), false) }
        return (options, value.isEnabled)
    }
    /// The window's draft for its display; any other display shows what is saved.
    func draft(on display: DisplayID) -> (options: ParticleOptions, isEnabled: Bool) {
        selectedDisplayID == display ? (options, isEnabled) : saved(on: display)
    }
    func isDirty(on display: DisplayID) -> Bool {
        guard selectedDisplayID == display else { return false }
        let saved = saved(on: display); return saved.options != options || saved.isEnabled != isEnabled
    }
    func canApply(on display: DisplayID) -> Bool { isDirty(on: display) && canSave }
    func apply(on display: DisplayID) { if selectedDisplayID == display { save() } }
    func previewContext(size: CGSize, visible: Bool) -> OverlayContext {
        OverlayContext(frame: .init(origin: .zero, size: size), backingScaleFactor: 2,
            maximumFramesPerSecond: previewPolicy.lowPowerMode ? 15 : 30, allowsAnimation: !previewPolicy.reduceMotion,
            isPaused: !visible || previewPolicy.isSuspended)
    }
    deinit {
        if let accessibilityObserver { NotificationCenter.default.removeObserver(accessibilityObserver) }
    }
}
