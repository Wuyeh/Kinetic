import AppKit
import Combine

/// Owns only overlays. No Wallpaper Runtime / Renderer / Library reference or playback commands.
@MainActor
final class OverlayManager: ObservableObject {
    typealias Factory = @MainActor (OverlayConfiguration) throws -> any DesktopOverlay
    typealias SurfaceFactory = @MainActor (DisplayID) -> any OverlaySurface
    @Published private(set) var states: [OverlayState] = []
    let store: OverlayStore
    private let registry: DisplayRegistry
    private let makeSurface: SurfaceFactory
    private let readReduceMotion: @MainActor () -> Bool
    private let timeoutNanoseconds: UInt64
    private var factories: [OverlayKind: Factory] = [:]
    private var configurations: [OverlayConfiguration] = []
    private var displays: [DisplayID: DesktopDisplay] = [:]
    private var persistentDisplays = Set<DisplayID>()
    private var slots: [UUID: Slot] = [:]
    private var surfaces: [DisplayID: any OverlaySurface] = [:]
    private var subscriptions = Set<AnyCancellable>()
    private var accessibilityObserver: NSObjectProtocol?
    private var globalPolicy = OverlayPerformancePolicy()
    private var suspendedDisplays = Set<DisplayID>()
    private(set) var isStarted = false

    private final class Slot {
        let id: UUID
        var configuration: OverlayConfiguration
        var applied: OverlayConfiguration?
        var active: (any DesktopOverlay)?
        var pending: (any DesktopOverlay)?
        var preparation: Task<Void, Never>?
        var timeout: Task<Void, Never>?
        var token = UUID()
        var state: OverlayState
        init(_ configuration: OverlayConfiguration) {
            id = configuration.id; self.configuration = configuration
            state = .init(id: configuration.id, displayID: configuration.displayID, kind: configuration.kind, lifecycle: .disabled)
        }
    }

    init(store: OverlayStore, registry: DisplayRegistry,
         preparationTimeoutNanoseconds: UInt64 = 12_000_000_000,
         readReduceMotion: @escaping @MainActor () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
         makeSurface: @escaping SurfaceFactory = { OverlayWindowOwner(displayID: $0) }) {
        self.store = store; self.registry = registry; self.makeSurface = makeSurface
        self.readReduceMotion = readReduceMotion; timeoutNanoseconds = preparationTimeoutNanoseconds
    }

