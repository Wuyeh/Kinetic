import AppKit
import AVFoundation

/// 预览内容的容器：只负责裁切与铺满，不接收鼠标事件，也不作为辅助功能元素。
@MainActor
final class LivePreviewContentView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = true
        layer?.cornerCurve = .continuous
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { nil }

    var cornerRadius: CGFloat {
        get { layer?.cornerRadius ?? 0 }
        set { layer?.cornerRadius = newValue }
    }

    override func layout() {
        super.layout()
        layoutPlayerLayers()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutPlayerLayers()
    }

    /// 视频图层跟随预览区域等比例缩放，不重建播放器。
    func layoutPlayerLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sublayer in layer?.sublayers ?? [] where sublayer is AVPlayerLayer {
            sublayer.frame = bounds
        }
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { [] }
}

/// 视频壁纸的卡片内预览：独立的 AVQueuePlayer + AVPlayerLooper，永远静音，从头开始循环。
/// 不复用桌面 VideoRenderer 实例，不接入 Now Playing 或媒体按键，不阻止显示器睡眠。
@MainActor
final class VideoPreviewSession: LivePreviewSession {
    let wallpaperID: Wallpaper.ID
    let url: URL
    private let content = LivePreviewContentView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
    private let playerLayer = AVPlayerLayer()
    private(set) var player: AVQueuePlayer?
    private(set) var looper: AVPlayerLooper?
    private var asset: AVURLAsset?
    private var observations: [NSKeyValueObservation] = []
    private var fallbackTask: Task<Void, Never>?
    private var isInvalidated = false

    private(set) var state: PreviewContentState = .preparing {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    var onStateChange: ((PreviewContentState) -> Void)?
    var contentView: NSView { content }

    init(wallpaper: Wallpaper) {
        wallpaperID = wallpaper.id
        url = wallpaper.resourceURL
    }

    func start() {
        guard !isInvalidated, player == nil else { return }
        let asset = AVURLAsset(url: url)
        let queue = AVQueuePlayer()
        // 预览永远没有声音，也不受全局 Audio 设置影响。
        queue.isMuted = true
        queue.volume = 0
        queue.preventsDisplaySleepDuringVideoPlayback = false
        queue.allowsExternalPlayback = false
        let looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(asset: asset))
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.player = queue
        playerLayer.frame = content.bounds
        content.layer?.addSublayer(playerLayer)
        self.asset = asset
        self.player = queue
        self.looper = looper
        #if DEBUG
        LivePreviewDiagnostics.shared.sessionStarted()
        LivePreviewDiagnostics.shared.track(player: queue)
        #endif

        observations = [
            playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] layer, _ in
                guard layer.isReadyForDisplay else { return }
                Task { @MainActor [weak self] in self?.markPlaying() }
            },
            queue.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                guard player.timeControlStatus == .playing else { return }
                Task { @MainActor [weak self] in self?.scheduleFallbackReveal() }
            },
            queue.observe(\.status, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.checkFailure() }
            },
            looper.observe(\.status, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.checkFailure() }
            },
            queue.observe(\.currentItem?.status, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.checkFailure() }
            }
        ]
        queue.play()
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        onStateChange = nil
        fallbackTask?.cancel()
        fallbackTask = nil
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        player?.pause()
        looper?.disableLooping()
        looper = nil
        player?.removeAllItems()
        playerLayer.player = nil
        playerLayer.removeFromSuperlayer()
        asset?.cancelLoading()
        asset = nil
        player = nil
        content.removeFromSuperview()
        #if DEBUG
        LivePreviewDiagnostics.shared.sessionEnded()
        #endif
    }

    private func markPlaying() {
        guard !isInvalidated, state == .preparing else { return }
        state = .playing
    }

    /// 个别情况下图层就绪通知较晚；播放已经开始时稍后再显示，缩略图始终垫在下面，不会黑屏。
    private func scheduleFallbackReveal() {
        guard !isInvalidated, state == .preparing, fallbackTask == nil else { return }
        fallbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            self?.markPlaying()
        }
    }

    private func checkFailure() {
        guard !isInvalidated, let player else { return }
        if player.status == .failed || looper?.status == .failed || player.currentItem?.status == .failed {
            state = .failed
        }
    }
}
