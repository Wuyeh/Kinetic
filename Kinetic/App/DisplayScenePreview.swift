import AppKit
import Combine
import KineticSceneRuntime

/// One silent, display-sized preview, never a second desktop surface. Superseded
/// hosts finish releasing before the replacement allocates, including rapid edits.
@MainActor
final class DisplayScenePreview: ObservableObject {
    let surface = VideoDraftSurface(frame: .init(x: 0, y: 0, width: 320, height: 200))
    @Published private(set) var isPreparing = false
    @Published private(set) var error: String?
    private(set) var renderer: SceneRenderer?
    private var values: [String: ScenePropertyValue] = [:]
    private var requestedWallpaperID: Wallpaper.ID?
    private var requestedFit: SceneDisplayFitSetting?
    private var requestedFrame: CustomDisplayFrame?
    private var requestedValues: [String: ScenePropertyValue]?
    private var task: Task<Void, Never>?
    private var retirement: Task<Void, Never>?
    private var generation = UUID()

    init() {
        surface.wantsLayer = true
        surface.layer?.contentsGravity = .resizeAspect
        surface.onWindowClose = { [weak self] in self?.stop() }
    }

    func update(_ wallpaper: Wallpaper, values: [String: ScenePropertyValue], fit: SceneDisplayFitSetting,
                frame: CustomDisplayFrame? = nil, aspect: CGFloat) {
        // 只改了「自定义」显示范围：跟着拖动立即更新正在显示的场景；准备中的场景完成时读取最新范围。
        if requestedWallpaperID == wallpaper.id, requestedValues == values, requestedFit == fit, error == nil {
            guard requestedFrame != frame else { return }
            requestedFrame = frame
            if let current = renderer, current.wallpaper.id == wallpaper.id { current.applyDisplay(fit, frame: frame) }
            return
        }
        let token = UUID(); generation = token
        requestedWallpaperID = wallpaper.id; requestedValues = values; requestedFit = fit; requestedFrame = frame
        task?.cancel(); error = nil; isPreparing = true
        task = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 80_000_000)
                guard let self, self.generation == token else { return }
                if let current = self.renderer, current.wallpaper.id == wallpaper.id {
                    // The host compares its committed values, including a superseded edit that
                    // completed before cancellation. A UI-side stale equality must not skip the revert.
                    let updated = try await current.scene.updatePropertyValues(values)
                    guard self.generation == token, !Task.isCancelled, self.renderer === current else { return }
                    if updated {
                        current.applyDisplay(fit, frame: self.requestedFrame)
                        self.values = values; self.isPreparing = false; self.task = nil; return
                    }
                    // Not continuously previewable: restart this wallpaper from the beginning with the
                    // new values below, showing its last frame meanwhile (user decision 2026-10-08).
                }
                // A different wallpaper, or an edit the running host cannot take, replaces the host.
                try Task.checkCancellation()
                guard self.generation == token else { return }
                if let old = self.renderer {
                    old.pause(); old.onFailure = nil
                    let frame = await old.scene.capturePreviewFrame()
                    try Task.checkCancellation()
                    guard self.generation == token, self.renderer === old else { return }
                    self.surface.layer?.contents = frame
                    let oldRetirement = self.retirement
                    let retiring = Task { @MainActor in
                        await oldRetirement?.value
                        await old.scene.disposeAwaitingResources()
                    }
                    self.retirement = retiring; self.renderer = nil
                    await retiring.value
                } else { await self.retirement?.value }
                try Task.checkCancellation()
                guard self.generation == token else { return }
                let candidate = SceneRenderer(wallpaper: wallpaper, engineAssets: SceneRenderer.engineAssetsProvider?(),
                    dependencyFolders: SceneRenderer.dependencyFolders(for: wallpaper), propertyValues: values,
                    participatesInGlobalDisplayFit: false)
                candidate.applyDisplay(fit, frame: self.requestedFrame)
                candidate.displayView.frame = CGRect(x: 0, y: 0, width: 320, height: 320 / max(0.1, aspect))
                self.renderer = candidate
                do {
                    try await candidate.prepare(); try Task.checkCancellation()
                    guard self.generation == token else { throw CancellationError() }
                    await candidate.scene.setPreviewFrameRateCeiling(30)
                    candidate.setMuted(true)
                    candidate.displayView.frame = self.surface.bounds
                    candidate.displayView.autoresizingMask = [.width, .height]
                    self.surface.addSubview(candidate.displayView)
                    // Retired hosts' views stay until the replacement covers them, then leave.
                    for view in self.surface.subviews where view !== candidate.displayView { view.removeFromSuperview() }
                    candidate.onFailure = { [weak self, weak candidate] error in
                        guard let self, let candidate, self.renderer === candidate else { return }
                        self.error = error.localizedDescription
                    }
                    candidate.play(); self.surface.layer?.contents = nil
                    self.values = values; self.isPreparing = false; self.task = nil
                } catch {
                    if self.renderer === candidate { self.renderer = nil }
                    let retiring = Task { @MainActor in await candidate.scene.disposeAwaitingResources() }
                    self.retirement = retiring
                    await retiring.value
                    throw error
                }
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.error = error.localizedDescription; self.isPreparing = false; self.task = nil
            }
        }
    }

    func stop() {
        generation = UUID(); task?.cancel(); task = nil
        if let renderer {
            renderer.pause(); renderer.onFailure = nil; renderer.displayView.removeFromSuperview()
            let previous = retirement
            retirement = Task { @MainActor in
                await previous?.value
                await renderer.scene.disposeAwaitingResources()
            }
            self.renderer = nil
        }
        requestedWallpaperID = nil; requestedValues = nil; requestedFit = nil; requestedFrame = nil
        surface.layer?.contents = nil
        values = [:]; isPreparing = false; error = nil
    }
    deinit { task?.cancel() }
}
