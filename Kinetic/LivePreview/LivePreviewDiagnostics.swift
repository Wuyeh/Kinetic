#if DEBUG
import AppKit
import AVFoundation
import Darwin
import SwiftUI
import WebKit

/// 仅 Debug：统计悬停预览创建与释放的资源，供单元测试与压力测试使用。
/// 播放器与网页视图用弱引用登记，释放后自动从统计中消失，因此能直接发现泄漏。
@MainActor
final class LivePreviewDiagnostics {
    static let shared = LivePreviewDiagnostics()
    static let launchArgument = "--live-preview-diagnostics"
    static var isPanelEnabled: Bool { ProcessInfo.processInfo.arguments.contains(launchArgument) }

    private let players = NSHashTable<AnyObject>.weakObjects()
    private let webViews = NSHashTable<AnyObject>.weakObjects()
    private(set) var sessionsStarted = 0
    private(set) var runningSessions = 0
    private(set) var peakRunningSessions = 0

    var alivePlayers: Int { players.allObjects.count }
    var aliveWebViews: Int { webViews.allObjects.count }

    func sessionStarted() {
        sessionsStarted += 1
        runningSessions += 1
        peakRunningSessions = max(peakRunningSessions, runningSessions)
    }

    func sessionEnded() {
        runningSessions = max(0, runningSessions - 1)
    }

    func track(player: AVPlayer) { players.add(player) }
    func track(webView: WKWebView) { webViews.add(webView) }

    func resetCounters() {
        sessionsStarted = 0
        peakRunningSessions = runningSessions
    }

    /// 当前进程的物理内存占用（与“活动监视器”的“内存”一致）。不含 WebKit 独立的网页进程。
    static func memoryFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<natural_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// 当前进程累计 CPU 时间（秒）。
    static func cpuTime() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return user + system
    }
}

/// 仅 Debug（`--live-preview-diagnostics`）：一个不抢焦点的小面板，每 0.5 秒显示预览资源、内存、CPU
/// 与桌面壁纸的实际状态，用来确认悬停预览不影响桌面。
@MainActor
final class LivePreviewDiagnosticsPanel {
    private let panel: NSPanel

    init(runtime: WallpaperRuntimeManager, library: WallpaperLibrary?) {
        let model = LivePreviewDiagnosticsModel(runtime: runtime, library: library)
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 190),
            styleMask: [.titled, .utilityWindow, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.title = NSLocalizedString("preview.diagnostics.title", comment: "")
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: LivePreviewDiagnosticsView(model: model)
            .environment(\.locale, Locale(identifier: "zh-Hans")))
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: frame.maxX - 300, y: frame.maxY - 20))
        }
        panel.orderFrontRegardless()
    }

    func close() { panel.close() }
}

@MainActor
private final class LivePreviewDiagnosticsModel: ObservableObject {
    struct Snapshot: Equatable {
        var sessionsStarted = 0
        var runningSessions = 0
        var peakRunningSessions = 0
        var alivePlayers = 0
        var aliveWebViews = 0
        var footprintMB = 0.0
        var cpuPercent = 0.0
        var desktop = ""
    }

    @Published private(set) var snapshot = Snapshot()
    private let runtime: WallpaperRuntimeManager
    private let library: WallpaperLibrary?
    private var timer: Timer?
    private var lastCPU = LivePreviewDiagnostics.cpuTime()
    private var lastSample = Date()

    init(runtime: WallpaperRuntimeManager, library: WallpaperLibrary?) {
        self.runtime = runtime
        self.library = library
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sample() }
        }
    }

    func reset() {
        LivePreviewDiagnostics.shared.resetCounters()
        sample()
    }

    private func sample() {
        let diagnostics = LivePreviewDiagnostics.shared
        let now = Date()
        let cpu = LivePreviewDiagnostics.cpuTime()
        let elapsed = max(0.001, now.timeIntervalSince(lastSample))
        let state = runtime.state
        let name = state.activeWallpaperID.flatMap { id in library?.wallpapers.first { $0.id == id }?.name }
            ?? NSLocalizedString("preview.diagnostics.none", comment: "")
        snapshot = Snapshot(
            sessionsStarted: diagnostics.sessionsStarted,
            runningSessions: diagnostics.runningSessions,
            peakRunningSessions: diagnostics.peakRunningSessions,
            alivePlayers: diagnostics.alivePlayers,
            aliveWebViews: diagnostics.aliveWebViews,
            footprintMB: Double(LivePreviewDiagnostics.memoryFootprint()) / 1_048_576,
            cpuPercent: (cpu - lastCPU) / elapsed * 100,
            desktop: "\(name) · \(state.playbackState.rawValue)"
        )
        lastCPU = cpu
        lastSample = now
    }
}

private struct LivePreviewDiagnosticsView: View {
    @ObservedObject var model: LivePreviewDiagnosticsModel

    var body: some View {
        let s = model.snapshot
        VStack(alignment: .leading, spacing: 4) {
            Text(String(format: NSLocalizedString("preview.diagnostics.sessions", comment: ""),
                        s.sessionsStarted, s.runningSessions, s.peakRunningSessions))
            Text(String(format: NSLocalizedString("preview.diagnostics.resources", comment: ""),
                        s.alivePlayers, s.aliveWebViews))
            Text(String(format: NSLocalizedString("preview.diagnostics.process", comment: ""),
                        s.footprintMB, s.cpuPercent))
            Text(String(format: NSLocalizedString("preview.diagnostics.desktop", comment: ""), s.desktop))
                .lineLimit(1)
            Button("preview.diagnostics.reset") { model.reset() }
                .controlSize(.small)
                .padding(.top, 4)
        }
        .font(.system(size: 12).monospacedDigit())
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
