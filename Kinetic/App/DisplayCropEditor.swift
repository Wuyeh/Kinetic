import AppKit
import AVFoundation
import KineticSceneRuntime

/// 显示器 › 显示方式 › 自定义（用户 2026-10-08）：完整比例的壁纸上，居中固定一个显示器比例的圆角光圈，
/// 光圈内正常显示、光圈外调暗。只有底下的壁纸移动：拖动、双指滑动（各方向 1:1 跟手）、双指捏合缩放；
/// 壁纸边缘不能进入光圈，光圈内始终铺满。静置 5 秒光圈外渐隐，再操作时渐显。
/// 改动实时写入显示器页草稿（缩略图跟着变），点「应用」才到桌面。
@MainActor
final class DisplayCropEditorWindow: NSObject, NSWindowDelegate {
    static let shared = DisplayCropEditorWindow()
    private var window: NSWindow?
    private var cropView: DisplayCropEditorView?
    private var displayID: DisplayID?
    private var wallpaperID: Wallpaper.ID?
    private var loading: Task<Void, Never>?
    private var token: UUID?

    var isOpen: Bool { window != nil }

    func open(displayID: DisplayID, wallpaper: Wallpaper, displayName: String, displayAspect: CGFloat,
              frame: CustomDisplayFrame, sceneValues: [String: ScenePropertyValue],
              onChange: @escaping (CustomDisplayFrame) -> Void) {
        if let window, self.displayID == displayID, wallpaperID == wallpaper.id {
            cropView?.onChange = onChange
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        close()
        let token = UUID()
        self.token = token; self.displayID = displayID; wallpaperID = wallpaper.id
        loading = Task { @MainActor [weak self] in
            let aspect = await Self.contentAspect(of: wallpaper) ?? 16 / 9
            guard let self, self.token == token, !Task.isCancelled else { return }
            self.show(title: displayName, displayAspect: displayAspect, contentAspect: aspect, frame: frame, onChange: onChange)
            do {
                let image = try await Self.image(of: wallpaper, contentAspect: aspect, sceneValues: sceneValues)
                guard self.token == token else { return }
                self.cropView?.setImage(image)
            } catch {
                guard self.token == token, !(error is CancellationError) else { return }
                self.cropView?.showError(error.localizedDescription)
            }
        }
    }

    /// 这块屏幕的草稿换了壁纸或不再是「自定义」时关闭（`wallpaperID` 为 nil 表示不再是自定义）。
    func closeIfStale(on displayID: DisplayID, wallpaperID: Wallpaper.ID?) {
        guard self.displayID == displayID, self.wallpaperID != wallpaperID else { return }
        close()
    }
    func close(on displayID: DisplayID) {
        guard self.displayID == displayID else { return }
        close()
    }
    func close() {
        let closing = window
        finish()
        closing?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        finish()
    }

    private func finish() {
        token = nil; loading?.cancel(); loading = nil
        cropView?.flush(); cropView?.onChange = nil; cropView = nil
        window?.delegate = nil; window = nil
        displayID = nil; wallpaperID = nil
    }

    private func show(title: String, displayAspect: CGFloat, contentAspect: CGFloat, frame: CustomDisplayFrame,
                      onChange: @escaping (CustomDisplayFrame) -> Void) {
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let maximum = CGSize(width: min(1440, visible.width * 0.85), height: min(960, visible.height * 0.85))
        let size = DisplayCropGeometry.windowContentSize(displayAspect: displayAspect, contentAspect: contentAspect,
                                                         maximum: maximum)
        let view = DisplayCropEditorView(displayAspect: displayAspect, contentAspect: contentAspect, frame: frame)
        view.onChange = onChange
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = String(format: NSLocalizedString("displayCrop.title", comment: ""), title)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.delegate = self
        window.center()
        self.window = window; cropView = view
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
    }

    /// 画面比例：视频按轨道（含旋转），场景按场景文件里的画布尺寸。读不到时由调用方用 16:9。
    private static func contentAspect(of wallpaper: Wallpaper) async -> CGFloat? {
        switch wallpaper.type {
        case .video:
            let asset = AVURLAsset(url: wallpaper.resourceURL)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) else { return nil }
            let shown = CGRect(origin: .zero, size: size).applying(transform).size
            let width = abs(shown.width), height = abs(shown.height)
            return width > 0 && height > 0 ? width / height : nil
        case .scene:
            let root = wallpaper.resourceURL
            let size = await Task.detached(priority: .userInitiated) { KineticSceneRuntime.canvasSize(root: root) }.value
            return size.map { $0.width / $0.height }
        case .web:
            return nil
        }
    }

