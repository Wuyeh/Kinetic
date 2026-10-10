import AppKit
import SwiftUI

/// A future data widget owns its view/subscriptions; no Wallpaper or Renderer access.
/// Creation is cheap and synchronous. Data arrival updates the view; pause/dispose stop work.
@MainActor
protocol WidgetContent: AnyObject {
    var displayView: NSView { get }
    var onFailure: (@MainActor () -> Void)? { get set }
    func update(configuration: WidgetConfiguration, context: OverlayContext) throws
    func play()
    func pause()
    func dispose()
}

@MainActor
final class WidgetContentRegistry {
    typealias Factory = @MainActor (WidgetConfiguration) throws -> any WidgetContent
    private var factories: [WidgetKind: Factory] = [:]
    func register(_ kind: WidgetKind, factory: @escaping Factory) { factories[kind] = factory }
    func make(_ configuration: WidgetConfiguration) throws -> (any WidgetContent)? { try factories[configuration.kind]?(configuration) }
}

@MainActor
private final class WidgetTileState: ObservableObject {
    @Published var configuration: WidgetConfiguration
    @Published var content: NSView?
    @Published var failed = false
    @Published var drawingScale = 1.0
    init(_ configuration: WidgetConfiguration) { self.configuration = configuration }
}

@MainActor
final class WidgetBoardOverlay: DesktopOverlay {
    let view = WidgetBoardCanvasView(frame: .zero)
    var displayView: NSView { view }
    var onFailure: (@MainActor (Error) -> Void)?
    private let repository: WidgetLayoutRepository
    private let registry: WidgetContentRegistry
    /// Desktop only: tiles live in their own windows above the desktop icons. Previews draw in `view`.
    let desktop: WidgetDesktopTiles?
    private var slots: [UUID: Slot] = [:]
    private(set) var layout = WidgetBoardLayout()
    private(set) var context: OverlayContext?
    private(set) var isDisposed = false
    private(set) var isPlaying = false
    var widgetIDs: Set<UUID> { Set(slots.keys) }
    func widgetFrame(_ id: UUID) -> CGRect? { slots[id]?.host.frame }
    func contentIdentity(_ id: UUID) -> ObjectIdentifier? { slots[id]?.provider.map(ObjectIdentifier.init) }

    @MainActor private final class Slot {
        let state: WidgetTileState
        let host: NSHostingView<WidgetTileView>
        var provider: (any WidgetContent)?
        init(_ configuration: WidgetConfiguration) {
            state = WidgetTileState(configuration)
            host = NSHostingView(rootView: WidgetTileView(state: state)); host.wantsLayer = true
            host.layer?.backgroundColor = NSColor.clear.cgColor
        }
        func dispose() { provider?.onFailure = nil; provider?.dispose(); provider = nil; state.content = nil; host.removeFromSuperview() }
    }

