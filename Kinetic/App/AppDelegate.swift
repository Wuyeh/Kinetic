import AppKit
import Combine
import QuartzCore
import KineticSceneRuntime

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    /// Module 2 的桌面窗口应使用此标识，不能用于普通主窗口或设置窗口。
    static let desktopWallpaperWindowIdentifier = NSUserInterfaceItemIdentifier(
        "Kinetic.DesktopWallpaper"
    )

    private var desktopWindowRuntime: DesktopWindowRuntime?
    let settingsStore = SettingsStore()
    private var settingsSubscriptions = Set<AnyCancellable>()
    private let appearanceTransition = AppearanceTransition()
    /// Module 18：系统状态 → Smart Pause 条件，只通过 Runtime 的公开接口生效。
    private(set) var smartPauseMonitor: SmartPauseMonitor?
    /// Module 19：登录时启动（系统状态为准，设置同步）。
    private(set) lazy var loginItems = LoginItemController(service: MainAppLoginItemService(), settings: settingsStore)
    /// Module 19：本次是否为登录启动；登录启动时启动阶段出现的主窗口不显示。
    private(set) var isLoginLaunch = false
    private var mainWindowSuppression = MainWindowLaunchSuppression(isLoginLaunch: false)
    /// Module 19：主窗口与打开它的 SwiftUI 动作，点按 Dock 图标时用来重新打开主窗口。
    private weak var mainWindow: NSWindow?
    private var openMainWindow: (@MainActor () -> Void)?
    /// 关闭主窗口时隐藏程序坞图标（App 继续运行，菜单栏图标保留），再次打开主窗口时恢复（用户，2026-10-08）。
    private var mainWindowCloseObserver: NSObjectProtocol?
    /// Module 19：每次启动恢复上次的壁纸。
    private var displayController: MultiDisplayController?
    /// Module 5：全局唯一的 Runtime Manager。启动时由 Module 19 恢复上次的壁纸。
    @Published private(set) var runtimeManager: WallpaperRuntimeManager?
    /// Module 6：Runtime 通过它在同一桌面窗口内完成 Crossfade。
    private var crossfadeHost: CrossfadeDesktopHost?
    /// Module 7：全局唯一的资料库（metadata 持久化）；启动时只读取，不添加或改动任何记录。
    @Published private(set) var library: WallpaperLibrary?
    /// Module 46：唯一的壁纸列表数据，主窗口与轮播共用（主窗口关闭后轮播仍要读列表）。
    @Published private(set) var localOrganization: LocalOrganizationStore?
    /// Module 46：按显示器轮播壁纸列表，经过既有的显示器 Apply 与 Crossfade。
    @Published private(set) var playlistPlayer: WallpaperPlaylistPlayer?
    /// Module 47：按显示器定时切换壁纸或壁纸列表。
    @Published private(set) var scheduler: WallpaperScheduler?
    /// Module 48：书签与方案的数据；方案的保存与应用。
    @Published private(set) var setupStore: SetupStore?
    private(set) var schemeCoordinator: WallpaperSchemeCoordinator?
    /// Module 49：全局快捷键。
    let globalShortcuts = GlobalShortcutCenter()
    /// Module 51：自适应帧率；Module 52：菜单栏性能条。测试宿主中为 nil。
    @Published private(set) var adaptiveFrameRate: AdaptiveFrameRateController?
    @Published private(set) var performanceStrip: PerformanceStripModel?
    /// Module 53：同步为系统壁纸。测试宿主中为 nil。
    @Published private(set) var systemWallpaper: SystemWallpaperProvider?
    /// Module 54：Sparkle 更新。测试宿主中为 nil；没有配置更新地址的构建也会创建，只在设置里说明不可用。
    @Published private(set) var updates: UpdateController?
    /// Module 55：设置 › 权限。只读状态，点按钮才请求。测试宿主中为 nil。
    @Published private(set) var permissions: PermissionCenter?
    /// Module 57：意外退出保护与「最近的问题」。只在恢复壁纸的正式启动中创建。
    private var uncleanExitGuard: UncleanExitGuard?
    @Published private(set) var launchRecovery: LaunchRecovery?
    @Published private(set) var problemLog: ProblemLog?
    /// Module 8：本地导入服务（复制到 Library Storage）；界面入口属于 Module 15 / 16。
    @Published private(set) var importService: LocalImportService?
    /// 1.0 Module 9：Steam 下载核心（SteamCMD、登录、下载、校验、入本地资料库）。
    @Published private(set) var steamService: SteamAcquisitionService?
    /// 1.0 Module 14：Steam 在线商店（用户自己的 Steam Web API Key，存钥匙串）。
    @Published private(set) var steamStore: SteamStoreService?
    /// 1.0 Module 28：Wallpaper Engine 引擎素材（链接用户的文件夹，或用用户的 Steam 账号下载）。
    @Published private(set) var engineAssets: EngineAssetsStore?
    /// Module 29: local scene values and presets, independent of library format 2.
    @Published private(set) var sceneProperties: ScenePropertyStore?
    @Published private(set) var videoPlayback: VideoPlaybackStore?
    @Published private(set) var webPlayback: WebPlaybackStore?
    @Published private(set) var displayWallpaperEditor: DisplayWallpaperEditor?
    private var aerialBrowser: AppleAerialBrowserWindow?
    @Published private(set) var overlays: OverlayManager?
    private var particleSettings: ParticleSettingsWindow?
    private var nixieClockSettings: NixieClockSettingsWindow?
    /// Shared with the display page, which previews particles and the clock (2026-10-08).
    private var particleEditor: ParticleEditorModel?
    private var clockEditor: NixieClockEditorModel?
    /// The display page's preview and 应用 for every overlay.
    @Published private(set) var displayOverlayEditors: DisplayOverlayEditors?
    @Published private(set) var weather: WeatherService?
    @Published private(set) var weatherSettings: WeatherSettingsModel?
    private var widgetLayouts: WidgetLayoutRepository?
    private var widgetContents: WidgetContentRegistry?
    private var widgetBoard: WidgetBoardWindow?
    /// Shared by the 桌面组件 window, the display page previews and the desktop tiles (2026-10-08).
    @Published private(set) var widgetEditor: WidgetBoardEditorModel?
    /// Module 38：所有后续系统组件共享这一服务；无可见订阅者时不采样。
    private(set) var systemMetrics: SystemMetricsService?
    private(set) var agentSessions: AgentSessionService?
    private var agentSessionSettings: AgentSessionSettingsWindow?
    private(set) var music: MusicService?
    @Published private(set) var audioResponse: AudioResponseService?
    private var musicEditor: MusicOverlayEditorModel?
    private var musicSettings: MusicSettingsWindow?
    /// 1.0 Module 18：按明确显示器保存下载并应用意图，关闭主窗口不会取消下载。
    private(set) var steamDisplayApply: SteamDisplayApplyCoordinator?
    let mainWindowNavigation = MainWindowNavigation()
    /// Module 20：第一次启动的引导；测试宿主与 Debug 验收会话中为 nil。
    @Published private(set) var onboarding: OnboardingController?
    #if DEBUG
    private var videoTestSession: VideoRendererTestSession?
    private var runtimeTestSession: RuntimeStateTestSession?
    private var crossfadeTestSession: CrossfadeTestSession?
    private var splitDisplayCrossfadeTestSession: SplitDisplayCrossfadeTestSession?
    private var libraryTestSession: LibraryTestSession?
    private var importTestSession: ImportTestSession?
    private var downloadTestSession: SteamDownloadTestSession?
    private var displayTargetTestSession: DisplayTargetTestSession?
    private var localDragTestSession: LocalWallpaperDragTestSession?
    private var appControlsTestSession: AppControlsTestSession?
    private var settingsPerformanceTestSession: SettingsPerformanceTestSession?
    private var sceneRuntimeTestSession: SceneRuntimeTestSession?
    private var scenePropertiesTestSession: ScenePropertiesTestSession?
    private var advancedVideoTestSession: AdvancedVideoTestSession?
    private var livePreviewDiagnosticsPanel: LivePreviewDiagnosticsPanel?
    #endif

    func applicationWillFinishLaunching(_ notification: Notification) {
        // 启动事件只在这里可靠可读。
        isLoginLaunch = LaunchContext.detectCurrentLaunch()
        mainWindowSuppression = MainWindowLaunchSuppression(isLoginLaunch: isLoginLaunch)
    }

    /// 主窗口出现时调用：登录启动的启动阶段内隐藏它（只在菜单栏运行），之后从菜单栏或 Dock 打开时正常显示。
    func mainWindowDidAppear(_ window: NSWindow) {
        mainWindow = window
        observeMainWindowClose(window)
        mainWindowSuppression.hide(window)
    }

    /// 主窗口内容创建时登记 SwiftUI 的打开动作；AppDelegate 自己拿不到 SwiftUI 环境。
    func registerMainWindowOpener(_ open: @escaping @MainActor () -> Void) {
        openMainWindow = open
    }

    /// 用户主动打开主窗口时调用，确保这次打开不会被当成登录启动的窗口隐藏。
    func endMainWindowSuppression() {
        mainWindowSuppression.end()
    }

    /// 用户主动打开主窗口之前调用：结束登录启动的隐藏，并让关闭主窗口时隐藏的程序坞图标回来。
    func willShowMainWindow() {
        endMainWindowSuppression()
        NSApp.setActivationPolicy(.regular)
    }

    /// 主窗口关闭后只留菜单栏图标。登录启动隐藏主窗口用的是 orderOut，不经过这里。
    private func observeMainWindowClose(_ window: NSWindow) {
        if let mainWindowCloseObserver { NotificationCenter.default.removeObserver(mainWindowCloseObserver) }
        mainWindowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            // 等窗口真正关闭后再切换；这期间又打开了主窗口就不隐藏。
            DispatchQueue.main.async { [weak self] in
                guard self?.mainWindow?.isVisible != true else { return }
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    /// Module 50：上次准备好的恢复在读取资料库之前完成；登录启动以系统状态为准，不随备份改变。
    private func restorePendingBackup() {
        guard !Self.isRunningTests, let storage = libraryStorage(),
              KineticBackupService.pendingRestore(in: storage) != nil else { return }
        let notice: (String, String)
        do {
            if let restored = try KineticBackupService.applyPendingRestore(in: storage, defaults: .standard) {
                if let data = restored.settings, var value = try? JSONDecoder().decode(SettingsState.self, from: data) {
                    value.launchAtLoginEnabled = settingsStore.state.launchAtLoginEnabled
                    settingsStore.replace(with: value)
                }
                notice = ("已从备份恢复", "备份时间：\(BackupSettingsSection.dateText(restored.createdAt))。原来的数据保存在资料库的 RestoreSafety 文件夹。")
            } else { return }
        } catch {
            notice = ("未能从备份恢复", "原来的数据没有改动。\n" + error.localizedDescription)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { SetupPrompts.inform(title: notice.0, message: notice.1) }
    }

    /// Module 49：全局快捷键的动作，都调用菜单栏 / 设置里已有的同一入口。
    func performGlobalShortcut(_ action: GlobalShortcutAction) {
        guard let runtime = runtimeManager else { return }
        switch action {
        case .playPauseAll:
            let isInLibrary: (Wallpaper.ID) -> Bool = { [weak self] in self?.library?.wallpaper(id: $0) != nil }
            if let primary = MenuBarPlaybackPresentation(summary: runtime.summary, isInLibrary: isInLibrary).primaryAction {
                MenuBarPlaybackPresentation.perform(primary, on: runtime, isInLibrary: isInLibrary)
            }
        case .nextWallpaper: playlistPlayer?.stepAll(.next)
        case .previousWallpaper: playlistPlayer?.stepAll(.previous)
        case .toggleAudio: runtime.setAudioEnabled(!runtime.isAudioEnabled)
        case .toggleMouseInteraction:
            settingsStore.set(\.webMouseInteractionPaused, to: !settingsStore.state.webMouseInteractionPaused)
        case .showHide:
            if NSApp.isActive, mainWindow?.isVisible == true {
                NSApp.hide(nil)
            } else {
                willShowMainWindow()
                NSApp.unhide(nil)
                if let mainWindow, mainWindow.isVisible || mainWindow.isMiniaturized { mainWindow.makeKeyAndOrderFront(nil) }
                else { openMainWindow?() }
                NSApp.activate(ignoringOtherApps: true)
            }
        case .reload:
            for display in runtime.displayIDs {
                if let wallpaper = runtime.activeWallpaper(on: display) { runtime.reloadActive(wallpaper, on: display) }
            }
        case .openSettings:
            NSApp.activate(ignoringOtherApps: true)
            // The app menu's 设置… item (⌘,) is the same entry SettingsLink uses.
            if let menu = NSApp.mainMenu?.items.first?.submenu,
               let index = menu.items.firstIndex(where: { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command }) {
                menu.performActionForItem(at: index)
            } else {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        }
    }

    /// Module 56：帮助 › 显示欢迎页。
    func showWelcome() {
        guard let onboarding else { return }
        onboarding.showAgain()
        willShowMainWindow()
        NSApp.unhide(nil)
        if let mainWindow, mainWindow.isVisible || mainWindow.isMiniaturized { mainWindow.makeKeyAndOrderFront(nil) }
        else { openMainWindow?() }
        NSApp.activate(ignoringOtherApps: true)
    }

    func showAppleAerials() {
        guard let library, let importService, let runtimeManager else { return }
        if aerialBrowser == nil {
            let catalog = AppleAerialCatalog(storage: library.storage)
            let model = AppleAerialBrowserModel(catalog: catalog, library: library, importer: importService,
                runtime: runtimeManager, cancelSteamApplication: { [weak self] display in
                    self?.steamDisplayApply?.cancelApplication(on: display)
                })
            aerialBrowser = AppleAerialBrowserWindow(model: model, runtime: runtimeManager)
        }
        aerialBrowser?.show()
    }

    /// `display`: opened from that display's page, so the window targets it (user, 2026-10-08).
    func showParticles(on display: DisplayID? = nil) {
        guard let particleEditor else { return }
        if particleSettings == nil { particleSettings = ParticleSettingsWindow(model: particleEditor) }
        particleSettings?.show()
        if let display, let model = particleSettings?.model, model.selectedDisplayID != display { model.selectDisplay(display) }
    }

    func showNixieClock(on display: DisplayID? = nil) {
        guard let clockEditor else { return }
        if nixieClockSettings == nil { nixieClockSettings = NixieClockSettingsWindow(model: clockEditor) }
        nixieClockSettings?.show()
        if let display, let model = nixieClockSettings?.model, model.selectedDisplayID != display { model.selectDisplay(display) }
    }

    func showWidgets(on display: DisplayID? = nil) {
        guard let widgetEditor else { return }
        if widgetBoard == nil { widgetBoard = WidgetBoardWindow(model: widgetEditor) }
        widgetBoard?.show()
        if let display, widgetEditor.selectedDisplayID != display { widgetEditor.selectDisplay(display) }
    }

    func showAgentSessions() {
        guard let agentSessions else { return }
        if agentSessionSettings == nil { agentSessionSettings = AgentSessionSettingsWindow(service: agentSessions) }
        agentSessionSettings?.show()
    }

    func showMusic(on display: DisplayID? = nil) {
        guard let musicEditor else { return }
        if let display { musicEditor.selectDisplay(display) }
        if musicSettings == nil { musicSettings = MusicSettingsWindow(model: musicEditor) }
        musicSettings?.show()
    }

    /// 原「设置 › 叠加层」的全部入口（2026-10-08 迁到显示器页标题旁的圆形按钮）；各自打开与之前相同的窗口。
    var displayOverlayMenu: DisplayOverlayMenu {
        var entries: [DisplayOverlayMenu.Entry] = [
            .init(id: "particles", titleKey: "particles.title", detailKey: "particles.settings.detail") { [weak self] in self?.showParticles(on: $0) },
            .init(id: "widgets", titleKey: "widgets.title", detailKey: "widgets.settings.detail") { [weak self] in self?.showWidgets(on: $0) },
            .init(id: "clock", titleKey: "clock.title", detailKey: "clock.settings.detail") { [weak self] in self?.showNixieClock(on: $0) },
        ]
        if agentSessions != nil {
            entries.append(.init(id: "agentSessions", titleKey: "agentSessions.settings.title", detailKey: nil) { [weak self] _ in
                self?.showAgentSessions()
            })
        }
        if musicEditor != nil {
            entries.append(.init(id: "music", titleKey: "music.title", detailKey: "music.settings.detail") { [weak self] in self?.showMusic(on: $0) })
        }
        return DisplayOverlayMenu(entries: entries)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        restorePendingBackup()
        if mainWindowSuppression.isActive {
            DispatchQueue.main.asyncAfter(deadline: .now() + MainWindowLaunchSuppression.launchPhase) { [weak self] in
                self?.endMainWindowSuppression()
            }
        }
        // 一个 App 级外观覆盖同时作用于主窗口与原生 Settings 窗口。
        // 跟随系统必须设为 nil，不能把当前系统浅色固化成显式浅色。
        appearanceTransition.apply(settingsStore.state.appearance, animated: false)
        settingsStore.$state
            .map(\.appearance)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] appearance in
                self?.appearanceTransition.apply(appearance, animated: true)
            }
            .store(in: &settingsSubscriptions)
        // 28.4：场景壁纸比例与显示器不同时的显示方式；改变时立即作用于正在显示的场景。
        SceneRenderer.applyDisplayFitSetting(settingsStore.state.sceneDisplayFit)
        settingsStore.$state
            .map(\.sceneDisplayFit)
            .removeDuplicates()
            .dropFirst()
            .sink { SceneRenderer.applyDisplayFitSetting($0) }
            .store(in: &settingsSubscriptions)

        // 在 Runtime 初始化之前，关闭当前进程中可能恢复的旧桌面窗口。
        // 已退出进程的窗口由 macOS 回收；此处不操作其他进程或系统桌面。
        DesktopWindowRuntime.closeOrphanedWindows(
            in: NSApp.windows, identifier: Self.desktopWallpaperWindowIdentifier
        )

        MultiDisplayController.closeOrphanedSurfaces()
        // Module 16：Runtime 不猜测主屏；由稳定显示器发现逐台接入独立桌面表面。
        let runtime = WallpaperRuntimeManager { [weak self] wallpaper in
            if wallpaper.type == .web {
                return WebRenderer(wallpaper: wallpaper,
                                   allowsNetwork: self?.settingsStore.state.webNetworkAccessEnabled ?? false)
            }
            return try WallpaperRuntimeManager.standardRenderer(for: wallpaper)
        }
        runtimeManager = runtime
        runtime.setAudioEnabled(settingsStore.state.wallpaperAudioEnabled)
        runtime.$isAudioEnabled.dropFirst().removeDuplicates().sink { [weak self] enabled in
            self?.settingsStore.set(\.wallpaperAudioEnabled, to: enabled)
        }.store(in: &settingsSubscriptions)
        startSmartPauseMonitor(runtime: runtime)
        #if DEBUG
        let sceneArguments = ProcessInfo.processInfo.arguments
        if sceneArguments.contains("--advanced-video-test") {
            advancedVideoTestSession = AdvancedVideoTestSession()
            advancedVideoTestSession?.start()
            return
        }
        if sceneArguments.contains("--scene-properties-test") {
            scenePropertiesTestSession = ScenePropertiesTestSession()
            scenePropertiesTestSession?.start()
            return
        }
        if sceneArguments.contains("--scene-runtime-test") || sceneArguments.contains("--scene-graph-test") || sceneArguments.contains("--scene-full-test") {
            sceneRuntimeTestSession = SceneRuntimeTestSession()
            sceneRuntimeTestSession?.start(fixtureSet: sceneArguments.contains("--scene-full-test") ? .full
                : sceneArguments.contains("--scene-graph-test") ? .graph : .bounded)
            return
        }
        // This panel owns in-memory preferences and independent sessions. Do not initialize
        // real library cleanup, assignment recording, Steam credentials, or login registration.
        if ProcessInfo.processInfo.arguments.contains("--settings-performance-test") {
            settingsPerformanceTestSession = SettingsPerformanceTestSession()
            settingsPerformanceTestSession?.start()
            return
        }
        #endif
        if let storage = libraryStorage() {
            WallpaperDeletionService.removeLeftovers(in: storage)
            let library = WallpaperLibrary(storage: storage)
            self.library = library
            localOrganization = LocalOrganizationStore(storage: storage)
            setupStore = SetupStore(storage: storage)
            let sceneProperties = ScenePropertyStore(storage: storage)
            self.sceneProperties = sceneProperties
            SceneRenderer.propertyValuesProvider = { [weak sceneProperties] id in sceneProperties?.configuration(for: id).values ?? [:] }
            let videoPlayback = VideoPlaybackStore(storage: storage)
            self.videoPlayback = videoPlayback
            VideoRenderer.optionsProvider = { [weak videoPlayback] id in videoPlayback?.configuration(for: id) ?? .init() }
            let webPlayback = WebPlaybackStore(storage: storage)
            self.webPlayback = webPlayback
            WebRenderer.optionsProvider = { [weak webPlayback] id in webPlayback?.configuration(for: id) ?? .init() }
            let displayEditor = DisplayWallpaperEditor(storage: storage, library: library, runtime: runtime,
                sceneStore: sceneProperties, videoStore: videoPlayback, webStore: webPlayback, settings: settingsStore)
            displayWallpaperEditor = displayEditor
            runtime.displayRendererFactory = { [weak displayEditor] wallpaper, display in
                if let displayEditor { return try displayEditor.makeRenderer(wallpaper, on: display) }
                return try WallpaperRuntimeManager.standardRenderer(for: wallpaper)
            }
            importService = LocalImportService(library: library)
            // 启动时还没有壁纸在播放：清理 Steam 项目更新后留下的旧版本内容。
            SteamWorkshopImporter.removeStaleVersions(in: library)
            steamService = SteamAcquisitionService(
                // SteamCMD 由不带沙盒的 Steam 小助手运行，位于 ~/Library/Application Support/Kinetic Steam/SteamCMD。
                installation: SteamCMDInstallation.standard(),
                library: library,
                isInUse: { [weak self] id in self?.runtimeManager?.isUsing(id) ?? false }
            )
            // XCTest hosts must not read the user's real credentials or wait for Keychain authorization.
            let steamKeyStore: SteamAPIKeyStoring = Self.isRunningTests || Self.isSteamStoreDemo
                ? MemorySteamAPIKeyStore() : KeychainSteamAPIKeyStore()
            steamStore = SteamStoreService(keyStore: steamKeyStore)
            #if DEBUG
            // R4 验收：合成的 Steam 商店与模拟下载，不联网、不读钥匙串、不运行真实 SteamCMD。
            if SteamStoreDemo.isEnabled {
                steamService = SteamStoreDemo.makeAcquisition(library: library)
                steamStore = SteamStoreDemo.makeStore()
            }
            #endif
            // 用户决定：年龄分级默认全部显示，设置中开启才隐藏；改变时立即重新查询（未浏览时不请求）。
            steamStore?.setHiddenAgeRatings(settingsStore.state.steamHiddenAgeRatings)
            settingsStore.$state.map(\.steamHiddenAgeRatings).removeDuplicates().dropFirst()
                .sink { [weak self] in self?.steamStore?.setHiddenAgeRatings($0) }
                .store(in: &settingsSubscriptions)
            let engineAssets = EngineAssetsStore()
            self.engineAssets = engineAssets
            SceneRenderer.engineAssetsProvider = { [weak engineAssets] in engineAssets?.assetsURL }
            // Module 28：Scene 的创意工坊依赖项。启动时还没有壁纸在播放，先清理不再被引用的依赖项。
            let dependencies = WorkshopDependencyStore(storage: storage)
            dependencies.removeUnreferenced(library: library)
            SceneRenderer.dependencyProvider = { [weak library] id in dependencies.folder(for: id, library: library) }
            importService?.onImported = { [weak self] wallpaper in
                guard wallpaper.type == .scene, let steam = self?.steamService else { return }
                Task { await steam.fetchMissingDependencies(of: wallpaper) }
            }
            if let steamService {
                steamDisplayApply = SteamDisplayApplyCoordinator(runtime: runtime, library: library, steam: steamService)
            }
        }
        if !Self.isRunningTests, !Self.isSteamStoreDemo {
            loginItems.start()
        }
        if let runtimeManager, let library {
            let controller = MultiDisplayController(
                registry: DisplayRegistry(), runtime: runtimeManager, library: library,
                store: DisplayAssignmentStore(library: library.storage),
                legacy: WallpaperRestorationStore(library: library.storage),
                restoreOnLaunch: Self.shouldRestoreWallpaper)
            displayController = controller
            if Self.shouldRestoreWallpaper {
                let exitGuard = UncleanExitGuard(directory: library.storage.rootURL)
                exitGuard.beginSession()
                controller.restoreHold = { [weak exitGuard] display, id in exitGuard?.isHeld(id, on: display) == true }
                uncleanExitGuard = exitGuard
                let log = ProblemLog(directory: library.storage.rootURL)
                for item in exitGuard.held {
                    let name = library.wallpaper(id: item.wallpaperID)?.name ?? item.wallpaperName
                    log.add(ProblemRecord(date: Date(), kind: .uncleanExit, displayName: item.displayName,
                                          wallpaperName: name, message: "这张壁纸刚换上不久 Kinetic 就意外退出；这次启动没有在这台显示器上自动恢复它。"))
                }
                if let issue = library.loadIssue {
                    log.add(ProblemRecord(date: Date(), kind: .libraryUnreadable, displayName: nil, wallpaperName: nil,
                                          message: issue.reason))
                }
                log.observe(runtimeManager)
                problemLog = log
            }
            controller.start()
            if let exitGuard = uncleanExitGuard {
                exitGuard.observe(runtimeManager, library: library)
                if !exitGuard.held.isEmpty {
                    launchRecovery = LaunchRecovery(exitGuard: exitGuard, runtime: runtimeManager, library: library)
                }
            }
            // Module 46：在恢复上次的壁纸之后接上，恢复不会被当成手动换壁纸。
            if let lists = localOrganization {
                let player = WallpaperPlaylistPlayer(storage: library.storage, runtime: runtimeManager,
                                                     library: library, lists: lists)
                playlistPlayer = player
                scheduler = WallpaperScheduler(storage: library.storage, runtime: runtimeManager,
                                               library: library, playlist: player,
                                               bookmarks: setupStore, editor: displayWallpaperEditor)
            }
            // Register a provider; empty configurations still create no effect or desktop window.
            OverlayWindowOwner.closeOrphanedWindows(in: NSApp.windows)
            let overlays = OverlayManager(store: OverlayStore(storage: library.storage), registry: controller.registry)
            self.overlays = overlays
            if Self.shouldRestoreWallpaper {
                let weather = WeatherService(store: WeatherStore(storage: library.storage))
                let responses = WeatherResponseStore(storage: library.storage)
                self.weather = weather
                weatherSettings = WeatherSettingsModel(weather: weather, responses: responses,
                    overlays: overlays.store, registry: controller.registry)
                overlays.register(.particles) { _ in WeatherResponsiveParticleOverlay(weather: weather, responses: responses) }
                let widgetLayouts = WidgetLayoutRepository(storage: library.storage), widgetContents = WidgetContentRegistry()
                self.widgetLayouts = widgetLayouts; self.widgetContents = widgetContents
                let metrics = SystemMetricsService.live()
                systemMetrics = metrics
                metrics.start(monitor: smartPauseMonitor)
                let music = MusicService(repository: LyricsRepository(file: library.storage.rootURL.appendingPathComponent("lyrics-cache.json")))
                self.music = music; music.start(monitor: smartPauseMonitor)
                let audio = AudioResponseService(music: music, publishSpectrum: { value in
                    SceneExternalInputs.publishSystemAudio(value.flatMap { try? SceneAudioSpectrum(left: $0.left, right: $0.right) })
                }, publishMedia: { source, value in
                    let track = value?.availability == .live ? value?.track : nil
                    SceneExternalInputs.publishMedia(playing: value?.isPlaying == true, title: track?.title,
                        artist: track?.artist, album: track?.album, duration: track?.duration, position: value?.position,
                        trackID: track?.id, playerBundleID: track == nil ? nil : source.bundleID, artwork: track?.artwork)
                })
                self.audioResponse = audio
                audio.start(runtime: runtimeManager, library: library, monitor: smartPauseMonitor)
                overlays.register(.music) { _ in MusicOverlay(service: music) }
                musicEditor = MusicOverlayEditorModel(manager: overlays, registry: controller.registry, service: music)
                widgetContents.registerSystemWidgets(service: metrics)
                widgetContents.registerWeatherWidget(service: weather)
                // Module 41: reads only folders the user grants in Settings, and only while a tile is visible.
                let sessions = AgentSessionService.live()
                agentSessions = sessions
                sessions.start(monitor: smartPauseMonitor)
                widgetContents.registerAgentSessionWidget(service: sessions)
                let widgetEditor = WidgetBoardEditorModel(manager: overlays, registry: controller.registry,
                    repository: widgetLayouts, contents: widgetContents, monitor: smartPauseMonitor)
                widgetEditor.onEditRequest = { [weak self] display, id in
                    self?.showWidgets(on: display); self?.widgetEditor?.selectWidget(id)
                }
                self.widgetEditor = widgetEditor
                // Desktop tiles sit above the desktop icons and can be dragged and right-clicked (user, 2026-10-08).
                overlays.register(.widgets) { [weak widgetEditor] configuration in
                    WidgetBoardOverlay(repository: widgetLayouts, registry: widgetContents,
                                       desktop: WidgetDesktopTiles(displayID: configuration.displayID, editor: widgetEditor))
                }
            } else {
                // Test hosts and standalone demos never read weather settings or request location/network.
                overlays.register(.particles) { _ in ParticleOverlay() }
            }
            // Module 42: no data source, so test hosts and demos get it too.
            overlays.register(.clock) { _ in NixieClockOverlay() }
            overlays.start(monitor: smartPauseMonitor)
            let particleEditor = ParticleEditorModel(manager: overlays, registry: controller.registry, monitor: smartPauseMonitor)
            let clockEditor = NixieClockEditorModel(manager: overlays, registry: controller.registry)
            self.particleEditor = particleEditor; self.clockEditor = clockEditor
            displayOverlayEditors = DisplayOverlayEditors(particles: particleEditor, clock: clockEditor, widgets: widgetEditor, music: musicEditor)
            if let setupStore, let displayWallpaperEditor, let playlistPlayer, let scheduler {
                schemeCoordinator = WallpaperSchemeCoordinator(store: setupStore, runtime: runtimeManager, library: library,
                    editor: displayWallpaperEditor, playlist: playlistPlayer, scheduler: scheduler,
                    overlays: overlays.store, layouts: widgetLayouts)
            }
            weather?.start(monitor: smartPauseMonitor)
            // 已有 Debug 验收面板继续使用当前系统主屏的实际表面，不另建重复桌面窗口。
            if let primary = runtimeManager.displayIDs.first, let surface = controller.surface(on: primary) {
                desktopWindowRuntime = surface.desktop
                crossfadeHost = surface.host as? CrossfadeDesktopHost
            }
        }
        // Module 49：测试宿主与独立验收会话不登记系统级快捷键。
        if !Self.isRunningTests {
            adaptiveFrameRate = AdaptiveFrameRateController(settings: settingsStore, monitor: smartPauseMonitor)
            performanceStrip = PerformanceStripModel()
            if let runtimeManager, let library {
                systemWallpaper = SystemWallpaperProvider(storage: library.storage, settings: settingsStore, runtime: runtimeManager,
                    library: library, editor: displayWallpaperEditor, pictures: WorkspaceDesktopPictures(),
                    capture: SystemWallpaperProvider.liveCapture(runtime: runtimeManager, editor: displayWallpaperEditor))
            }
            WebRenderer.isMouseInteractionPaused = settingsStore.state.webMouseInteractionPaused
            settingsStore.$state.map(\.webMouseInteractionPaused).removeDuplicates().dropFirst()
                .sink { WebRenderer.isMouseInteractionPaused = $0 }.store(in: &settingsSubscriptions)
            globalShortcuts.handler = { [weak self] in self?.performGlobalShortcut($0) }
            globalShortcuts.start(settings: settingsStore)
            let updates = UpdateController(settings: settingsStore)
            updates.start()
            self.updates = updates
            permissions = PermissionCenter(music: music, audioResponse: audioResponse)
        }
        if Self.shouldOfferOnboarding, let runtimeManager, let library, let importService {
            onboarding = OnboardingController(
                store: OnboardingStore(library: library.storage),
                library: library,
                importer: importService,
                runtime: runtimeManager,
                demos: OnboardingDemoCatalog.bundled()
            )
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--app-controls-test") {
            appControlsTestSession = AppControlsTestSession()
            appControlsTestSession?.start()
        }
        if ProcessInfo.processInfo.arguments.contains("--download-ux-test") {
            downloadTestSession = SteamDownloadTestSession()
            downloadTestSession?.start()
        }
        if ProcessInfo.processInfo.arguments.contains("--display-target-test") {
            displayTargetTestSession = DisplayTargetTestSession()
            displayTargetTestSession?.start()
        }
        if ProcessInfo.processInfo.arguments.contains("--local-drag-test") {
            localDragTestSession = LocalWallpaperDragTestSession()
            localDragTestSession?.start()
        }
        if LivePreviewDiagnostics.isPanelEnabled, let runtimeManager {
            livePreviewDiagnosticsPanel = LivePreviewDiagnosticsPanel(runtime: runtimeManager, library: library)
        }
        if ProcessInfo.processInfo.environment[Self.acceptanceLibraryEnvironmentKey] == "Module21",
           !Self.isRunningTests, let library, let importService {
            onboarding?.finish()
            Task { await CardStatesDemoLibrary.seedRecoveryIfNeeded(library: library, importer: importService) }
        } else if CardStatesDemoLibrary.isEnabled, let library, let importService {
            Task { await CardStatesDemoLibrary.seedIfNeeded(library: library, importer: importService) }
        } else if ProcessInfo.processInfo.arguments.contains("--desktop-window-test") {
            desktopWindowRuntime?.present(DesktopTestPatternView(frame: .zero))
        } else if ProcessInfo.processInfo.arguments.contains("--video-renderer-test"),
                  let desktopWindowRuntime {
            videoTestSession = VideoRendererTestSession(desktop: desktopWindowRuntime)
            videoTestSession?.start()
        } else if ProcessInfo.processInfo.arguments.contains("--runtime-state-test"),
                  let runtimeManager {
            runtimeTestSession = RuntimeStateTestSession(runtime: runtimeManager)
            runtimeTestSession?.start()
        } else if ProcessInfo.processInfo.arguments.contains("--crossfade-test"),
                  let runtimeManager, let crossfadeHost {
            crossfadeTestSession = CrossfadeTestSession(runtime: runtimeManager, host: crossfadeHost)
            crossfadeTestSession?.start()
        } else if ProcessInfo.processInfo.arguments.contains("--split-display-crossfade-test") {
            // 1.0 Module 6：独立的两个会话（屏幕左右两半），不使用 App 的 Runtime。
            splitDisplayCrossfadeTestSession = SplitDisplayCrossfadeTestSession(mode: .splitMainScreen)
            splitDisplayCrossfadeTestSession?.start()
        } else if ProcessInfo.processInfo.arguments.contains("--physical-display-crossfade-test") {
            // 1.0 Module 5 / 6 真实多显示器验收：每台连接的显示器一个会话，不使用 App 的 Runtime。
            splitDisplayCrossfadeTestSession = SplitDisplayCrossfadeTestSession(mode: .physicalScreens)
            splitDisplayCrossfadeTestSession?.start()
        } else if ProcessInfo.processInfo.arguments.contains("--library-test"),
                  let storage = try? LibraryTestSession.acceptanceStorage() {
            libraryTestSession = LibraryTestSession(library: WallpaperLibrary(storage: storage))
            libraryTestSession?.start()
        } else if ProcessInfo.processInfo.arguments.contains("--import-test"),
                  let runtimeManager, let storage = try? ImportTestSession.acceptanceStorage() {
            importTestSession = ImportTestSession(library: WallpaperLibrary(storage: storage), runtime: runtimeManager)
            importTestSession?.start()
        }
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        uncleanExitGuard?.endSession()
        globalShortcuts.shutdown()
        adaptiveFrameRate?.shutdown()
        performanceStrip?.shutdown()
        systemWallpaper?.shutdown()
        scheduler?.shutdown()
        playlistPlayer?.shutdown()
        aerialBrowser?.close()
        particleSettings?.close()
        nixieClockSettings?.close()
        widgetBoard?.close()
        agentSessionSettings?.close()
        musicSettings?.close()
        audioResponse?.shutdown()
        music?.shutdown()
        systemMetrics?.shutdown()
        agentSessions?.shutdown()
        overlays?.shutdown()
        weatherSettings?.closed()
        weather?.shutdown()
        // 退出会停止 Runtime：先停止记录，下次启动仍恢复退出前的壁纸。
        displayController?.stopRecording()
        smartPauseMonitor?.stop()
        WallpaperPreviewCoordinator.shared.stopAll()
        steamDisplayApply?.shutdown()
        #if DEBUG
        videoTestSession?.stop()
        runtimeTestSession?.stop()
        crossfadeTestSession?.stop()
        splitDisplayCrossfadeTestSession?.stop()
        libraryTestSession?.stop()
        importTestSession?.stop()
        displayTargetTestSession?.stop()
        localDragTestSession?.stop()
        appControlsTestSession?.stop()
        settingsPerformanceTestSession?.stop()
        sceneRuntimeTestSession?.stop()
        scenePropertiesTestSession?.stop()
        advancedVideoTestSession?.stop()
        #endif
        // 退出时恢复用户原本的 macOS 壁纸，并释放所有 Renderer。
        runtimeManager?.shutdown()
        displayController?.closeSurfaces()
        desktopWindowRuntime?.stop()
    }

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// R4 Debug 验收的合成 Steam 商店：不读钥匙串、不登记登录项。
    private static var isSteamStoreDemo: Bool {
        #if DEBUG
        return SteamStoreDemo.isEnabled
        #else
        return false
        #endif
    }

    /// 测试宿主和各 Debug 验收面板不恢复壁纸，避免改动用户桌面或干扰验收。
    private static var shouldRestoreWallpaper: Bool {
        if isRunningTests { return false }
        #if DEBUG
        let sessions = ["--desktop-window-test", "--video-renderer-test", "--runtime-state-test",
                        "--crossfade-test", "--library-test", "--import-test", "--split-display-crossfade-test",
                        "--physical-display-crossfade-test", "--download-ux-test", "--display-target-test", "--local-drag-test", "--app-controls-test", "--settings-performance-test", "--scene-runtime-test", "--scene-graph-test", "--scene-full-test", SteamStoreDemo.argument]
        if sessions.contains(where: ProcessInfo.processInfo.arguments.contains) { return false }
        #endif
        return true
    }

    /// Module 20：与恢复壁纸相同的范围；卡片状态演示资料库会自行填充，也不显示引导。
    private static var shouldOfferOnboarding: Bool {
        guard shouldRestoreWallpaper else { return false }
        #if DEBUG
        if CardStatesDemoLibrary.isEnabled { return false }
        #endif
        return true
    }

    /// 「智能暂停」（播放）以及「低电量模式时暂停」「使用电池时暂停」（通用）各自控制对应条件是否交给 Runtime；
    /// 关闭后立即恢复播放（手动暂停除外）。
    private func startSmartPauseMonitor(runtime: WallpaperRuntimeManager) {
        let monitor = SmartPauseMonitor.live(runtime: runtime)
        monitor.preferences = SmartPausePreferences(settings: settingsStore.state)
        settingsStore.$state
            .map { SmartPausePreferences(settings: $0) }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak monitor] preferences in monitor?.preferences = preferences }
            .store(in: &settingsSubscriptions)
        monitor.start()
        smartPauseMonitor = monitor
        runtime.$summary.map { $0.displays.map(\.id) }.removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak monitor] in monitor?.updateDisplays($0) }
            .store(in: &settingsSubscriptions)
    }

    /// 正式资料库目录；Debug 的卡片状态演示与验收资料库使用独立目录，不读写正式资料库。
    private func libraryStorage() -> LibraryStorageLocation? {
        #if DEBUG
        if CardStatesDemoLibrary.isEnabled { return try? CardStatesDemoLibrary.storage() }
        if let storage = Self.acceptanceLibraryStorage() { return storage }
        #endif
        return try? LibraryStorageLocation.standard()
    }

    #if DEBUG
    /// 仅 Debug 验收：环境变量 `KINETIC_ACCEPTANCE_LIBRARY=<名称>` 使用
    /// `Application Support/Kinetic-Acceptance/<名称>/` 这个独立的（可以是全新的空）资料库，例如验收首次启动引导。
    static let acceptanceLibraryEnvironmentKey = "KINETIC_ACCEPTANCE_LIBRARY"

    private static func acceptanceLibraryStorage() -> LibraryStorageLocation? {
        let name = ProcessInfo.processInfo.environment[acceptanceLibraryEnvironmentKey]
            ?? (SteamStoreDemo.isEnabled ? SteamStoreDemo.libraryName : nil)
        guard let name,
              !name.isEmpty, !name.contains("/"),
              let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                         appropriateFor: nil, create: true)
        else { return nil }
        return LibraryStorageLocation(rootURL: support.appendingPathComponent("Kinetic-Acceptance/\(name)", isDirectory: true))
    }
    #endif

    /// 点按 Dock 图标：主窗口没有显示时把它打开（登录启动后、或关闭主窗口后）。
    /// 桌面壁纸窗口始终可见，`flag` 总是 true，不能据此判断主窗口是否打开。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        endMainWindowSuppression()
        guard mainWindow?.isVisible != true, let openMainWindow else { return true }
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        openMainWindow()
        NSApp.activate(ignoringOtherApps: true)
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

}

/// 主题切换的淡化过渡。
///
/// 把 Core Animation 的淡化过渡加在每个可见窗口的**根图层**（窗口框架视图）上：它同时包含窗口背景、
/// 标题栏 / 工具栏和全部内容，旧外观与新外观整体交叉淡化。只加在内容视图上时，窗口背景会立刻换色，
/// 内容却还在从旧文字颜色淡出，过渡中间看起来像一片空白。
/// 过渡由合成器完成，主线程不抓取任何窗口画面；快速连续切换时新的过渡直接替换旧的，最后一次选择立即生效。
@MainActor
final class AppearanceTransition {
    static let duration: CFTimeInterval = 0.3
    /// Core Animation 总是以 kCATransition 为键保存过渡动画；新的过渡会替换进行中的那一个。
    static let animationKey = kCATransition

    /// 应用外观；返回是否启动了淡化过渡。
    @discardableResult
    func apply(_ mode: AppearanceMode, animated: Bool) -> Bool {
        let target = Self.appearance(for: mode)
        guard NSApp.appearance?.name != target?.name else { return false }
        let fades = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSApp.appearance = target
        if fades {
            // 改外观只标记重绘；真正的重绘与图层提交发生在本轮 run loop 末尾。此时挂上的过渡以上一帧
            // （旧外观）为起点、以新外观为终点。先改外观再挂过渡，避免窗口框架在外观变化时清掉动画。
            for layer in Self.transitionLayers() {
                layer.add(Self.makeTransition(), forKey: Self.animationKey)
            }
        }
        return fades
    }

    /// 跟随系统必须是 nil，不能把当前系统外观固化成显式外观。
    static func appearance(for mode: AppearanceMode) -> NSAppearance? {
        switch mode {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    static func makeTransition() -> CATransition {
        let transition = CATransition()
        transition.type = .fade
        transition.duration = duration
        transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return transition
    }

    /// 可见窗口（不含桌面壁纸窗口）的根图层；框架视图没有图层时退回内容视图的图层。
    static func transitionLayers() -> [CALayer] {
        NSApp.windows.compactMap { window in
            guard window.isVisible, !window.isMiniaturized,
                  window.identifier != AppDelegate.desktopWallpaperWindowIdentifier,
                  let content = window.contentView else { return nil }
            var root: NSView = content
            while let parent = root.superview { root = parent }
            return root.layer ?? content.layer
        }
    }
}
