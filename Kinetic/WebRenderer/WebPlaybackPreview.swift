import AppKit
import Combine
import SwiftUI

/// Settings-owned, silent surface; has no library store, Runtime or desktop host reference.
@MainActor
final class WebPlaybackPreview: ObservableObject {
    let surface = WebDraftSurface(frame: .init(x: 0, y: 0, width: 420, height: 262.5))
    @Published private(set) var isPreparing = false
    @Published private(set) var error: String?
    private(set) var renderer: WebRenderer?
    private var pending: WebRenderer?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var ownerID: UUID?
    private var requestedWallpaperID: Wallpaper.ID?
    private var requestedOptions: WebPlaybackOptions?
    private var requestedNetwork: Bool?
    private let debounceNanoseconds: UInt64
    init(debounceNanoseconds: UInt64 = 80_000_000) {
        self.debounceNanoseconds = debounceNanoseconds
        surface.onWindowClose = { [weak self] in self?.stop() }
    }
    func update(_ wallpaper: Wallpaper, options: WebPlaybackOptions, allowsNetwork: Bool,
                ownerID: UUID? = nil, forceReload: Bool = false) {
        guard forceReload || requestedWallpaperID != wallpaper.id || requestedOptions != options
                || requestedNetwork != allowsNetwork || self.ownerID != ownerID || error != nil else { return }
        generation = UUID(); let token = generation
        self.ownerID = ownerID; requestedWallpaperID = wallpaper.id
        requestedOptions = options; requestedNetwork = allowsNetwork
        task?.cancel(); pending?.dispose(); pending = nil
        error = nil; isPreparing = true
        task = Task { @MainActor [weak self] in
            do {
                if let delay = self?.debounceNanoseconds, delay > 0 { try await Task.sleep(nanoseconds: delay) }
                guard let self, self.generation == token else { return }
                let options = try options.validated()
                if !forceReload, let current = self.renderer, current.isPrepared,
                   current.wallpaper.id == wallpaper.id, current.allowsNetwork == allowsNetwork,
                   !options.requiresReload(comparedTo: current.options) {
                    try await current.updateOptions(options)
                    guard self.generation == token, !Task.isCancelled else { return }
                    self.isPreparing = false; self.task = nil; return
                }
                let candidate = WebRenderer(wallpaper: wallpaper, allowsNetwork: allowsNetwork, options: options)
                self.pending = candidate
                do {
                    try await candidate.prepare(); try Task.checkCancellation()
                    guard self.generation == token else { candidate.dispose(); return }
                    candidate.setMuted(true)
                    let old = self.renderer
                    candidate.displayView.frame = self.surface.bounds
                    candidate.displayView.autoresizingMask = [.width, .height]
                    self.surface.addSubview(candidate.displayView)
                    self.renderer = candidate; self.pending = nil
                    old?.onFailure = nil; old?.displayView.removeFromSuperview(); old?.dispose()
                    candidate.onFailure = { [weak self, weak candidate] error in
                        guard let self, let candidate, self.renderer === candidate else { return }
                        self.error = error.localizedDescription
                    }
                    self.isPreparing = false; self.task = nil; candidate.play()
                } catch {
                    if self.pending === candidate { self.pending = nil }
                    candidate.dispose(); throw error
                }
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.error = error.localizedDescription; self.isPreparing = false; self.task = nil
            }
        }
    }
    func stop(ownerID: UUID? = nil) {
        if let ownerID, self.ownerID != ownerID { return }
        generation = UUID(); task?.cancel(); task = nil
        pending?.dispose(); pending = nil
        renderer?.onFailure = nil; renderer?.displayView.removeFromSuperview(); renderer?.dispose(); renderer = nil
        requestedWallpaperID = nil; requestedOptions = nil; requestedNetwork = nil; self.ownerID = nil
        isPreparing = false; error = nil
    }
    deinit { task?.cancel() }
}

@MainActor
final class WebDraftSurface: NSView {
    var onWindowClose: (@MainActor () -> Void)?
    private var observer: NSObjectProtocol?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil
        if let window {
            observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                object: window, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.onWindowClose?() }
                }
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}

@MainActor
struct WebPlaybackPreviewView: View {
    @ObservedObject var preview: WebPlaybackPreview
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text("效果预览").font(.headline); if preview.isPreparing { ProgressView().controlSize(.small) } }
            WebDraftSurfaceView(preview: preview)
                .aspectRatio(16.0 / 10.0, contentMode: .fit)
                .background(Color.black.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text("修改只更新此预览；保存并应用后才更新屏幕。预览始终静音。")
                .font(.caption).foregroundStyle(.secondary)
            if let error = preview.error { Text("预览失败：" + error).font(.caption).foregroundStyle(.red) }
        }
    }
}
private struct WebDraftSurfaceView: NSViewRepresentable {
    let preview: WebPlaybackPreview
    func makeNSView(context: Context) -> NSView { preview.surface }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