    /// 窗口里显示的完整比例静态画面。场景用当前草稿的参数单独准备一份（静音、不进桌面），截图后立即释放。
    private static func image(of wallpaper: Wallpaper, contentAspect: CGFloat,
                              sceneValues: [String: ScenePropertyValue]) async throws -> CGImage {
        switch wallpaper.type {
        case .video:
            let asset = AVURLAsset(url: wallpaper.resourceURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 2560, height: 2560)
            let duration = try await asset.load(.duration)
            // 避开片头可能的黑场。
            let time = duration.seconds.isFinite && duration.seconds > 2 ? CMTime(seconds: 1, preferredTimescale: 600) : .zero
            return try await withTaskCancellationHandler {
                try await generator.image(at: time).image
            } onCancel: { generator.cancelAllCGImageGeneration() }
        case .scene:
            let renderer = SceneRenderer(wallpaper: wallpaper, engineAssets: SceneRenderer.engineAssetsProvider?(),
                                         dependencyFolders: SceneRenderer.dependencyFolders(for: wallpaper),
                                         propertyValues: sceneValues, participatesInGlobalDisplayFit: false)
            let width: CGFloat = 1600
            renderer.displayView.frame = CGRect(x: 0, y: 0, width: width, height: (width / max(0.1, contentAspect)).rounded())
            do {
                try await renderer.prepare()
                renderer.setMuted(true)
                var image = renderer.scene.preparedFrame
                if renderer.scene.usesFullEngine {
                    // 让片头渐入走完一点再截图。
                    renderer.play()
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    image = await renderer.scene.capturePreviewFrame() ?? image
                }
                await renderer.scene.disposeAwaitingResources()
                guard let image else { throw DisplayCropEditorError.noImage }
                return image
            } catch {
                await renderer.scene.disposeAwaitingResources()
                throw error
            }
        case .web:
            throw DisplayCropEditorError.noImage
        }
    }
}

enum DisplayCropEditorError: LocalizedError {
    case noImage
    var errorDescription: String? { NSLocalizedString("displayCrop.error.noImage", comment: "") }
}

/// 光圈与壁纸的几何关系（视图坐标，左下角为原点）。光圈固定，只有壁纸的矩形随范围改变。
struct DisplayCropGeometry: Equatable {
    static let margin: CGFloat = 44
    var bounds: CGRect
    var displayAspect: CGFloat
    var contentAspect: CGFloat

    private var displayRatio: CGFloat { displayAspect.isFinite && displayAspect > 0 ? displayAspect : 16 / 10 }
    private var contentRatio: CGFloat { contentAspect.isFinite && contentAspect > 0 ? contentAspect : 16 / 9 }

    /// 居中的显示器比例光圈；范围为 1 时整幅壁纸刚好放进窗口（四周留 `margin`）。
    var aperture: CGRect {
        let available = bounds.insetBy(dx: Self.margin, dy: Self.margin)
        guard available.width > 1, available.height > 1 else {
            return CGRect(x: bounds.midX - 0.5, y: bounds.midY - 0.5, width: 1, height: 1)
        }
        let wide = max(1, contentRatio / displayRatio), tall = max(1, displayRatio / contentRatio)
        let width = min(available.width / wide, available.height * displayRatio / tall)
        let height = width / displayRatio
        return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
    }
    /// 范围为 1 时壁纸的尺寸：刚好盖住光圈。
    var coverSize: CGSize {
        let aperture = aperture
        return contentRatio > displayRatio
            ? CGSize(width: aperture.height * contentRatio, height: aperture.height)
            : CGSize(width: aperture.width, height: aperture.width / contentRatio)
    }

    /// 缩放在 1…最大之间，中心点让光圈留在壁纸以内。
    func clamped(_ frame: CustomDisplayFrame) -> CustomDisplayFrame {
        let zoom = frame.zoom.isFinite ? min(CustomDisplayFrame.maximumZoom, max(1, frame.zoom)) : 1
        let aperture = aperture, cover = coverSize
        let halfX = Double(aperture.width / (2 * cover.width)) / zoom
        let halfY = Double(aperture.height / (2 * cover.height)) / zoom
        func center(_ value: Double, _ half: Double) -> Double {
            let value = value.isFinite ? value : 0.5
            return min(max(value, min(half, 0.5)), max(1 - half, 0.5))
        }
        return CustomDisplayFrame(zoom: zoom, centerX: center(frame.centerX, halfX), centerY: center(frame.centerY, halfY))
    }
    func contentRect(for frame: CustomDisplayFrame) -> CGRect {
        let frame = clamped(frame), aperture = aperture, cover = coverSize
        let size = CGSize(width: cover.width * frame.zoom, height: cover.height * frame.zoom)
        return CGRect(x: aperture.midX - frame.centerX * size.width, y: aperture.midY - (1 - frame.centerY) * size.height,
                      width: size.width, height: size.height)
    }
    func frame(forContentRect rect: CGRect) -> CustomDisplayFrame {
        let aperture = aperture, cover = coverSize
        guard rect.width > 0, rect.height > 0, cover.width > 0 else { return CustomDisplayFrame() }
        return clamped(CustomDisplayFrame(zoom: Double(rect.width / cover.width),
                                          centerX: Double((aperture.midX - rect.minX) / rect.width),
                                          centerY: Double(1 - (aperture.midY - rect.minY) / rect.height)))
    }
    func panned(_ frame: CustomDisplayFrame, by delta: CGVector) -> CustomDisplayFrame {
        self.frame(forContentRect: contentRect(for: frame).offsetBy(dx: delta.dx, dy: delta.dy))
    }
    /// 以 `point` 为中心缩放：手指下的那一点不动（到了边界再由夹紧挪回）。
    func zoomed(_ frame: CustomDisplayFrame, by factor: CGFloat, around point: CGPoint) -> CustomDisplayFrame {
        let current = clamped(frame)
        guard factor.isFinite, factor > 0 else { return current }
        let zoom = min(CustomDisplayFrame.maximumZoom, max(1, current.zoom * Double(factor)))
        let scale = CGFloat(zoom / current.zoom)
        let rect = contentRect(for: current)
        return self.frame(forContentRect: CGRect(x: point.x - (point.x - rect.minX) * scale, y: point.y - (point.y - rect.minY) * scale,
                                                 width: rect.width * scale, height: rect.height * scale))
    }

