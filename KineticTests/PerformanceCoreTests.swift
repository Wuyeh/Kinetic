import AppKit
import XCTest
@testable import Kinetic

@MainActor
final class PerformanceCoreTests: XCTestCase {
    func testSafetyRemainsActiveWhenConfigurablePoliciesAreDisabled() {
        let preferences = SmartPausePreferences(smartPause: false, lowPowerMode: false, batteryPower: false)
        let safety: [(WritableKeyPath<SmartPauseConditions, Bool>, SmartPauseReason)] = [
            (\.screenLocked, .screenLocked), (\.systemAsleep, .systemAsleep), (\.displayAsleep, .displayAsleep),
            (\.criticalThermal, .criticalThermal), (\.criticalMemory, .criticalMemory)
        ]
        for (key, reason) in safety {
            var conditions = SmartPauseConditions(); conditions[keyPath: key] = true
            XCTAssertEqual(preferences.reasons(for: conditions), [reason])
        }
        var configurable = SmartPauseConditions()
        configurable.fullScreenApp = true; configurable.batteryLow = true
        configurable.lowPowerMode = true; configurable.onBatteryPower = true
        XCTAssertFalse(preferences.shouldPause(configurable))
    }

    func testFullscreenAndOcclusionAreIndependentAndExceptionsNeverBypassSleep() {
        var preferences = SmartPausePreferences()
        let fullscreen = DisplayPauseConditions(fullScreenApp: true)
        let occluded = DisplayPauseConditions(occluded: true)
        XCTAssertEqual(preferences.reasons(for: fullscreen), [.fullScreenApp])
        XCTAssertTrue(preferences.reasons(for: occluded).isEmpty)
        preferences.occlusion = true; preferences.fullScreen = false
        XCTAssertEqual(preferences.reasons(for: occluded), [.occluded])
        XCTAssertTrue(preferences.reasons(for: fullscreen).isEmpty)
        preferences.excludedApps = ["test.app"]
        XCTAssertEqual(preferences.reasons(for: .init(fullScreenApp: true, occluded: true, asleep: true,
                                                     frontmostBundleID: "test.app")), [.displayAsleep])
        preferences.smartPause = false
        XCTAssertEqual(preferences.reasons(for: .init(asleep: true)), [.displayAsleep])
    }

    func testVisibilitySeparatesOtherSpaceFromSameSpaceCoverageAndIgnoresStoppedWindows() {
        XCTAssertEqual(LiveSmartPauseProbe.visibility(isVisible: false, onActiveSpace: false, occluded: true), .init())
        XCTAssertEqual(LiveSmartPauseProbe.visibility(isVisible: true, onActiveSpace: false, occluded: true), .init(fullScreenApp: true))
        XCTAssertEqual(LiveSmartPauseProbe.visibility(isVisible: true, onActiveSpace: true, occluded: true), .init(occluded: true))
        XCTAssertEqual(LiveSmartPauseProbe.visibility(isVisible: true, onActiveSpace: true, occluded: false), .init())
    }

    func testLocalPauseAffectsOnlyTargetAndResumesWithoutPreparingAnotherRenderer() async {
        let h = Harness(); await h.start(); defer { h.stop() }
        h.probe.displays[h.b] = .init(fullScreenApp: true)
        h.monitor.refreshQueryableConditions()
        XCTAssertEqual(h.runtime.state(of: h.a)?.playbackState, .playing)
        XCTAssertEqual(h.runtime.state(of: h.b)?.playbackState, .smartPaused)
        XCTAssertEqual(h.monitor.displayReasons[h.b], [.fullScreenApp])
        h.probe.displays[h.b] = .init()
        h.monitor.refreshQueryableConditions()
        XCTAssertEqual(h.runtime.state(of: h.b)?.playbackState, .playing)
        XCTAssertEqual(h.renderers.count, 2)
        XCTAssertEqual(h.renderers[1].calls, ["play", "pause", "resume"])
    }

    func testSafetyEndingDoesNotBrieflyResumeAStillCoveredDisplay() async {
        let h = Harness(); await h.start(); defer { h.stop() }
        h.probe.displays[h.b] = .init(fullScreenApp: true)
        h.probe.isScreenLocked = true; h.monitor.refreshQueryableConditions()
        XCTAssertEqual(h.runtime.state(of: h.a)?.playbackState, .smartPaused)
        XCTAssertEqual(h.runtime.state(of: h.b)?.playbackState, .smartPaused)
        h.probe.isScreenLocked = false; h.monitor.refreshQueryableConditions()
        XCTAssertEqual(h.runtime.state(of: h.a)?.playbackState, .playing)
        XCTAssertEqual(h.runtime.state(of: h.b)?.playbackState, .smartPaused)
        XCTAssertEqual(h.renderers[1].calls, ["play", "pause"])
    }

    func testAutomaticRecoveryPreservesManualPauseAndStop() async {
        let h = Harness(); await h.start(); defer { h.stop() }
        h.probe.isThermalCritical = true; h.monitor.refreshQueryableConditions()
        h.runtime.pause(.display(h.a)); h.runtime.stop(.display(h.b))
        h.probe.isThermalCritical = false; h.monitor.refreshQueryableConditions()
        XCTAssertEqual(h.runtime.state(of: h.a)?.playbackState, .manualPaused)
        XCTAssertEqual(h.runtime.state(of: h.b)?.playbackState, .stopped)
        XCTAssertEqual(h.renderers.count, 2)
        XCTAssertFalse(h.renderers[0].calls.contains("resume"))
    }

    func testCriticalMemoryAndThermalNotificationsStartAndEndSafetyImmediately() async {
        let h = Harness(); await h.start(); defer { h.stop() }
        h.monitor.preferences.smartPause = false
        h.probe.isMemoryCritical = true; h.probe.pressureHandler?()
        XCTAssertEqual(h.monitor.globalReasons, [.criticalMemory])
        XCTAssertEqual(h.runtime.state(of: h.a)?.playbackState, .smartPaused)
        h.probe.isThermalCritical = true
        h.application.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        h.probe.isMemoryCritical = false; h.probe.pressureHandler?()
        XCTAssertEqual(h.monitor.globalReasons, [.criticalThermal])
        XCTAssertEqual(h.runtime.state(of: h.b)?.playbackState, .smartPaused)
        h.probe.isThermalCritical = false
        h.application.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        XCTAssertEqual(h.runtime.state(of: h.b)?.playbackState, .playing)
    }

    func testLiveSettingChangesAndPerAppExceptionsApplyToCurrentConditions() async {
        let h = Harness(); await h.start(); defer { h.stop() }
        h.probe.displays[h.a] = .init(occluded: true, frontmostBundleID: "test.app")
        h.monitor.refreshQueryableConditions()
        XCTAssertEqual(h.runtime.state(of: h.a)?.playbackState, .playing)
        h.monitor.preferences.occlusion = true
        XCTAssertEqual(h.runtime.state(of: h.a)?.playbackState, .smartPaused)
        h.monitor.preferences.excludedApps = ["test.app"]
        XCTAssertEqual(h.runtime.state(of: h.a)?.playbackState, .playing)
        h.probe.isMemoryCritical = true; h.monitor.refreshQueryableConditions()
        XCTAssertEqual(h.runtime.state(of: h.a)?.playbackState, .smartPaused)
    }

    func testNewAndReconnectedSessionsInheritSafetyWithoutOldCoverageFlags() async {
        let h = Harness(); await h.start(); defer { h.stop() }
        h.probe.displays[h.b] = .init(fullScreenApp: true); h.monitor.refreshQueryableConditions()
        h.runtime.removeDisplay(h.b); h.monitor.updateDisplays([h.a])
        h.probe.isThermalCritical = true; h.monitor.refreshQueryableConditions()
        h.runtime.addDisplay(h.b, host: AppControlTestHost())
        h.probe.displays[h.b] = .init(); h.monitor.updateDisplays([h.a, h.b])
        h.runtime.apply(h.wallpaper, to: h.b); await h.settle()
        XCTAssertEqual(h.runtime.state(of: h.b)?.playbackState, .smartPaused)
        h.probe.isThermalCritical = false; h.monitor.refreshQueryableConditions()
        XCTAssertEqual(h.runtime.state(of: h.b)?.playbackState, .playing)
        XCTAssertEqual(h.monitor.displayReasons[h.b], [])
    }

    func testOneDisplaySleepDoesNotPauseAnotherAndCannotBeExcluded() async {
        let h = Harness(); await h.start(); defer { h.stop() }
        h.monitor.preferences.smartPause = false
        h.probe.displays[h.b] = .init(asleep: true)
        h.monitor.refreshQueryableConditions()
        XCTAssertEqual(h.runtime.state(of: h.a)?.playbackState, .playing)
        XCTAssertEqual(h.runtime.state(of: h.b)?.playbackState, .smartPaused)
    }

    func testAllPolicyChangesDoNotPublishUserCommandsOrChangeWallpaperAssignment() async {
        let h = Harness(); await h.start(); defer { h.stop() }
        h.probe.isMemoryCritical = true; h.monitor.refreshQueryableConditions()
        h.probe.isMemoryCritical = false; h.monitor.refreshQueryableConditions()
        XCTAssertNil(h.runtime.globalUserCommand)
        XCTAssertEqual(h.runtime.activeWallpaper(on: h.a)?.id, h.wallpaper.id)
        XCTAssertEqual(h.runtime.activeWallpaper(on: h.b)?.id, h.wallpaper.id)
    }

    func testPerDisplayDesktopNotificationsAndObserverCleanup() async {
        let h = Harness(); await h.start(); defer { h.stop() }
        let window = NSWindow(contentRect: .init(x: -4000, y: -4000, width: 100, height: 100), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        h.probe.displays[h.b] = .init(fullScreenApp: true)
        window.identifier = .init("other")
        h.application.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        XCTAssertEqual(h.runtime.state(of: h.b)?.playbackState, .playing)
        window.identifier = .init("test.desktop.B")
        h.application.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        XCTAssertEqual(h.runtime.state(of: h.b)?.playbackState, .smartPaused)
        h.monitor.stop()
        XCTAssertNil(h.probe.pressureHandler); XCTAssertNil(h.probe.powerHandler)
        h.probe.displays[h.b] = .init()
        h.application.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        XCTAssertEqual(h.runtime.state(of: h.b)?.playbackState, .smartPaused)
    }

    @MainActor
    private final class Harness {
        let a = DisplayID("A"), b = DisplayID("B")
        let probe = PerformanceTestProbe()
        let application = NotificationCenter()
        var renderers: [RecordingRenderer] = []
        let wallpaper = Wallpaper(name: "Test", type: .video, source: .local, resourceURL: URL(fileURLWithPath: "/test/video.mp4"))
        lazy var runtime = WallpaperRuntimeManager { [unowned self] in
            let renderer = RecordingRenderer($0); renderers.append(renderer); return renderer
        }
        lazy var monitor = SmartPauseMonitor(probe: probe, workspaceNotifications: NotificationCenter(),
            distributedNotifications: NotificationCenter(), applicationNotifications: application,
            desktopWindowIdentifier: .init("test.desktop"), usesPerDisplayPolicy: true,
            onDisplayChange: { [unowned self] in runtime.setSmartPausePolicy(global: $0, displays: $1) }, onChange: { _ in })
        func start() async {
            runtime.addDisplay(a, host: AppControlTestHost()); runtime.addDisplay(b, host: AppControlTestHost())
            monitor.updateDisplays([a, b]); monitor.start()
            runtime.apply(wallpaper, to: a); runtime.apply(wallpaper, to: b); await settle()
        }
        func settle() async { for _ in 0..<50 { await Task.yield() } }
        func stop() { monitor.stop(); runtime.shutdown() }
    }

    @MainActor
    private final class RecordingRenderer: WallpaperRenderer {
        let wallpaper: Wallpaper
        let displayView = NSView()
        var onFailure: (@MainActor (Error) -> Void)?
        var calls: [String] = []
        init(_ wallpaper: Wallpaper) { self.wallpaper = wallpaper }
        func prepare() async throws {}
        func play() { calls.append("play") }
        func pause() { calls.append("pause") }
        func resume() { calls.append("resume") }
        func setMuted(_ muted: Bool) {}
        func dispose() { calls.append("dispose") }
    }
}

@MainActor
final class PerformanceTestProbe: SmartPauseSystemProbe {
    var isScreenLocked = false, isDisplayAsleep = false, isFullScreenAppActive = false
    var isBatteryLow = false, isLowPowerModeEnabled = false, isOnBatteryPower = false
    var isThermalCritical = false, isMemoryCritical = false
    var displays: [DisplayID: DisplayPauseConditions] = [:]
    var pressureHandler: (@MainActor () -> Void)?, powerHandler: (@MainActor () -> Void)?
    func displayConditions(for ids: [DisplayID]) -> [DisplayID: DisplayPauseConditions] { displays.filter { ids.contains($0.key) } }
    func startObservingPressure(_ onChange: @escaping @MainActor () -> Void) { pressureHandler = onChange }
    func stopObservingPressure() { pressureHandler = nil }
    func startObservingPowerSource(_ onChange: @escaping @MainActor () -> Void) { powerHandler = onChange }
    func stopObservingPowerSource() { powerHandler = nil }
}
