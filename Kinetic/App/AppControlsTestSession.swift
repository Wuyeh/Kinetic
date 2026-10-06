#if DEBUG
import AppKit
import Combine
import SwiftUI

/// 模拟下载 + 两个窗口内视频表面，使用生产 Card / Drag Overlay / Coordinator / Runtime / Crossfade / Menu controls。
/// 不联网，不改真实桌面，不写用户资料库；模拟内容只在此会话的内存中。
@MainActor
final class AppControlsTestSession {
    private var window: NSWindow?
    private var model: AppControlsTestModel?
    func start() {
        guard let model = AppControlsTestModel() else { return }
        self.model = model
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1080, height: 790),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Kinetic — 下载应用与菜单控制验收（模拟设备）"
        window.isReleasedWhenClosed = false
        window.minSize = .init(width: 1000, height: 770)
        window.contentView = NSHostingView(rootView: AppControlsTestPanel(model: model))
        window.center(); window.makeKeyAndOrderFront(nil)
        self.window = window
        model.reset()
    }
    func stop() { model?.stop(); window?.close(); model = nil; window = nil }
}

@MainActor
private final class AppControlsTestModel: ObservableObject {
    let a = DisplayID("acceptance-A"), b = DisplayID("acceptance-B")
    let runtime = WallpaperRuntimeManager()
    let first = WindowVideoHost(), second = WindowVideoHost()
    let old: Wallpaper, candidate: Wallpaper
    let remote = SteamStoreItem(workshopID: "simulated", title: "模拟远程壁纸", previewURL: nil, creatorSteamID: nil,
                               authorName: "本地验收", timeCreated: nil, timeUpdated: nil, fileSize: nil, type: .video, tags: [])
    let posters = SteamPosterCache(directory: nil)
    @Published var notice = "模拟下载等待有效松手；不操作真实桌面"
    @Published var selected = false
    @Published var isDownloading = false
    @Published var prepareShouldFail = false
    @Published var drag = SteamDisplayDragPresentation()
    var frames: [DisplayID: CGRect] = [:]
    private(set) var records: [Wallpaper.ID: Wallpaper] = [:]
    private var continuation: CheckedContinuation<Result<Wallpaper, SteamAcquisitionError>, Never>?
    private var coordinator: SteamDisplayApplyCoordinator!
    private var subscriptions = Set<AnyCancellable>()

    init?() {
        guard let cool = Bundle.main.url(forResource: "loop", withExtension: "mp4", subdirectory: "Fixtures"),
              let warm = Bundle.main.url(forResource: "loop-warm", withExtension: "mp4", subdirectory: "Fixtures") else { return nil }
        old = Wallpaper(name: "原蓝色视频", type: .video, source: .local, resourceURL: cool)
        candidate = Wallpaper(name: "新暖色视频", type: .video, source: .steam, resourceURL: warm)
        runtime.addDisplay(a, name: "模拟显示器 A", host: CrossfadeDesktopHost(desktop: first), frame: .init(x: 0, y: 0, width: 1600, height: 1000))
        connectSecond()
        runtime.$summary.sink { [weak self] summary in
            self?.objectWillChange.send()
            self?.drag.refresh(frames: self?.frames ?? [:], displays: summary.displays.map(\.id))
        }.store(in: &subscriptions)
        runtime.$isAudioEnabled.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        coordinator = SteamDisplayApplyCoordinator(runtime: runtime, resolveWorkshop: { [weak self] _ in
            guard let self else { return nil }; return self.records[self.candidate.id]
        }, resolveWallpaper: { [weak self] in self?.records[$0] }, acquire: { [weak self] _ in
            guard let self else { return .failure(.network) }
            self.isDownloading = true
            self.notice = "下载中：旧壁纸应继续显示（模拟 38%）"
            return await withCheckedContinuation { self.continuation = $0 }
        })
        coordinator.notices.sink { [weak self] in self?.notice = $0.message }.store(in: &subscriptions)
    }

    var items: [DisplayTargetItem] {
        runtime.summary.displays.enumerated().map {
            DisplayTargetItem(display: $1, index: $0, wallpaper: runtime.activeWallpaper(on: $1.id))
        }
    }
    var cardState: SteamStoreCardState { isDownloading ? .downloading(progress: 0.38) : records[candidate.id] == nil ? .remote : .inLibrary(candidate.id) }