    /// 让范围为 1 的整幅壁纸加四周留白放进 `maximum` 的窗口内容尺寸。
    static func windowContentSize(displayAspect: CGFloat, contentAspect: CGFloat, maximum: CGSize) -> CGSize {
        let display = displayAspect.isFinite && displayAspect > 0 ? displayAspect : 16 / 10
        let content = contentAspect.isFinite && contentAspect > 0 ? contentAspect : 16 / 9
        // 以光圈宽度为单位的整幅壁纸尺寸。
        let width = max(1, content / display), height = max(1, display / content) / display
        let room = CGSize(width: max(200, maximum.width - 2 * margin), height: max(150, maximum.height - 2 * margin))
        let unit = min(room.width / width, room.height / height, 900)
        return CGSize(width: (unit * width + 2 * margin).rounded(), height: (unit * height + 2 * margin).rounded())
    }
}

@MainActor
final class DisplayCropEditorView: NSView {
    static let cornerRadius: CGFloat = 12
    /// 静置多久后光圈外渐隐（用户要求 5 秒；测试缩短）。
    var idleDelay: TimeInterval = 5 { didSet { if idleTimer != nil { restartIdleTimer() } } }
    var onChange: ((CustomDisplayFrame) -> Void)?
    private(set) var value: CustomDisplayFrame
    private(set) var isOutsideHidden = false
    private let displayAspect: CGFloat
    private var contentAspect: CGFloat
    private let imageLayer = CALayer()
    private let dimLayer = CAShapeLayer()
    private let hideLayer = CAShapeLayer()
    private let ringLayer = CAShapeLayer()
    private let spinner = NSProgressIndicator()
    private let message = NSTextField(wrappingLabelWithString: "")
    private var idleTimer: Timer?
    private var commitScheduled = false
    private var dragLocation: CGPoint?

    var geometry: DisplayCropGeometry {
        DisplayCropGeometry(bounds: bounds, displayAspect: displayAspect, contentAspect: contentAspect)
    }

    init(displayAspect: CGFloat, contentAspect: CGFloat, frame value: CustomDisplayFrame) {
        self.displayAspect = displayAspect; self.contentAspect = contentAspect; self.value = value
        super.init(frame: CGRect(x: 0, y: 0, width: 640, height: 400))
        wantsLayer = true
        layer?.masksToBounds = true
        imageLayer.contentsGravity = .resize
        imageLayer.minificationFilter = .trilinear
        for shape in [dimLayer, hideLayer] { shape.fillRule = .evenOdd }
        dimLayer.fillColor = NSColor.black.withAlphaComponent(0.55).cgColor
        hideLayer.opacity = 0
        ringLayer.fillColor = nil
        ringLayer.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        ringLayer.lineWidth = 2
        ringLayer.shadowColor = NSColor.black.cgColor
        ringLayer.shadowOpacity = 0.35
        ringLayer.shadowRadius = 6
        ringLayer.shadowOffset = .zero
        for sublayer in [imageLayer, dimLayer, hideLayer, ringLayer] { layer?.addSublayer(sublayer) }
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
        message.alignment = .center
        message.textColor = .secondaryLabelColor
        message.isHidden = true
        addSubview(spinner); addSubview(message)
        spinner.startAnimation(nil)
        updateColors()
        restartIdleTimer()
    }
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setImage(_ image: CGImage) {
        spinner.stopAnimation(nil); message.isHidden = true
        if image.width > 0, image.height > 0 { contentAspect = CGFloat(image.width) / CGFloat(image.height) }
        imageLayer.contents = image
        value = geometry.clamped(value)
        layoutLayers()
    }
    func showError(_ text: String) {
        spinner.stopAnimation(nil)
        message.stringValue = text; message.isHidden = false
        needsLayout = true
    }
    /// 关闭窗口前把最后的范围写回草稿。
    func flush() {
        guard commitScheduled else { return }
        commitScheduled = false
        onChange?(value)
    }