    init(repository: WidgetLayoutRepository, registry: WidgetContentRegistry, desktop: WidgetDesktopTiles? = nil) {
        self.repository = repository; self.registry = registry; self.desktop = desktop
        desktop?.dropCell = { [weak self] id, origin in
            guard let self, let size = self.context?.frame.size else { return nil }
            return WidgetGrid.dropCell(for: id, at: origin, in: self.layout, canvas: size)
        }
        desktop?.cellFrame = { [weak self] id, cell in
            guard let self, let size = self.context?.frame.size, let metrics = WidgetGrid.Metrics(canvas: size),
                  let widget = self.layout.widgets.first(where: { $0.id == id }) else { return nil }
            return metrics.frame(cell, widget.size)
        }
    }
    func prepare(configuration: OverlayConfiguration, context: OverlayContext) async throws {
        try Task.checkCancellation(); try update(configuration: configuration, context: context); try Task.checkCancellation()
    }
    func update(configuration: OverlayConfiguration, context: OverlayContext) throws {
        let reference = try WidgetBoardReference(configuration: configuration)
        try updatePreview(layout: repository.load(reference.layoutID), context: context)
    }
    /// Explicit preview data has no storage commit or desktop assignment.
    /// `floating` draws a widget being dragged at that frame instead of its grid cell.
    func updatePreview(layout: WidgetBoardLayout, context: OverlayContext, floating: [UUID: CGRect] = [:]) throws {
        guard !isDisposed, context.frame.width.isFinite, context.frame.height.isFinite,
              context.frame.width > 0, context.frame.height > 0, context.backingScaleFactor.isFinite,
              context.backingScaleFactor > 0, (1...60).contains(context.maximumFramesPerSecond) else { throw WidgetBoardError.invalidLayout }
        let layout = try layout.validated() // Validate the entire edit before changing a live view.
        if context.isPaused { isPlaying = false }
        let removed = slots.keys.filter { id in !layout.widgets.contains(where: { $0.id == id }) }
        for id in removed { slots.removeValue(forKey: id)?.dispose(); desktop?.remove(id) }
        view.frame.size = context.frame.size
        desktop?.setDisplayFrame(context.frame)
        let frames = WidgetGrid.frames(layout.widgets, in: context.frame.size)
        for widget in layout.widgets {
            if let old = slots[widget.id], old.state.configuration.kind != widget.kind { slots.removeValue(forKey: widget.id)?.dispose() }
            let slot: Slot
            if let existing = slots[widget.id] { slot = existing }
            else {
                slot = Slot(widget); slots[widget.id] = slot
                if desktop == nil { view.addSubview(slot.host) }
                do { slot.provider = try registry.make(widget) } catch { slot.state.failed = true }
                slot.provider?.onFailure = { [weak self, weak slot] in
                    guard let self, !self.isDisposed, let slot, self.slots[widget.id] === slot else { return }
                    self.fail(slot)
                }
            }
            slot.state.configuration = widget
            // A widget with no free cell is not shown; widgets never overlap.
            let frame = floating[widget.id] ?? frames[widget.id]
            slot.state.drawingScale = (frame?.width ?? widget.size.dimensions.width) / widget.size.dimensions.width
            if let desktop {
                desktop.place(widget.id, host: slot.host, size: widget.size, frame: frame)
            } else {
                slot.host.frame = frame ?? .zero; slot.host.isHidden = frame == nil
                // z-order matches persisted array order; geometry and settings keep the same provider.
                view.addSubview(slot.host, positioned: .above, relativeTo: nil)
            }
            var childContext = context; childContext.frame = .init(origin: .zero, size: frame?.size ?? widget.size.dimensions)
            do {
                try slot.provider?.update(configuration: widget, context: childContext)
                if !slot.state.failed { slot.state.content = slot.provider?.displayView }
                if isPlaying && !context.isPaused { slot.provider?.play() } else { slot.provider?.pause() }
            } catch { fail(slot) }
        }
        self.layout = layout; self.context = context
    }
    private func fail(_ slot: Slot) {
        slot.provider?.onFailure = nil; slot.provider?.dispose(); slot.provider = nil
        slot.state.content = nil; slot.state.failed = true
    }
    func play() {
        guard !isDisposed, context?.isPaused == false else { return }; isPlaying = true
        slots.values.forEach { $0.provider?.play() }
    }
    func pause() { isPlaying = false; slots.values.forEach { $0.provider?.pause() } }
    func dispose() {
        guard !isDisposed else { return }; isDisposed = true; isPlaying = false
        slots.values.forEach { $0.dispose() }; slots = [:]; context = nil; layout = .init(); onFailure = nil
        desktop?.close(); view.removeFromSuperview()
    }
    deinit {
        let slots = slots, desktop = desktop
        Task { @MainActor in slots.values.forEach { $0.dispose() }; desktop?.close() }
    }
}

@MainActor
final class WidgetBoardCanvasView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true; layer?.backgroundColor = NSColor.clear.cgColor; layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { nil }
    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
private struct WidgetTileView: View {
    @ObservedObject var state: WidgetTileState
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if state.configuration.showsTitle {
                Label(state.configuration.title, systemImage: state.configuration.kind.symbol)
                    .font(.system(size: 13 * state.drawingScale, weight: .semibold)).lineLimit(1)
            }
            if let view = state.content { WidgetNativeContent(view: view).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else {
                Spacer(minLength: 0)
                Text(state.failed ? "widgets.unavailable" : "widgets.notConnected")
                    .font(.system(size: 12 * state.drawingScale)).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
        }.padding(14 * state.drawingScale).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .kineticGlass(in: RoundedRectangle(cornerRadius: 18 * state.drawingScale, style: .continuous))
            .opacity(state.configuration.opacity)
    }
}

@MainActor
private struct WidgetNativeContent: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView {
        let host = NSView(); host.wantsLayer = true; host.layer?.backgroundColor = NSColor.clear.cgColor
        return host
    }
    func updateNSView(_ host: NSView, context: Context) {
        if view.superview !== host { host.subviews.forEach { $0.removeFromSuperview() }; host.addSubview(view) }
        view.frame = host.bounds; view.autoresizingMask = [.width, .height]
    }
    static func dismantleNSView(_ host: NSView, coordinator: ()) { host.subviews.forEach { $0.removeFromSuperview() } }
}
