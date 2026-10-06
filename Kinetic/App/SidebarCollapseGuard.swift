import AppKit
import SwiftUI

/// 侧栏折叠守卫：侧栏只能在最小…最大宽度之间调整，任何途径都不能把它整体收起。
///
/// NavigationSplitView 在 macOS 上由 NSSplitViewController 实现，侧栏项默认可折叠：
/// 拖过最小宽度继续往里拉、窗口太窄或执行 toggleSidebar 时都会收起。SwiftUI 在之后的更新中
/// 还会把侧栏项的 `canCollapse` 改回 true，所以只在布局时设置一次并不可靠——
/// 改回之后再拖过最小宽度，侧栏就会在拖动中消失。
///
/// 守卫在 AppKit 层同步兜住所有路径：
/// * 监听侧栏项的 `canCollapse` / `canCollapseFromWindowResize` / `isCollapsed`，一旦被改回立即恢复；
/// * 分栏尺寸每次变化（包括拖动中的每一步）都重新检查当前分栏项：被替换的新项同样上锁，
///   发现折叠、隐藏或窄于最小宽度时立即回到最小宽度；
/// * 最小宽度是硬限制，拖过它只会停住。
@MainActor
final class SidebarCollapseGuard {
    let minimumWidth: CGFloat
    let maximumWidth: CGFloat

    /// 右侧内容区的最小宽度。
    var detailMinimumWidth: CGFloat = 0 {
        didSet { if oldValue != detailMinimumWidth { configureItems() } }
    }

    private(set) weak var controller: NSSplitViewController?
    private weak var observedSidebar: NSSplitViewItem?
    private var itemObservations: [NSKeyValueObservation] = []
    private var resizeObserver: NSObjectProtocol?
    private var isAdjusting = false

    init(minimumWidth: CGFloat, maximumWidth: CGFloat) {
        self.minimumWidth = minimumWidth
        self.maximumWidth = maximumWidth
    }

    deinit {
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
    }

    var sidebarItem: NSSplitViewItem? {
        guard let items = controller?.splitViewItems, !items.isEmpty else { return nil }
        return items.first { $0.behavior == .sidebar } ?? items.first
    }

    /// 侧栏在分栏视图里的那一格（macOS 新版会在项视图外再包一层）。
    var sidebarPane: NSView? {
        guard let split = controller?.splitView, let item = sidebarItem else { return nil }
        let view = item.viewController.view
        return split.arrangedSubviews.first { view === $0 || view.isDescendant(of: $0) } ?? view
    }

