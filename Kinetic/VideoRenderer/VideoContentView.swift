import AppKit
import AVFoundation

/// 只负责显示；播放决策由持有 Renderer 的调用方发出。
@MainActor
final class VideoContentView: NSView {
    let playerLayer = AVPlayerLayer()
    private let posterLayer = CALayer()
    private(set) var hasPoster = false

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
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        posterLayer.frame = bounds
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    func setPoster(_ image: CGImage) {
        posterLayer.contents = image
        hasPoster = true
    }

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
    }
}
