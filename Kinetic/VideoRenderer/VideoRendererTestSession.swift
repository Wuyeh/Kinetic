#if DEBUG
import AppKit

/// 仅 Module 3 专用 scheme 启用的验收协调器；不是产品 UI 或 Module 5 状态机。
@MainActor
final class VideoRendererTestSession: NSObject {
    private let desktop: DesktopWindowRuntime
    private var renderer: VideoRenderer?
    private var preparation: Task<Void, Never>?
    private var panel: NSWindow?
    private let status = NSTextField(wrappingLabelWithString: "")
    private var timer: Timer?
    private var message = NSLocalizedString("video.test.preparing", comment: "")

    init(desktop: DesktopWindowRuntime) { self.desktop = desktop }

    func start() {
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 150),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = NSLocalizedString("video.test.title", comment: "")
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        let buttons = NSStackView(views: [
            button("video.test.pause", #selector(pauseVideo)),
            button("video.test.resume", #selector(resumeVideo)),
            button("video.test.stop", #selector(stopVideo))
        ])
        buttons.orientation = .horizontal
        status.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let stack = NSStackView(views: [status, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        panel.contentView = stack
        self.panel = panel
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        updateStatus()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateStatus() }
        }
        preparation = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let short = ProcessInfo.processInfo.arguments.contains("--video-test-short")
                // 仓库不包含用户原始视频；没有本地验收副本时使用可复现的短视频。
                let localSample = short ? nil
                    : Bundle.main.url(forResource: "5115FE36-676D-450D-B436-C9A45D8286D1", withExtension: "mov")
                let url = localSample
                    ?? Bundle.main.url(forResource: "loop", withExtension: "mp4", subdirectory: "Fixtures")
                guard let url else { throw VideoRendererError.missingFile }
                let model = Wallpaper(name: url.lastPathComponent, type: .video, source: .local, resourceURL: url)
                let candidate = VideoRenderer(wallpaper: model)
                renderer = candidate
                candidate.onFailure = { [weak self] error in
                    self?.message = error.localizedDescription
                    self?.updateStatus()
                }
                try await candidate.prepare()
                try Task.checkCancellation()
                desktop.present(candidate.contentView)
                candidate.play()
                message = NSLocalizedString("video.test.playing", comment: "")
                updateStatus()
            } catch is CancellationError {
                // Stop / 退出取消准备，保留既有状态文字。
            } catch {
                message = error.localizedDescription
                updateStatus()
            }
        }
    }

    private func button(_ key: String, _ action: Selector) -> NSButton {
        NSButton(title: NSLocalizedString(key, comment: ""), target: self, action: action)
    }

    @objc private func pauseVideo() {
        guard renderer?.isPrepared == true else { return }
        renderer?.pause()
        message = NSLocalizedString("video.test.paused", comment: "")
        updateStatus()
    }

    @objc private func resumeVideo() {
        guard renderer?.isPrepared == true else { return }
        renderer?.resume()
        message = NSLocalizedString("video.test.playing", comment: "")
        updateStatus()
    }

    @objc private func stopVideo() {
        preparation?.cancel()
        preparation = nil
        desktop.stop()
        renderer?.dispose()
        renderer = nil
        message = NSLocalizedString("video.test.stopped", comment: "")
        updateStatus()
    }

    private func updateStatus() {
        let time = renderer?.currentTime.seconds ?? 0
        let loops = renderer?.completedLoopCount ?? 0
        let format = NSLocalizedString("video.test.status", comment: "")
        status.stringValue = String(format: format, message, time.isFinite ? time : 0, loops)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        stopVideo()
        panel?.close()
        panel = nil
    }
}
#endif
