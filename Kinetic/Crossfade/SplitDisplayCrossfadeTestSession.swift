#if DEBUG
import AppKit
import Combine

/// 仅 Debug 验收启用的调试面板；不是产品 UI，也不是 Module 16 的显示器发现。
/// 每个目标显示器一个桌面表面与会话，用肉眼和采样检查：一台显示器的交叉淡化、暂停、停止不影响其他显示器（规格 22、25）。
/// - `.splitMainScreen`（`--split-display-crossfade-test`，scheme `Kinetic-1.0-Module6`）：把主屏幕左右两半当作两台显示器。
/// - `.physicalScreens`（`--physical-display-crossfade-test`，scheme `Kinetic-1.0-MultiDisplay`）：每台真实连接的显示器一个会话，
///   按系统显示器编号找到它的位置；显示器断开时该会话的窗口隐藏、内容保留（Module 2 的行为），重新连接后回到原位。
/// 使用独立的 Runtime，不改动 App 的壁纸与资料库。
@MainActor
final class SplitDisplayCrossfadeTestSession: NSObject {
    enum Mode {
        case splitMainScreen
        case physicalScreens
    }

    private struct Target {
        let id: DisplayID
        let title: String
        let resolve: @MainActor () -> DesktopDisplay?
    }

    private let mode: Mode
    private let runtime = WallpaperRuntimeManager()
    private var targets: [Target] = []
    private var surfaces: [DisplayID: DisplayDesktopSurface] = [:]
    private var samples: [Wallpaper] = []
    private var panel: NSWindow?
    private let status = NSTextField(wrappingLabelWithString: "")
    private var subscriptions: Set<AnyCancellable> = []
    private var monitor: Timer?
    private var stressTask: Task<Void, Never>?
    private var stressProgress = NSLocalizedString("splitCrossfade.test.notRun", comment: "")
    private var monitorSamples = 0
    private var monitorGaps = 0
    private var otherReloads = 0
    /// 只切换第一台显示器时，其他显示器当前的底层内容。
    private var watchedContents: [DisplayID: NSView] = [:]

    init(mode: Mode) {
        self.mode = mode
    }

    func start() {
        samples = [sample("loop", "splitCrossfade.test.blue"), sample("loop-warm", "splitCrossfade.test.warm")]
            .compactMap { $0 }
        targets = mode == .splitMainScreen ? Self.halfTargets() : Self.physicalTargets()
        for target in targets {
            let surface = DisplayDesktopSurface(
                windowIdentifier: NSUserInterfaceItemIdentifier("Kinetic.MultiDisplayCrossfadeTest.\(target.id.rawValue)"),
                resolveDisplay: target.resolve)
            surfaces[target.id] = surface
            runtime.addDisplay(target.id, name: target.title, host: surface.host)
        }

        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 320),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = NSLocalizedString(mode == .splitMainScreen ? "splitCrossfade.test.title"
                                        : "splitCrossfade.test.physicalTitle", comment: "")
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        status.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let firstTitle = targets.first?.title ?? ""
        let rows: [NSView] = targets.indices.map { row(for: $0) }
        let stack = NSStackView(views: [status as NSView] + rows + [
            NSStackView(views: [
                button(String(format: NSLocalizedString("splitCrossfade.test.firstStress", comment: ""), firstTitle),
                       #selector(runFirstStress)),
                button(NSLocalizedString("splitCrossfade.test.bothStress", comment: ""), #selector(runAllStress)),
                button(NSLocalizedString("splitCrossfade.test.stopAll", comment: ""), #selector(stopAll))
            ])
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        panel.contentView = stack
        self.panel = panel
        panel.center()
        panel.makeKeyAndOrderFront(nil)

        runtime.$summary.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateStatus() }
        }.store(in: &subscriptions)
        monitor = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkStages() }
        }
        updateStatus()
    }

    func stop() {
        stressTask?.cancel()
        stressTask = nil
        monitor?.invalidate()
        monitor = nil
        subscriptions.removeAll()
        runtime.shutdown()
        surfaces.values.forEach { $0.desktop.stop() }
        panel?.close()
        panel = nil
    }

    // MARK: - 目标显示器

