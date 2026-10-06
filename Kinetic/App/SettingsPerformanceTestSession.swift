#if DEBUG
import AppKit
import Combine
import SwiftUI

/// Production settings and real video sessions, with in-memory preferences and injected system conditions.
/// Never registers a login item, writes assignments, or creates real system pressure.
/// The explicit real-desktop button creates an ephemeral surface with the production system probe.
@MainActor
final class SettingsPerformanceTestSession {
    private var windows: [NSWindow] = []
    private var model: SettingsPerformanceTestModel?
    func start() {
        guard let model = SettingsPerformanceTestModel() else { return }
        self.model = model
        let settings = NSWindow(contentRect: .init(x: 80, y: 280, width: 800, height: 570),
                                styleMask: [.titled, .closable], backing: .buffered, defer: false)
        settings.title = "Kinetic — 设置验收（内存配置）"
        settings.isReleasedWhenClosed = false
        settings.contentView = NSHostingView(rootView: SettingsContentView(settings: model.settings, runtime: model.runtime,
            loginItems: model.login, steam: nil, store: nil, library: nil, monitor: model.monitor)
            .environment(\.locale, Locale(identifier: "zh-Hans"))
            .background { WindowGlassBackground(style: .sidebar).ignoresSafeArea() })
        let controls = NSWindow(contentRect: .init(x: 900, y: 280, width: 650, height: 570),
                                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        controls.title = "Kinetic — 暂停策略验收（模拟条件）"
        controls.isReleasedWhenClosed = false
        controls.minSize = .init(width: 650, height: 590)
        controls.contentView = NSHostingView(rootView: SettingsPerformanceTestPanel(model: model))
        windows = [settings, controls]
        controls.makeKeyAndOrderFront(nil); settings.makeKeyAndOrderFront(nil)
        model.reset()
    }
    func stop() { model?.stop(); windows.forEach { $0.close() }; windows = []; model = nil }
}

@MainActor
private final class SettingsPerformanceTestModel: ObservableObject {
    let a = DisplayID("settings-test-A"), b = DisplayID("settings-test-B")
    let settings = SettingsStore(defaults: SettingsTestDefaults())
    let runtime = WallpaperRuntimeManager()
    let first = SettingsTestVideoHost(), second = SettingsTestVideoHost()
    let probe = SettingsTestSystemProbe()
    let wallpaper: Wallpaper
    lazy var login = LoginItemController(service: SettingsTestLoginService(), settings: settings)
    lazy var monitor = SmartPauseMonitor(probe: probe, workspaceNotifications: NotificationCenter(),
        distributedNotifications: NotificationCenter(), applicationNotifications: NotificationCenter(),
        desktopWindowIdentifier: .init("settings-test"), usesPerDisplayPolicy: true,
        onDisplayChange: { [weak self] global, displays in self?.runtime.setSmartPausePolicy(global: global, displays: displays) },
        onChange: { _ in })
    private let appearance = AppearanceTransition()
    private var subscriptions = Set<AnyCancellable>()
    private var liveRuntime: WallpaperRuntimeManager?
    private var liveMonitor: SmartPauseMonitor?
    private var liveSubscriptions = Set<AnyCancellable>()
    @Published var liveStatus = "实际桌面验收未启动"
    @Published var fullscreen = false
    @Published var occluded = false
    @Published var locked = false
    @Published var thermal = false
    @Published var memory = false
    init?() {
        guard let url = Bundle.main.url(forResource: "loop", withExtension: "mp4", subdirectory: "Fixtures") else { return nil }
        wallpaper = Wallpaper(name: "窗口内蓝色视频", type: .video, source: .local, resourceURL: url)
        runtime.addDisplay(a, name: "模拟显示器 A", host: CrossfadeDesktopHost(desktop: first), frame: .init(x: 0, y: 0, width: 1600, height: 1000))
        runtime.addDisplay(b, name: "模拟显示器 B", host: CrossfadeDesktopHost(desktop: second), frame: .init(x: 1600, y: 0, width: 1600, height: 1000))
        monitor.updateDisplays([a, b]); monitor.start()
        settings.$state.sink { [weak self] state in
            guard let self else { return }
            self.monitor.preferences = SmartPausePreferences(settings: state)
            self.appearance.apply(state.appearance, animated: true)
        }.store(in: &subscriptions)
        runtime.$summary.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        runtime.$isAudioEnabled.dropFirst().sink { [weak self] in self?.settings.set(\.wallpaperAudioEnabled, to: $0) }
            .store(in: &subscriptions)
    }
    func update() {
        probe.isScreenLocked = locked; probe.isThermalCritical = thermal; probe.isMemoryCritical = memory
        probe.local[b] = .init(fullScreenApp: fullscreen, occluded: occluded, frontmostBundleID: "com.apple.Safari")
        monitor.refreshQueryableConditions()
    }
    func reset() {
        fullscreen = false; occluded = false; locked = false; thermal = false; memory = false
        update(); runtime.stop(.allDisplays)
        runtime.apply(wallpaper, to: a); runtime.apply(wallpaper, to: b)
    }
    func status(_ id: DisplayID) -> String { runtime.state(of: id)?.playbackState.rawValue ?? "—" }
    func startLive() {
        guard liveRuntime == nil, let display = DisplayRegistry.systemDisplays().first else { return }
        let identifier = NSUserInterfaceItemIdentifier("Kinetic.SettingsLiveTest")
        let desktop = DesktopWindowRuntime(identifier: .init(identifier.rawValue + "." + display.id.rawValue),
            primaryDisplay: { display.desktop })
        let runtime = WallpaperRuntimeManager()
        runtime.addDisplay(display.id, name: display.name, host: CrossfadeDesktopHost(desktop: desktop))
        let monitor = SmartPauseMonitor(probe: LiveSmartPauseProbe(desktopWindowIdentifier: identifier),
            workspaceNotifications: NSWorkspace.shared.notificationCenter,
            distributedNotifications: DistributedNotificationCenter.default(), applicationNotifications: .default,
            desktopWindowIdentifier: identifier, usesPerDisplayPolicy: true,
            onDisplayChange: { [weak runtime] in runtime?.setSmartPausePolicy(global: $0, displays: $1) }, onChange: { _ in })
        liveRuntime = runtime; liveMonitor = monitor
        settings.$state.sink { [weak monitor] in monitor?.preferences = SmartPausePreferences(settings: $0) }
            .store(in: &liveSubscriptions)
        runtime.$summary.sink { [weak self] summary in
            self?.liveStatus = "实际桌面：" + (summary.displays.first?.runtime.playbackState.rawValue ?? "—")
        }.store(in: &liveSubscriptions)
        monitor.updateDisplays([display.id]); monitor.start(); runtime.apply(wallpaper, to: display.id)
    }
    func stopLive() {
        liveMonitor?.stop(); liveRuntime?.shutdown(); liveSubscriptions.removeAll()
        liveMonitor = nil; liveRuntime = nil; liveStatus = "实际桌面验收未启动"
    }
    func stop() { stopLive(); monitor.stop(); runtime.shutdown(); subscriptions.removeAll() }
}

@MainActor
private struct SettingsPerformanceTestPanel: View {
    @ObservedObject var model: SettingsPerformanceTestModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("上方使用模拟条件与窗口内真实视频，不操作登录项。").foregroundStyle(.secondary)
            HStack(spacing: 20) {
                VStack { Text("显示器 A"); SettingsTestVideoView(host: model.first).frame(width: 280, height: 175); Text(model.status(model.a)) }
                VStack { Text("显示器 B"); SettingsTestVideoView(host: model.second).frame(width: 280, height: 175); Text(model.status(model.b)) }
            }
            HStack {
                Toggle("B 全屏", isOn: condition(\.fullscreen))
                Toggle("B 遮挡", isOn: condition(\.occluded))
                Toggle("锁屏", isOn: condition(\.locked))
            }
            HStack {
                Toggle("严重温度", isOn: condition(\.thermal))
                Toggle("严重内存压力", isOn: condition(\.memory))
            }
            HStack {
                Button("手动暂停 A") { model.runtime.pause(.display(model.a)) }
                Button("停止 B") { model.runtime.stop(.display(model.b)) }
                Button("继续全部") { model.runtime.resume(.allDisplays) }
                Button("重置") { model.reset() }
            }
            Text("B 的前台应用模拟为 Safari，可通过设置中的应用例外验证策略。").foregroundStyle(.secondary)
            Divider()
            HStack {
                Button("启动实际桌面验收") { model.startLive() }
                Button("停止实际桌面验收") { model.stopLive() }
            }
            Text(model.liveStatus)
            Text("实际桌面模式读取真实系统条件，不写资料库或显示器分配；停止后恢复原生壁纸。").foregroundStyle(.secondary)
        }.padding(22).frame(width: 650, height: 570, alignment: .topLeading)
    }
    private func condition(_ key: ReferenceWritableKeyPath<SettingsPerformanceTestModel, Bool>) -> Binding<Bool> {
        Binding(get: { model[keyPath: key] }, set: { model[keyPath: key] = $0; model.update() })
    }
}

