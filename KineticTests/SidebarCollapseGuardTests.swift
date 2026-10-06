import AppKit
import SwiftUI
import XCTest
@testable import Kinetic

/// 侧栏拖到最小宽度后继续往里拉，不能触发整体折叠。
///
/// 拖动用定时器在 NSSplitView 的拖动跟踪循环里逐个投递鼠标事件，模拟真实的慢速拖动：
/// 每一步之间 run loop 照常运行，SwiftUI 可以在拖动中途更新分栏配置。
@MainActor
final class SidebarCollapseGuardTests: XCTestCase {
    private let minimum = MainWindowDesignTokens.Sidebar.minimumWidth
    private let maximum = MainWindowDesignTokens.Sidebar.maximumWidth
    private let detailMinimum = MainWindowDesignTokens.Content.minimumWidth
    private var windows: [NSWindow] = []
    /// 最近一次拖动过程中每一步测得的侧栏可见宽度（折叠 / 隐藏时为 0）。
    private var dragSamples: [CGFloat] = []
    /// 最近一次模拟拖动是否完整送达（被真实鼠标或系统打断时为 false，此时只检查“没有折叠”）。
    private var lastDragCompleted = false

    override func tearDown() async throws {
        windows.forEach { $0.orderOut(nil); $0.close() }
        windows = []
    }

