#if DEBUG
import AppKit
import Combine
import SwiftUI

/// Two independent real video surfaces; never restore or change the user's desktop/library.
@MainActor
final class AdvancedVideoTestSession {
    private var window: NSWindow?
    private var model: AdvancedVideoTestModel?
    func start() {
        do {
            let model = try AdvancedVideoTestModel(); self.model = model
            let window = NSWindow(contentRect: .init(x: 100, y: 100, width: 1080, height: 840),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Kinetic — Module 30 高级视频验收"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: AdvancedVideoTestPanel(model: model)
                .environment(\.locale, Locale(identifier: "zh-Hans")))
            self.window = window; window.makeKeyAndOrderFront(nil)
            model.runtime.apply(model.video, to: model.a); model.runtime.apply(model.other, to: model.b)
        } catch { NSLog("Module 30 acceptance: %@", error.localizedDescription) }
    }
    func stop() { model?.preview.stop(); model?.runtime.shutdown(); window?.close(); model = nil; window = nil }
}

@MainActor
private final class AdvancedVideoTestModel: ObservableObject {
    let a = DisplayID("advanced-video-A"), b = DisplayID("advanced-video-B")
    let hostA = AdvancedVideoTestHost(), hostB = AdvancedVideoTestHost()
    let preview = VideoPlaybackPreview()
    let library: WallpaperLibrary
    let video: Wallpaper, other: Wallpaper
    let storage: LibraryStorageLocation
    @Published var store: VideoPlaybackStore
    lazy var runtime = WallpaperRuntimeManager { [weak self] wallpaper in
        VideoRenderer(wallpaper: wallpaper, options: self?.store.configuration(for: wallpaper.id) ?? .init())
    }
    private var subscriptions = Set<AnyCancellable>()
    init() throws {
        guard let aURL = Bundle.main.url(forResource: "loop", withExtension: "mp4", subdirectory: "Fixtures"),
              let bURL = Bundle.main.url(forResource: "loop", withExtension: "mov", subdirectory: "Fixtures") else {
            throw VideoRendererError.missingFile
        }
        storage = .init(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("Kinetic-Module30/" + UUID().uuidString))
        store = VideoPlaybackStore(storage: storage); library = WallpaperLibrary(storage: storage)
        video = Wallpaper(name: "A — 视频设置验证", type: .video, source: .local, resourceURL: aURL)
        other = Wallpaper(name: "B — 另一视频", type: .video, source: .local, resourceURL: bURL)
        try library.add(other); try library.add(video)
        runtime.addDisplay(a, host: CrossfadeDesktopHost(desktop: hostA))
        runtime.addDisplay(b, host: CrossfadeDesktopHost(desktop: hostB))
        runtime.$summary.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
    }
    func reloadStore() { store = VideoPlaybackStore(storage: storage) }
}

@MainActor
private struct AdvancedVideoTestPanel: View {
    @ObservedObject var model: AdvancedVideoTestModel
    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            ScrollView {
                VideoPlaybackSettingsSection(library: model.library, store: model.store, runtime: model.runtime,
                                             preview: model.preview, showsInlinePreview: false)
                    .id(ObjectIdentifier(model.store)).padding(24)
            }.frame(width: 670)
            ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                VideoPlaybackPreviewView(preview: model.preview).frame(width: 320)
                Text("A — 已应用的模拟主屏").font(.headline)
                AdvancedVideoTestSurface(host: model.hostA).frame(width: 320, height: 150)
                Text(model.runtime.state(of: model.a)?.playbackState.rawValue ?? "—")
                HStack {
                    Button("暂停 A") { model.runtime.pause(.display(model.a)) }.kineticGlassButton()
                    Button("继续 A") { model.runtime.resume(.display(model.a)) }.kineticGlassButton()
                }
                Text("B — 保持原播放").font(.headline)
                AdvancedVideoTestSurface(host: model.hostB).frame(width: 320, height: 100)
                Text(model.runtime.state(of: model.b)?.playbackState.rawValue ?? "—")
                HStack {
                    Button("重新读取设置") { model.reloadStore() }.kineticGlassButton()
                    Button("停止全部") { model.runtime.stop() }.kineticGlassButton()
                    Button("重新播放样例") {
                        model.runtime.apply(model.video, to: model.a); model.runtime.apply(model.other, to: model.b)
                    }.kineticGlassButton()
                }
                if let failure = model.runtime.lastFailure { Text(failure.detail).foregroundStyle(.red) }
                Text("效果预览跟随草稿；A / B 模拟屏幕，只在保存后更新。不操作真实桌面、资料库或 Steam。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.top, 24)
            }.frame(width: 340)
        }.background { WindowGlassBackground(style: .sidebar).ignoresSafeArea() }
    }
}
@MainActor
private final class AdvancedVideoTestHost: DesktopContentHost {
    let view = NSView()
    func present(_ content: NSView) -> Bool {
        view.subviews.forEach { $0.removeFromSuperview() }
        content.frame = view.bounds; content.autoresizingMask = [.width, .height]
        view.addSubview(content); return true
    }
    func stop() { view.subviews.forEach { $0.removeFromSuperview() } }
}
private struct AdvancedVideoTestSurface: NSViewRepresentable {
    let host: AdvancedVideoTestHost
    func makeNSView(context: Context) -> NSView { host.view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif
