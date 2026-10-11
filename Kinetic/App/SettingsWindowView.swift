import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Module 25: a stable settings map. Future features have no inactive-looking fake controls.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, appearance, playback, web, steam, weather, music, performance, shortcuts, permissions, about
    var id: String { rawValue }
    var titleKey: String { "settings.\(rawValue)" }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .playback: return "play.circle"
        case .web: return "globe"
        case .steam: return "gamecontroller"
        case .weather: return "cloud.sun"
        case .music: return "music.note"
        case .performance: return "gauge.with.dots.needle.50percent"
        case .shortcuts: return "keyboard"
        case .permissions: return "lock.shield"
        case .about: return "info.circle"
        }
    }
}

@MainActor
struct KineticSettingsView: View {
    @ObservedObject var appDelegate: AppDelegate
    var body: some View {
        Group {
            if let runtime = appDelegate.runtimeManager {
                SettingsContentView(settings: appDelegate.settingsStore, runtime: runtime,
                                    loginItems: appDelegate.loginItems, steam: appDelegate.steamService,
                                    store: appDelegate.steamStore, engineAssets: appDelegate.engineAssets,
                                    library: appDelegate.library,
                                    monitor: appDelegate.smartPauseMonitor,
                                    sceneProperties: appDelegate.sceneProperties,
                                    videoPlayback: appDelegate.videoPlayback,
                                    webPlayback: appDelegate.webPlayback,
                                    weatherSettings: appDelegate.weatherSettings,
                                    audioResponse: appDelegate.audioResponse, music: appDelegate.music,
                                    shortcuts: appDelegate.globalShortcuts,
                                    adaptiveFrameRate: appDelegate.adaptiveFrameRate,
                                    systemWallpaper: appDelegate.systemWallpaper,
                                    updates: appDelegate.updates,
                                    permissions: appDelegate.permissions,
                                    problems: appDelegate.problemLog,
                                    onBrowseAerials: { appDelegate.showAppleAerials() },
                                    onEditParticles: { appDelegate.showParticles() })
            } else {
                ProgressView().frame(width: 800, height: 570)
            }
        }
        .background { WindowGlassBackground(style: .sidebar).ignoresSafeArea() }
    }
}

@MainActor
struct SettingsContentView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var runtime: WallpaperRuntimeManager
    @ObservedObject var loginItems: LoginItemController
    let steam: SteamAcquisitionService?
    let store: SteamStoreService?
    var engineAssets: EngineAssetsStore? = nil
    let library: WallpaperLibrary?
    let monitor: SmartPauseMonitor?
    var sceneProperties: ScenePropertyStore? = nil
    var videoPlayback: VideoPlaybackStore? = nil
    var webPlayback: WebPlaybackStore? = nil
    var weatherSettings: WeatherSettingsModel? = nil
    var audioResponse: AudioResponseService? = nil
    var music: MusicService? = nil
    /// Module 49.
    var shortcuts: GlobalShortcutCenter? = nil
    /// Module 51.
    var adaptiveFrameRate: AdaptiveFrameRateController? = nil
    /// Module 53.
    var systemWallpaper: SystemWallpaperProvider? = nil
    /// Module 54.
    var updates: UpdateController? = nil
    /// Module 55.
    var permissions: PermissionCenter? = nil
    /// Module 57.
    var problems: ProblemLog? = nil
    var onBrowseAerials: (() -> Void)? = nil
    var onEditParticles: (() -> Void)? = nil
    @State private var section: SettingsSection = .general
    @State private var exceptionError: String?

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(SettingsSection.allCases) { page in
                        Button {
                            section = page
                        } label: {
                            Label(LocalizedStringKey(page.titleKey), systemImage: page.symbol)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12).padding(.vertical, 9)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(section == page ? Color.primary.opacity(0.09) : .clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                        .accessibilityAddTraits(section == page ? .isSelected : [])
                    }
                }.padding(12)
            }.frame(width: 172)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text(LocalizedStringKey(section.titleKey)).font(.title2.weight(.semibold))
                    .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 18)
                if section == .steam, let steam, let store {
                    SteamSettingsView(steam: steam, store: store, engineAssets: engineAssets, settings: settings)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) { page }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(.horizontal, 28).padding(.bottom, 28)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 800, height: 570)
        .onAppear { loginItems.refresh() }
    }

    @ViewBuilder private var page: some View {
        switch section {
        case .general:
            Toggle("settings.login", isOn: Binding(get: { loginItems.status.isOn }, set: { loginItems.setEnabled($0) }))
            loginItemNote
            Divider()
            Toggle("settings.pauseInLowPowerMode", isOn: setting(\.pauseInLowPowerMode))
            Toggle("settings.pauseOnBattery", isOn: setting(\.pauseOnBatteryPower))
            note("settings.powerPause.detail")
            if let library {
                Divider()
                BackupSettingsSection(storage: library.storage)
            }
            if let problems {
                Divider()
                RecentProblemsSection(log: problems, displayCount: { runtime.displayIDs.count })
            }
        case .appearance:
            Picker("settings.appearance.mode", selection: setting(\.appearance)) {
                Text("settings.appearance.system").tag(AppearanceMode.system)
                Text("settings.appearance.light").tag(AppearanceMode.light)
                Text("settings.appearance.dark").tag(AppearanceMode.dark)
            }.pickerStyle(.radioGroup)
            note("settings.appearance.material")
        case .playback:
            Toggle("settings.audio", isOn: Binding(get: { runtime.isAudioEnabled }, set: { runtime.setAudioEnabled($0) }))
            Toggle("settings.smartPause", isOn: setting(\.smartPauseEnabled))
            note("settings.smartPause.detail")
            Toggle("同步为系统壁纸", isOn: setting(\.systemWallpaperSyncEnabled))
            note("把每台显示器的 macOS 系统壁纸换成 Kinetic 当前壁纸的静止画面，调度中心、切换桌面空间和退出 Kinetic 后看到的与动态壁纸一致；换壁纸或应用参数后更新。关闭时换回原来的系统壁纸。")
            if let systemWallpaper { SystemWallpaperStatus(provider: systemWallpaper) }
            if let library, let videoPlayback {
                Divider()
                VideoPlaybackSettingsSection(library: library, store: videoPlayback, runtime: runtime)
            }
            if let onBrowseAerials {
                Divider()
                Button("浏览 Apple 航拍…", action: onBrowseAerials).kineticGlassButton()
            }
            Divider()
            SceneDisplayFitControl(selection: setting(\.sceneDisplayFit)).pickerStyle(.radioGroup)
            note("settings.scene.displayFit.detail")
            if let library, let sceneProperties {
                Divider()
                ScenePropertiesSection(library: library, store: sceneProperties, runtime: runtime)
            }
        case .web:
            Toggle("settings.web.network", isOn: setting(\.webNetworkAccessEnabled))
            note("settings.web.security")
            Toggle("暂停所有网页壁纸的鼠标交互", isOn: setting(\.webMouseInteractionPaused))
            note("只影响开启了「鼠标移动交互」的网页壁纸，各自的设置保留；也可以用快捷键切换（设置 › 快捷键）。")
            note("settings.web.appliesNext")
            if let library, let webPlayback {
                Divider()
                WebPlaybackSettingsSection(library: library, store: webPlayback, runtime: runtime,
                                           allowsNetwork: settings.state.webNetworkAccessEnabled)
            }
        case .steam:
            note("settings.steam.unavailable")
        case .performance:
            performanceSettings
        case .weather:
            if let model = weatherSettings {
                WeatherSettingsView(model: model, weather: model.weather, store: model.weather.store,
                                    responses: model.responses, onEditParticles: onEditParticles)
            } else { note("settings.feature.later") }
        case .music:
            if let audioResponse, let music { AudioResponseSettingsView(service: audioResponse, music: music) }
            else { note("settings.feature.later") }
        case .shortcuts:
            if let shortcuts { GlobalShortcutSettingsView(settings: settings, center: shortcuts) }
            else { note("settings.feature.later") }
        case .permissions:
            if let permissions {
                PermissionCenterView(center: permissions, engineAssets: engineAssets, onOpenSteamSettings: { section = .steam })
            } else { note("settings.feature.later") }
        case .about:
            Text("app.name").font(.title2.weight(.semibold))
            Text(Self.versionText)
            note("settings.about.tagline")
            if let updates {
                Divider()
                UpdateSettingsSection(updates: updates, settings: settings)
            }
        }
    }

    private var performanceSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("settings.performance.safety").font(.headline)
            note("settings.performance.safety.detail")
            Divider()
            Toggle("settings.smartPause", isOn: setting(\.smartPauseEnabled))
            Toggle("settings.performance.fullscreen", isOn: setting(\.pauseWhenFullScreen))
                .disabled(!settings.state.smartPauseEnabled)
            Toggle("settings.performance.occlusion", isOn: setting(\.pauseWhenOccluded))
                .disabled(!settings.state.smartPauseEnabled)
            note("settings.performance.perDisplay")
            Divider()
            Toggle("自适应帧率", isOn: setting(\.adaptiveFrameRateEnabled))
            note("使用电池、低电量模式或机器温度偏高时，场景壁纸降到 15 帧，网页壁纸的脚本动画限制在 30 帧；条件解除后恢复。视频壁纸不变。「使用电池 / 低电量时暂停」开启时仍然优先暂停。")
            if let adaptiveFrameRate { AdaptiveFrameRateStatus(controller: adaptiveFrameRate) }
            Divider()
            Text("settings.performance.exceptions").font(.headline)
            note("settings.performance.exceptions.detail")
            ForEach(settings.state.smartPauseExcludedApps, id: \.self) { id in
                HStack {
                    Text(Self.applicationName(id)).lineLimit(1).help(id)
                    Spacer()
                    Button("settings.performance.removeApp") {
                        settings.set(\.smartPauseExcludedApps, to: settings.state.smartPauseExcludedApps.filter { $0 != id })
                    }
                }
            }
            Button("settings.performance.addApp", action: addException)
            if let exceptionError { Text(exceptionError).foregroundStyle(.red) }
            if let monitor {
                Divider()
                PerformanceStatusView(monitor: monitor, runtime: runtime)
            }
        }
    }

    @ViewBuilder private var loginItemNote: some View {
        switch loginItems.status {
        case .requiresApproval:
            note("settings.login.requiresApproval")
            Button("settings.login.openSystemSettings") { loginItems.openSystemSettings() }
        case .enabled, .disabled: note("settings.login.detail")
        }
        if let error = loginItems.lastError {
            Text(String(format: NSLocalizedString("settings.login.error", comment: ""), error)).foregroundStyle(.red)
        }
    }

    private func note(_ key: LocalizedStringKey) -> some View {
        Text(key).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    private func setting<Value: Equatable>(_ keyPath: WritableKeyPath<SettingsState, Value>) -> Binding<Value> {
        Binding(get: { settings.state[keyPath: keyPath] }, set: { settings.set(keyPath, to: $0) })
    }
    private func addException() {
        exceptionError = nil
        let panel = NSOpenPanel()
        panel.title = NSLocalizedString("settings.performance.addApp", comment: "")
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        var ids = settings.state.smartPauseExcludedApps
        for url in panel.urls {
            guard let id = Bundle(url: url)?.bundleIdentifier, !id.isEmpty else {
                exceptionError = NSLocalizedString("settings.performance.invalidApp", comment: ""); continue
            }
            if !ids.contains(id) { ids.append(id) }
        }
        settings.set(\.smartPauseExcludedApps, to: ids)
    }
    private static func applicationName(_ id: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)?.deletingPathExtension().lastPathComponent ?? id
    }
    static var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return String(format: NSLocalizedString("settings.about.versionBuild", comment: ""), version, build)
    }
}

