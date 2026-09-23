import AppKit

/// 桌面窗口内的固定舞台。最底层始终是完全不透明的当前壁纸，
/// 新壁纸只在其上方淡入；舞台本身透明，不绘制任何黑色背景。
@MainActor
final class CrossfadeStageView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        autoresizesSubviews = true
    }

    required init?(coder: NSCoder) { nil }

    override var isOpaque: Bool { false }

    /// 由下到上的壁纸内容（每个内容各自位于一个舞台容器中）。
    var contents: [NSView] { subviews.compactMap { $0.subviews.first } }
    /// 最上层的内容，即当前（或正在淡入的）壁纸。
    var topContent: NSView? { contents.last }

    func slot(containing content: NSView) -> NSView? {
        guard let slot = content.superview, slot.superview === self else { return nil }
        return slot
    }

    /// 内容放入舞台自有的透明容器；淡入只作用于容器，不依赖 Renderer 视图自身的图层实现。
    @discardableResult
    func install(_ content: NSView, alpha: CGFloat) -> NSView {
        let slot = NSView(frame: bounds)
        slot.wantsLayer = true
        slot.autoresizingMask = [.width, .height]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        slot.alphaValue = alpha
        CATransaction.commit()
        content.frame = slot.bounds
        content.autoresizingMask = [.width, .height]
        slot.addSubview(content)
        addSubview(slot, positioned: .above, relativeTo: nil)
        return slot
    }

    /// 内容先离开容器，再移除容器；调用方随后才能安全释放对应 Renderer。
    func remove(_ content: NSView) {
        let slot = self.slot(containing: content)
        content.removeFromSuperview()
        slot?.removeFromSuperview()
    }

    func removeAll() {
        for slot in subviews {
            slot.layer?.removeAllAnimations()
            slot.subviews.forEach { $0.removeFromSuperview() }
            slot.removeFromSuperview()
        }
    }
}

/// Crossfade Engine。
/// 包装桌面窗口：A 保持完全显示，B 首帧就绪后在 A 上方淡入，
/// 淡入完成后先把 A 移出窗口，再通知调用方释放 A。任何时刻底层都有完整画面，不出现黑帧。
/// 不决定播放状态，不创建或释放 Renderer；这些仍由 WallpaperRuntimeManager 负责。
@MainActor
final class CrossfadeDesktopHost: DesktopContentHost {
    /// 交叉淡化时长（300–400ms）。
    nonisolated static let standardDuration: TimeInterval = 0.35

    let duration: TimeInterval
    let stage = CrossfadeStageView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))

    /// 仅供诊断与测试读取。
    private(set) var completedTransitionCount = 0
    private(set) var lastTransitionDuration: TimeInterval?
    var isTransitioning: Bool { pending != nil }

    private struct PendingTransition {
        let token: Int
        let incoming: NSView
        let incomingSlot: NSView
        let outgoing: NSView
        let startedAt: TimeInterval
        let completion: @MainActor () -> Void
    }

    private let desktop: DesktopContentHost
    private var pending: PendingTransition?
    private var nextToken = 0
    private var isStagePresented = false
    private var lastPresentResult = false

    init(desktop: DesktopContentHost, duration: TimeInterval = CrossfadeDesktopHost.standardDuration) {
        self.desktop = desktop
        self.duration = duration
    }

    /// 没有旧内容时（首次应用、重新启用）直接显示，不做淡入。
    @discardableResult
    func present(_ contentView: NSView) -> Bool {
        finishPendingTransitionImmediately()
        for content in stage.contents where content !== contentView { stage.remove(content) }
        if let slot = stage.slot(containing: contentView) {
            setAlpha(slot, 1)
        } else {
            stage.install(contentView, alpha: 1)
        }
        return presentStageIfNeeded()
    }

    @discardableResult
    func transition(to contentView: NSView, completion: @escaping @MainActor () -> Void) -> Bool {
        // 上一次淡入尚未结束：立即完成它（B 已完全不透明，A 被移出并释放），再开始新的。
        finishPendingTransitionImmediately()
        guard duration > 0, let outgoing = stage.topContent, outgoing !== contentView else {
            let shown = present(contentView)
            completion()
            return shown
        }

        // 先以透明度 0 放在 A 之上，同一轮提交中开始动画，B 不会先闪现。
        let slot = stage.install(contentView, alpha: 0)
        let shown = presentStageIfNeeded()

        nextToken += 1
        let token = nextToken
        pending = PendingTransition(token: token, incoming: contentView, incomingSlot: slot, outgoing: outgoing,
                                    startedAt: ProcessInfo.processInfo.systemUptime, completion: completion)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            slot.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in self?.finishTransition(token) }
        })
        // 兜底：即使系统没有回调动画完成（例如显示器休眠），A 也一定会被移出并释放。
        let fallback = duration + 0.5
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(fallback * 1_000_000_000))
            self?.finishTransition(token)
        }
        return shown
    }

    /// 先移出所有内容并关闭桌面窗口（恢复原生壁纸），再通知调用方释放淡出中的旧壁纸。
    func stop() {
        let interrupted = pending
        pending = nil
        stage.removeAll()
        desktop.stop()
        isStagePresented = false
        lastPresentResult = false
        interrupted?.completion()
    }

    private func presentStageIfNeeded() -> Bool {
        guard !isStagePresented else { return lastPresentResult }
        isStagePresented = true
        lastPresentResult = desktop.present(stage)
        return lastPresentResult
    }

    private func finishTransition(_ token: Int) {
        guard let transition = pending, transition.token == token else { return }
        complete(transition)
    }

    private func finishPendingTransitionImmediately() {
        guard let transition = pending else { return }
        transition.incomingSlot.layer?.removeAllAnimations()
        complete(transition)
    }

    private func complete(_ transition: PendingTransition) {
        pending = nil
        // B 此时已完全不透明，移出 A 不会露出任何空白。
        setAlpha(transition.incomingSlot, 1)
        stage.remove(transition.outgoing)
        completedTransitionCount += 1
        lastTransitionDuration = ProcessInfo.processInfo.systemUptime - transition.startedAt
        transition.completion()
    }

    private func setAlpha(_ view: NSView, _ alpha: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.alphaValue = alpha
        CATransaction.commit()
    }
}