    func reset() {
        continuation?.resume(returning: .failure(.network)); continuation = nil
        coordinator.cancelApplication(on: a); coordinator.cancelApplication(on: b)
        isDownloading = false; prepareShouldFail = false; drag.cancel(); frames = [:]
        records = [old.id: old]
        if !runtime.hasDisplay(b) { connectSecond() }
        runtime.setSmartPauseActive(false); runtime.stop(.allDisplays)
        runtime.apply(old, to: a); runtime.apply(old, to: b)
        notice = "两屏显示原视频，等待拖放"
    }
    func stop() {
        coordinator.shutdown()
        continuation?.resume(returning: .failure(.network)); continuation = nil
        runtime.shutdown(); subscriptions.removeAll()
    }
    func completeDownload(succeeds: Bool) {
        guard let continuation else { return }
        self.continuation = nil; isDownloading = false
        if succeeds {
            var record = candidate
            if prepareShouldFail { record.resourceURL = URL(fileURLWithPath: "/kinetic-acceptance-missing.mp4") }
            records[record.id] = record
            continuation.resume(returning: .success(record))
        } else { continuation.resume(returning: .failure(.network)) }
    }
    func connectSecond() {
        runtime.addDisplay(b, name: "模拟显示器 B", host: CrossfadeDesktopHost(desktop: second), frame: .init(x: 0, y: 0, width: 1600, height: 1000))
    }
    func handle(_ event: CardDisplayDragEvent) {
        switch event {
        case .began: frames = [:]; drag.begin(remote, posterURL: nil)
        case .moved(let point): drag.move(point, from: remote.id, frames: frames, displays: runtime.displayIDs)
        case .ended(let point):
            if let (item, display) = drag.takeDrop(from: remote.id, at: point, frames: frames, displays: runtime.displayIDs) {
                coordinator.request(item.acquisitionInfo, to: display)
            }
        case .cancelled: drag.cancel()
        }
    }
    func hoverSecond() {
        if let frame = frames[b] { handle(.moved(.init(x: frame.midX, y: frame.midY))) }
    }
    func release() { handle(.ended(drag.location ?? .init(x: -1, y: -1))) }
    func summary(_ display: DisplayID) -> String {
        let state = runtime.state(of: display)
        return "\(runtime.activeWallpaper(on: display)?.name ?? "原生壁纸") · \(state?.playbackState.rawValue ?? "disconnected")"
    }
}

@MainActor
private struct AppControlsTestPanel: View {
    @ObservedObject var model: AppControlsTestModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("模拟设备验收：Steam 长按与全局控制。窗口内播放真实视频，下载用手动完成按钮模拟。")
            HStack(alignment: .top, spacing: 20) {
                VStack { Text("显示器 A"); WindowVideoPreview(host: model.first).frame(width: 300, height: 180); Text(model.summary(model.a)) }
                VStack { Text("显示器 B"); WindowVideoPreview(host: model.second).frame(width: 300, height: 180); Text(model.summary(model.b)) }
                VStack(alignment: .leading, spacing: 10) {
                    let summary = MenuBarPlaybackPresentation(summary: model.runtime.summary, isInLibrary: { model.records[$0] != nil })
                    Image(nsImage: KineticLogo.menuBarImage(accent: summary.iconUsesAccent))
                    Text(summary.summaryText)
                    MenuBarGlobalControls(runtime: model.runtime, isInLibrary: { model.records[$0] != nil })
                }.frame(width: 300)
            }
            HStack(spacing: 24) {
                SteamStoreCard(item: model.remote, state: model.cardState, isSelected: model.selected, posters: model.posters,
                               onSelect: { model.selected = true },
                               onDownload: { _ in model.notice = "双击：只下载到本地；未发送显示器应用请求" },
                               onDisplayDrag: { _, event in model.handle(event) }).frame(width: 145)
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Button("开始拖动（测试）") { model.handle(.began) }
                        Button("悬停 B（测试）") { model.hoverSecond() }
                        Button("松手（测试）") { model.release() }
                        Button("取消") { model.handle(.cancelled) }
                    }
                    HStack {
                        Button("下载完成（模拟）") { model.completeDownload(succeeds: true) }.disabled(!model.isDownloading)
                        Button("下载失败（模拟）") { model.completeDownload(succeeds: false) }.disabled(!model.isDownloading)
                        Toggle("模拟准备失败", isOn: $model.prepareShouldFail)
                    }
                    HStack {
                        Button("断开 B") { model.runtime.removeDisplay(model.b); model.frames = [:] }
                        Button("重新连接 B") { model.connectSecond() }
                        Button("仅停止 A") { model.runtime.stop(.display(model.a)) }
                        Button("重置验收") { model.reset() }
                    }
                    Text(model.notice).fixedSize(horizontal: false, vertical: true)
                    Text("内存资料库：\(model.records.count) 项；\(model.isDownloading ? "下载中" : "无下载")").font(.caption)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(24).padding(.top, 150)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { WindowGlassBackground() }
        .overlay {
            if let item = model.drag.item {
                WallpaperDisplayDragOverlay(location: model.drag.location, items: model.items, hoveredID: model.drag.hoveredDisplayID) {
                    PosterView(posterURL: model.drag.posterURL, placeholderType: item.type ?? .web)
                }
            }
        }
        .onPreferenceChange(DisplayTargetFrameKey.self) {
            model.frames = $0; model.drag.refresh(frames: $0, displays: model.runtime.displayIDs)
        }
        .onExitCommand { model.drag.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in model.drag.cancel() }
    }
}

@MainActor
private final class WindowVideoHost: DesktopContentHost {
    let view = NSView(frame: .init(x: 0, y: 0, width: 300, height: 180))
    func present(_ content: NSView) -> Bool {
        if content.superview !== view {
            view.subviews.forEach { $0.removeFromSuperview() }
            content.frame = view.bounds; content.autoresizingMask = [.width, .height]; view.addSubview(content)
        }
        return true
    }
    func stop() { view.subviews.forEach { $0.removeFromSuperview() } }
}
private struct WindowVideoPreview: NSViewRepresentable {
    let host: WindowVideoHost
    func makeNSView(context: Context) -> NSView { host.view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif
