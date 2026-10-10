import AppKit
import Combine
import SwiftUI

/// The display page's own drawing of the widget board, kept over the wallpaper preview (user, 2026-10-08).
@MainActor
final class DisplayWidgetPreview: ObservableObject {
    @Published private(set) var overlay: WidgetBoardOverlay?
    func update(_ model: WidgetBoardEditorModel, layout: WidgetBoardLayout, context: OverlayContext, floating: [UUID: CGRect]) {
        let overlay = self.overlay ?? WidgetBoardOverlay(repository: model.repository, registry: model.contents)
        if self.overlay == nil { self.overlay = overlay }
        do {
            try overlay.updatePreview(layout: layout, context: context, floating: floating)
            if context.isPaused { overlay.pause() } else { overlay.play() }
        } catch { overlay.pause() }
    }
    func pause() { overlay?.pause() }
    /// The overlay's own deinit also releases its tiles if the page goes away without disappearing.
    func stop() { overlay?.dispose(); overlay = nil }
}

/// Widgets on the display preview: drag to a grid cell, hover for the remove badge, right-click for size,
/// edit and remove. Every change is a draft until the page's 应用.
@MainActor
struct DisplayWidgetLayer: View {
    private struct Drag: Equatable { let id: UUID; var frame: CGRect }
    @ObservedObject var model: WidgetBoardEditorModel
    let displayID: DisplayID
    let size: CGSize
    let visible: Bool
    @StateObject private var preview = DisplayWidgetPreview()
    @State private var drag: Drag?
    @State private var hovered: UUID?

    private var draft: WidgetBoardEditorModel.Draft { model.draft(on: displayID) }
    private var canvas: CGSize { model.canvasSize(on: displayID) }
    private var scale: CGFloat { canvas.width > 0 && size.width.isFinite ? size.width / canvas.width : 1 }

    var body: some View {
        // Only what 应用 would put on the desktop: nothing while the board is switched off.
        let layout = draft.isEnabled ? draft.layout : .init(), frames = WidgetGrid.frames(layout.widgets, in: canvas)
        ZStack(alignment: .topLeading) {
            if draft.isEnabled, let overlay = preview.overlay {
                DisplayWidgetSurface(overlay: overlay)
                    .frame(width: canvas.width, height: canvas.height)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
                    .allowsHitTesting(false)
            }
            if let drag, let target = dropFrame(drag) {
                RoundedRectangle(cornerRadius: 18 * scale, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .frame(width: target.width * scale, height: target.height * scale)
                    .offset(x: target.minX * scale, y: target.minY * scale)
                    .allowsHitTesting(false)
            }
            ForEach(layout.widgets) { widget in
                if let frame = drag?.id == widget.id ? drag?.frame : frames[widget.id] {
                    handle(widget, frame: frame, base: frames[widget.id] ?? frame)
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .coordinateSpace(name: "displayWidgets")
        .onAppear(perform: refresh)
        .onChange(of: draft) { _ in refresh() }
        .onChange(of: visible) { _ in refresh() }
        .onChange(of: canvas) { _ in refresh() }
        .onChange(of: model.previewPolicy) { _ in refresh() }
        .onChange(of: drag) { _ in refresh() }
        .onDisappear { preview.stop() }
    }

    private func handle(_ widget: WidgetConfiguration, frame: CGRect, base: CGRect) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18 * scale, style: .continuous)
        return shape.fill(Color.clear).contentShape(shape)
            .overlay(shape.stroke(model.selectedWidgetID == widget.id ? MainWindowDesignTokens.accent : .clear, lineWidth: 2))
            .frame(width: frame.width * scale, height: frame.height * scale)
            .overlay(alignment: .topLeading) {
                if hovered == widget.id && drag == nil {
                    Button { model.remove(widget.id, on: displayID) } label: {
                        Image(systemName: "minus.circle.fill").font(.system(size: 17))
                            .symbolRenderingMode(.palette).foregroundStyle(.white, Color.black.opacity(0.6))
                    }
                    .buttonStyle(.plain).offset(x: -7, y: -7)
                    .help(Text("widgets.remove")).accessibilityLabel(Text("widgets.remove"))
                }
            }
            .offset(x: frame.minX * scale, y: frame.minY * scale)
            .onHover { inside in if inside { hovered = widget.id } else if hovered == widget.id { hovered = nil } }
            .onTapGesture { model.selectWidget(widget.id) }
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("displayWidgets"))
                .onChanged { value in
                    guard scale > 0 else { return }
                    if drag?.id != widget.id { model.selectWidget(widget.id) }
                    drag = Drag(id: widget.id, frame: clamped(base.offsetBy(dx: value.translation.width / scale, dy: value.translation.height / scale)))
                }
                .onEnded { _ in
                    guard let ended = drag, ended.id == widget.id else { drag = nil; return }
                    drag = nil; model.drop(widget.id, at: ended.frame.origin, on: displayID)
                })
            .contextMenu {
                ForEach(WidgetSize.allCases, id: \.self) { size in
                    Button { model.edit(widget.id, on: displayID) { $0.size = size } } label: {
                        if widget.size == size { Label(size.title, systemImage: "checkmark") } else { Text(size.title) }
                    }
                }
                Divider()
                Button { model.onEditRequest?(displayID, widget.id) } label: { Text("widgets.menu.edit") }
                Button(role: .destructive) { model.remove(widget.id, on: displayID) } label: { Text("widgets.remove") }
            }
            .accessibilityElement().accessibilityLabel(Text(widget.title))
            .accessibilityAddTraits(model.selectedWidgetID == widget.id ? .isSelected : [])
    }
    private func clamped(_ frame: CGRect) -> CGRect {
        CGRect(x: max(0, min(canvas.width - frame.width, frame.minX)), y: max(0, min(canvas.height - frame.height, frame.minY)),
               width: frame.width, height: frame.height)
    }
    private func dropFrame(_ drag: Drag) -> CGRect? {
        guard let metrics = WidgetGrid.Metrics(canvas: canvas), let widget = draft.layout.widgets.first(where: { $0.id == drag.id }),
              let cell = WidgetGrid.dropCell(for: drag.id, at: drag.frame.origin, in: draft.layout, canvas: canvas) else { return nil }
        return metrics.frame(cell, widget.size)
    }
    private func refresh() {
        guard visible, draft.isEnabled else { preview.pause(); return }
        preview.update(model, layout: draft.layout, context: model.previewContext(on: displayID, visible: visible),
                       floating: drag.map { [$0.id: $0.frame] } ?? [:])
    }
}

