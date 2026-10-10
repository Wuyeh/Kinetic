import AppKit
import SwiftUI

@MainActor final class DisplayMusicPreviewState: ObservableObject {
    @Published private(set) var overlay: MusicOverlay?
    func update(model: MusicOverlayEditorModel, options: MusicOverlayOptions, canvas: CGSize, visible: Bool) {
        let overlay = self.overlay ?? MusicOverlay(service: model.service)
        if self.overlay == nil { self.overlay = overlay }
        do {
            let configuration = try options.applying(to: .init(kind: .music, displayID: .init("display-music-preview")))
            try overlay.update(configuration: configuration, context: .init(frame: CGRect(origin: .zero, size: canvas), backingScaleFactor: 1,
                maximumFramesPerSecond: 1, allowsAnimation: true, isPaused: !visible))
            if visible { overlay.play() } else { overlay.pause() }
        } catch { overlay.pause() }
    }
    func stop() { overlay?.dispose(); overlay = nil }
}

@MainActor struct DisplayMusicPreview: View {
    @ObservedObject var model: MusicOverlayEditorModel
    let displayID: DisplayID
    let size: CGSize
    let visible: Bool
    @StateObject private var preview = DisplayMusicPreviewState()
    @State private var musicStart: MusicOverlayOptions?
    @State private var lyricsStart: MusicOverlayOptions?
    private var draft: MusicOverlayEditorModel.Draft { model.draft(on: displayID) }
    private var canvas: CGSize { model.displaySize(on: displayID) }
    private var scale: CGFloat { size.width / max(1, canvas.width) }
    var body: some View {
        ZStack(alignment: .topLeading) {
            if draft.isEnabled {
                if let overlay = preview.overlay {
                    MusicPreviewSurface(overlay: overlay).frame(width: canvas.width, height: canvas.height)
                        .scaleEffect(scale, anchor: .topLeading).frame(width: size.width, height: size.height, alignment: .topLeading)
                        .allowsHitTesting(false)
                }
                handle(isLyrics: false)
                if draft.options.lyrics != .off { handle(isLyrics: true) }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .onAppear(perform: refresh).onChange(of: draft) { _ in refresh() }
        .onChange(of: visible) { _ in refresh() }.onChange(of: canvas) { _ in refresh() }
        .onDisappear { preview.stop() }
    }
    @ViewBuilder private func handle(isLyrics: Bool) -> some View {
        if let frame = draft.options.frame(in: canvas, isLyrics: isLyrics) {
            RoundedRectangle(cornerRadius: 18 * scale).fill(Color.clear).contentShape(Rectangle())
                .frame(width: frame.width * scale, height: frame.height * scale).position(x: frame.midX * scale, y: frame.midY * scale)
                .gesture(DragGesture(minimumDistance: 2).onChanged { value in
                    let base = (isLyrics ? lyricsStart : musicStart) ?? draft.options
                    if isLyrics { lyricsStart = base } else { musicStart = base }
                    model.move(from: base, by: .init(width: value.translation.width / max(0.001, scale),
                        height: value.translation.height / max(0.001, scale)), on: displayID, isLyrics: isLyrics)
                }.onEnded { _ in if isLyrics { lyricsStart = nil } else { musicStart = nil } })
                .help(Text("music.drag")).accessibilityLabel(Text(isLyrics ? "lyrics.mode" : "music.title"))
        }
    }
    private func refresh() {
        guard draft.isEnabled else { preview.stop(); return }
        preview.update(model: model, options: draft.options, canvas: canvas, visible: visible)
    }
}

@MainActor private struct MusicPreviewSurface: NSViewRepresentable {
    let overlay: MusicOverlay
    func makeNSView(context: Context) -> NSView { let host = NSView(); host.addSubview(overlay.displayView); return host }
    func updateNSView(_ host: NSView, context: Context) {
        if overlay.displayView.superview !== host { host.addSubview(overlay.displayView) }
        overlay.displayView.frame = host.bounds; overlay.displayView.autoresizingMask = [.width, .height]
    }
    static func dismantleNSView(_ host: NSView, coordinator: ()) { host.subviews.forEach { $0.removeFromSuperview() } }
}
