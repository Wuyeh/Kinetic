#if DEBUG
import AppKit
import Combine

/// 仅 Kinetic-Module6 验收 scheme 启用的调试面板；不是产品 UI。
/// 通过 Runtime Manager 的公开命令切换壁纸，并持续检查舞台底层是否始终有完整画面。
@MainActor
final class CrossfadeTestSession: NSObject {
    private let runtime: WallpaperRuntimeManager
    private let host: CrossfadeDesktopHost
    private var panel: NSWindow?
    private let status = NSTextField(wrappingLabelWithString: "")
    private var subscriptions: Set<AnyCancellable> = []
    private var monitor: Timer?
    private var samples: [Wallpaper] = []
    private var stressTask: Task<Void, Never>?
    private var stressProgress: String
    private var monitorSamples = 0
    private var monitorGaps = 0

    init(runtime: WallpaperRuntimeManager, host: CrossfadeDesktopHost) {
        self.runtime = runtime
        self.host = host
        stressProgress = NSLocalizedString("crossfade.test.notRun", comment: "")
    }

    func start() {
        // 仅使用仓库内的 Debug 测试素材：A 为蓝色，B 为暖橙色，便于肉眼看到交叉淡化。
        samples = [
            sample("loop", "mp4", "crossfade.test.sampleA"),
            sample("loop-warm", "mp4", "crossfade.test.sampleB"),
            sample("corrupt", "mp4", "crossfade.test.sampleCorrupt")
        ].compactMap { $0 }

        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 280),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = NSLocalizedString("crossfade.test.title", comment: "")
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        let applyButtons: [NSView] = samples.indices.map { index in
            let button = NSButton(title: String(format: NSLocalizedString("crossfade.test.apply", comment: ""),
                                                samples[index].name),
                                  target: self, action: #selector(applySample(_:)))
            button.tag = index
            return button
        }
        let applyRow = NSStackView(views: applyButtons)
        let controlRow = NSStackView(views: [
            NSButton(title: NSLocalizedString("crossfade.test.stress", comment: ""), target: self, action: #selector(runStress)),
            NSButton(title: NSLocalizedString("crossfade.test.stop", comment: ""), target: self, action: #selector(stopWallpaper))
        ])
        status.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let stack = NSStackView(views: [status, applyRow, controlRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        panel.contentView = stack
        self.panel = panel
        panel.center()
        panel.makeKeyAndOrderFront(nil)

        runtime.$state.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateStatus() }
        }.store(in: &subscriptions)
        monitor = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkStage() }
        }
        updateStatus()
    }

    func stop() {
        stressTask?.cancel()
        stressTask = nil
        monitor?.invalidate()
        monitor = nil
        subscriptions.removeAll()
        panel?.close()
        panel = nil
    }

    private func sample(_ name: String, _ ext: String, _ key: String) -> Wallpaper? {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Fixtures") else { return nil }
        return Wallpaper(name: NSLocalizedString(key, comment: ""), type: .video, source: .local, resourceURL: url)
    }

    @objc private func applySample(_ sender: NSButton) {
        guard stressTask == nil, samples.indices.contains(sender.tag) else { return }
        runtime.apply(samples[sender.tag])
    }

    @objc private func stopWallpaper() {
        stressTask?.cancel()
        runtime.stop()
    }

    /// A ↔ B 交替切换 50 次；每次等待淡入完成、旧壁纸释放后再进行下一次。
    @objc private func runStress() {
        guard stressTask == nil, samples.count >= 2 else { return }
        let a = samples[0], b = samples[1]
        monitorSamples = 0
        monitorGaps = 0
        let startCount = host.completedTransitionCount
        stressTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var durations: [TimeInterval] = []
            var completed = 0
            defer { self.stressTask = nil }
            for index in 0..<50 {
                if Task.isCancelled { break }
                let target = self.runtime.state.activeWallpaperID == a.id ? b : a
                let expectFade = self.runtime.state.activeWallpaperID != nil
                self.runtime.apply(target)
                let deadline = ProcessInfo.processInfo.systemUptime + 10
                while !(self.runtime.state.activeWallpaperID == target.id && !self.host.isTransitioning) {
                    if Task.isCancelled || ProcessInfo.processInfo.systemUptime > deadline { break }
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                guard self.runtime.state.activeWallpaperID == target.id, !self.host.isTransitioning else { break }
                completed = index + 1
                if expectFade, let duration = self.host.lastTransitionDuration { durations.append(duration) }
                self.stressProgress = String(format: NSLocalizedString("crossfade.test.progress", comment: ""), completed)
                self.updateStatus()
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            let fades = self.host.completedTransitionCount - startCount
            let average = durations.isEmpty ? 0 : durations.reduce(0, +) / Double(durations.count) * 1000
            let maximum = (durations.max() ?? 0) * 1000
            self.stressProgress = String(format: NSLocalizedString("crossfade.test.result", comment: ""),
                                         completed, fades, average, maximum)
            self.updateStatus()
        }
        updateStatus()
    }

    /// 只要有 Active 壁纸，舞台最底层必须是完全不透明、已有首帧的内容。
    private func checkStage() {
        guard runtime.state.activeWallpaperID != nil else { return }
        monitorSamples += 1
        let baseSlot = host.stage.subviews.first
        let baseContent = baseSlot?.subviews.first
        let baseReady = (baseContent as? VideoContentView)?.hasPoster ?? (baseContent != nil)
        if baseSlot == nil || baseSlot?.alphaValue != 1 || !baseReady { monitorGaps += 1 }
        if monitorSamples % 30 == 0 { updateStatus() }
    }

    private func updateStatus() {
        let none = NSLocalizedString("runtime.test.none", comment: "")
        let last = host.lastTransitionDuration.map { String(format: "%.0f ms", $0 * 1000) } ?? none
        status.stringValue = String(
            format: NSLocalizedString("crossfade.test.status", comment: ""),
            NSLocalizedString("runtime.state.\(runtime.state.playbackState.rawValue)", comment: ""),
            runtime.activeWallpaper?.name ?? none,
            host.duration * 1000,
            host.completedTransitionCount,
            last,
            stressProgress,
            monitorSamples,
            monitorGaps,
            runtime.lastFailure.map { "\($0.message)（\($0.detail)）" } ?? none
        )
    }
}
#endif
