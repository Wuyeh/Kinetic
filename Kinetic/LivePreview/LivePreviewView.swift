import AppKit
import SwiftUI

/// 叠在静态缩略图上方的 Live Preview 层。准备好之前完全透明（缩略图继续显示），
/// 就绪后轻微淡入；不接收点击，不参与辅助功能，也不改变预览区域的尺寸。
@MainActor
struct LivePreviewLayer: View {
    let preview: WallpaperPreviewCoordinator.ActivePreview
    let cornerRadius: CGFloat
    /// 预览区域不再可见（窗口关闭、最小化、失去前台、滚出可视范围）时调用；只针对这一个会话。
    let onInterrupted: (LivePreviewSession) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            LivePreviewHost(
                contentView: preview.session.contentView,
                isRevealed: preview.state == .playing,
                animatesReveal: !reduceMotion,
                cornerRadius: cornerRadius,
                onInterrupted: { [weak session = preview.session] in
                    if let session { onInterrupted(session) }
                }
            )
            if preview.showsProgress && preview.state == .preparing {
                ProgressView()
                    .controlSize(.small)
                    .padding(MainWindowDesignTokens.Spacing.small)
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 把会话的内容视图放进 SwiftUI。内容由会话持有，SwiftUI 重建视图时只会重新挂载，不会新建播放器。
struct LivePreviewHost: NSViewRepresentable {
    let contentView: NSView
    let isRevealed: Bool
    let animatesReveal: Bool
    let cornerRadius: CGFloat
    let onInterrupted: () -> Void

    func makeNSView(context: Context) -> LivePreviewHostView {
        let view = LivePreviewHostView()
        update(view, animated: false)
        return view
    }

    func updateNSView(_ view: LivePreviewHostView, context: Context) {
        update(view, animated: animatesReveal)
    }

    static func dismantleNSView(_ view: LivePreviewHostView, coordinator: ()) {
        view.releaseContent()
    }

    private func update(_ view: LivePreviewHostView, animated: Bool) {
        view.onInterrupted = onInterrupted
        (contentView as? LivePreviewContentView)?.cornerRadius = cornerRadius
        view.embed(contentView)
        view.setRevealed(isRevealed, animated: animated)
    }
}

@MainActor
final class LivePreviewHostView: NSView {
    var onInterrupted: (() -> Void)?
    private var observedWindow: NSWindow?
    private var observedClipView: NSClipView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        alphaValue = 0
    }

    required init?(coder: NSCoder) { nil }

    func embed(_ content: NSView) {
        guard content.superview !== self else { return }
        subviews.forEach { $0.removeFromSuperview() }
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }

    func releaseContent() {
        stopObserving()
        onInterrupted = nil
        subviews.forEach { $0.removeFromSuperview() }
    }

    /// 缩略图 → 预览 150–200 ms 淡入；“减少动态效果”时直接切换。
    func setRevealed(_ revealed: Bool, animated: Bool) {
        let target: CGFloat = revealed ? 1 : 0
        guard alphaValue != target else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = revealed ? 0.18 : 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                animator().alphaValue = target
            }
        } else {
            alphaValue = target
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { [] }

    // MARK: Visibility

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil, window != nil {
            stopObserving()
            interrupt()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        startObserving(window)
    }

    private func startObserving(_ window: NSWindow) {
        stopObserving()
        observedWindow = window
        let center = NotificationCenter.default
        for name in [
            NSWindow.willCloseNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didChangeOcclusionStateNotification
        ] {
            center.addObserver(self, selector: #selector(windowStateChanged(_:)), name: name, object: window)
        }
        center.addObserver(self, selector: #selector(applicationStateChanged(_:)),
                           name: NSApplication.didResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(applicationStateChanged(_:)),
                           name: NSApplication.didHideNotification, object: nil)
        if let clipView = enclosingScrollView?.contentView {
            clipView.postsBoundsChangedNotifications = true
            observedClipView = clipView
            center.addObserver(self, selector: #selector(scrollBoundsChanged(_:)),
                               name: NSView.boundsDidChangeNotification, object: clipView)
        }
    }

    private func stopObserving() {
        NotificationCenter.default.removeObserver(self)
        observedWindow = nil
        observedClipView = nil
    }

    @objc private func windowStateChanged(_ notification: Notification) {
        guard let window = observedWindow else { return }
        if notification.name == NSWindow.didChangeOcclusionStateNotification,
           window.occlusionState.contains(.visible) {
            return
        }
        interrupt()
    }

    @objc private func applicationStateChanged(_ notification: Notification) {
        interrupt()
    }

    /// 滚动后卡片完全离开可视范围时停止预览。
    @objc private func scrollBoundsChanged(_ notification: Notification) {
        guard let clipView = observedClipView else { return }
        if !convert(bounds, to: clipView).intersects(clipView.bounds) { interrupt() }
    }

    /// 在当前界面更新结束后再通知，避免在 SwiftUI 更新视图的过程中修改状态。
    private func interrupt() {
        guard let callback = onInterrupted else { return }
        DispatchQueue.main.async { callback() }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
