import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Module 24：菜单栏按全部显示器汇总，只读取 Runtime 的快照。
struct MenuBarPlaybackPresentation: Equatable {
    enum PrimaryAction: Equatable { case pause, resume, reenable }
    let summary: RuntimeSummary
    private let controls: FloatingToolbarState

    init(summary: RuntimeSummary, isInLibrary: (Wallpaper.ID) -> Bool) {
        self.summary = summary
        controls = FloatingToolbarState(summary: summary, isInLibrary: isInLibrary)
    }

    /// 单显示器兼容入口，也供既有 v0.1 状态测试使用。
    init(state: WallpaperRuntimeState, canReenable: Bool) {
        self.init(summary: .init(displays: [.init(displayID: .main, displayName: "", runtime: state)]),
                  isInLibrary: { _ in canReenable })
    }

    var iconUsesAccent: Bool { summary.hasEnabledDisplay }
    var primaryAction: PrimaryAction? {
        switch controls.playbackAction {
        case .pauseAll: return .pause
        case .resumeAll: return .resume
        case .reenableAll: return .reenable
        case .none: return nil
        }
    }
    var canStop: Bool { controls.canStop }
    var hasWallpaperContext: Bool { canStop || primaryAction != nil }
    var statusKey: String { "runtime.state.\(summary.playbackState.rawValue)" }
    var summaryText: String {
        let groups = RuntimeSummary.aggregatePriority.compactMap { state -> String? in
            let count = summary.displays.filter { $0.runtime.playbackState == state }.count
            guard count > 0 else { return nil }
            return String(format: NSLocalizedString("menu.displays.\(state.rawValue)", comment: ""), count)
        }
        return groups.isEmpty ? NSLocalizedString("runtime.state.noWallpaper", comment: "") : groups.joined(separator: " · ")
    }

    @MainActor
    static func perform(_ action: PrimaryAction, on runtime: WallpaperRuntimeManager,
                        isInLibrary: (Wallpaper.ID) -> Bool) {
        switch action {
        case .pause: runtime.pause(.allDisplays)
        case .resume: runtime.resume(.allDisplays)
        case .reenable: runtime.reenable(.allDisplays, isInLibrary: isInLibrary)
        }
    }
}

/// 菜单栏请求可在主窗口重新创建后消费，不依赖某个已关闭的窗口实例。
@MainActor
final class MainWindowNavigation: ObservableObject {
    // Deliver after storing the request: a live window consumes synchronously.
    // @Published's willSet delivery would restore an already-consumed request.
    let requests = CurrentValueSubject<ShellSection?, Never>(nil)
    var requestedSection: ShellSection? { requests.value }
    func request(_ section: ShellSection) { requests.send(section) }
    func consume() { requests.send(nil) }
}

@MainActor
struct KineticMenuBarStatusView: View {
    @ObservedObject var appDelegate: AppDelegate

    var body: some View {
        if let runtime = appDelegate.runtimeManager {
            RuntimeMenuBarStatusView(runtime: runtime)
        } else {
            KineticMenuBarStatusViewSymbol(usesAccent: false)
        }
    }
}

@MainActor
private struct RuntimeMenuBarStatusView: View {
    @ObservedObject var runtime: WallpaperRuntimeManager

    var body: some View {
        KineticMenuBarStatusViewSymbol(
            usesAccent: runtime.summary.hasEnabledDisplay
        )
    }
}

private struct KineticMenuBarStatusViewSymbol: View {
    let usesAccent: Bool

    var body: some View {
        // Module 22：正式的动态轨迹 K（渲染成图片：菜单栏只显示图片与文字）。
        // 黑白模板图由系统按菜单栏外观着色；播放 / 智能暂停时为品牌主色。
        Image(nsImage: KineticLogo.menuBarImage(accent: usesAccent))
            .renderingMode(usesAccent ? .original : .template)
            .accessibilityLabel("Kinetic")
    }
}

@MainActor
struct KineticMenuBarControllerView: View {
    @ObservedObject var appDelegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let runtime = appDelegate.runtimeManager, let library = appDelegate.library {
            RuntimeMenuBarControllerView(
                runtime: runtime,
                library: library,
                importer: appDelegate.importService,
                navigation: appDelegate.mainWindowNavigation,
                steamApply: appDelegate.steamDisplayApply,
                willShowMainWindow: { [appDelegate] in appDelegate.endMainWindowSuppression() }
            )
        } else {
            Text("shell.error.unavailable")
            Divider()
            Button("menu.openKinetic") {
                appDelegate.endMainWindowSuppression()
                NSApp.unhide(nil)
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            if #available(macOS 14.0, *) {
                SettingsLink { Text("menu.settings") }
            } else {
                Button("menu.settings") {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
            }
            Button("menu.quit") { NSApp.terminate(nil) }
        }
    }
}

@MainActor
struct RuntimeMenuBarControllerView: View {
    @ObservedObject var runtime: WallpaperRuntimeManager
    @ObservedObject var library: WallpaperLibrary
    let importer: LocalImportService?
    let navigation: MainWindowNavigation
    let steamApply: SteamDisplayApplyCoordinator?
    /// Module 19：用户主动打开主窗口，登录启动的隐藏不再生效。
    let willShowMainWindow: @MainActor () -> Void
    @Environment(\.openWindow) private var openWindow
    @State private var importMessage: String?
    @State private var isImporting = false

