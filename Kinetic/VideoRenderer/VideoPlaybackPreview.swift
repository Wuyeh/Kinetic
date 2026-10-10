import AppKit
import Combine
import SwiftUI

/// An editor-owned, silent video surface. It has no store, desktop host or Runtime reference.
@MainActor
final class VideoPlaybackPreview: ObservableObject {
    typealias RendererFactory = @MainActor (Wallpaper, VideoPlaybackOptions) -> any WallpaperRenderer
    let surface = VideoDraftSurface(frame: .init(x: 0, y: 0, width: 420, height: 262.5))
    @Published private(set) var isPreparing = false
    @Published private(set) var error: String?
    @Published private(set) var previewOptions: VideoPlaybackOptions?
    private(set) var renderer: (any WallpaperRenderer)?
    private var pending: (any WallpaperRenderer)?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var ownerID: UUID?
    private var requestedWallpaperID: Wallpaper.ID?
    private var requestedOptions: VideoPlaybackOptions?
    private let debounceNanoseconds: UInt64
    private let factory: RendererFactory

    init(debounceNanoseconds: UInt64 = 80_000_000, rendererFactory: RendererFactory? = nil) {
        self.debounceNanoseconds = debounceNanoseconds
        factory = rendererFactory ?? { VideoRenderer(wallpaper: $0, options: $1) }
        surface.onWindowClose = { [weak self] in self?.stop() }
    }

    func update(_ wallpaper: Wallpaper, options: VideoPlaybackOptions, ownerID: UUID? = nil) {
        guard requestedWallpaperID != wallpaper.id || requestedOptions != options
                || self.ownerID != ownerID || error != nil else { return }
        // 只改了「自定义」显示范围：跟着拖动立即更新，不等防抖、不重建。
        if task == nil, error == nil, self.ownerID == ownerID, requestedWallpaperID == wallpaper.id,
           var requested = requestedOptions, requested.customFrame != options.customFrame {
            requested.customFrame = options.customFrame
            if requested == options, options.customFrame?.isValid ?? true,
               let video = renderer as? VideoRenderer, video.wallpaper.id == wallpaper.id, video.isPrepared {
                requestedOptions = options
                video.updateCustomFrame(options.customFrame)
                previewOptions = options
                return
            }
        }
        generation = UUID(); let token = generation
        self.ownerID = ownerID; requestedWallpaperID = wallpaper.id; requestedOptions = options
        task?.cancel()
        pending?.onFailure = nil; pending?.dispose(); pending = nil
        error = nil; isPreparing = true
        task = Task { @MainActor [weak self] in
            do {
                if let delay = self?.debounceNanoseconds, delay > 0 { try await Task.sleep(nanoseconds: delay) }
                guard let self, self.generation == token else { return }
                let options = try options.validated()
                if let video = self.renderer as? VideoRenderer,
                   video.wallpaper.id == wallpaper.id, video.isPrepared {
                    try await video.updateOptions(options)
                    try Task.checkCancellation()
                    guard self.generation == token else { return }
                    self.previewOptions = options; self.error = nil; self.isPreparing = false; self.task = nil
                    return
                }
                let candidate = self.factory(wallpaper, options)
                self.pending = candidate
                do {
                    try await candidate.prepare()
                    try Task.checkCancellation()
                    guard self.generation == token else { candidate.dispose(); return }
                    candidate.setMuted(true)
                    let old = self.renderer
                    candidate.displayView.frame = self.surface.bounds
                    candidate.displayView.autoresizingMask = [.width, .height]
                    self.surface.addSubview(candidate.displayView)
                    self.renderer = candidate; self.pending = nil
                    old?.onFailure = nil; old?.displayView.removeFromSuperview(); old?.dispose()
                    self.previewOptions = options; self.error = nil; self.isPreparing = false; self.task = nil
                    candidate.onFailure = { [weak self, weak candidate] failure in
                        guard let self, let candidate, self.renderer === candidate else { return }
                        self.error = failure.localizedDescription
                    }
                    candidate.play()
                } catch {
                    if self.pending === candidate { self.pending = nil }
                    candidate.onFailure = nil; candidate.dispose()
                    throw error
                }
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                // A bad draft never removes the last successful preview, or touches the desktop.
                self.error = error.localizedDescription; self.isPreparing = false; self.task = nil
            }
        }
    }

    func stop(ownerID: UUID? = nil) {
        if let ownerID, self.ownerID != ownerID { return }
        generation = UUID(); task?.cancel(); task = nil
        pending?.onFailure = nil; pending?.dispose(); pending = nil
        renderer?.onFailure = nil; renderer?.displayView.removeFromSuperview(); renderer?.dispose(); renderer = nil
        requestedWallpaperID = nil; requestedOptions = nil; self.ownerID = nil
        previewOptions = nil; isPreparing = false; error = nil
    }
    deinit { task?.cancel() }
}

@MainActor
final class VideoDraftSurface: NSView {
    var onWindowClose: (@MainActor () -> Void)?
    private var windowCloseObserver: NSObjectProtocol?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowCloseObserver { NotificationCenter.default.removeObserver(windowCloseObserver) }
        windowCloseObserver = nil
        if let window {
            windowCloseObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                object: window, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.onWindowClose?() }
                }
        }
    }
    deinit { if let windowCloseObserver { NotificationCenter.default.removeObserver(windowCloseObserver) } }
}

@MainActor
struct VideoPlaybackPreviewView: View {
    @ObservedObject var preview: VideoPlaybackPreview
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("效果预览").font(.headline)
                if preview.isPreparing { ProgressView().controlSize(.small) }
            }
            VideoDraftSurfaceView(preview: preview)
                .aspectRatio(16.0 / 10.0, contentMode: .fit)
                .background(Color.black.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text("调参数只更新此预览；保存并应用后才更新屏幕。预览始终静音。")
                .font(.caption).foregroundStyle(.secondary)
            if let error = preview.error { Text("预览失败：" + error).font(.caption).foregroundStyle(.red) }
        }
    }
}

private struct VideoDraftSurfaceView: NSViewRepresentable {
    let preview: VideoPlaybackPreview
    func makeNSView(context: Context) -> NSView { preview.surface }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
