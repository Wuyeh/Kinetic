import AppKit
import Combine

/// Display-specific drafts survive closing the editor; only explicit 保存 / 应用 writes the overlay store.
@MainActor final class MusicOverlayEditorModel: ObservableObject {
    struct Draft: Equatable { var options = MusicOverlayOptions(); var isEnabled = false }
    @Published private(set) var selectedDisplayID: DisplayID?
    @Published var options = MusicOverlayOptions() { didSet { remember() } }
    @Published var isEnabled = false { didSet { remember() } }
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    let manager: OverlayManager
    let registry: DisplayRegistry
    let service: MusicService
    private var drafts: [DisplayID: Draft] = [:]
    private var selecting = false
    private var subscriptions = Set<AnyCancellable>()
    init(manager: OverlayManager, registry: DisplayRegistry, service: MusicService) {
        self.manager = manager; self.registry = registry; self.service = service
        manager.store.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        manager.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
    }
    var connectedDisplays: [DisplayDescriptor] { registry.displays.filter(\.isPersistent) }
    var canSave: Bool { selectedDisplayID.map(canApply(on:)) ?? false }
    var state: OverlayState? {
        guard let id = manager.store.configurations.first(where: { $0.kind == .music && $0.displayID == selectedDisplayID })?.id else { return nil }
        return manager.states.first { $0.id == id }
    }
    func opened() { if selectedDisplayID == nil { selectDisplay(connectedDisplays.first?.id) } }
    func selectDisplay(_ id: DisplayID?) {
        selecting = true; selectedDisplayID = id
        let value = id.map(draft(on:)) ?? .init(); options = value.options; isEnabled = value.isEnabled
        selecting = false; error = nil; notice = nil
        if let value = manager.store.configurations.first(where: { $0.kind == .music && $0.displayID == id }),
           (try? MusicOverlayOptions(configuration: value)) == nil { error = OverlayError.invalidConfiguration.localizedDescription }
    }
    private func remember() {
        guard !selecting, let id = selectedDisplayID else { return }
        drafts[id] = .init(options: options, isEnabled: isEnabled); error = nil; notice = nil
    }
    func saved(on id: DisplayID) -> Draft {
        guard let value = manager.store.configurations.first(where: { $0.kind == .music && $0.displayID == id }),
              let options = try? MusicOverlayOptions(configuration: value) else { return .init() }
        return .init(options: options, isEnabled: value.isEnabled)
    }
    func draft(on id: DisplayID) -> Draft { drafts[id] ?? saved(on: id) }
    func isDirty(on id: DisplayID) -> Bool { draft(on: id) != saved(on: id) }
    func canApply(on id: DisplayID) -> Bool {
        manager.isStarted && manager.store.loadError == nil && isDirty(on: id)
            && (connectedDisplays.contains { $0.id == id } || !draft(on: id).isEnabled)
    }
    func save() { if let id = selectedDisplayID { apply(on: id) } }
    func apply(on id: DisplayID) {
        error = nil; notice = nil
        guard canApply(on: id) else { error = OverlayError.targetUnavailable.localizedDescription; return }
        do {
            let draft = draft(on: id)
            var value = manager.store.configurations.first { $0.kind == .music && $0.displayID == id }
                ?? OverlayConfiguration(kind: .music, displayID: id, maximumFramesPerSecond: 1)
            value = try draft.options.applying(to: value); value.isEnabled = draft.isEnabled
            if connectedDisplays.contains(where: { $0.id == id }) { try manager.configure(value) } else { try manager.store.upsert(value) }
            drafts[id] = nil; notice = NSLocalizedString("music.saved", comment: "")
        } catch { self.error = error.localizedDescription }
    }
    func defaults() { options = .init() }
    func retry() { if let id = state?.id { manager.retry(id) } }
    func move(from start: MusicOverlayOptions, by delta: CGSize, on id: DisplayID, isLyrics: Bool) {
        if selectedDisplayID != id { selectDisplay(id) }
        options = start.moved(by: delta, in: displaySize(on: id), isLyrics: isLyrics)
    }
    func displaySize(on id: DisplayID) -> CGSize {
        connectedDisplays.first { $0.id == id }?.desktop.frame.size ?? CGSize(width: 1600, height: 1000)
    }
}