    private static func halfTargets() -> [Target] {
        func half(_ left: Bool) -> DesktopDisplay? {
            guard let screen = DesktopDisplay.primary() else { return nil }
            var frame = screen.frame
            let leftWidth = (frame.width / 2).rounded(.down)
            if left {
                frame.size.width = leftWidth
            } else {
                frame.origin.x += leftWidth
                frame.size.width -= leftWidth
            }
            return DesktopDisplay(id: screen.id, frame: frame, backingScaleFactor: screen.backingScaleFactor)
        }
        return [
            Target(id: DisplayID("split-left"), title: NSLocalizedString("splitCrossfade.test.left", comment: ""),
                   resolve: { half(true) }),
            Target(id: DisplayID("split-right"), title: NSLocalizedString("splitCrossfade.test.right", comment: ""),
                   resolve: { half(false) })
        ]
    }

    /// 启动时连接的每台真实显示器；之后按系统显示器编号查找，找不到（已断开）时返回 nil。
    private static func physicalTargets() -> [Target] {
        NSScreen.screens.compactMap { screen -> Target? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return nil }
            let displayNumber = number.uint32Value
            return Target(id: DisplayID("screen-\(displayNumber)"), title: screen.localizedName,
                          resolve: { display(number: displayNumber) })
        }
    }

    private static func display(number: CGDirectDisplayID) -> DesktopDisplay? {
        for screen in NSScreen.screens {
            guard let value = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  value.uint32Value == number else { continue }
            return DesktopDisplay(id: number, frame: screen.frame, backingScaleFactor: screen.backingScaleFactor)
        }
        return nil
    }

    // MARK: - 界面

    private func sample(_ name: String, _ key: String) -> Wallpaper? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "mp4", subdirectory: "Fixtures") else { return nil }
        return Wallpaper(name: NSLocalizedString(key, comment: ""), type: .video, source: .local, resourceURL: url)
    }

    private func button(_ title: String, _ action: Selector, tag: Int = 0) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.tag = tag
        return button
    }

    /// tag = 目标序号 × 10 + 动作。
    private func row(for index: Int) -> NSView {
        let label = NSTextField(labelWithString: targets[index].title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        let base = index * 10
        let keys = ["splitCrossfade.test.blue", "splitCrossfade.test.warm", "splitCrossfade.test.pause",
                    "splitCrossfade.test.resume", "splitCrossfade.test.stop"]
        let buttons = keys.enumerated().map { offset, key -> NSView in
            button(NSLocalizedString(key, comment: ""), #selector(targetAction(_:)), tag: base + offset)
        }
        return NSStackView(views: [label as NSView] + buttons)
    }

    @objc private func targetAction(_ sender: NSButton) {
        guard stressTask == nil, targets.indices.contains(sender.tag / 10) else { return }
        let id = targets[sender.tag / 10].id
        switch sender.tag % 10 {
        case 0 where samples.count > 0: runtime.apply(samples[0], to: id)
        case 1 where samples.count > 1: runtime.apply(samples[1], to: id)
        case 2: runtime.pause(.display(id))
        case 3: runtime.resume(.display(id))
        case 4: runtime.stop(.display(id))
        default: break
        }
    }

    @objc private func stopAll() {
        stressTask?.cancel()
        runtime.stop()
    }

    // MARK: - 连续切换

    /// 第一台显示器连续切换 20 次，其他显示器保持不动（没有壁纸的先放上暖色）。
    @objc private func runFirstStress() {
        guard stressTask == nil, samples.count >= 2, let first = targets.first else { return }
        resetMonitor()
        for target in targets.dropFirst() where runtime.state(of: target.id)?.activeWallpaperID == nil {
            runtime.apply(samples[1], to: target.id)
        }
        runStress(count: 20, ids: [first.id])
    }

    @objc private func runAllStress() {
        guard stressTask == nil, samples.count >= 2 else { return }
        resetMonitor()
        runStress(count: 10, ids: targets.map(\.id))
    }

    private func resetMonitor() {
        monitorSamples = 0
        monitorGaps = 0
        otherReloads = 0
        watchedContents = [:]
    }

    private func runStress(count: Int, ids: [DisplayID]) {
        let a = samples[0], b = samples[1]
        stressTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.stressTask = nil
                self.watchedContents = [:]
                self.updateStatus()
            }
            // 等待其他显示器就绪后再开始记录它们的内容。
            try? await Task.sleep(nanoseconds: 600_000_000)
            for target in self.targets where !ids.contains(target.id) {
                if let content = self.baseContent(target.id) { self.watchedContents[target.id] = content }
            }
            var completed = 0
            for _ in 0..<count {
                if Task.isCancelled { break }
                var pending: [(DisplayID, Wallpaper)] = []
                for id in ids {
                    let target = self.runtime.state(of: id)?.activeWallpaperID == a.id ? b : a
                    pending.append((id, target))
                    self.runtime.apply(target, to: id)
                }
                let deadline = ProcessInfo.processInfo.systemUptime + 10
                while !pending.allSatisfy({ id, target in
                    self.runtime.state(of: id)?.activeWallpaperID == target.id
                        && self.surfaces[id]?.host.isTransitioning == false
                }) {
                    if Task.isCancelled || ProcessInfo.processInfo.systemUptime > deadline { break }
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                completed += 1
                self.stressProgress = String(format: NSLocalizedString("splitCrossfade.test.progress", comment: ""),
                                             completed, count)
                self.updateStatus()
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            self.stressProgress = String(format: NSLocalizedString("splitCrossfade.test.result", comment: ""),
                                         completed, count)
        }
    }

    // MARK: - 检查

    private func baseContent(_ id: DisplayID) -> NSView? {
        surfaces[id]?.host.stage.subviews.first?.subviews.first
    }

    /// 有 Active 壁纸的显示器，舞台最底层必须是完全不透明、已有首帧的内容；只切换第一台时其他显示器的内容不能变化。
    private func checkStages() {
        var checked = false
        for target in targets where runtime.state(of: target.id)?.activeWallpaperID != nil {
            checked = true
            let baseSlot = surfaces[target.id]?.host.stage.subviews.first
            let ready = (baseSlot?.subviews.first as? VideoContentView)?.hasPoster ?? false
            if baseSlot == nil || baseSlot?.alphaValue != 1 || !ready { monitorGaps += 1 }
        }
        for (id, watched) in watchedContents where baseContent(id) !== watched {
            otherReloads += 1
            watchedContents[id] = baseContent(id)
        }
        guard checked else { return }
        monitorSamples += 1
        if monitorSamples % 30 == 0 { updateStatus() }
    }

    private func updateStatus() {
        let none = NSLocalizedString("runtime.test.none", comment: "")
        let lines = targets.map { target -> String in
            let state = runtime.state(of: target.id)?.playbackState ?? .noWallpaper
            let surface = surfaces[target.id]
            let frame: String
            if let display = surface?.desktop.targetDisplay {
                frame = String(format: "%.0f×%.0f @ %.0f,%.0f", display.frame.width, display.frame.height,
                               display.frame.minX, display.frame.minY)
            } else {
                // 有壁纸却没有位置：显示器暂时不可用（例如已断开）；没有壁纸时桌面窗口本来就不存在。
                let hasContent = runtime.state(of: target.id)?.activeWallpaperID != nil
                frame = NSLocalizedString(hasContent ? "splitCrossfade.test.unavailable" : "splitCrossfade.test.notShown",
                                          comment: "")
            }
            return String(format: NSLocalizedString("splitCrossfade.test.side", comment: ""),
                          target.title,
                          NSLocalizedString("runtime.state.\(state.rawValue)", comment: ""),
                          runtime.activeWallpaper(on: target.id)?.name ?? none,
                          surface?.host.completedTransitionCount ?? 0,
                          surface?.host.lastTransitionDuration.map { String(format: "%.0f ms", $0 * 1000) } ?? none)
                + "（\(frame)）"
        }
        status.stringValue = (lines + [
            String(format: NSLocalizedString("splitCrossfade.test.stress", comment: ""), stressProgress),
            String(format: NSLocalizedString("splitCrossfade.test.check", comment: ""),
                   monitorSamples, monitorGaps, otherReloads)
        ]).joined(separator: "\n")
    }
}
#endif
