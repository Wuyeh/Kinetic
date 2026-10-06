import AppKit
import Combine
import QuartzCore

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
    /// Module 19：每次启动恢复上次的壁纸。
    private var displayController: MultiDisplayController?
    /// Module 5：全局唯一的 Runtime Manager。启动时由 Module 19 恢复上次的壁纸。
    @Published private(set) var runtimeManager: WallpaperRuntimeManager?
    /// Module 6：Runtime 通过它在同一桌面窗口内完成 Crossfade。
    private var crossfadeHost: CrossfadeDesktopHost?
    /// Module 7：全局唯一的资料库（metadata 持久化）；启动时只读取，不添加或改动任何记录。
    @Published private(set) var library: WallpaperLibrary?
    /// Module 8：本地导入服务（复制到 Library Storage）；界面入口属于 Module 15 / 16。
    @Published private(set) var importService: LocalImportService?
    /// 1.0 Module 9：Steam 下载核心（SteamCMD、登录、下载、校验、入本地资料库）。
    @Published private(set) var steamService: SteamAcquisitionService?
    /// 1.0 Module 14：Steam 在线商店（用户自己的 Steam Web API Key，存钥匙串）。
    @Published private(set) var steamStore: SteamStoreService?
    /// 1.0 Module 28：Wallpaper Engine 引擎素材（链接用户的文件夹，或用用户的 Steam 账号下载）。
    @Published private(set) var engineAssets: EngineAssetsStore?
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

    func applicationDidFinishLaunching(_ notification: Notification) {
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
            let steamKeyStore: SteamAPIKeyStoring = Self.isRunningTests
                ? MemorySteamAPIKeyStore() : KeychainSteamAPIKeyStore()
            steamStore = SteamStoreService(keyStore: steamKeyStore)
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
        if !Self.isRunningTests {
            loginItems.start()
        }
        if let runtimeManager, let library {
            let controller = MultiDisplayController(
                registry: DisplayRegistry(), runtime: runtimeManager, library: library,
                store: DisplayAssignmentStore(library: library.storage),
                legacy: WallpaperRestorationStore(library: library.storage),
                restoreOnLaunch: Self.shouldRestoreWallpaper)
            displayController = controller
            controller.start()
            // 已有 Debug 验收面板继续使用当前系统主屏的实际表面，不另建重复桌面窗口。
            if let primary = runtimeManager.displayIDs.first, let surface = controller.surface(on: primary) {
                desktopWindowRuntime = surface.desktop
                crossfadeHost = surface.host as? CrossfadeDesktopHost
            }
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
        #endif
        // 退出时恢复用户原本的 macOS 壁纸，并释放所有 Renderer。
        runtimeManager?.shutdown()
        displayController?.closeSurfaces()
        desktopWindowRuntime?.stop()
    }

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// 测试宿主和各 Debug 验收面板不恢复壁纸，避免改动用户桌面或干扰验收。
    private static var shouldRestoreWallpaper: Bool {
        if isRunningTests { return false }
        #if DEBUG
        let sessions = ["--desktop-window-test", "--video-renderer-test", "--runtime-state-test",
                        "--crossfade-test", "--library-test", "--import-test", "--split-display-crossfade-test",
                        "--physical-display-crossfade-test", "--download-ux-test", "--display-target-test", "--local-drag-test", "--app-controls-test", "--settings-performance-test", "--scene-runtime-test", "--scene-graph-test", "--scene-full-test"]
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
        guard let name = ProcessInfo.processInfo.environment[acceptanceLibraryEnvironmentKey],
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
