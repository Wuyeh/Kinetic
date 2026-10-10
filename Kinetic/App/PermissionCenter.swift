import AppKit
import Combine
import CoreLocation
import SwiftUI

/// Module 55：一项系统权限现在的状态。
enum PermissionState: Equatable, Sendable {
    case granted
    /// 还没有询问过（点「请求授权」时系统才会弹出询问）。
    case notDetermined
    case denied
    /// 家长控制、描述文件等限制，用户在 Kinetic 里改不了。
    case restricted
    /// 现在查不到：例如播放器没有运行、系统定位服务整体关闭。
    case unavailable(String)

    var label: String {
        switch self {
        case .granted: return "已允许"
        case .notDetermined: return "未询问"
        case .denied: return "已拒绝"
        case .restricted: return "受限制"
        case .unavailable: return "无法查看"
        }
    }

    var color: Color {
        switch self {
        case .granted: return .green
        case .denied, .restricted: return .orange
        case .notDetermined, .unavailable: return .secondary
        }
    }

    var detail: String? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }

    static func location(_ status: CLAuthorizationStatus, servicesEnabled: Bool) -> PermissionState {
        guard servicesEnabled else { return .unavailable("系统的定位服务整体关闭了（系统设置 › 隐私与安全性 › 定位服务）。") }
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        // authorizedAlways / authorized / authorizedWhenInUse：macOS 上都表示可以取位置。
        default: return .granted
        }
    }

    /// 只读状态（不弹询问）的 Apple Events 结果。
    static func automation(_ availability: MusicAvailability, player: String) -> PermissionState {
        switch availability {
        case .live, .noTrack, .inactive, .timedOut: return .granted
        case .permissionRequired: return .notDetermined
        case .denied: return .denied
        case .notRunning: return .unavailable("\(player) 没有运行；打开它之后才能查看或请求授权。")
        case .unavailable: return .unavailable("macOS 没有返回 \(player) 的授权状态。")
        }
    }

    static func screenCapture(_ granted: Bool) -> PermissionState { granted ? .granted : .notDetermined }
}

/// 系统设置里对应的隐私页面。
enum PrivacyPane: String, CaseIterable, Sendable {
    case locationServices = "Privacy_LocationServices"
    case automation = "Privacy_Automation"
    case screenCapture = "Privacy_ScreenCapture"

    var url: URL { URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)")! }

    @MainActor func open() {
        if !NSWorkspace.shared.open(url),
           let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") {
            NSWorkspace.shared.open(app)
        }
    }
}

/// 只查状态、不弹询问的读取方式；测试里替换。
@MainActor
protocol PermissionProbing: AnyObject {
    var locationStatus: CLAuthorizationStatus { get }
    var locationServicesEnabled: Bool { get }
    func automationStatus(_ source: MusicSource) async -> MusicAvailability
    var screenCaptureGranted: Bool { get }
}

@MainActor
final class SystemPermissionProbe: PermissionProbing {
    private let reader = LiveMusicReader()
    let locationManager = CLLocationManager()
    var locationStatus: CLAuthorizationStatus { locationManager.authorizationStatus }
    var locationServicesEnabled: Bool { CLLocationManager.locationServicesEnabled() }
    func automationStatus(_ source: MusicSource) async -> MusicAvailability { await reader.permissionStatus(source) }
    var screenCaptureGranted: Bool { CGPreflightScreenCaptureAccess() }
}

/// Module 55：设置 › 权限。
///
/// 打开页面、从系统设置回到 Kinetic 时只读状态，不触发任何系统询问；只有点「请求授权」才询问，
/// 已拒绝的项目只能在系统设置里改，按钮直接打开对应页面。首次启动不请求任何权限。
@MainActor
final class PermissionCenter: NSObject, ObservableObject {
    @Published private(set) var location: PermissionState = .notDetermined
    @Published private(set) var automation: [MusicSource: PermissionState] = [:]
    @Published private(set) var screenCapture: PermissionState = .notDetermined
    @Published private(set) var isRequesting = false

    private let probe: PermissionProbing
    private let music: MusicService?
    private let audioResponse: AudioResponseService?
    private var subscriptions = Set<AnyCancellable>()

