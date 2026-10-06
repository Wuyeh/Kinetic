import AppKit
import XCTest
@testable import Kinetic

/// Module 19：登录项（系统状态为准、默认关闭）、登录启动识别，以及每次启动恢复上次的壁纸。
@MainActor
final class LaunchAndLoginItemTests: XCTestCase {
    private var suites: [String] = []
    private var roots: [URL] = []

    override func tearDown() async throws {
        suites.forEach { UserDefaults(suiteName: $0)?.removePersistentDomain(forName: $0) }
        suites = []
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        roots = []
    }

    private func isolatedDefaults() throws -> UserDefaults {
        let suite = "KineticTests.Launch.\(UUID().uuidString)"
        suites.append(suite)
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    private func spin(_ seconds: TimeInterval = 0.02) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: 登录项

    private struct LoginItemError: LocalizedError {
        var errorDescription: String? { "需要用户许可" }
    }

    @MainActor
    private final class FakeLoginService: LoginItemService {
        var status: LoginItemStatus = .disabled
        var registerError: Error?
        var calls: [String] = []

        func register() throws {
            calls.append("register")
            if let registerError { throw registerError }
            status = .enabled
        }

        func unregister() throws {
            calls.append("unregister")
            status = .disabled
        }

        func openSystemSettings() { calls.append("openSystemSettings") }
    }

    func testOffByDefaultAndNothingIsRegisteredAtLaunch() throws {
        let settings = SettingsStore(defaults: try isolatedDefaults())
        XCTAssertFalse(settings.state.launchAtLoginEnabled)
        let service = FakeLoginService()
        let controller = LoginItemController(service: service, settings: settings)
        controller.start(applicationNotifications: NotificationCenter())
        XCTAssertEqual(service.calls, [])
        XCTAssertEqual(controller.status, .disabled)
        XCTAssertFalse(settings.state.launchAtLoginEnabled)
    }

    func testSwitchRegistersAndUnregistersTheApp() throws {
        let settings = SettingsStore(defaults: try isolatedDefaults())
        let service = FakeLoginService()
        let controller = LoginItemController(service: service, settings: settings)
        controller.start(applicationNotifications: NotificationCenter())

        controller.setEnabled(true)
        XCTAssertEqual(controller.status, .enabled)
        XCTAssertTrue(settings.state.launchAtLoginEnabled)
        controller.setEnabled(true)
        XCTAssertEqual(service.calls, ["register"], "已启用时不重复登记")

        controller.setEnabled(false)
        XCTAssertEqual(controller.status, .disabled)
        XCTAssertFalse(settings.state.launchAtLoginEnabled)
        XCTAssertEqual(service.calls, ["register", "unregister"])
    }

    func testFailureLeavesTheSwitchOffAndExplainsWhy() throws {
        let settings = SettingsStore(defaults: try isolatedDefaults())
        let service = FakeLoginService()
        service.registerError = LoginItemError()
        let controller = LoginItemController(service: service, settings: settings)

        controller.setEnabled(true)
        XCTAssertEqual(controller.status, .disabled)
        XCTAssertFalse(settings.state.launchAtLoginEnabled)
        XCTAssertEqual(controller.lastError, "需要用户许可")

        service.registerError = nil
        controller.setEnabled(true)
        XCTAssertNil(controller.lastError)
        XCTAssertTrue(settings.state.launchAtLoginEnabled)
    }

    /// 用户在「系统设置 > 登录项」中改动后，回到 Kinetic 时开关跟着系统走。
    func testSystemSettingsAreTheSourceOfTruth() throws {
        let settings = SettingsStore(defaults: try isolatedDefaults())
        let service = FakeLoginService()
        let center = NotificationCenter()
        let controller = LoginItemController(service: service, settings: settings)
        controller.start(applicationNotifications: center)
        controller.setEnabled(true)

        service.status = .requiresApproval
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        spin()
        XCTAssertEqual(controller.status, .requiresApproval)
        XCTAssertTrue(controller.status.isOn, "已登记但等待允许：开关仍为开，并提示去系统设置")
        controller.openSystemSettings()
        XCTAssertEqual(service.calls.last, "openSystemSettings")

        service.status = .disabled
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        spin()
        XCTAssertFalse(settings.state.launchAtLoginEnabled)
    }

    /// 旧版本只保存了偏好（当时还没有接入系统）：启动时按偏好登记一次。
    func testPreferenceSavedByAnEarlierVersionIsAppliedOnce() throws {
        let settings = SettingsStore(defaults: try isolatedDefaults())
        settings.set(\.launchAtLoginEnabled, to: true)
        let service = FakeLoginService()
        let controller = LoginItemController(service: service, settings: settings)
        controller.start(applicationNotifications: NotificationCenter())
        XCTAssertEqual(service.calls, ["register"])
        XCTAssertEqual(controller.status, .enabled)
    }

    // MARK: 登录启动识别

    private func openApplicationEvent(loginItem: Bool, eventID: AEEventID = AEEventID(kAEOpenApplication)) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass), eventID: eventID, targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID)
        )
        if loginItem {
            event.setParam(NSAppleEventDescriptor(enumCode: OSType(keyAELaunchedAsLogInItem)),
                           forKeyword: AEKeyword(keyAEPropData))
        }
        return event
    }

    func testRecognisesLoginItemLaunches() {
        XCTAssertTrue(LaunchContext.isLoginLaunch(event: openApplicationEvent(loginItem: true), environment: [:]))
        XCTAssertFalse(LaunchContext.isLoginLaunch(event: openApplicationEvent(loginItem: false), environment: [:]),
                       "手动打开")
        XCTAssertFalse(LaunchContext.isLoginLaunch(
            event: openApplicationEvent(loginItem: true, eventID: AEEventID(kAEReopenApplication)), environment: [:]))
        XCTAssertFalse(LaunchContext.isLoginLaunch(event: nil, environment: [:]))
        #if DEBUG
        XCTAssertTrue(LaunchContext.isLoginLaunch(
            event: nil, environment: [LaunchContext.simulatedLoginLaunchEnvironmentKey: "1"]))
        #endif
    }

    func testManualLaunchShowsTheMainWindow() {
        let window = makeWindow()
        let suppression = MainWindowLaunchSuppression(isLoginLaunch: false)
        XCTAssertFalse(suppression.hide(window))
        window.orderFront(nil)
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(window.alphaValue, 1)
        window.orderOut(nil)
    }

    func testLoginLaunchKeepsTheLaunchWindowHiddenUntilTheUserOpensIt() {
        let window = makeWindow()
        let suppression = MainWindowLaunchSuppression(isLoginLaunch: true)
        XCTAssertTrue(suppression.hide(window))
        XCTAssertEqual(window.alphaValue, 0, "启动阶段保持透明，不会闪现")

        // SwiftUI 稍后才把窗口显示出来：启动阶段内每次出现都立即隐藏。
        window.orderFront(nil)
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        XCTAssertFalse(window.isVisible)
        window.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        XCTAssertFalse(window.isVisible)

        // 用户从菜单栏或 Dock 打开：恢复正常显示。
        suppression.end()
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(window.alphaValue, 1)
        window.orderFront(nil)
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        XCTAssertTrue(window.isVisible)
        XCTAssertFalse(suppression.hide(window), "之后再出现的主窗口不再隐藏")
        window.orderOut(nil)
    }

    func testWindowAppearingAfterTheLaunchPhaseIsShown() {
        // 系统这次没有在启动时创建主窗口：启动阶段结束后用户第一次打开也必须显示。
        let suppression = MainWindowLaunchSuppression(isLoginLaunch: true)
        suppression.end()
        XCTAssertFalse(suppression.isActive)
        let window = makeWindow()
        XCTAssertFalse(suppression.hide(window))
        XCTAssertEqual(window.alphaValue, 1)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 160),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    // MARK: 恢复上次的壁纸

    func testRecordFollowsTheRuntimeState() {
        let id = UUID()
        var state = WallpaperRuntimeState()
        XCTAssertNil(WallpaperRestorationRecord(state: state), "还没有壁纸：保留原有记录")
        state.playbackState = .preparing
        state.preparingWallpaperID = id
        XCTAssertNil(WallpaperRestorationRecord(state: state), "首次准备中：不记录")

        state = WallpaperRuntimeState(playbackState: .playing, activeWallpaperID: id)
        XCTAssertEqual(WallpaperRestorationRecord(state: state),
                       WallpaperRestorationRecord(wallpaperID: id, isStopped: false, isManuallyPaused: false))
        state.playbackState = .smartPaused
        XCTAssertEqual(WallpaperRestorationRecord(state: state)?.isManuallyPaused, false, "自动暂停不算手动暂停")
        state.playbackState = .manualPaused
        XCTAssertEqual(WallpaperRestorationRecord(state: state)?.isManuallyPaused, true)

        state = WallpaperRuntimeState(playbackState: .stopped, lastActiveWallpaperID: id)
        XCTAssertEqual(WallpaperRestorationRecord(state: state),
                       WallpaperRestorationRecord(wallpaperID: id, isStopped: true, isManuallyPaused: false))
    }

    func testRecordsAreKeptPerLibrary() throws {
        let defaults = try isolatedDefaults()
        let product = WallpaperRestorationStore(defaults: defaults, library: LibraryStorageLocation(rootURL: URL(fileURLWithPath: "/tmp/kinetic-a")))
        let demo = WallpaperRestorationStore(defaults: defaults, library: LibraryStorageLocation(rootURL: URL(fileURLWithPath: "/tmp/kinetic-b")))
        let a = WallpaperRestorationRecord(wallpaperID: UUID(), isStopped: false, isManuallyPaused: true)
        let b = WallpaperRestorationRecord(wallpaperID: UUID(), isStopped: true, isManuallyPaused: false)
        product.save(a)
        demo.save(b)
        XCTAssertEqual(product.load(), a)
        XCTAssertEqual(demo.load(), b)
    }

    @MainActor
    private final class RecordingRenderer: WallpaperRenderer {
        let wallpaper: Wallpaper
        let displayView = NSView()
        var onFailure: (@MainActor (Error) -> Void)?
        var calls: [String] = []
        init(wallpaper: Wallpaper) { self.wallpaper = wallpaper }
        func prepare() async throws {}
        func play() { calls.append("play") }
        func pause() { calls.append("pause") }
        func resume() { calls.append("resume") }
        func setMuted(_ muted: Bool) {}
        func dispose() { calls.append("dispose") }
    }

    @MainActor
    private final class StubDesktop: DesktopContentHost {
        func present(_ contentView: NSView) -> Bool { true }
        func stop() {}
    }

    private struct Launch {
        let runtime: WallpaperRuntimeManager
        let restorer: WallpaperRestorer
        let renderers: () -> [RecordingRenderer]
    }

    /// 模拟一次 App 启动：新的 Runtime，同一资料库与同一记录。
    private func launch(library: WallpaperLibrary, defaults: UserDefaults) -> Launch {
        var made: [RecordingRenderer] = []
        let runtime = WallpaperRuntimeManager(desktop: StubDesktop()) { wallpaper in
            let renderer = RecordingRenderer(wallpaper: wallpaper)
            made.append(renderer)
            return renderer
        }
        let restorer = WallpaperRestorer(
            store: WallpaperRestorationStore(defaults: defaults, library: library.storage),
            runtime: runtime, library: library
        )
        return Launch(runtime: runtime, restorer: restorer, renderers: { made })
    }

    private func waitForActive(_ runtime: WallpaperRuntimeManager) {
        let deadline = Date().addingTimeInterval(2)
        while runtime.state.activeWallpaperID == nil && Date() < deadline { spin(0.01) }
    }

    /// 退出（会停止 Runtime）后再次启动：恢复同一张壁纸；手动暂停的保持暂停；用户停止过的不恢复。
    func testEveryLaunchRestoresTheLastWallpaper() throws {
        let defaults = try isolatedDefaults()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KineticRestore-\(UUID().uuidString)")
        roots.append(root)
        let library = WallpaperLibrary(storage: LibraryStorageLocation(rootURL: root))
        let rain = Wallpaper(name: "雨夜", type: .video, source: .local, resourceURL: root.appendingPathComponent("rain.mp4"))
        let sea = Wallpaper(name: "海边", type: .video, source: .local, resourceURL: root.appendingPathComponent("sea.mp4"))
        try library.add(rain)
        try library.add(sea)

        // 第一次启动：没有记录，不应用任何壁纸。
        var run = launch(library: library, defaults: defaults)
        XCTAssertNil(run.restorer.restore())
        run.restorer.startRecording()
        run.runtime.apply(rain)
        waitForActive(run.runtime)
        XCTAssertEqual(run.runtime.state.playbackState, .playing)
        // 退出：先停止记录，再停止 Runtime。
        run.restorer.stopRecording()
        run.runtime.shutdown()

        // 第二次启动：继续播放雨夜。
        run = launch(library: library, defaults: defaults)
        XCTAssertEqual(run.restorer.restore()?.id, rain.id)
        run.restorer.startRecording()
        waitForActive(run.runtime)
        XCTAssertEqual(run.runtime.state.playbackState, .playing)
        XCTAssertEqual(run.renderers().first?.calls, ["play"])
        // 换成海边并手动暂停后退出。
        run.runtime.apply(sea)
        let deadline = Date().addingTimeInterval(2)
        while run.runtime.state.activeWallpaperID != sea.id && Date() < deadline { spin(0.01) }
        run.runtime.pause()
        run.restorer.stopRecording()
        run.runtime.shutdown()

        // 第三次启动：恢复海边，但保持手动暂停，不开始播放。
        run = launch(library: library, defaults: defaults)
        XCTAssertEqual(run.restorer.restore()?.id, sea.id)
        run.restorer.startRecording()
        waitForActive(run.runtime)
        XCTAssertEqual(run.runtime.state.playbackState, .manualPaused)
        XCTAssertEqual(run.renderers().first?.calls, [], "恢复后停在第一帧，不开始播放")
        // 用户停止壁纸后退出。
        run.runtime.stop()
        spin()
        run.restorer.stopRecording()
        run.runtime.shutdown()

        // 第四次启动：用户停止过，不恢复。
        run = launch(library: library, defaults: defaults)
        XCTAssertNil(run.restorer.restore())
        XCTAssertEqual(run.runtime.state.playbackState, .noWallpaper)
        run.runtime.shutdown()
    }

    func testDeletedWallpaperIsNotRestored() throws {
        let defaults = try isolatedDefaults()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KineticRestore-\(UUID().uuidString)")
        roots.append(root)
        let library = WallpaperLibrary(storage: LibraryStorageLocation(rootURL: root))
        let store = WallpaperRestorationStore(defaults: defaults, library: library.storage)
        store.save(WallpaperRestorationRecord(wallpaperID: UUID(), isStopped: false, isManuallyPaused: false))
        let run = launch(library: library, defaults: defaults)
        XCTAssertNil(run.restorer.restore())
        XCTAssertEqual(run.runtime.state.playbackState, .noWallpaper)
    }
}