    override func layout() {
        super.layout()
        layoutLayers()
        let aperture = geometry.aperture
        spinner.sizeToFit()
        spinner.frame.origin = CGPoint(x: aperture.midX - spinner.frame.width / 2, y: aperture.midY - spinner.frame.height / 2)
        message.preferredMaxLayoutWidth = max(100, aperture.width - 40)
        let size = message.fittingSize
        message.frame = CGRect(x: aperture.midX - size.width / 2, y: aperture.midY - size.height / 2, width: size.width, height: size.height)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    private func layoutLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let geometry = geometry, aperture = geometry.aperture
        imageLayer.frame = geometry.contentRect(for: value)
        let ring = CGPath(roundedRect: aperture, cornerWidth: Self.cornerRadius, cornerHeight: Self.cornerRadius, transform: nil)
        let outside = CGMutablePath()
        outside.addRect(bounds); outside.addPath(ring)
        for shape in [dimLayer, hideLayer] { shape.frame = bounds; shape.path = outside }
        ringLayer.frame = bounds; ringLayer.path = ring
        CATransaction.commit()
    }
    private func updateColors() {
        var background = NSColor.windowBackgroundColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { background = NSColor.windowBackgroundColor.cgColor }
        layer?.backgroundColor = background
        hideLayer.fillColor = background
    }

    // MARK: Interaction

    override func mouseDown(with event: NSEvent) {
        dragLocation = convert(event.locationInWindow, from: nil)
        // 按住不放也算在操作。
        idleTimer?.invalidate(); idleTimer = nil
        setOutsideHidden(false)
        NSCursor.closedHand.push()
    }
    override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if let last = dragLocation {
            update(geometry.panned(value, by: CGVector(dx: location.x - last.x, dy: location.y - last.y)))
        }
        dragLocation = location
    }
    override func mouseUp(with event: NSEvent) {
        guard dragLocation != nil else { return }
        dragLocation = nil
        NSCursor.pop()
        restartIdleTimer()
    }
    /// 双指滑动：任何方向都按手指移动的距离 1:1 移动壁纸（与系统「自然滚动」设置无关，壁纸总是跟着手指）。
    override func scrollWheel(with event: NSEvent) {
        var delta = CGVector(dx: event.scrollingDeltaX, dy: -event.scrollingDeltaY)
        if event.hasPreciseScrollingDeltas {
            if !event.isDirectionInvertedFromDevice { delta = CGVector(dx: -delta.dx, dy: -delta.dy) }
        } else {
            delta = CGVector(dx: delta.dx * 10, dy: delta.dy * 10)
        }
        guard delta.dx != 0 || delta.dy != 0 else { return }
        interacted()
        update(geometry.panned(value, by: delta))
    }
    /// 双指捏合：以手指位置为中心缩放。
    override func magnify(with event: NSEvent) {
        interacted()
        update(geometry.zoomed(value, by: 1 + event.magnification, around: convert(event.locationInWindow, from: nil)))
    }
    override func cancelOperation(_ sender: Any?) { window?.performClose(sender) }

    private func update(_ next: CustomDisplayFrame) {
        guard next != value else { return }
        value = next
        layoutLayers()
        scheduleCommit()
    }
    /// 草稿与缩略图最多每秒更新 30 次，窗口里的壁纸每个事件都跟着动。
    private func scheduleCommit() {
        guard !commitScheduled else { return }
        commitScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 30) { [weak self] in
            guard let self, self.commitScheduled else { return }
            self.commitScheduled = false
            self.onChange?(self.value)
        }
    }
    private func interacted() {
        setOutsideHidden(false)
        if dragLocation == nil { restartIdleTimer() }
    }
    private func restartIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: idleDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.setOutsideHidden(true) }
        }
    }
    /// 光圈外的壁纸、调暗层与光圈线一起渐隐 / 渐显；光圈内不变。
    func setOutsideHidden(_ hidden: Bool) {
        guard hidden != isOutsideHidden else { return }
        isOutsideHidden = hidden
        CATransaction.begin()
        CATransaction.setAnimationDuration(hidden ? 0.8 : 0.3)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        hideLayer.opacity = hidden ? 1 : 0
        ringLayer.opacity = hidden ? 0 : 1
        CATransaction.commit()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { idleTimer?.invalidate(); idleTimer = nil }
    }
}