@MainActor
private struct PerformanceStatusView: View {
    @ObservedObject var monitor: SmartPauseMonitor
    @ObservedObject var runtime: WallpaperRuntimeManager
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("settings.performance.status").font(.headline)
            if monitor.globalReasons.isEmpty && monitor.displayReasons.values.allSatisfy(\.isEmpty) {
                Text("settings.performance.clear").foregroundStyle(.secondary)
            } else {
                if !monitor.globalReasons.isEmpty { Text(Self.describe(monitor.globalReasons)) }
                ForEach(runtime.summary.displays) { display in
                    let reasons = monitor.displayReasons[display.id, default: []].subtracting(monitor.globalReasons)
                    if !reasons.isEmpty {
                        Text(display.displayName + "：" + Self.describe(reasons))
                    }
                }
            }
            Text("settings.performance.manualPriority").foregroundStyle(.secondary)
        }
    }
    private static func describe(_ reasons: Set<SmartPauseReason>) -> String {
        SmartPauseReason.allCases.filter { reasons.contains($0) }
            .map { NSLocalizedString("settings.performance.reason.\($0.rawValue)", comment: "") }.joined(separator: "、")
    }
}

/// Module 51: whether frame rates are lowered right now, and why.
private struct AdaptiveFrameRateStatus: View {
    @ObservedObject var controller: AdaptiveFrameRateController
    var body: some View {
        Text(controller.reason.map { "现在已降帧：" + $0.title } ?? "现在以正常帧率播放。")
            .font(.caption).foregroundStyle(.secondary)
    }
}

/// Module 53: a failed sync or restore is shown under the switch.
private struct SystemWallpaperStatus: View {
    @ObservedObject var provider: SystemWallpaperProvider
    var body: some View {
        if let error = provider.lastError { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
    }
}
