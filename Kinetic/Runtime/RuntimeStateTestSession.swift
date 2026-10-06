#if DEBUG
import AppKit
import Combine

/// 仅 Kinetic-Module5 验收 scheme 启用的调试面板；不是产品 UI、Menu Bar 或 Floating Toolbar。
/// 所有按钮只调用 WallpaperRuntimeManager 的公开命令，不直接接触 Renderer。
@MainActor
final class RuntimeStateTestSession: NSObject {
    private let runtime: WallpaperRuntimeManager
    private var panel: NSWindow?
    private let status = NSTextField(wrappingLabelWithString: "")
    private var subscriptions: Set<AnyCancellable> = []
    private var samples: [Wallpaper] = []
    /// 面板最近一次模拟的系统条件；真实监听属于 Module 18。
    private var simulatedSmartCondition = false

    init(runtime: WallpaperRuntimeManager) { self.runtime = runtime }

    func start() {
        // 仅使用仓库生成的 Debug 测试素材；Release 不包含这些资源。
        samples = [
            sample("loop", "mp4", "runtime.test.sampleA"),
            sample("loop", "mov", "runtime.test.sampleB"),
            sample("corrupt", "mp4", "runtime.test.sampleCorrupt")
        ].compactMap { $0 }

        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 260),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = NSLocalizedString("runtime.test.title", comment: "")
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        let applyRow = row(samples.indices.map { index in
            let button = NSButton(title: String(format: NSLocalizedString("runtime.test.apply", comment: ""),
                                                samples[index].name),
                                  target: self, action: #selector(applySample(_:)))
            button.tag = index
            return button
        })
        let controlRow = row([
            button("runtime.test.pause", #selector(pause)),
            button("runtime.test.resume", #selector(resume)),
            button("runtime.test.smartOn", #selector(smartOn)),
            button("runtime.test.smartOff", #selector(smartOff)),
            button("runtime.test.stop", #selector(stopWallpaper)),
            button("runtime.test.reenable", #selector(reenable))
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
        runtime.$lastFailure.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateStatus() }
        }.store(in: &subscriptions)
        updateStatus()
    }

    func stop() {
        subscriptions.removeAll()
        panel?.close()
        panel = nil
    }

    private func sample(_ name: String, _ ext: String, _ key: String) -> Wallpaper? {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Fixtures") else { return nil }
        return Wallpaper(name: NSLocalizedString(key, comment: ""), type: .video, source: .local, resourceURL: url)
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        return row
    }

    private func button(_ key: String, _ action: Selector) -> NSButton {
        NSButton(title: NSLocalizedString(key, comment: ""), target: self, action: action)
    }

    @objc private func applySample(_ sender: NSButton) {
        guard samples.indices.contains(sender.tag) else { return }
        runtime.apply(samples[sender.tag])
    }

    @objc private func pause() { runtime.pause() }
    @objc private func resume() { runtime.resume() }
    @objc private func smartOn() {
        simulatedSmartCondition = true
        runtime.setSmartPauseActive(true)
        updateStatus()
    }

    @objc private func smartOff() {
        simulatedSmartCondition = false
        runtime.setSmartPauseActive(false)
        updateStatus()
    }
    @objc private func stopWallpaper() { runtime.stop() }
    @objc private func reenable() { runtime.reenable() }

    private func updateStatus() {
        let state = runtime.state
        let none = NSLocalizedString("runtime.test.none", comment: "")
        let smart = NSLocalizedString(simulatedSmartCondition ? "runtime.test.yes" : "runtime.test.no", comment: "")
        let format = NSLocalizedString("runtime.test.status", comment: "")
        status.stringValue = String(
            format: format,
            NSLocalizedString("runtime.state.\(state.playbackState.rawValue)", comment: ""),
            runtime.activeWallpaper?.name ?? none,
            runtime.preparingWallpaper?.name ?? none,
            runtime.lastActiveWallpaper?.name ?? none,
            smart,
            runtime.lastFailure.map { "\($0.message)（\($0.detail)）" } ?? none
        )
    }
}
#endif