    init(probe: PermissionProbing? = nil, music: MusicService? = nil, audioResponse: AudioResponseService? = nil) {
        let probe = probe ?? SystemPermissionProbe()
        self.probe = probe
        self.music = music
        self.audioResponse = audioResponse
        super.init()
        (probe as? SystemPermissionProbe)?.locationManager.delegate = self
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refreshSoon() }.store(in: &subscriptions)
    }

    func refreshSoon() { Task { await refresh() } }

    func refresh() async {
        location = .location(probe.locationStatus, servicesEnabled: probe.locationServicesEnabled)
        screenCapture = .screenCapture(probe.screenCaptureGranted)
        var states: [MusicSource: PermissionState] = [:]
        for source in MusicSource.allCases {
            states[source] = .automation(await probe.automationStatus(source), player: source.title)
        }
        automation = states
    }

    func requestLocation() {
        switch location {
        case .notDetermined:
            (probe as? SystemPermissionProbe)?.locationManager.requestWhenInUseAuthorization()
        default:
            PrivacyPane.locationServices.open()
        }
    }

    func requestAutomation(_ source: MusicSource) {
        guard automation[source] == .notDetermined else {
            PrivacyPane.automation.open()
            return
        }
        isRequesting = true
        Task {
            if let music { _ = await music.authorize(source) } else { _ = await LiveMusicReader().authorize(source) }
            isRequesting = false
            await refresh()
        }
    }

    /// 与设置 › 音乐「授权或重新连接系统音频」同一入口；macOS 不再弹询问时打开系统设置。
    func requestScreenCapture() {
        if screenCapture == .granted {
            PrivacyPane.screenCapture.open()
        } else {
            _ = SystemAudioCapture().requestPermission()
            audioResponse?.refreshAuthorization()
        }
        refreshSoon()
    }
}

extension PermissionCenter: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in await self?.refresh() }
    }
}

struct PermissionCenterView: View {
    @ObservedObject var center: PermissionCenter
    var engineAssets: EngineAssetsStore?
    var onOpenSteamSettings: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Kinetic 不会在首次打开时一次性请求权限：每一项只在你用到对应功能，或在这里点「请求授权」时才询问。从系统设置改完回来，这里的状态会自动更新。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            row(symbol: "location", title: "定位", state: center.location,
                purpose: "只用于天气：天气地点选「系统定位」时取大致位置查询当地天气。手动填写城市时不需要。") {
                action(for: center.location, request: "请求授权", perform: center.requestLocation)
            }
            ForEach(MusicSource.allCases, id: \.self) { source in
                let state = center.automation[source] ?? .notDetermined
                row(symbol: "music.note", title: "自动化：\(source.title)", state: state,
                    purpose: "读取 \(source.title) 正在播放的曲目、封面和进度，供音乐卡片与歌词使用；播放控制只在你点相应按钮时执行。") {
                    if case .unavailable = state {
                        EmptyView()
                    } else {
                        action(for: state, request: "请求授权") { center.requestAutomation(source) }
                            .disabled(center.isRequesting)
                    }
                }
            }
            row(symbol: "waveform", title: "屏幕与系统录音", state: center.screenCapture,
                purpose: "只取系统声音（不录屏幕画面），让壁纸的音柱和粒子随音乐跳动。macOS 把它归在「录屏与系统录音」里。") {
                action(for: center.screenCapture, request: "请求授权", perform: center.requestScreenCapture)
            }
            fileAccess
            row(symbol: "hand.raised", title: "网页壁纸的摄像头、麦克风、定位", state: nil,
                purpose: "始终拦截：网页壁纸无法使用摄像头、麦克风或定位，Kinetic 也不会为它们请求这些权限。") { EmptyView() }
        }
        .task { await center.refresh() }
    }

    private var fileAccess: some View {
        row(symbol: "folder", title: "文件访问", state: nil,
            purpose: "资料库在 Kinetic 自己的容器里，不需要额外权限；导入和导出每次都通过系统的文件面板由你选择，不保留长期访问。") {
            VStack(alignment: .leading, spacing: 6) {
                Text(Self.engineAssetsText(engineAssets?.status)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let onOpenSteamSettings {
                    Button("在设置 › Steam 中管理", action: onOpenSteamSettings).kineticGlassButton()
                }
            }
        }
    }

    static func engineAssetsText(_ status: EngineAssetsStore.Status?) -> String {
        switch status {
        case .ready(.linked, let name)?: return "Wallpaper Engine 素材：已链接文件夹「\(name ?? "assets")」（只读，书签保存在 Kinetic 里）。"
        case .ready(.downloaded, _)?: return "Wallpaper Engine 素材：使用 Kinetic 下载的副本，不需要额外权限。"
        case .unavailable(.linked, let reason)?: return "Wallpaper Engine 素材：链接的文件夹现在读不到（\(reason)），可以重新链接。"
        case .unavailable(_, let reason)?: return "Wallpaper Engine 素材：现在读不到（\(reason)）。"
        case .notConfigured?, nil: return "Wallpaper Engine 素材：还没有链接或下载。"
        }
    }

    @ViewBuilder
    private func action(for state: PermissionState, request: String, perform: @escaping () -> Void) -> some View {
        switch state {
        case .notDetermined:
            Button(request, action: perform).kineticGlassButton()
        case .denied, .restricted, .granted:
            Button("打开系统设置", action: perform).kineticGlassButton()
        case .unavailable:
            EmptyView()
        }
    }

    private func row<Actions: View>(symbol: String, title: String, state: PermissionState?, purpose: String,
                                    @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(title).font(.headline)
                    if let state {
                        Text(state.label).font(.caption.weight(.semibold)).foregroundStyle(state.color)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(state.color.opacity(0.14), in: Capsule())
                    } else {
                        Text("说明").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.14), in: Capsule())
                    }
                }
                Text(purpose).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let detail = state?.detail {
                    Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                actions()
            }
        }
    }
}