private final class SettingsTestDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    init() { super.init(suiteName: nil)! }
    override func data(forKey defaultName: String) -> Data? { values[defaultName] as? Data }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
}
@MainActor
private final class SettingsTestLoginService: LoginItemService {
    var status = LoginItemStatus.disabled
    func register() throws { status = .enabled }
    func unregister() throws { status = .disabled }
    func openSystemSettings() {}
}
@MainActor
private final class SettingsTestSystemProbe: SmartPauseSystemProbe {
    var isScreenLocked = false, isThermalCritical = false, isMemoryCritical = false
    var isDisplayAsleep = false, isFullScreenAppActive = false, isBatteryLow = false
    var isLowPowerModeEnabled = false, isOnBatteryPower = false
    var local: [DisplayID: DisplayPauseConditions] = [:]
    func displayConditions(for displays: [DisplayID]) -> [DisplayID: DisplayPauseConditions] { local.filter { displays.contains($0.key) } }
    func startObservingPowerSource(_ onChange: @escaping @MainActor () -> Void) {}
    func stopObservingPowerSource() {}
}
@MainActor
private final class SettingsTestVideoHost: DesktopContentHost {
    let view = NSView(frame: .init(x: 0, y: 0, width: 280, height: 175))
    func present(_ content: NSView) -> Bool {
        if content.superview !== view {
            view.subviews.forEach { $0.removeFromSuperview() }
            content.frame = view.bounds; content.autoresizingMask = [.width, .height]; view.addSubview(content)
        }
        return true
    }
    func stop() { view.subviews.forEach { $0.removeFromSuperview() } }
}
private struct SettingsTestVideoView: NSViewRepresentable {
    let host: SettingsTestVideoHost
    func makeNSView(context: Context) -> NSView { host.view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif
