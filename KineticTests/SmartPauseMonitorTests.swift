import AppKit
import XCTest
@testable import Kinetic

/// Module 18：系统条件 → Smart Pause、设置开关、与 Manual Pause 优先级的端到端配合，以及真实探针的判断规则。
@MainActor
final class SmartPauseMonitorTests: XCTestCase {
    // MARK: Fakes

    @MainActor
    private final class FakeProbe: SmartPauseSystemProbe {
        var isScreenLocked = false
        var isDisplayAsleep = false
        var isFullScreenAppActive = false
        var isBatteryLow = false
        var isLowPowerModeEnabled = false
        var isOnBatteryPower = false
        private(set) var powerHandler: (@MainActor () -> Void)?

        func startObservingPowerSource(_ onChange: @escaping @MainActor () -> Void) { powerHandler = onChange }
        func stopObservingPowerSource() { powerHandler = nil }
    }

    @MainActor
    private final class Changes {
        var values: [Bool] = []
    }

    private struct Harness {
        let monitor: SmartPauseMonitor
        let probe: FakeProbe
        let workspace: NotificationCenter
        let distributed: NotificationCenter
        let application: NotificationCenter
        let changes: Changes
    }

    private let desktopIdentifier = NSUserInterfaceItemIdentifier("KineticTests.SmartPause.Desktop")
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        windows.forEach { $0.orderOut(nil); $0.close() }
        windows = []
    }

    private func makeWindow(identifier: NSUserInterfaceItemIdentifier?) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -4_000, y: -4_000, width: 200, height: 120),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.identifier = identifier
        windows.append(window)
        return window
    }

    private func makeHarness(settleDelay: TimeInterval = 0.05, configure: (FakeProbe) -> Void = { _ in }) -> Harness {
        let probe = FakeProbe()
        configure(probe)
        let changes = Changes()
        let workspace = NotificationCenter()
        let distributed = NotificationCenter()
        let application = NotificationCenter()
        let monitor = SmartPauseMonitor(
            probe: probe,
            workspaceNotifications: workspace,
            distributedNotifications: distributed,
            applicationNotifications: application,
            desktopWindowIdentifier: desktopIdentifier,
            fullScreenSettleDelay: settleDelay
        ) { active in changes.values.append(active) }
        return Harness(monitor: monitor, probe: probe, workspace: workspace,
                       distributed: distributed, application: application, changes: changes)
    }

    private func spin(_ seconds: TimeInterval = 0.02) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func post(_ center: NotificationCenter, _ name: Notification.Name) {
        center.post(name: name, object: nil)
        spin()
    }

    // MARK: 各条件

    func testMacSleepPausesUntilWake() {
        let h = makeHarness()
        h.monitor.start()
        post(h.workspace, NSWorkspace.willSleepNotification)
        XCTAssertTrue(h.monitor.conditions.systemAsleep)
        post(h.workspace, NSWorkspace.didWakeNotification)
        XCTAssertEqual(h.changes.values, [true, false])
    }

    func testDisplaySleepPausesUntilDisplaysWake() {
        let h = makeHarness()
        h.monitor.start()
        post(h.workspace, NSWorkspace.screensDidSleepNotification)
        XCTAssertTrue(h.monitor.conditions.displayAsleep)
        post(h.workspace, NSWorkspace.screensDidWakeNotification)
        XCTAssertEqual(h.changes.values, [true, false])
    }

    func testScreenLockPausesUntilUnlock() {
        let h = makeHarness()
        h.monitor.start()
        post(h.distributed, SmartPauseMonitor.screenLockedNotification)
        XCTAssertTrue(h.monitor.conditions.screenLocked)
        post(h.distributed, SmartPauseMonitor.screenUnlockedNotification)
        XCTAssertEqual(h.changes.values, [true, false])
    }

    func testSwitchingToAnotherUserCountsAsLocked() {
        let h = makeHarness()
        h.monitor.start()
        post(h.workspace, NSWorkspace.sessionDidResignActiveNotification)
        XCTAssertTrue(h.monitor.isSmartPauseActive)
        h.probe.isScreenLocked = false
        post(h.workspace, NSWorkspace.sessionDidBecomeActiveNotification)
        XCTAssertEqual(h.changes.values, [true, false])
    }

    func testFullScreenAppPausesWhenItsSpaceIsActive() {
        let h = makeHarness()
        h.monitor.start()
        h.probe.isFullScreenAppActive = true
        post(h.workspace, NSWorkspace.activeSpaceDidChangeNotification)
        XCTAssertTrue(h.monitor.conditions.fullScreenApp)
        h.probe.isFullScreenAppActive = false
        post(h.workspace, NSWorkspace.activeSpaceDidChangeNotification)
        XCTAssertEqual(h.changes.values, [true, false])
    }

    func testFullScreenFollowsTheWallpaperWindowsOcclusion() {
        let h = makeHarness()
        h.monitor.start()
        let desktop = makeWindow(identifier: desktopIdentifier)
        let other = makeWindow(identifier: NSUserInterfaceItemIdentifier("other"))

        h.probe.isFullScreenAppActive = true
        h.application.post(name: NSWindow.didChangeOcclusionStateNotification, object: other)
        spin()
        XCTAssertFalse(h.monitor.conditions.fullScreenApp, "只看 Kinetic 自己的壁纸窗口")
        h.application.post(name: NSWindow.didChangeOcclusionStateNotification, object: desktop)
        spin()
        XCTAssertTrue(h.monitor.conditions.fullScreenApp)

        h.probe.isFullScreenAppActive = false
        h.application.post(name: NSWindow.didChangeOcclusionStateNotification, object: desktop)
        spin()
        XCTAssertEqual(h.changes.values, [true, false])

        // 壁纸停止、窗口关闭时条件随之结束。
        h.probe.isFullScreenAppActive = true
        h.application.post(name: NSWindow.didChangeOcclusionStateNotification, object: desktop)
        spin()
        h.application.post(name: NSWindow.willCloseNotification, object: desktop)
        spin()
        XCTAssertFalse(h.monitor.conditions.fullScreenApp)
        XCTAssertEqual(h.changes.values, [true, false, true, false])
    }

    func testFullScreenIsRecheckedAfterTheSpaceAnimationSettles() {
        let h = makeHarness(settleDelay: 0.05)
        h.monitor.start()
        post(h.workspace, NSWorkspace.activeSpaceDidChangeNotification)
        XCTAssertFalse(h.monitor.conditions.fullScreenApp)
        // 进入全屏的动画结束后窗口才覆盖整块屏幕。
        h.probe.isFullScreenAppActive = true
        spin(0.2)
        XCTAssertTrue(h.monitor.conditions.fullScreenApp)
        XCTAssertEqual(h.changes.values, [true])
    }

    func testLowBatteryPausesUntilPowerRecovers() {
        let h = makeHarness()
        h.monitor.start()
        h.probe.isBatteryLow = true
        h.probe.powerHandler?()
        XCTAssertTrue(h.monitor.conditions.batteryLow)
        h.probe.isBatteryLow = false
        h.probe.powerHandler?()
        XCTAssertEqual(h.changes.values, [true, false])
    }

    // MARK: 组合、初始状态与设置

    func testResumesOnlyWhenEveryConditionHasEnded() {
        let h = makeHarness()
        h.monitor.start()
        post(h.distributed, SmartPauseMonitor.screenLockedNotification)
        post(h.workspace, NSWorkspace.screensDidSleepNotification)
        post(h.distributed, SmartPauseMonitor.screenUnlockedNotification)
        XCTAssertTrue(h.monitor.isSmartPauseActive, "显示器仍在睡眠")
        post(h.workspace, NSWorkspace.screensDidWakeNotification)
        XCTAssertFalse(h.monitor.isSmartPauseActive)
        XCTAssertEqual(h.changes.values, [true, false], "中间不能反复暂停 / 继续")
    }

    func testStartsFromTheCurrentSystemState() {
        let h = makeHarness { $0.isScreenLocked = true }
        h.monitor.start()
        XCTAssertTrue(h.monitor.conditions.screenLocked)
        XCTAssertEqual(h.changes.values, [true])
    }

    func testWakeReadsStateThatChangedWhileAsleep() {
        let h = makeHarness()
        h.monitor.start()
        post(h.workspace, NSWorkspace.willSleepNotification)
        // 睡眠期间锁屏、没有收到通知：醒来时从系统读取。
        h.probe.isScreenLocked = true
        post(h.workspace, NSWorkspace.didWakeNotification)
        XCTAssertTrue(h.monitor.isSmartPauseActive)
        post(h.distributed, SmartPauseMonitor.screenUnlockedNotification)
        XCTAssertEqual(h.changes.values, [true, false])
    }

    func testSettingOffSkipsFullscreenAndTurningItOnAppliesImmediately() {
        let h = makeHarness()
        h.monitor.preferences.smartPause = false
        h.monitor.start()
        h.probe.isFullScreenAppActive = true
        post(h.workspace, NSWorkspace.activeSpaceDidChangeNotification)
        XCTAssertTrue(h.monitor.conditions.fullScreenApp, "条件照常记录")
        XCTAssertEqual(h.changes.values, [], "关闭时不暂停")

        h.monitor.preferences.smartPause = true
        XCTAssertEqual(h.changes.values, [true])
        h.monitor.preferences.smartPause = false
        XCTAssertEqual(h.changes.values, [true, false], "关闭后立即恢复")
    }

    // MARK: 低电量模式与电池供电（「通用」中的独立开关）

    func testPowerPreferencesComeFromSettingsWithUserDefaults() {
        let preferences = SmartPausePreferences(settings: SettingsState())
        XCTAssertTrue(preferences.smartPause)
        XCTAssertTrue(preferences.lowPowerMode, "低电量模式时暂停：默认开")
        XCTAssertFalse(preferences.batteryPower, "使用电池时暂停：默认关")
        XCTAssertEqual(SmartPausePreferences(), preferences)
    }

    func testLowPowerModePausesByDefaultAndFollowsItsSetting() {
        let h = makeHarness()
        h.monitor.start()
        h.probe.isLowPowerModeEnabled = true
        post(h.application, .NSProcessInfoPowerStateDidChange)
        XCTAssertTrue(h.monitor.conditions.lowPowerMode)
        XCTAssertEqual(h.changes.values, [true])

        h.monitor.preferences.lowPowerMode = false
        XCTAssertEqual(h.changes.values, [true, false], "关闭此选项后立即继续")
        h.monitor.preferences.lowPowerMode = true
        XCTAssertEqual(h.changes.values, [true, false, true])

        h.probe.isLowPowerModeEnabled = false
        post(h.application, .NSProcessInfoPowerStateDidChange)
        XCTAssertEqual(h.changes.values, [true, false, true, false], "关闭低电量模式后继续")
    }

    func testBatteryPowerPausesOnlyWhenTheOptionIsOn() {
        let h = makeHarness()
        h.monitor.start()
        h.probe.isOnBatteryPower = true
        h.probe.powerHandler?()
        XCTAssertTrue(h.monitor.conditions.onBatteryPower)
        XCTAssertEqual(h.changes.values, [], "默认关闭：拔掉电源仍播放")

        h.monitor.preferences.batteryPower = true
        XCTAssertEqual(h.changes.values, [true])
        h.probe.isOnBatteryPower = false
        h.probe.powerHandler?()
        XCTAssertEqual(h.changes.values, [true, false], "接上电源后继续")
    }

    func testPowerOptionsAreIndependentOfSmartPause() {
        let h = makeHarness()
        h.monitor.preferences = SmartPausePreferences(smartPause: false, lowPowerMode: true, batteryPower: true)
        h.monitor.start()
        post(h.distributed, SmartPauseMonitor.screenLockedNotification)
        XCTAssertEqual(h.changes.values, [true], "1.0 系统保护：关闭智能暂停仍不能绕过锁屏")
        post(h.distributed, SmartPauseMonitor.screenUnlockedNotification)
        XCTAssertEqual(h.changes.values, [true, false])

        h.probe.isLowPowerModeEnabled = true
        post(h.application, .NSProcessInfoPowerStateDidChange)
        XCTAssertEqual(h.changes.values, [true, false, true], "低电量模式仍暂停")
        h.probe.isLowPowerModeEnabled = false
        post(h.application, .NSProcessInfoPowerStateDidChange)
        h.probe.isOnBatteryPower = true
        h.probe.powerHandler?()
        XCTAssertEqual(h.changes.values, [true, false, true, false, true], "电池供电仍暂停")

        // 反过来：只开智能暂停时，电源条件不影响。
        post(h.distributed, SmartPauseMonitor.screenLockedNotification)
        h.monitor.preferences = SmartPausePreferences(smartPause: true, lowPowerMode: false, batteryPower: false)
        XCTAssertEqual(h.changes.values, [true, false, true, false, true], "锁屏条件仍在，保持暂停、不重复通知")
        post(h.distributed, SmartPauseMonitor.screenUnlockedNotification)
        XCTAssertFalse(h.monitor.isSmartPauseActive)
    }

    func testStartsPausedWhenAlreadyInLowPowerMode() {
        let h = makeHarness { $0.isLowPowerModeEnabled = true }
        h.monitor.start()
        XCTAssertEqual(h.changes.values, [true])
    }

    func testStopRemovesEveryObserver() {
        let h = makeHarness()
        h.monitor.start()
        h.monitor.stop()
        post(h.workspace, NSWorkspace.willSleepNotification)
        post(h.distributed, SmartPauseMonitor.screenLockedNotification)
        h.probe.isFullScreenAppActive = true
        post(h.application, NSApplication.didChangeScreenParametersNotification)
        h.probe.isLowPowerModeEnabled = true
        post(h.application, .NSProcessInfoPowerStateDidChange)
        XCTAssertNil(h.probe.powerHandler)
        XCTAssertEqual(h.changes.values, [])
    }

    // MARK: 与 Runtime 的端到端配合（Manual Pause 优先）

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

    func testSmartPauseResumesInPlaceAndNeverOverridesManualPause() {
        let desktop = StubDesktop()
        var renderer: RecordingRenderer?
        let runtime = WallpaperRuntimeManager(desktop: desktop) { wallpaper in
            let made = RecordingRenderer(wallpaper: wallpaper)
            renderer = made
            return made
        }
        let h = makeHarness()
        let monitor = SmartPauseMonitor(
            probe: h.probe,
            workspaceNotifications: h.workspace,
            distributedNotifications: h.distributed,
            applicationNotifications: h.application,
            desktopWindowIdentifier: desktopIdentifier
        ) { [weak runtime] active in runtime?.setSmartPauseActive(active) }
        monitor.start()

        runtime.apply(Wallpaper(name: "雨夜", type: .video, source: .local,
                                resourceURL: URL(fileURLWithPath: "/kinetic-smart-pause/rain.mp4")))
        let deadline = Date().addingTimeInterval(2)
        while runtime.state.playbackState != .playing && Date() < deadline { spin(0.01) }
        XCTAssertEqual(runtime.state.playbackState, .playing)

        // 锁屏 → 自动暂停；解锁 → 从原位置继续（resume，不重新 play）。
        post(h.distributed, SmartPauseMonitor.screenLockedNotification)
        XCTAssertEqual(runtime.state.playbackState, .smartPaused)
        post(h.distributed, SmartPauseMonitor.screenUnlockedNotification)
        XCTAssertEqual(runtime.state.playbackState, .playing)
        XCTAssertEqual(renderer?.calls, ["play", "pause", "resume"])

        // 智能暂停中用户手动暂停：条件结束后仍保持手动暂停，直到用户继续。
        post(h.workspace, NSWorkspace.screensDidSleepNotification)
        XCTAssertEqual(runtime.state.playbackState, .smartPaused)
        runtime.pause()
        XCTAssertEqual(runtime.state.playbackState, .manualPaused)
        post(h.workspace, NSWorkspace.screensDidWakeNotification)
        XCTAssertEqual(runtime.state.playbackState, .manualPaused)
        XCTAssertEqual(renderer?.calls, ["play", "pause", "resume", "pause"])

        // 手动暂停后出现又消失的系统条件同样不会恢复播放。
        post(h.workspace, NSWorkspace.willSleepNotification)
        post(h.workspace, NSWorkspace.didWakeNotification)
        XCTAssertEqual(runtime.state.playbackState, .manualPaused)
        runtime.resume()
        XCTAssertEqual(runtime.state.playbackState, .playing)
        XCTAssertEqual(renderer?.calls, ["play", "pause", "resume", "pause", "resume"])

        monitor.stop()
        runtime.shutdown()
    }

    // MARK: 真实探针的判断规则

    /// 真实探针：壁纸窗口显示但完全不可见（这里放在屏幕外）即视为被全屏 App 遮住；没有显示时不判断。
    func testLiveProbeUsesTheWallpaperWindowsVisibility() {
        let probe = LiveSmartPauseProbe(desktopWindowIdentifier: desktopIdentifier)
        XCTAssertFalse(probe.isFullScreenAppActive, "没有壁纸窗口")

        let desktop = makeWindow(identifier: desktopIdentifier)
        XCTAssertFalse(probe.isFullScreenAppActive, "壁纸窗口尚未显示")
        desktop.orderFrontRegardless()
        let deadline = Date().addingTimeInterval(2)
        while desktop.occlusionState.contains(.visible) && Date() < deadline { spin(0.05) }
        XCTAssertTrue(probe.isFullScreenAppActive, "显示中但完全看不见")
        desktop.orderOut(nil)
        XCTAssertFalse(probe.isFullScreenAppActive)
    }

    func testLowBatteryThreshold() {
        XCTAssertEqual(LiveSmartPauseProbe.lowBatteryThreshold, 20)
        XCTAssertTrue(LiveSmartPauseProbe.isBatteryLow(onBattery: true, percent: 20))
        XCTAssertTrue(LiveSmartPauseProbe.isBatteryLow(onBattery: true, percent: 3))
        XCTAssertFalse(LiveSmartPauseProbe.isBatteryLow(onBattery: true, percent: 21))
        XCTAssertFalse(LiveSmartPauseProbe.isBatteryLow(onBattery: false, percent: 5), "接电源时不算低电量")
    }

    /// 在测试宿主的真实环境读取一次：测试运行时屏幕未锁、显示器亮着。
    func testLiveProbeReadsTheCurrentSystemState() {
        let probe = LiveSmartPauseProbe(desktopWindowIdentifier: desktopIdentifier)
        let battery = LiveSmartPauseProbe.batteryReading()
        print("KSMART locked=\(probe.isScreenLocked) displayAsleep=\(probe.isDisplayAsleep) batteryLow=\(probe.isBatteryLow) lowPowerMode=\(probe.isLowPowerModeEnabled) onBattery=\(probe.isOnBatteryPower) battery=\(String(describing: battery))")
        XCTAssertEqual(probe.isLowPowerModeEnabled, ProcessInfo.processInfo.isLowPowerModeEnabled)
        XCTAssertFalse(probe.isScreenLocked)
        XCTAssertFalse(probe.isDisplayAsleep)
        if let battery {
            XCTAssertEqual(probe.isOnBatteryPower, battery.onBattery)
            XCTAssertEqual(probe.isBatteryLow, LiveSmartPauseProbe.isBatteryLow(onBattery: battery.onBattery, percent: battery.percent))
        } else {
            XCTAssertFalse(probe.isBatteryLow, "没有内置电池的 Mac 不会低电量暂停")
            XCTAssertFalse(probe.isOnBatteryPower)
        }
    }
}