@MainActor
private struct DisplayWidgetSurface: NSViewRepresentable {
    let overlay: WidgetBoardOverlay
    func makeNSView(context: Context) -> NSView {
        let host = NSView(); host.addSubview(overlay.displayView); return host
    }
    func updateNSView(_ host: NSView, context: Context) {
        if overlay.displayView.superview !== host { host.addSubview(overlay.displayView) }
        overlay.displayView.frame = host.bounds; overlay.displayView.autoresizingMask = [.width, .height]
    }
    static func dismantleNSView(_ host: NSView, coordinator: ()) { host.subviews.forEach { $0.removeFromSuperview() } }
}

/// Every desktop overlay's editor, for the display page: one preview and one 应用 for all of them
/// (user, 2026-10-08). Changes in any editor refresh the page.
@MainActor
final class DisplayOverlayEditors: ObservableObject {
    let particles: ParticleEditorModel?
    let clock: NixieClockEditorModel?
    let widgets: WidgetBoardEditorModel?
    let music: MusicOverlayEditorModel?
    /// Failures of 应用 on a display page, from the particle and clock editors.
    @Published private(set) var applyErrors: [DisplayID: String] = [:]
    private var subscriptions = Set<AnyCancellable>()

    init(particles: ParticleEditorModel?, clock: NixieClockEditorModel?, widgets: WidgetBoardEditorModel?, music: MusicOverlayEditorModel? = nil) {
        self.particles = particles; self.clock = clock; self.widgets = widgets; self.music = music
        let changes = [particles?.objectWillChange.eraseToAnyPublisher(), clock?.objectWillChange.eraseToAnyPublisher(),
                       widgets?.objectWillChange.eraseToAnyPublisher(), music?.objectWillChange.eraseToAnyPublisher()].compactMap { $0 }
        Publishers.MergeMany(changes).sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
    }
    func canApply(on display: DisplayID) -> Bool {
        (widgets?.canApply(on: display) ?? false) || (particles?.canApply(on: display) ?? false) || (clock?.canApply(on: display) ?? false) || (music?.canApply(on: display) ?? false)
    }
    func apply(on display: DisplayID) {
        var failures: [String] = []
        if let widgets, widgets.canApply(on: display) { widgets.apply(on: display) }
        if let particles, particles.canApply(on: display) { particles.apply(on: display); if let error = particles.error { failures.append(error) } }
        if let clock, clock.canApply(on: display) { clock.apply(on: display); if let error = clock.error { failures.append(error) } }
        if let music, music.canApply(on: display) { music.apply(on: display); if let error = music.error { failures.append(error) } }
        applyErrors[display] = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }
    func error(on display: DisplayID) -> String? {
        [widgets?.applyErrors[display], applyErrors[display]].compactMap { $0 }.joined(separator: "\n").nilIfEmpty
    }
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }

