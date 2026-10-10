import AppKit
import AVFoundation

/// 只负责显示；播放决策由持有 Renderer 的调用方发出。
@MainActor
final class VideoContentView: NSView {
    let playerLayer = AVPlayerLayer()
    private let posterLayer = CALayer()
    private(set) var hasPoster = false
    /// 「自定义」按画面比例计算显示的部分；来自静态帧（与播放画面同一处理管线、同一比例）。
    private var contentSize: CGSize?
    private var fit = VideoPlaybackOptions.DisplayFit.fill
    private var customFrame: CustomDisplayFrame?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = true
        posterLayer.contentsGravity = .resizeAspectFill
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.isHidden = true
        layer?.addSublayer(posterLayer)
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        layoutContent()
    }

    /// 「自定义」时两层放大到整幅画面的尺寸并移动，让选定的部分正好落在视图里；其余方式铺在视图上。
    private func layoutContent() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var frame = bounds
        if fit == .custom, let contentSize, bounds.width > 0, bounds.height > 0 {
            let region = (customFrame ?? CustomDisplayFrame()).region(content: contentSize, viewport: bounds.size)
            let width = bounds.width / region.width, height = bounds.height / region.height
            // 图层坐标以左下角为原点，区域以左上角为原点。
            frame = CGRect(x: -region.minX * width, y: -(1 - region.maxY) * height, width: width, height: height)
        }
        posterLayer.frame = frame
        playerLayer.frame = frame
        CATransaction.commit()
    }

    func setPoster(_ image: CGImage) {
        posterLayer.contents = image
        hasPoster = true
        contentSize = CGSize(width: image.width, height: image.height)
        if fit == .custom { layoutContent() }
    }

    func setDisplayFit(_ fit: VideoPlaybackOptions.DisplayFit, frame: CustomDisplayFrame? = nil) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch fit {
        case .fill, .custom: playerLayer.videoGravity = .resizeAspectFill; posterLayer.contentsGravity = .resizeAspectFill
        case .fit: playerLayer.videoGravity = .resizeAspect; posterLayer.contentsGravity = .resizeAspect
        case .stretch: playerLayer.videoGravity = .resize; posterLayer.contentsGravity = .resize
        }
        CATransaction.commit()
        self.fit = fit; customFrame = frame
        layoutContent()
    }

    var posterGravity: CALayerContentsGravity { posterLayer.contentsGravity }

    func showVideo(_ visible: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.isHidden = !visible
        CATransaction.commit()
    }

    func clear() {
        showVideo(false)
        playerLayer.player = nil
        posterLayer.contents = nil
        hasPoster = false
        contentSize = nil
        layoutContent()
    }
}
