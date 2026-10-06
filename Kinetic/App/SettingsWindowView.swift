import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Module 25: a stable settings map. Future features have no inactive-looking fake controls.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, appearance, playback, web, steam, displays, overlays, weather, music, performance, shortcuts, about
    var id: String { rawValue }
    var titleKey: String { "settings.\(rawValue)" }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .playback: return "play.circle"
        case .web: return "globe"
        case .steam: return "gamecontroller"
        case .displays: return "display.2"
        case .overlays: return "square.3.layers.3d"
        case .weather: return "cloud.sun"
        case .music: return "music.note"
        case .performance: return "gauge.with.dots.needle.50percent"
        case .shortcuts: return "keyboard"
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
                                    monitor: appDelegate.smartPauseMonitor)
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
                    SteamSettingsView(steam: steam, store: store, engineAssets: engineAssets)
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
        case .web:
            Toggle("settings.web.network", isOn: setting(\.webNetworkAccessEnabled))
            note("settings.web.security")
            note("settings.web.appliesNext")
        case .steam:
            note("settings.steam.unavailable")
        case .displays:
            displaySettings
        case .performance:
            performanceSettings
        case .overlays, .weather, .music, .shortcuts:
            note("settings.feature.later")
        case .about:
            Text("app.name").font(.title2.weight(.semibold))
            Text(Self.versionText)
            note("settings.about.tagline")
        }
    }

    private var displaySettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            if runtime.summary.displays.isEmpty { note("settings.displays.empty") }
            ForEach(Array(runtime.summary.displays.enumerated()), id: \.element.id) { index, display in
                VStack(alignment: .leading, spacing: 6) {
                    Label(display.displayName.isEmpty ? String(format: NSLocalizedString("displayPicker.fallback", comment: ""), index + 1) : display.displayName,
                          systemImage: "display").font(.headline)
                    Text(NSLocalizedString("runtime.state.\(display.runtime.playbackState.rawValue)", comment: ""))
                    if let active = runtime.activeWallpaper(on: display.id) { Text(active.name).lineLimit(2) }
                    if let size = display.frame?.size {
                        Text(String(format: NSLocalizedString("settings.displays.size", comment: ""),
                                    Int(size.width * display.scaleFactor), Int(size.height * display.scaleFactor)))
                            .foregroundStyle(.secondary)
                    }
                }
                Divider()
            }
            note("settings.displays.detail")
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