/// The overlays drawn over the display page's wallpaper preview, in desktop order: particles, the clock,
/// then widgets (which sit above the desktop icons). Only what 应用 would show is drawn.
@MainActor
struct DisplayOverlayPreviews: View {
    @ObservedObject var editors: DisplayOverlayEditors
    let displayID: DisplayID
    let size: CGSize
    let visible: Bool
    var body: some View {
        ZStack(alignment: .topLeading) {
            if let particles = editors.particles {
                DisplayParticlePreview(model: particles, displayID: displayID, size: size, visible: visible)
            }
            if let clock = editors.clock {
                DisplayClockPreview(model: clock, displayID: displayID, size: size, visible: visible)
            }
            if let music = editors.music {
                DisplayMusicPreview(model: music, displayID: displayID, size: size, visible: visible)
            }
            if let widgets = editors.widgets {
                DisplayWidgetLayer(model: widgets, displayID: displayID, size: size, visible: visible)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

/// Particles render at the preview's own size; their sizes follow the view, as on the desktop.
@MainActor
final class DisplayParticlePreviewState: ObservableObject {
    @Published private(set) var overlay: ParticleOverlay?
    func update(options: ParticleOptions, context: OverlayContext) {
        let overlay = self.overlay ?? ParticleOverlay()
        if self.overlay == nil { self.overlay = overlay }
        do {
            let configuration = try options.applying(to: OverlayConfiguration(kind: .particles, displayID: .init("display-page-preview")))
            try overlay.update(configuration: configuration, context: context)
            if context.isPaused { overlay.pause() } else { overlay.play() }
        } catch { overlay.pause() }
    }
    func stop() { overlay?.dispose(); overlay = nil }
}

@MainActor
struct DisplayParticlePreview: View {
    @ObservedObject var model: ParticleEditorModel
    let displayID: DisplayID
    let size: CGSize
    let visible: Bool
    @StateObject private var state = DisplayParticlePreviewState()
    private var draft: (options: ParticleOptions, isEnabled: Bool) { model.draft(on: displayID) }
    private var showing: Bool { draft.isEnabled && size.width > 0 && size.height > 0 }

    var body: some View {
        Group {
            if showing, let overlay = state.overlay {
                ParticlePreviewSurface(overlay: overlay).frame(width: size.width, height: size.height)
            }
        }
        .allowsHitTesting(false)
        .onAppear(perform: refresh)
        .onChange(of: draft.options) { _ in refresh() }
        .onChange(of: draft.isEnabled) { _ in refresh() }
        .onChange(of: visible) { _ in refresh() }
        .onChange(of: size) { _ in refresh() }
        .onChange(of: model.previewPolicy) { _ in refresh() }
        .onDisappear { state.stop() }
    }
    private func refresh() {
        guard showing else { state.stop(); return }
        state.update(options: draft.options, context: model.previewContext(size: size, visible: visible))
    }
}

@MainActor
private struct ParticlePreviewSurface: NSViewRepresentable {
    let overlay: ParticleOverlay
    func makeNSView(context: Context) -> NSView {
        let host = NSView(); host.wantsLayer = true; host.layer?.masksToBounds = true
        host.addSubview(overlay.displayView); overlay.displayView.frame = host.bounds
        overlay.displayView.autoresizingMask = [.width, .height]; return host
    }
    func updateNSView(_ view: NSView, context: Context) {
        if overlay.displayView.superview !== view { view.addSubview(overlay.displayView) }
        overlay.displayView.frame = view.bounds
    }
    static func dismantleNSView(_ host: NSView, coordinator: ()) { host.subviews.forEach { $0.removeFromSuperview() } }
}

/// The clock at its place on this display; dragging it moves it (a draft until 应用 or 保存).
@MainActor
struct DisplayClockPreview: View {
    @ObservedObject var model: NixieClockEditorModel
    let displayID: DisplayID
    let size: CGSize
    let visible: Bool
    @State private var dragBase: NixieClockOptions?

    var body: some View {
        let draft = model.draft(on: displayID), canvas = model.displaySize(on: displayID)
        let factor = size.width / max(1, canvas.width)
        ZStack(alignment: .topLeading) {
            if draft.isEnabled, let frame = draft.options.frame(in: canvas) {
                face(draft.options)
                    .frame(width: frame.width * factor, height: frame.height * factor)
                    .contentShape(Rectangle())
                    .position(x: frame.midX * factor, y: frame.midY * factor)
                    .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                        let base = dragBase ?? draft.options; dragBase = base
                        model.move(from: base, by: .init(width: value.translation.width / max(factor, 0.001),
                                                         height: value.translation.height / max(factor, 0.001)), on: displayID)
                    }.onEnded { _ in dragBase = nil })
                    .help(Text("clock.drag"))
                    .accessibilityLabel(Text("clock.title"))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    @ViewBuilder private func face(_ options: NixieClockOptions) -> some View {
        if visible {
            TimelineView(.periodic(from: .now, by: 1)) { context in face(options, at: context.date) }
        } else { face(options, at: Date()) }
    }
    private func face(_ options: NixieClockOptions, at date: Date) -> some View {
        NixieClockFace(options: options,
                       digits: NixieClockOptions.digits(at: date, uses24Hour: options.uses24Hour, leadingZero: options.leadingZero),
                       separatorLit: NixieClockOptions.separatorLit(at: date, blinking: options.blinksSeparator
                                                                    && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion))
    }
}