    // MARK: Helpers

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func makeWindow(width: CGFloat = 1_100, height: CGFloat = 700) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -4_000, y: -4_000, width: width, height: height),
                              styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        return window
    }

    private func splitView(in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView, split.delegate is NSSplitViewController { return split }
        for subview in view.subviews {
            if let split = splitView(in: subview) { return split }
        }
        return nil
    }

    private func sidebarPane(of split: NSSplitView) -> NSView? { split.arrangedSubviews.first }

    private func sidebarItem(of split: NSSplitView) -> NSSplitViewItem? {
        guard let controller = split.delegate as? NSSplitViewController else { return nil }
        return controller.splitViewItems.first { $0.behavior == .sidebar } ?? controller.splitViewItems.first
    }

    /// 侧栏在屏幕上的实际宽度；折叠或隐藏时为 0。
    private func visibleSidebarWidth(_ split: NSSplitView) -> CGFloat {
        guard let pane = sidebarPane(of: split), let item = sidebarItem(of: split) else { return 0 }
        if item.isCollapsed || split.isSubviewCollapsed(pane) || pane.isHidden { return 0 }
        return pane.frame.width
    }

    /// 按住分隔条，依次拖到 `xs`（分栏坐标，可为负数，即拖出窗口左侧），最后松开。
    private func slowDrag(_ split: NSSplitView, through xs: [CGFloat], interval: TimeInterval = 0.012) {
        guard let window = split.window, let pane = sidebarPane(of: split) else {
            return XCTFail("分栏尚未放进窗口")
        }
        let y = split.bounds.midY
        func event(_ type: NSEvent.EventType, _ x: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: split.convert(NSPoint(x: x, y: y), to: nil),
                               modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                               clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        }
        final class Step { var index = 0; var samples: [CGFloat] = []; var releasePosted = false }
        let step = Step()
        // CFRunLoopTimer 加在 common modes，拖动跟踪循环（event tracking mode）中也会触发。
        let timer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + interval,
                                                    interval, 0, 0) { timer in
            step.samples.append(self.visibleSidebarWidth(split))
            if step.index < xs.count {
                NSApp.postEvent(event(.leftMouseDragged, xs[step.index]), atStart: false)
                step.index += 1
            } else {
                NSApp.postEvent(event(.leftMouseUp, xs.last ?? 0), atStart: false)
                step.releasePosted = true
                CFRunLoopTimerInvalidate(timer)
            }
        }
        CFRunLoopAddTimer(CFRunLoopGetMain(), timer, .commonModes)
        split.mouseDown(with: event(.leftMouseDown, pane.frame.maxX + split.dividerThickness / 2))
        CFRunLoopTimerInvalidate(timer)
        dragSamples = step.samples
        lastDragCompleted = step.releasePosted
        spin(0.4)
    }

    /// 拖动中和拖动后侧栏都没有被收起；拖动完整送达时还应正好停在最小宽度。
    private func assertStoppedAtMinimum(_ split: NSSplitView, _ label: String,
                                        file: StaticString = #filePath, line: UInt = #line) {
        let width = visibleSidebarWidth(split)
        XCTAssertGreaterThanOrEqual(dragSamples.min() ?? 0, minimum - 1, "\(label)：拖动过程中侧栏被收起",
                                    file: file, line: line)
        XCTAssertGreaterThanOrEqual(width, minimum - 1, "\(label)：侧栏被收起或窄于最小宽度", file: file, line: line)
        XCTAssertFalse(sidebarItem(of: split)?.isCollapsed ?? true, label, file: file, line: line)
        if lastDragCompleted {
            XCTAssertEqual(width, minimum, accuracy: 1, "\(label)：应停在最小宽度", file: file, line: line)
        }
    }

    /// 先慢慢拖到最小宽度附近，停一下，再继续往里拉到窗口外。
    private func pastMinimumPath(from start: CGFloat) -> [CGFloat] {
        var xs: [CGFloat] = []
        var x = start
        while x > minimum - 4 { x -= 3; xs.append(x) }
        xs += Array(repeating: minimum - 4, count: 25)
        while x > -250 { x -= 4; xs.append(x) }
        xs += Array(repeating: -250, count: 25)
        return xs
    }

    // MARK: AppKit split view (collapse paths)

    private final class PlainViewController: NSViewController {
        override func loadView() { view = NSView() }
    }

    private func makePlainSplit() -> (NSWindow, NSSplitViewController, NSSplitViewItem) {
        let controller = NSSplitViewController()
        let sidebar = NSSplitViewItem(sidebarWithViewController: PlainViewController())
        sidebar.minimumThickness = minimum
        sidebar.maximumThickness = maximum
        let content = NSSplitViewItem(viewController: PlainViewController())
        content.minimumThickness = detailMinimum
        controller.addSplitViewItem(sidebar)
        controller.addSplitViewItem(content)
        let window = makeWindow()
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1_100, height: 700))
        window.orderFrontRegardless()
        controller.splitView.layoutSubtreeIfNeeded()
        controller.splitView.setPosition(225, ofDividerAt: 0)
        spin(0.1)
        return (window, controller, sidebar)
    }

    /// 对照：没有守卫时，同样的慢速拖动会把可折叠的侧栏整体收起——证明模拟拖动确实走到了折叠逻辑。
    func testUnguardedSidebarCollapsesWhenDraggedPastMinimum() throws {
        let (_, controller, sidebar) = makePlainSplit()
        XCTAssertTrue(sidebar.canCollapse)
        slowDrag(controller.splitView, through: pastMinimumPath(from: 225))
        guard lastDragCompleted else { throw XCTSkip("模拟拖动被打断") }
        XCTAssertEqual(visibleSidebarWidth(controller.splitView), 0, "对照组应当被系统折叠")
    }

    func testGuardStopsPlainSidebarAtMinimumWhenDraggedPastIt() {
        let (_, controller, sidebar) = makePlainSplit()
        let sidebarGuard = SidebarCollapseGuard(minimumWidth: minimum, maximumWidth: maximum)
        sidebarGuard.attach(to: controller)
        XCTAssertFalse(sidebar.canCollapse)
        for round in 1...3 {
            slowDrag(controller.splitView, through: pastMinimumPath(from: visibleSidebarWidth(controller.splitView)))
            assertStoppedAtMinimum(controller.splitView, "第 \(round) 轮")
        }
        withExtendedLifetime(sidebarGuard) {}
    }

    /// 其他代码把侧栏重新设为可折叠、直接折叠、执行 toggleSidebar 或替换侧栏项，侧栏都保持可见。
    func testGuardUndoesEveryCollapsePath() {
        let (_, controller, sidebar) = makePlainSplit()
        let sidebarGuard = SidebarCollapseGuard(minimumWidth: minimum, maximumWidth: maximum)
        sidebarGuard.attach(to: controller)

        sidebar.canCollapse = true
        XCTAssertFalse(sidebar.canCollapse, "被改回可折叠时应立即恢复")
        if #available(macOS 14.0, *) {
            sidebar.canCollapseFromWindowResize = true
            XCTAssertFalse(sidebar.canCollapseFromWindowResize)
        }

        sidebar.isCollapsed = true
        spin(0.5)
        XCTAssertFalse(sidebar.isCollapsed)
        XCTAssertGreaterThanOrEqual(visibleSidebarWidth(controller.splitView), minimum - 1)

        controller.toggleSidebar(nil)
        spin(0.8)
        XCTAssertFalse(sidebar.isCollapsed)
        XCTAssertGreaterThanOrEqual(visibleSidebarWidth(controller.splitView), minimum - 1)

        // SwiftUI 可能替换分栏项：新项同样上锁。
        let replacement = NSSplitViewItem(sidebarWithViewController: PlainViewController())
        replacement.minimumThickness = minimum
        controller.removeSplitViewItem(sidebar)
        controller.insertSplitViewItem(replacement, at: 0)
        controller.splitView.layoutSubtreeIfNeeded()
        spin(0.2)
        XCTAssertFalse(replacement.canCollapse)
        replacement.canCollapse = true
        XCTAssertFalse(replacement.canCollapse)
        slowDrag(controller.splitView, through: pastMinimumPath(from: visibleSidebarWidth(controller.splitView)))
        XCTAssertGreaterThanOrEqual(dragSamples.min() ?? 0, minimum - 1)
        withExtendedLifetime(sidebarGuard) {}
    }

    // MARK: SwiftUI NavigationSplitView (same configuration as the main window)

    private final class VisibilityLog: ObservableObject {
        var values: [NavigationSplitViewVisibility] = []
        /// 拖动期间持续变化，迫使整个 NavigationSplitView 反复重新计算（模拟主窗口里状态随时刷新）。
        @Published var tick = 0
    }

    private struct Harness: View {
        @ObservedObject var log: VisibilityLog
        let locked: Bool
        @State private var visibility: NavigationSplitViewVisibility = .all

        var body: some View {
            NavigationSplitView(columnVisibility: $visibility) {
                List {
                    Text("搜索")
                    Text("喜爱")
                    Text("Steam \(log.tick % 2)")
                }
                .frame(minWidth: MainWindowDesignTokens.Sidebar.minimumWidth)
                .navigationSplitViewColumnWidth(
                    min: MainWindowDesignTokens.Sidebar.minimumWidth,
                    ideal: MainWindowDesignTokens.Sidebar.defaultWidth,
                    max: MainWindowDesignTokens.Sidebar.maximumWidth
                )
            } detail: {
                Text("\(log.tick)")
                    .frame(minWidth: MainWindowDesignTokens.Content.minimumWidth,
                           maxWidth: .infinity, maxHeight: .infinity)
                    .background {
                        // 与主窗口相同：守卫放在 detail 列。
                        if locked {
                            SidebarCollapseLock(detailMinimumWidth: MainWindowDesignTokens.Content.minimumWidth)
                                .frame(width: 0, height: 0)
                        }
                    }
            }
            .onChange(of: visibility) { value in
                log.values.append(value)
                if locked, value != .all { visibility = .all }
            }
        }
    }

    private func makeSwiftUISplit(locked: Bool) -> (NSWindow, NSSplitView, VisibilityLog)? {
        let log = VisibilityLog()
        let window = makeWindow()
        window.contentViewController = NSHostingController(rootView: Harness(log: log, locked: locked))
        window.setContentSize(NSSize(width: 1_100, height: 700))
        window.orderFrontRegardless()
        spin(0.5)
        guard let content = window.contentView, let split = splitView(in: content) else {
            XCTFail("没有找到 NavigationSplitView 的分栏视图")
            return nil
        }
        return (window, split, log)
    }

    func testUnguardedNavigationSplitViewCollapsesWhenDraggedPastMinimum() throws {
        let (_, split, _) = try XCTUnwrap(makeSwiftUISplit(locked: false))
        let start = visibleSidebarWidth(split)
        XCTAssertGreaterThan(start, minimum - 1)
        slowDrag(split, through: pastMinimumPath(from: start))
        guard lastDragCompleted else { throw XCTSkip("模拟拖动被打断") }
        XCTAssertEqual(visibleSidebarWidth(split), 0, "对照组：系统默认会折叠侧栏")
    }

    func testLockedSidebarStopsAtMinimumWhenDraggedPastIt() throws {
        let (_, split, log) = try XCTUnwrap(makeSwiftUISplit(locked: true))
        let start = visibleSidebarWidth(split)
        XCTAssertEqual(start, MainWindowDesignTokens.Sidebar.defaultWidth, accuracy: 1)

        for round in 1...4 {
            // 每一轮都从当前位置（第一轮默认宽度，之后已是最小宽度）拖过最小宽度，一直拉到窗口外。
            slowDrag(split, through: pastMinimumPath(from: visibleSidebarWidth(split)))
            assertStoppedAtMinimum(split, "第 \(round) 轮")
        }
        XCTAssertFalse(log.values.contains { $0 != .all }, "侧栏可见性不应离开 .all：\(log.values)")

        // 之后仍可正常拖宽，并停在最大宽度。
        slowDrag(split, through: stride(from: minimum, through: 420, by: 5).map { $0 })
        if lastDragCompleted { XCTAssertEqual(visibleSidebarWidth(split), maximum, accuracy: 1) }
    }

    /// 拖动期间界面状态不断刷新（主窗口里运行状态、选中、预览等都会触发）：侧栏仍须停在最小宽度。
    func testLockedSidebarSurvivesViewUpdatesDuringDrag() throws {
        let (_, split, log) = try XCTUnwrap(makeSwiftUISplit(locked: true))
        let item = try XCTUnwrap(sidebarItem(of: split))
        @MainActor final class Changes { var values: [Bool] = [] }
        let changes = Changes()
        let watch = item.observe(\.canCollapse, options: [.new]) { item, _ in
            MainActor.assumeIsolated { changes.values.append(item.canCollapse) }
        }
        defer { watch.invalidate() }

        let ticker = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent(), 0.03, 0, 0) { _ in
            log.tick += 1
        }
        CFRunLoopAddTimer(CFRunLoopGetMain(), ticker, .commonModes)
        defer { CFRunLoopTimerInvalidate(ticker) }

        for round in 1...4 {
            slowDrag(split, through: pastMinimumPath(from: visibleSidebarWidth(split)))
            print("KSIDEBAR round \(round) minDuringDrag=\(dragSamples.min() ?? -1) width=\(visibleSidebarWidth(split)) tick=\(log.tick) canCollapseChanges=\(changes.values)")
            assertStoppedAtMinimum(split, "第 \(round) 轮（界面持续刷新）")
        }
        XCTAssertFalse(log.values.contains { $0 != .all }, "侧栏可见性不应离开 .all：\(log.values)")
    }

    // MARK: Real main window (the test host runs the app)

    private func mainWindowSplit() -> NSSplitView? {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            for window in NSApp.windows where window.isVisible && !windows.contains(window) {
                if let content = window.contentView, let split = splitView(in: content),
                   sidebarItem(of: split)?.behavior == .sidebar {
                    return split
                }
            }
            spin(0.1)
        }
        return nil
    }

    private func describe(_ split: NSSplitView) -> String {
        let panes = split.arrangedSubviews.map { pane -> String in
            let hosted = pane.subviews.first.map { "\(Int($0.frame.minX))+\(Int($0.frame.width))" } ?? "-"
            return "pane(\(Int(pane.frame.minX))+\(Int(pane.frame.width)) hidden=\(pane.isHidden) collapsed=\(split.isSubviewCollapsed(pane)) sub=\(hosted))"
        }
        let item = sidebarItem(of: split)
        return "item(collapsed=\(item?.isCollapsed ?? false) canCollapse=\(item?.canCollapse ?? false) min=\(item?.minimumThickness ?? -1)) " + panes.joined(separator: " ")
    }

    /// 在真实主窗口上慢速拖过最小宽度（多轮、停顿、拖出窗口外），侧栏必须停在最小宽度。
    func testMainWindowSidebarStopsAtMinimumWhenDraggedPastIt() throws {
        guard let split = mainWindowSplit() else {
            throw XCTSkip("测试宿主没有打开主窗口")
        }
        @MainActor final class Changes { var values: [Bool] = [] }
        let changes = Changes()
        let item = try XCTUnwrap(sidebarItem(of: split))
        let watch = item.observe(\.canCollapse, options: [.new]) { item, _ in
            MainActor.assumeIsolated { changes.values.append(item.canCollapse) }
        }
        defer { watch.invalidate() }
        print("KSIDEBAR main before \(describe(split))")
        for round in 1...5 {
            slowDrag(split, through: pastMinimumPath(from: visibleSidebarWidth(split)))
            print("KSIDEBAR main round \(round) completed=\(lastDragCompleted) minDuringDrag=\(dragSamples.min() ?? -1) \(describe(split))")
            assertStoppedAtMinimum(split, "主窗口第 \(round) 轮")
        }
        slowDrag(split, through: stride(from: minimum, through: MainWindowDesignTokens.Sidebar.defaultWidth, by: 4).map { $0 })
        print("KSIDEBAR main after \(describe(split)) canCollapseChanges=\(changes.values)")
        XCTAssertFalse(item.canCollapse)
    }
}