    private var presentation: MenuBarPlaybackPresentation {
        MenuBarPlaybackPresentation(summary: runtime.summary, isInLibrary: { library.wallpaper(id: $0) != nil })
    }

    private var wallpaperName: String? {
        guard runtime.summary.displays.count == 1, let display = runtime.summary.displays.first else { return nil }
        let wallpaper: Wallpaper?
        if display.runtime.playbackState == .stopped {
            wallpaper = display.runtime.lastActiveWallpaperID.flatMap { library.wallpaper(id: $0) }
        } else {
            wallpaper = runtime.activeWallpaper(on: display.id) ?? runtime.preparingWallpaper
        }
        guard let name = wallpaper?.name else { return nil }
        return name.count > 42 ? String(name.prefix(41)) + "…" : name
    }

    var body: some View {
        Text("app.name")
        Divider()
        if runtime.summary.displays.count > 1 {
            Text(presentation.summaryText)
        } else if let wallpaperName {
            Text(runtime.summary.playbackState == .stopped ? "menu.lastWallpaper" : "menu.currentWallpaper")
            Text(wallpaperName)
            Text(NSLocalizedString(presentation.statusKey, comment: "Menu bar playback status"))
            if runtime.summary.playbackState == .smartPaused {
                Text("menu.smartPauseHint")
            }
        } else {
            Text("runtime.state.noWallpaper")
        }

        MenuBarGlobalControls(runtime: runtime, isInLibrary: { library.wallpaper(id: $0) != nil })

        if let failure = runtime.lastFailure {
            Divider()
            Text(failure.message)
            if runtime.hasDisplay(failure.displayID),
               let wallpaper = library.wallpaper(id: failure.wallpaperID),
               WallpaperCardVisualState.isPlayable(wallpaper) {
                Button("recovery.retry") {
                    WallpaperPreviewCoordinator.shared.stopAll()
                    // 重试回到出错的那台显示器。
                    steamApply?.cancelApplication(on: failure.displayID)
                    runtime.apply(wallpaper, to: failure.displayID)
                }
            }
            Button("recovery.dismiss") { runtime.dismissFailure() }
        }

        Divider()
        Menu("menu.addWallpaper") {
            ForEach(FloatingToolbarAddItem.allCases, id: \.titleKey) { item in
                Button(LocalizedStringKey(item.titleKey)) { add(item) }
                    .disabled(item != .openSteamWorkshop && (importer == nil || isImporting))
            }
        }
        if let importMessage {
            Text(importMessage)
        }
        Button("menu.openKinetic") { showMainWindow() }

        Divider()
        if #available(macOS 14.0, *) {
            SettingsLink { Text("menu.settings") }
        } else {
            Button("menu.settings") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        }
        Button("menu.quit") { NSApp.terminate(nil) }
    }

    private func add(_ item: FloatingToolbarAddItem) {
        switch item {
        case .importVideo: Task { await importItems(webFolders: false) }
        case .importWebFolder: Task { await importItems(webFolders: true) }
        case .openSteamWorkshop:
            navigation.request(.steam)
            showMainWindow()
        }
    }

    private func showMainWindow() {
        willShowMainWindow()
        NSApp.unhide(nil)
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func importItems(webFolders: Bool) async {
        guard let importer, !isImporting else { return }
        let panel = LocalImportPanel.makePanel()
        if webFolders {
            panel.title = NSLocalizedString("shell.import.web", comment: "")
            panel.message = NSLocalizedString("shell.import.webMessage", comment: "")
        }
        panel.prompt = NSLocalizedString("import.panel.prompt", comment: "")
        panel.allowedContentTypes = webFolders ? [.folder] : VideoFormats.contentTypes + [.folder]
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = !webFolders
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK else { return }
        isImporting = true
        defer { isImporting = false }
        let outcomes = await importer.importItems(at: panel.urls)
        if let message = LocalImportSummary(outcomes: outcomes).message { importMessage = message }
    }
}

/// 同一组生产菜单动作也用于隔离的真实窗口验收。
@MainActor
struct MenuBarGlobalControls: View {
    @ObservedObject var runtime: WallpaperRuntimeManager
    let isInLibrary: (Wallpaper.ID) -> Bool

    var body: some View {
        let presentation = MenuBarPlaybackPresentation(summary: runtime.summary, isInLibrary: isInLibrary)
        if presentation.hasWallpaperContext {
            Divider()
            if let action = presentation.primaryAction {
                Button(action.titleKey) { MenuBarPlaybackPresentation.perform(action, on: runtime, isInLibrary: isInLibrary) }
            }
            if presentation.canStop {
                Button("menu.stopAll") { runtime.stop(.allDisplays) }
            }
        }
        Button(audioTitle) { runtime.setAudioEnabled(!runtime.isAudioEnabled) }
    }

    private var audioTitle: String {
        let state = NSLocalizedString(runtime.isAudioEnabled ? "menu.audio.on" : "menu.audio.off", comment: "")
        return String(format: NSLocalizedString("menu.audio.format", comment: ""), state)
    }
}

private extension MenuBarPlaybackPresentation.PrimaryAction {
    var titleKey: LocalizedStringKey {
        switch self {
        case .pause: return "menu.pauseAll"
        case .resume: return "menu.resumeAll"
        case .reenable: return "menu.reenableAll"
        }
    }
}