    func attach(to controller: NSSplitViewController) {
        if controller !== self.controller {
            if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
            self.controller = controller
            observedSidebar = nil
            itemObservations = []
            // queue: nil —— 在发出通知的当下同步处理，拖动跟踪循环中的每一步都能及时纠正。
            resizeObserver = NotificationCenter.default.addObserver(
                forName: NSSplitView.didResizeSubviewsNotification, object: controller.splitView, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.enforce() }
            }
        }
        enforce()
    }

    /// 重新给当前分栏项上锁；侧栏已被折叠、隐藏或过窄时立即恢复。
    func enforce() {
        configureItems()
        restoreIfNeeded()
    }

    func configureItems() {
        guard let controller, let sidebar = sidebarItem else { return }
        if sidebar !== observedSidebar { observe(sidebar) }
        Self.lock(sidebar)
        if sidebar.minimumThickness != minimumWidth { sidebar.minimumThickness = minimumWidth }
        if sidebar.maximumThickness != maximumWidth { sidebar.maximumThickness = maximumWidth }
        for other in controller.splitViewItems where other !== sidebar {
            if other.canCollapse { other.canCollapse = false }
            if detailMinimumWidth > 0, other.minimumThickness != detailMinimumWidth {
                other.minimumThickness = detailMinimumWidth
            }
        }
    }

    private static func lock(_ item: NSSplitViewItem) {
        if item.canCollapse { item.canCollapse = false }
        if #available(macOS 14.0, *), item.canCollapseFromWindowResize {
            item.canCollapseFromWindowResize = false
        }
    }

    private func observe(_ item: NSSplitViewItem) {
        observedSidebar = item
        var observations = [
            item.observe(\.canCollapse, options: [.new]) { item, _ in
                MainActor.assumeIsolated { Self.lock(item) }
            },
            item.observe(\.isCollapsed, options: [.new]) { [weak self] item, _ in
                MainActor.assumeIsolated {
                    guard item.isCollapsed else { return }
                    self?.restoreIfNeeded()
                    // 折叠可能带动画，结束后再确认一次。
                    DispatchQueue.main.async { self?.restoreIfNeeded() }
                }
            },
        ]
        if #available(macOS 14.0, *) {
            observations.append(item.observe(\.canCollapseFromWindowResize, options: [.new]) { item, _ in
                MainActor.assumeIsolated { Self.lock(item) }
            })
        }
        itemObservations = observations
    }

    /// 侧栏被折叠、隐藏或窄于最小宽度时，展开并回到最小宽度。
    /// 用 setPosition 调整分隔线，与用户拖动走同一路径，SwiftUI 的列宽随之更新。
    func restoreIfNeeded() {
        guard !isAdjusting, let controller, let sidebar = sidebarItem, let pane = sidebarPane else { return }
        let split = controller.splitView
        guard split.window != nil, split.bounds.width > minimumWidth else { return }
        let collapsed = sidebar.isCollapsed || split.isSubviewCollapsed(pane) || pane.isHidden
        guard collapsed || pane.frame.width < minimumWidth - 0.5 else { return }
        isAdjusting = true
        defer { isAdjusting = false }
        Self.lock(sidebar)
        if sidebar.isCollapsed { sidebar.isCollapsed = false }
        split.setPosition(minimumWidth, ofDividerAt: 0)
    }

    /// 窗口出现时使用默认宽度。
    func applyWidth(_ width: CGFloat) {
        guard let split = controller?.splitView else { return }
        split.setPosition(min(max(width, minimumWidth), maximumWidth), ofDividerAt: 0)
    }

    /// 窗口内容宽度放不下「侧栏 + 右侧最小宽度」时把侧栏推窄（不低于最小宽度），
    /// 否则 SwiftUI 会保留旧列宽，把整体内容撑得比窗口宽，两侧被裁切。
    func fitSidebar(toContentWidth contentWidth: CGFloat) {
        guard !isAdjusting, let split = controller?.splitView, let pane = sidebarPane else { return }
        let widest = contentWidth - detailMinimumWidth - split.dividerThickness
        let target = max(minimumWidth, min(maximumWidth, widest))
        guard pane.frame.width > target + 0.5 else { return }
        isAdjusting = true
        defer { isAdjusting = false }
        split.setPosition(target, ofDividerAt: 0)
    }
}

/// 主窗口分栏的原生配置入口（放在 detail 列背景里，侧栏状态变化不会影响它的存活）：
/// 交给 `SidebarCollapseGuard` 上锁；移除 SwiftUI 在工具栏加入的边栏开关（工具栏本身保留，
/// 标题栏高度与红绿灯位置不变）；窗口出现时设置默认宽度；窗口变窄时先推窄侧栏。
struct SidebarCollapseLock: NSViewRepresentable {
    var minimumWidth = MainWindowDesignTokens.Sidebar.minimumWidth
    var defaultWidth = MainWindowDesignTokens.Sidebar.defaultWidth
    var maximumWidth = MainWindowDesignTokens.Sidebar.maximumWidth
    let detailMinimumWidth: CGFloat

    func makeNSView(context: Context) -> LockView {
        LockView(sidebarGuard: SidebarCollapseGuard(minimumWidth: minimumWidth, maximumWidth: maximumWidth),
                 defaultWidth: defaultWidth)
    }

    func updateNSView(_ nsView: LockView, context: Context) {
        nsView.sidebarGuard.detailMinimumWidth = detailMinimumWidth
        nsView.apply()
    }

    final class LockView: NSView {
        let sidebarGuard: SidebarCollapseGuard
        private let defaultWidth: CGFloat
        private var didApplyDefaultWidth = false
        private var toolbarObserver: NSObjectProtocol?
        private var resizeObservers: [NSObjectProtocol] = []
        private weak var observedWindow: NSWindow?

