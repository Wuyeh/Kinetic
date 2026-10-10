#if DEBUG
import AppKit
import Combine
import KineticSceneRuntime
import SwiftUI

/// Isolated Module 29 acceptance: bundled self-authored scene, temporary library, two embedded surfaces.
/// No real desktop, saved assignments, Steam credentials or login service.
@MainActor
final class ScenePropertiesTestSession {
    private var window: NSWindow?
    private var model: ScenePropertiesTestModel?
    func start() {
        do {
            let model = try ScenePropertiesTestModel()
            self.model = model
            let window = NSWindow(contentRect: .init(x: 120, y: 100, width: 1_060, height: 760),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Kinetic — Module 29 场景属性与预设验收"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ScenePropertiesTestPanel(model: model)
                .environment(\.locale, Locale(identifier: "zh-Hans")))
            self.window = window
            window.makeKeyAndOrderFront(nil)
            model.runtime.apply(model.wallpaper, to: model.a)
            model.runtime.apply(model.other, to: model.b)
        } catch { NSLog("Module 29 acceptance: %@", error.localizedDescription) }
    }
    func stop() { model?.runtime.shutdown(); window?.close(); model = nil; window = nil }
}

@MainActor
private final class ScenePropertiesTestModel: ObservableObject {
    let a = DisplayID("scene-properties-A"), b = DisplayID("scene-properties-B")
    let hostA = ScenePropertiesTestHost(), hostB = ScenePropertiesTestHost()
    let library: WallpaperLibrary
    let wallpaper: Wallpaper, other: Wallpaper
    let storage: LibraryStorageLocation
    @Published var store: ScenePropertyStore
    @Published var error: String?
    lazy var runtime = WallpaperRuntimeManager { [weak self] wallpaper in
        SceneRenderer(wallpaper: wallpaper, engineAssets: nil,
                      propertyValues: self?.store.configuration(for: wallpaper.id).values ?? [:])
    }
    private var subscriptions = Set<AnyCancellable>()
    init() throws {
        guard let root = Bundle.main.url(forResource: "scene-properties-sample", withExtension: nil, subdirectory: "Fixtures"),
              let cool = Bundle.main.url(forResource: "scene-full-sample", withExtension: nil, subdirectory: "Fixtures") else {
            throw ScenePropertyStoreError.unreadable
        }
        storage = .init(rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("Kinetic-Module29/" + UUID().uuidString))
        store = ScenePropertyStore(storage: storage)
        library = WallpaperLibrary(storage: storage)
        wallpaper = Wallpaper(name: "属性验证场景", type: .scene, source: .local, resourceURL: root)
        other = Wallpaper(name: "另一屏场景", type: .scene, source: .local, resourceURL: cool.appendingPathComponent("cool"))
        try library.add(other); try library.add(wallpaper)
        runtime.addDisplay(a, host: CrossfadeDesktopHost(desktop: hostA))
        runtime.addDisplay(b, host: CrossfadeDesktopHost(desktop: hostB))
        runtime.$summary.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
    }
    func reloadStore() { store = ScenePropertyStore(storage: storage) }
}

@MainActor
private struct ScenePropertiesTestPanel: View {
    @ObservedObject var model: ScenePropertiesTestModel
    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            ScrollView {
                ScenePropertiesSection(library: model.library, store: model.store, runtime: model.runtime)
                    .id(ObjectIdentifier(model.store)).padding(24)
            }.frame(width: 650)
            VStack(alignment: .leading, spacing: 12) {
                Text("A — 属性验证场景").font(.headline)
                ScenePropertiesTestSurface(host: model.hostA).frame(width: 320, height: 180)
                Text(model.runtime.state(of: model.a)?.playbackState.rawValue ?? "—")
                HStack {
                    Button("暂停 A") { model.runtime.pause(.display(model.a)) }.kineticGlassButton()
                    Button("继续 A") { model.runtime.resume(.display(model.a)) }.kineticGlassButton()
                }
                Text("B — 另一场景，保持播放").font(.headline)
                ScenePropertiesTestSurface(host: model.hostB).frame(width: 320, height: 180)
                Text(model.runtime.state(of: model.b)?.playbackState.rawValue ?? "—")
                Button("重新读取已保存设置") { model.reloadStore() }.kineticGlassButton()
                if let failure = model.runtime.lastFailure { Text(failure.detail).foregroundStyle(.red) }
                Text("独立预览，不操作真实桌面或 Steam。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.top, 24)
        }.background { WindowGlassBackground(style: .sidebar).ignoresSafeArea() }
    }
}
@MainActor
private final class ScenePropertiesTestHost: DesktopContentHost {
    let view = NSView()
    func present(_ contentView: NSView) -> Bool {
        view.subviews.forEach { $0.removeFromSuperview() }
        contentView.frame = view.bounds; contentView.autoresizingMask = [.width, .height]
        view.addSubview(contentView); return true
    }
    func stop() { view.subviews.forEach { $0.removeFromSuperview() } }
}
private struct ScenePropertiesTestSurface: NSViewRepresentable {
    let host: ScenePropertiesTestHost
    func makeNSView(context: Context) -> NSView { host.view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif
