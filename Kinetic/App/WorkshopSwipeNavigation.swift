import AppKit
import SwiftUI

/// Workshop 两指左右滑动（用户 2026-10-08，参考 Safari）：当前页跟着手指平移，松手越过阈值就沿手指方向
/// 滑出窗口，再加载停留过的上一页 / 下一页；没有可去的页时那个方向完全不动。只认触控板的连续滚动事件。
@MainActor
final class WorkshopSwipeNavigator: ObservableObject {
    enum Direction: Equatable { case back, forward }
    struct Request: Equatable {
        let direction: Direction
        let id = UUID()
    }

    /// 与 Safari 相同：手指向右是后退，向左是前进。
    static let backDirectionSign: CGFloat = 1
    /// 松手时超过宽度的这一比例，或快速甩动，就完成翻页。
    static let completionFraction: CGFloat = 0.25
    static let flickVelocity: CGFloat = 800
    static let slideDuration: TimeInterval = 0.22

    /// 当前页的水平位移（点），正值向右。
    @Published private(set) var offset: CGFloat = 0
    /// 当前页已滑出、新页还没换上时为 true（视图在这段时间隐藏旧内容）。
    @Published private(set) var isCovered = false
    /// 视图收到后执行翻页，然后调用 `didNavigate()`。
    @Published private(set) var request: Request?
    var canGo: (Direction) -> Bool = { _ in false }
    var reduceMotion = false
    private(set) var isTracking = false

    private enum Tracking: Equatable { case idle, deciding(CGVector), swiping, ignoring, finishing }
    private var tracking = Tracking.idle { didSet { isTracking = !(tracking == .idle) } }
    private var width: CGFloat = 800
    private var velocity: CGFloat = 0
    private var lastTime: TimeInterval?
    private var lastMoveTime: TimeInterval?

    /// 本地事件监视器调用。返回 true 表示这个事件属于翻页手势，不再交给滚动视图。
    func handle(_ event: NSEvent, width: CGFloat) -> Bool {
        guard event.hasPreciseScrollingDeltas else { return false }
        // 换算成手指的移动方向（与系统「自然滚动」设置无关）。
        let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        return handle(phase: event.phase, momentumPhase: event.momentumPhase,
                      fingerDelta: CGVector(dx: event.scrollingDeltaX * sign, dy: event.scrollingDeltaY * sign),
                      time: event.timestamp, width: width)
    }

    func handle(phase: NSEvent.Phase, momentumPhase: NSEvent.Phase, fingerDelta: CGVector, time: TimeInterval, width: CGFloat) -> Bool {
        if phase.isEmpty {
            // 松手后的惯性：属于刚完成的翻页手势就吞掉，其余照常滚动。
            guard case .finishing = tracking else { return false }
            if momentumPhase.contains(.ended) || momentumPhase.contains(.cancelled) { tracking = .idle }
            return true
        }
        if phase.contains(.mayBegin) { return false }
        if phase.contains(.began) {
            tracking = isCovered || request != nil ? .ignoring : .deciding(.zero)
            velocity = 0; lastTime = time; lastMoveTime = time
            if width > 0 { self.width = width }
        }
        switch tracking {
        case .deciding(let total):
            let sum = CGVector(dx: total.dx + fingerDelta.dx, dy: total.dy + fingerDelta.dy)
            let ended = phase.contains(.ended) || phase.contains(.cancelled)
            guard hypot(sum.dx, sum.dy) >= 4, !ended else {
                tracking = ended ? .idle : .deciding(sum)
                return false
            }
            guard abs(sum.dx) > abs(sum.dy) * 1.2, canGo(direction(for: sum.dx)) else {
                tracking = .ignoring
                return false
            }
            tracking = .swiping
            setOffset(clamped(sum.dx))
            return true
        case .swiping:
            if fingerDelta.dx != 0, let lastTime, time > lastTime {
                velocity = velocity * 0.4 + fingerDelta.dx / CGFloat(time - lastTime) * 0.6
                lastMoveTime = time
            }
            lastTime = time
            setOffset(clamped(offset + fingerDelta.dx))
            if phase.contains(.ended) || phase.contains(.cancelled) {
                // 停住再松手不算甩动。
                if time - (lastMoveTime ?? time) > 0.08 { velocity = 0 }
                finish(cancelled: phase.contains(.cancelled))
                tracking = .finishing
            }
            return true
        case .ignoring:
            if phase.contains(.ended) || phase.contains(.cancelled) { tracking = .idle }
            return false
        case .finishing, .idle:
            return false
        }
    }

    /// 视图完成翻页（新页的内容已在原位）后调用：新页淡入。
    func didNavigate() {
        request = nil
        offset = 0
        if reduceMotion { isCovered = false }
        else { withAnimation(.easeOut(duration: 0.15)) { isCovered = false } }
    }

    private func direction(for dx: CGFloat) -> Direction {
        dx * Self.backDirectionSign > 0 ? .back : .forward
    }
    /// 只能往有页的方向移动；最多移出一个宽度。
    private func clamped(_ value: CGFloat) -> CGFloat {
        let back = canGo(.back) ? width : 0, forward = canGo(.forward) ? width : 0
        let right = Self.backDirectionSign > 0 ? back : forward, left = Self.backDirectionSign > 0 ? forward : back
        return min(right, max(-left, value))
    }
    private func setOffset(_ value: CGFloat) {
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) { offset = value }
    }
    private func finish(cancelled: Bool) {
        let distance = abs(offset)
        let flicked = abs(velocity) > Self.flickVelocity && velocity * offset > 0 && distance > 40
        guard !cancelled, distance > 0, distance > width * Self.completionFraction || flicked else {
            if reduceMotion { offset = 0 } else { withAnimation(.easeOut(duration: 0.18)) { offset = 0 } }
            return
        }
        let direction = direction(for: offset), target = offset > 0 ? width : -width
        if reduceMotion { offset = target; complete(direction); return }
        withAnimation(.easeOut(duration: Self.slideDuration)) { offset = target }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.slideDuration * 1_000_000_000))
            self?.complete(direction)
        }
    }
    /// 当前页已滑出窗口：遮住它，请视图换成停留过的页。
    private func complete(_ direction: Direction) {
        isCovered = true
        request = Request(direction: direction)
    }
}

/// 在主窗口内容区（Workshop 页所在的滚动视图）上接收两指滚动；只看事件，不拦截点按。
struct WorkshopSwipeArea: NSViewRepresentable {
    let navigator: WorkshopSwipeNavigator
    func makeNSView(context: Context) -> MonitorView { MonitorView(navigator: navigator) }
    func updateNSView(_ view: MonitorView, context: Context) { view.navigator = navigator }
    static func dismantleNSView(_ view: MonitorView, coordinator: ()) { view.removeMonitor() }

    final class MonitorView: NSView {
        weak var navigator: WorkshopSwipeNavigator?
        private var monitor: Any?
        init(navigator: WorkshopSwipeNavigator) {
            self.navigator = navigator
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handle(event) ?? event
            }
        }
        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let navigator, let window, event.window === window, !isHiddenOrHasHiddenAncestor else { return event }
            let area: NSView = enclosingScrollView ?? self
            // 手势开始时指针要在内容区里；进行中的手势一直跟到结束。
            if !navigator.isTracking {
                let point = area.convert(event.locationInWindow, from: nil)
                guard area.visibleRect.contains(point) else { return event }
            }
            return navigator.handle(event, width: area.visibleRect.width) ? nil : event
        }
    }
}