        init(sidebarGuard: SidebarCollapseGuard, defaultWidth: CGFloat) {
            self.sidebarGuard = sidebarGuard
            self.defaultWidth = defaultWidth
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        deinit {
            if let toolbarObserver { NotificationCenter.default.removeObserver(toolbarObserver) }
            resizeObservers.forEach { NotificationCenter.default.removeObserver($0) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            // SwiftUI 在首次布局后才完成分栏配置，稍后再确认一次并设置默认宽度。
            DispatchQueue.main.async { [weak self] in
                self?.apply()
                self?.applyDefaultWidthOnce()
            }
        }

        override func layout() {
            super.layout()
            apply()
        }

        func apply() {
            guard let window else { return }
            if let controller = splitViewController() {
                sidebarGuard.attach(to: controller)
                // 分栏可能晚于本视图进入窗口：第一次拿到分栏后再设置默认宽度。
                if !didApplyDefaultWidth {
                    DispatchQueue.main.async { [weak self] in self?.applyDefaultWidthOnce() }
                }
            }
            hideSidebarToggle(in: window.toolbar)
            observeToolbarIfNeeded()
            observeWindowResizeIfNeeded()
            DispatchQueue.main.async { [weak self] in self?.fitSidebarToWindow() }
        }

        private func applyDefaultWidthOnce() {
            guard !didApplyDefaultWidth, window != nil,
                  let split = sidebarGuard.controller?.splitView, split.bounds.width > 0 else { return }
            didApplyDefaultWidth = true
            sidebarGuard.applyWidth(defaultWidth)
        }

        private func observeWindowResizeIfNeeded() {
            guard let window, window !== observedWindow else { return }
            resizeObservers.forEach { NotificationCenter.default.removeObserver($0) }
            observedWindow = window
            resizeObservers = [
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didResizeNotification, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.fitSidebarToWindow() }
                },
            ]
        }

        private func fitSidebarToWindow() {
            guard let width = window?.contentView?.bounds.width else { return }
            sidebarGuard.fitSidebar(toContentWidth: width)
        }

        private func hideSidebarToggle(in toolbar: NSToolbar?) {
            guard let toolbar else { return }
            // 从后往前移除，避免索引错位；工具栏本身保留。
            for index in toolbar.items.indices.reversed() where isSidebarToggle(toolbar.items[index]) {
                Self.disable(toolbar.items[index])
                toolbar.removeItem(at: index)
            }
        }

        /// SwiftUI 会在窗口出现后才把边栏开关加入工具栏，所以监听加入事件。
        private func observeToolbarIfNeeded() {
            guard toolbarObserver == nil else { return }
            toolbarObserver = NotificationCenter.default.addObserver(
                forName: NSToolbar.willAddItemNotification, object: nil, queue: .main
            ) { [weak self] notification in
                guard let item = notification.userInfo?["item"] as? NSToolbarItem else { return }
                MainActor.assumeIsolated {
                    guard let self, let toolbar = notification.object as? NSToolbar,
                          toolbar === self.window?.toolbar, self.isSidebarToggle(item) else { return }
                    Self.disable(item)
                    // 加入完成后再处理一次（SwiftUI 可能在加入后重新配置该项）。
                    DispatchQueue.main.async { [weak self] in
                        self?.hideSidebarToggle(in: self?.window?.toolbar)
                    }
                }
            }
        }

        /// 边栏开关：系统 `.toggleSidebar` 项，或 SwiftUI 以其他标识提供、动作为 toggleSidebar 的项。
        /// 识别过的开关标识；停用后动作被清空，仍能据此认出它。
        private var toggleIdentifiers: Set<NSToolbarItem.Identifier> = [.toggleSidebar]

        func isSidebarToggle(_ item: NSToolbarItem) -> Bool {
            if toggleIdentifiers.contains(item.itemIdentifier) { return true }
            guard item.action == #selector(NSSplitViewController.toggleSidebar(_:))
                    || item.itemIdentifier.rawValue.localizedCaseInsensitiveContains("sidebar") else { return false }
            toggleIdentifiers.insert(item.itemIdentifier)
            return true
        }

        static func disable(_ item: NSToolbarItem) {
            item.isEnabled = false
            item.action = nil
            item.target = nil
            if #available(macOS 15.0, *), !item.isHidden { item.isHidden = true }
        }

        /// 从本视图向上找到 NavigationSplitView 的 NSSplitView（其代理是 NSSplitViewController）。
        private func splitViewController() -> NSSplitViewController? {
            var view: NSView? = superview
            while let current = view {
                if let split = current as? NSSplitView,
                   let controller = split.delegate as? NSSplitViewController {
                    return controller
                }
                view = current.superview
            }
            return nil
        }
    }
}