    /// Future modules register their isolated content implementations; none are registered in 33.
    func register(_ kind: OverlayKind, factory: @escaping Factory) {
        factories[kind] = factory
        if isStarted { reconcile() }
    }
    func start(monitor: SmartPauseMonitor? = nil) {
        guard !isStarted else { return }; isStarted = true
        globalPolicy.reduceMotion = readReduceMotion()
        if let monitor {
            globalPolicy.isSuspended = !monitor.globalReasons.isEmpty || Self.requiresSafetyPause(monitor.conditions)
            globalPolicy.lowPowerMode = monitor.conditions.lowPowerMode
            suspendedDisplays = Set(monitor.displayReasons.filter { !$0.value.isEmpty }.map(\.key))
        }
        store.$configurations.sink { [weak self] value in
            self?.configurations = value; self?.reconcile()
        }.store(in: &subscriptions)
        registry.$displays.sink { [weak self] value in
            guard let self else { return }
            self.displays = Dictionary(uniqueKeysWithValues: value.map { ($0.id, $0.desktop) })
            self.persistentDisplays = Set(value.filter(\.isPersistent).map(\.id))
            self.reconcile()
        }.store(in: &subscriptions)
        if let monitor {
            monitor.$globalReasons.combineLatest(monitor.$displayReasons, monitor.$conditions)
                .sink { [weak self] global, local, conditions in
                    guard let self else { return }
                    // @Published delivers before assignment; use the supplied condition snapshot.
                    self.globalPolicy.isSuspended = !global.isEmpty || Self.requiresSafetyPause(conditions)
                    self.globalPolicy.lowPowerMode = conditions.lowPowerMode
                    self.suspendedDisplays = Set(local.filter { !$0.value.isEmpty }.map(\.key))
                    self.reconcile()
                }.store(in: &subscriptions)
        }
        accessibilityObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.isStarted else { return }
                    self.globalPolicy.reduceMotion = self.readReduceMotion(); self.reconcile()
                }
            }
    }
    /// Explicit target only. A disconnected or nonpersistent identity never falls back to main.
    func configure(_ configuration: OverlayConfiguration) throws {
        guard isStarted, displays[configuration.displayID] != nil,
              persistentDisplays.contains(configuration.displayID) else { throw OverlayError.targetUnavailable }
        try store.upsert(configuration)
    }
    func setPolicy(_ policy: OverlayPerformancePolicy, suspendedDisplays: Set<DisplayID> = []) {
        globalPolicy = policy; self.suspendedDisplays = suspendedDisplays
        if isStarted { reconcile() }
    }
    func retry(_ id: UUID) {
        guard let slot = slots[id], slot.state.lifecycle == .failed else { return }
        slot.state.failure = nil; slot.state.lifecycle = .disabled; reconcile()
    }
    func shutdown() {
        guard isStarted else { return }; isStarted = false
        subscriptions.removeAll()
        if let accessibilityObserver { NotificationCenter.default.removeObserver(accessibilityObserver) }
        accessibilityObserver = nil
        for slot in slots.values { release(slot) }
        surfaces.values.forEach { $0.close() }; surfaces.removeAll(); slots.removeAll(); states = []
        // Registry / system monitor are borrowed. Wallpaper owns their start / stop.
    }

    private func context(for configuration: OverlayConfiguration, display: DesktopDisplay) -> OverlayContext {
        var policy = globalPolicy
        policy.isSuspended = policy.isSuspended || suspendedDisplays.contains(configuration.displayID)
        return policy.context(for: configuration, display: display)
    }
    private static func requiresSafetyPause(_ conditions: SmartPauseConditions) -> Bool {
        conditions.screenLocked || conditions.displayAsleep || conditions.systemAsleep
            || conditions.criticalThermal || conditions.criticalMemory
    }
    private func reconcile() {
        guard isStarted else { return }
        let desired = Set(configurations.map(\.id))
        for id in Array(slots.keys) where !desired.contains(id) {
            if let slot = slots.removeValue(forKey: id) { release(slot) }
        }
        for configuration in configurations {
            let slot = slots[configuration.id] ?? Slot(configuration); slots[configuration.id] = slot
            if slot.configuration != configuration {
                let old = slot.configuration
                cancelPreparation(slot)
                if old.displayID != configuration.displayID || old.kind != configuration.kind { releaseActive(slot) }
                slot.configuration = configuration
                slot.state = .init(id: slot.id, displayID: configuration.displayID, kind: configuration.kind, lifecycle: .disabled)
            }
            guard configuration.isEnabled else {
                release(slot); slot.state.lifecycle = .disabled; slot.state.failure = nil; continue
            }
            guard let display = displays[configuration.displayID] else {
                release(slot); slot.state.lifecycle = .waitingForDisplay; slot.state.failure = nil; continue
            }
            guard let factory = factories[configuration.kind] else {
                release(slot); slot.state.lifecycle = .unavailable; slot.state.failure = nil; continue
            }
            if let active = slot.active {
                let context = context(for: configuration, display: display)
                // Safety suspension precedes a fallible edit; invalid parameters cannot keep ticking.
                if context.isPaused { active.pause() }
                guard slot.active === active else { continue }
                do {
                    try active.update(configuration: configuration, context: context)
                    guard slot.active === active else { continue }
                    surfaces[configuration.displayID]?.realign(display)
                    slot.applied = configuration
                    slot.state.lifecycle = context.isPaused ? .paused : .running; slot.state.failure = nil
                    if !context.isPaused { active.play() }
                } catch {
                    // Failed edits retain the existing overlay; never touch wallpaper resources.
                    slot.state.lifecycle = .failed; slot.state.failure = error.localizedDescription
                }
            } else if slot.pending == nil, slot.state.lifecycle != .failed {
                prepare(slot, factory: factory, display: display)
            }
        }
        for (id, surface) in surfaces {
            surface.setOrder(configurations.filter { $0.displayID == id && slots[$0.id]?.active != nil }.map(\.id))
        }
        publish()
    }
    private func prepare(_ slot: Slot, factory: Factory, display: DesktopDisplay) {
        let candidate: any DesktopOverlay
        do { candidate = try factory(slot.configuration) }
        catch { slot.state.lifecycle = .failed; slot.state.failure = error.localizedDescription; return }
        let configuration = slot.configuration, token = UUID(); slot.token = token
        slot.pending = candidate; slot.state.lifecycle = .preparing; slot.state.failure = nil
        let initialContext = context(for: configuration, display: display)
        candidate.onFailure = { [weak self, weak slot, weak candidate] error in
            guard let self, let slot, let candidate, self.isStarted,
                  slot.pending === candidate || slot.active === candidate else { return }
            self.fail(slot, error: error)
        }
        let timeoutNanoseconds = self.timeoutNanoseconds
        slot.timeout = Task { @MainActor [weak self, weak slot] in
            do { try await Task.sleep(nanoseconds: timeoutNanoseconds) } catch { return }
            guard let self, let slot, self.isStarted, slot.token == token, slot.pending != nil else { return }
            self.fail(slot, error: OverlayError.preparationTimedOut)
        }
        slot.preparation = Task { @MainActor [weak self, weak slot] in
            do {
                try await candidate.prepare(configuration: configuration, context: initialContext)
                try Task.checkCancellation()
                guard let self, let slot, self.isStarted, slot.token == token,
                      slot.pending === candidate, let display = self.displays[configuration.displayID] else { candidate.dispose(); return }
                let context = self.context(for: slot.configuration, display: display)
                try candidate.update(configuration: slot.configuration, context: context)
                try Task.checkCancellation()
                guard slot.token == token, slot.pending === candidate else { return }
                let surface = self.surfaces[configuration.displayID] ?? self.makeSurface(configuration.displayID)
                do { try surface.present(candidate.displayView, for: slot.id, display: display) }
                catch { if self.surfaces[configuration.displayID] == nil { surface.close() }; throw error }
                guard slot.token == token, slot.pending === candidate else {
                    surface.remove(slot.id)
                    if self.surfaces[configuration.displayID] == nil { surface.close() }
                    return
                }
                self.surfaces[configuration.displayID] = surface
                slot.timeout?.cancel(); slot.timeout = nil; slot.preparation = nil
                slot.pending = nil; slot.active = candidate; slot.applied = slot.configuration
                slot.state.lifecycle = context.isPaused ? .paused : .running
                if context.isPaused { candidate.pause() } else { candidate.play() }
                surface.setOrder(self.configurations.filter { $0.displayID == configuration.displayID && self.slots[$0.id]?.active != nil }.map(\.id))
                self.publish()
            } catch {
                candidate.dispose()
                guard let self, let slot, self.isStarted, slot.token == token else { return }
                self.fail(slot, error: error)
            }
        }
    }
    private func fail(_ slot: Slot, error: Error) {
        release(slot); slot.state.lifecycle = .failed; slot.state.failure = error.localizedDescription; publish()
    }
    private func cancelPreparation(_ slot: Slot) {
        slot.token = UUID(); slot.timeout?.cancel(); slot.timeout = nil
        slot.preparation?.cancel(); slot.preparation = nil
        slot.pending?.onFailure = nil; slot.pending?.dispose(); slot.pending = nil
    }
    private func releaseActive(_ slot: Slot) {
        let active = slot.active
        active?.onFailure = nil; slot.active = nil; slot.applied = nil
        let displayID = slot.configuration.displayID
        surfaces[displayID]?.remove(slot.id)
        active?.dispose()
        if !slots.values.contains(where: { $0 !== slot && $0.configuration.displayID == displayID && $0.active != nil }) {
            surfaces.removeValue(forKey: displayID)?.close()
        }
    }
    private func release(_ slot: Slot) { cancelPreparation(slot); releaseActive(slot) }
    private func publish() { states = configurations.compactMap { slots[$0.id]?.state } }
    deinit {
        if let accessibilityObserver { NotificationCenter.default.removeObserver(accessibilityObserver) }
        for slot in slots.values { slot.preparation?.cancel(); slot.timeout?.cancel() }
        let effects = slots.values.flatMap { [$0.active, $0.pending].compactMap { $0 } }
        let ownedSurfaces = Array(surfaces.values)
        // A caller that drops the manager without explicit shutdown must not leave desktop windows.
        Task { @MainActor in
            effects.forEach { $0.onFailure = nil }
            ownedSurfaces.forEach { $0.close() }
            effects.forEach { $0.dispose() }
        }
    }
}
