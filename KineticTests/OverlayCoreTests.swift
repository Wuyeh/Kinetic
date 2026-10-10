import AppKit
import XCTest
@testable import Kinetic

@MainActor
private final class OverlayTestView: NSView {
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemBlue.setFill()
        NSBezierPath(ovalIn: .init(x: bounds.midX - 10, y: bounds.midY - 10, width: 20, height: 20)).fill()
    }
}

@MainActor
private final class TestOverlay: DesktopOverlay {
    let displayView: NSView = OverlayTestView(frame: .init(x: 0, y: 0, width: 100, height: 100))
    var onFailure: (@MainActor (Error) -> Void)?
    var controlled = false, rejectUpdates = false, disposed = false
    var failOnUpdate = false, failOnPlay = false
    var completion: ((Result<Void, Error>) -> Void)?
    var contexts: [OverlayContext] = [], values: [OverlayConfiguration] = []
    var preparedContexts: [OverlayContext] = []
    var prepares = 0, plays = 0, pauses = 0, disposals = 0
    func prepare(configuration: OverlayConfiguration, context: OverlayContext) async throws {
        prepares += 1
        preparedContexts.append(context)
        if controlled { try await withCheckedThrowingContinuation { continuation in completion = { continuation.resume(with: $0) } } }
    }
    func update(configuration: OverlayConfiguration, context: OverlayContext) throws {
        if rejectUpdates { throw OverlayError.invalidConfiguration }
        if failOnUpdate { onFailure?(OverlayError.unavailable) }
        contexts.append(context); values.append(configuration)
    }
    func play() { if !disposed { plays += 1 }; if failOnPlay { onFailure?(OverlayError.unavailable) } }
    func pause() { if !disposed { pauses += 1 } }
    func dispose() { if !disposed { disposed = true; disposals += 1 }; onFailure = nil }
    func finish(_ result: Result<Void, Error> = .success(())) { let callback = completion; completion = nil; callback?(result) }
}

@MainActor
private final class TestOverlaySurface: OverlaySurface {
    var views: [UUID: NSView] = [:], order: [UUID] = []
    var display: DesktopDisplay?, closed = false, reject = false
    func present(_ view: NSView, for id: UUID, display: DesktopDisplay) throws {
        if reject { throw OverlayError.invalidWindowLevel }
        views[id] = view; self.display = display; closed = false
    }
    func remove(_ id: UUID) { views[id] = nil }
    func realign(_ display: DesktopDisplay) { self.display = display }
    func setOrder(_ ids: [UUID]) { order = ids }
    func close() { views.removeAll(); closed = true }
}

@MainActor
private final class SurfaceTracker {
    var surfaces: [DisplayID: TestOverlaySurface] = [:]
    var created = 0
    var reject = false
    func make(_ id: DisplayID) -> TestOverlaySurface {
        let surface = TestOverlaySurface(); surface.reject = reject; surfaces[id] = surface; created += 1; return surface
    }
}

@MainActor
private final class OverlayProbe: SmartPauseSystemProbe {
    var isScreenLocked = false, isDisplayAsleep = false, isFullScreenAppActive = false
    var isBatteryLow = false, isLowPowerModeEnabled = false, isOnBatteryPower = false
    func startObservingPowerSource(_ onChange: @escaping @MainActor () -> Void) {}
    func stopObservingPowerSource() {}
}

@MainActor
final class OverlayCoreTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() { roots.forEach { try? FileManager.default.removeItem(at: $0) }; super.tearDown() }
    private func store() throws -> OverlayStore {
        let root = TestWorkspaceDirectory.make(".build/Module33/Fixtures")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); roots.append(root)
        return OverlayStore(storage: .init(rootURL: root))
    }
    private func descriptor(_ id: String = "display-A", x: CGFloat = 0, scale: CGFloat = 2) -> DisplayDescriptor {
        .init(id: .init(id), name: id, desktop: .init(id: 1, frame: .init(x: x, y: 0, width: 640, height: 400), backingScaleFactor: scale), isPersistent: true)
    }
    private func configuration(_ kind: OverlayKind = .particles, display: String = "display-A") -> OverlayConfiguration {
        var value = OverlayConfiguration(kind: kind, displayID: .init(display)); value.isEnabled = true; return value
    }
    private func manager(_ store: OverlayStore, discover: @escaping @MainActor () -> [DisplayDescriptor],
                         timeout: UInt64 = 12_000_000_000) -> (OverlayManager, DisplayRegistry, SurfaceTracker) {
        let registry = DisplayRegistry(discover: discover, applicationNotifications: NotificationCenter(), workspaceNotifications: NotificationCenter())
        let tracker = SurfaceTracker()
        let manager = OverlayManager(store: store, registry: registry, preparationTimeoutNanoseconds: timeout,
            readReduceMotion: { false }, makeSurface: { tracker.make($0) })
        manager.start(); registry.start(); return (manager, registry, tracker)
    }
    private func wait(_ condition: () -> Bool, timeout: TimeInterval = 3) async throws {
        let end = ProcessInfo.processInfo.systemUptime + timeout
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < end else { throw OverlayError.preparationTimedOut }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testDefaultCreatesNoWindowEffectOrSettingsFile() throws {
        let store = try store(), display = descriptor()
        let (manager, registry, surfaces) = manager(store, discover: { [display] })
        defer { manager.shutdown(); registry.stop() }
        XCTAssertTrue(manager.states.isEmpty); XCTAssertEqual(surfaces.created, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        let unavailable = configuration(); try manager.configure(unavailable)
        XCTAssertEqual(manager.states.first?.lifecycle, .unavailable); XCTAssertEqual(surfaces.created, 0)
        try store.setEnabled(false, for: unavailable.id)
        XCTAssertEqual(manager.states.first?.lifecycle, .disabled)
    }
    func testConfigurationRoundTripPreservesExplicitTargetManualPauseAndParameters() throws {
        let store = try store(); var value = configuration(.clock, display: "display-B")
        value.isManuallyPaused = true; value.maximumFramesPerSecond = 24
        value.parameters = ["density": .number(0.5), "name": .text("夜晚"), "enabled": .boolean(true)]
        try store.upsert(value)
        let restored = OverlayStore(storage: .init(rootURL: store.fileURL.deletingLastPathComponent()))
        XCTAssertEqual(restored.configurations, [value]); XCTAssertNil(restored.loadError)
        try restored.setEnabled(false, for: value.id); try restored.remove(value.id)
        XCTAssertTrue(OverlayStore(storage: .init(rootURL: store.fileURL.deletingLastPathComponent())).configurations.isEmpty)
    }
    func testInvalidValuesAndDuplicateLimitDoNotOverwriteValidStore() throws {
        let store = try store(), valid = configuration(); try store.upsert(valid)
        let before = try Data(contentsOf: store.fileURL)
        var invalid = valid; invalid.maximumFramesPerSecond = 0
        XCTAssertThrowsError(try store.upsert(invalid))
        invalid = valid; invalid.parameters = ["number": .number(.infinity)]
        XCTAssertThrowsError(try store.upsert(invalid))
        invalid = valid; invalid.parameters = ["text": .text(String(repeating: "a", count: 2_049))]
        XCTAssertThrowsError(try store.upsert(invalid))
        invalid = valid; invalid.displayID = .main; XCTAssertThrowsError(try store.upsert(invalid))
        invalid.displayID = .init("session-display-42"); XCTAssertThrowsError(try store.upsert(invalid))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
        for _ in 1..<OverlayStore.maximumPerDisplay { try store.upsert(configuration()) }
        let full = try Data(contentsOf: store.fileURL)
        XCTAssertThrowsError(try store.upsert(configuration())); XCTAssertEqual(try Data(contentsOf: store.fileURL), full)
    }
    func testCorruptFutureOversizedAndSymlinkSettingsArePreserved() throws {
        for bytes in [Data("bad".utf8), Data(#"{"version":2,"configurations":[]}"#.utf8), Data(repeating: 0, count: OverlayStore.maximumBytes + 1)] {
            let initial = try store(); try bytes.write(to: initial.fileURL)
            let loaded = OverlayStore(storage: .init(rootURL: initial.fileURL.deletingLastPathComponent()))
            XCTAssertNotNil(loaded.loadError); XCTAssertThrowsError(try loaded.upsert(configuration()))
            XCTAssertEqual(try Data(contentsOf: initial.fileURL), bytes)
        }
        let initial = try store(), outside = try store()
        try outside.upsert(configuration())
        let bytes = try Data(contentsOf: outside.fileURL)
        try FileManager.default.createSymbolicLink(at: initial.fileURL, withDestinationURL: outside.fileURL)
        let linked = OverlayStore(storage: .init(rootURL: initial.fileURL.deletingLastPathComponent()))
        XCTAssertNotNil(linked.loadError); XCTAssertThrowsError(try linked.upsert(configuration()))
        XCTAssertEqual(try Data(contentsOf: outside.fileURL), bytes)
    }
    func testAtomicWriteFailureDoesNotPublishUnsavedConfiguration() throws {
        let store = try store(); var notifications = 0
        let observer = store.$configurations.dropFirst().sink { _ in notifications += 1 }
        defer { observer.cancel() }
        try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.upsert(configuration()))
        XCTAssertEqual(notifications, 0); XCTAssertTrue(store.configurations.isEmpty)
    }
    func testUnknownDisconnectedAndTransientDisplayNeverFallBackToMain() throws {
        let store = try store(), display = descriptor()
        let (manager, registry, surfaces) = manager(store, discover: { [display] })
        defer { manager.shutdown(); registry.stop() }
        XCTAssertThrowsError(try manager.configure(configuration(display: "display-missing")))
        XCTAssertTrue(store.configurations.isEmpty); XCTAssertEqual(surfaces.created, 0)
        try store.upsert(configuration(display: "display-missing"))
        XCTAssertEqual(manager.states.first?.lifecycle, .waitingForDisplay); XCTAssertEqual(surfaces.created, 0)
    }
    func testOnlyExplicitDisplayOwnsSurfaceAndTwoEffectsShareIt() async throws {
        let store = try store(), a = descriptor(), b = descriptor("display-B", x: 640)
        let (manager, registry, surfaces) = manager(store, discover: { [a, b] })
        defer { manager.shutdown(); registry.stop() }
        var created: [TestOverlay] = []
        for kind in [OverlayKind.particles, .clock] { manager.register(kind) { _ in let effect = TestOverlay(); created.append(effect); return effect } }
        let first = configuration(), second = configuration(.clock)
        try manager.configure(first); try manager.configure(second)
        try await wait { manager.states.allSatisfy { $0.lifecycle == .running } }
        XCTAssertEqual(surfaces.created, 1); XCTAssertNil(surfaces.surfaces[b.id])
        XCTAssertEqual(surfaces.surfaces[a.id]?.order, [first.id, second.id]); XCTAssertEqual(created.count, 2)
        try store.setEnabled(false, for: first.id)
        XCTAssertEqual(surfaces.surfaces[a.id]?.views.count, 1); XCTAssertFalse(surfaces.surfaces[a.id]?.closed ?? true)
        try store.setEnabled(false, for: second.id)
        XCTAssertTrue(surfaces.surfaces[a.id]?.closed ?? false); XCTAssertTrue(created.allSatisfy(\.disposed))
    }
    func testPolicyAndManualPauseUpdateSameEffectAndNeverResetIt() async throws {
        let store = try store(), display = descriptor()
        let (manager, registry, _) = manager(store, discover: { [display] })
        defer { manager.shutdown(); registry.stop() }
        let effect = TestOverlay(); manager.register(.particles) { _ in effect }
        let value = configuration(); try manager.configure(value)
        try await wait { manager.states.first?.lifecycle == .running }
        manager.setPolicy(.init(isSuspended: true, reduceMotion: true, lowPowerMode: true))
        XCTAssertEqual(manager.states.first?.lifecycle, .paused)
        XCTAssertEqual(effect.contexts.last?.maximumFramesPerSecond, 15); XCTAssertEqual(effect.contexts.last?.allowsAnimation, false)
        try store.setManuallyPaused(true, for: value.id); manager.setPolicy(.init())
        XCTAssertEqual(manager.states.first?.lifecycle, .paused)
        try store.setManuallyPaused(false, for: value.id)
        XCTAssertEqual(manager.states.first?.lifecycle, .running); XCTAssertEqual(effect.prepares, 1)
        XCTAssertEqual(effect.contexts.last?.backingScaleFactor, 2)
    }
    func testSingleDisplaySuspensionDoesNotPauseTheOther() async throws {
        let store = try store(), a = descriptor(), b = descriptor("display-B", x: 640)
        let (manager, registry, _) = manager(store, discover: { [a, b] })
        defer { manager.shutdown(); registry.stop() }
        var effects: [DisplayID: TestOverlay] = [:]
        manager.register(.particles) { config in let e = TestOverlay(); effects[config.displayID] = e; return e }
        try manager.configure(configuration()); try manager.configure(configuration(display: b.id.rawValue))
        try await wait { manager.states.allSatisfy { $0.lifecycle == .running } }
        manager.setPolicy(.init(), suspendedDisplays: [a.id])
        XCTAssertEqual(manager.states.first { $0.displayID == a.id }?.lifecycle, .paused)
        XCTAssertEqual(manager.states.first { $0.displayID == b.id }?.lifecycle, .running)
        XCTAssertEqual(effects[b.id]?.pauses, 0)
    }
    func testGeometryAndDraftValuesUpdateInPlaceFailureKeepsOldView() async throws {
        let store = try store(); var display = descriptor()
        let (manager, registry, surfaces) = manager(store, discover: { [display] })
        defer { manager.shutdown(); registry.stop() }
        let effect = TestOverlay(); manager.register(.particles) { _ in effect }
        var value = configuration(); try manager.configure(value)
        try await wait { manager.states.first?.lifecycle == .running }
        let view = surfaces.surfaces[display.id]?.views[value.id]
        value.parameters = ["speed": .number(2)]; try manager.configure(value)
        display = descriptor(x: -640, scale: 1); registry.refresh()
        XCTAssertEqual(effect.prepares, 1); XCTAssertTrue(surfaces.surfaces[display.id]?.views[value.id] === view)
        XCTAssertEqual(effect.contexts.last?.frame.origin.x, -640); XCTAssertEqual(effect.contexts.last?.backingScaleFactor, 1)
        effect.rejectUpdates = true; value.parameters = ["speed": .number(3)]; try manager.configure(value)
        XCTAssertEqual(manager.states.first?.lifecycle, .failed); XCTAssertFalse(effect.disposed)
        XCTAssertEqual(effect.values.last?.parameters["speed"], .number(2)); XCTAssertTrue(surfaces.surfaces[display.id]?.views[value.id] === view)
        effect.rejectUpdates = false; manager.retry(value.id)
        XCTAssertEqual(manager.states.first?.lifecycle, .running); XCTAssertEqual(effect.values.last?.parameters["speed"], .number(3))
    }
    func testOneRuntimeFailureReleasesOnlyThatEffect() async throws {
        let store = try store(), display = descriptor()
        let (manager, registry, surfaces) = manager(store, discover: { [display] })
        defer { manager.shutdown(); registry.stop() }
        let bad = TestOverlay(), good = TestOverlay()
        manager.register(.particles) { _ in bad }; manager.register(.clock) { _ in good }
        let a = configuration(), b = configuration(.clock)
        try manager.configure(a); try manager.configure(b)
        try await wait { manager.states.allSatisfy { $0.lifecycle == .running } }
        bad.onFailure?(OverlayError.unavailable)
        XCTAssertEqual(manager.states.first { $0.id == a.id }?.lifecycle, .failed)
        XCTAssertEqual(manager.states.first { $0.id == b.id }?.lifecycle, .running)
        XCTAssertTrue(bad.disposed); XCTAssertFalse(good.disposed)
        XCTAssertEqual(surfaces.surfaces[display.id]?.views.count, 1); XCTAssertFalse(surfaces.surfaces[display.id]?.closed ?? true)
    }
    func testDisconnectDisposeAndReconnectRestoresOnlyStableTarget() async throws {
        let store = try store(), a = descriptor(), b = descriptor("display-B", x: 640)
        var connected = [a, b]
        let (manager, registry, surfaces) = manager(store, discover: { connected })
        defer { manager.shutdown(); registry.stop() }
        var effects: [TestOverlay] = []
        manager.register(.particles) { _ in let e = TestOverlay(); effects.append(e); return e }
        let value = configuration(); try manager.configure(value); try await wait { manager.states.first?.lifecycle == .running }
        connected = [b]; registry.refresh()
        XCTAssertEqual(manager.states.first?.lifecycle, .waitingForDisplay); XCTAssertTrue(effects[0].disposed)
        XCTAssertNil(surfaces.surfaces[b.id]); XCTAssertEqual(store.configurations, [value])
        connected = [a, b]; registry.refresh(); try await wait { manager.states.first?.lifecycle == .running }
        XCTAssertEqual(effects.count, 2); XCTAssertNil(surfaces.surfaces[b.id])
    }
    func testDisabledAndLatePrepareCannotResurrectOverlay() async throws {
        let store = try store(), display = descriptor()
        let (manager, registry, surfaces) = manager(store, discover: { [display] })
        defer { manager.shutdown(); registry.stop() }
        let effect = TestOverlay(); effect.controlled = true; manager.register(.particles) { _ in effect }
        let value = configuration(); try manager.configure(value); try await wait { effect.completion != nil }
        let oldCallback = effect.onFailure; try store.setEnabled(false, for: value.id)
        effect.finish(); oldCallback?(OverlayError.unavailable)
        try await Task.sleep(nanoseconds: 15_000_000)
        XCTAssertEqual(manager.states.first?.lifecycle, .disabled); XCTAssertEqual(surfaces.created, 0); XCTAssertEqual(effect.disposals, 1)
    }
    func testTimedOutNoncooperativePreparationIsIsolatedAndLateResultDiscarded() async throws {
        let store = try store(), display = descriptor()
        let (manager, registry, surfaces) = manager(store, discover: { [display] }, timeout: 20_000_000)
        defer { manager.shutdown(); registry.stop() }
        let effect = TestOverlay(); effect.controlled = true; manager.register(.particles) { _ in effect }
        try manager.configure(configuration()); try await wait { effect.completion != nil }
        try await wait { manager.states.first?.lifecycle == .failed }; effect.finish()
        try await Task.sleep(nanoseconds: 15_000_000)
        XCTAssertEqual(surfaces.created, 0); XCTAssertEqual(effect.disposals, 1)
        XCTAssertEqual(manager.states.first?.failure, OverlayError.preparationTimedOut.localizedDescription)
    }
    func testSurfaceFailureAndFactoryFailureAreContained() async throws {
        let store = try store(), display = descriptor()
        let (manager, registry, surfaces) = manager(store, discover: { [display] })
        defer { manager.shutdown(); registry.stop() }
        manager.register(.particles) { _ in throw OverlayError.unavailable }
        let first = configuration(); try manager.configure(first)
        XCTAssertEqual(manager.states.first?.lifecycle, .failed); XCTAssertEqual(surfaces.created, 0)
        let effect = TestOverlay(); surfaces.reject = true
        manager.register(.clock) { _ in effect }; let second = configuration(.clock); try manager.configure(second)
        try await wait { manager.states.first { $0.id == second.id }?.lifecycle == .failed }
        XCTAssertTrue(effect.disposed); XCTAssertTrue(surfaces.surfaces[display.id]?.closed ?? false)
    }
    func testShutdownCancelsPendingAndDoesNotStopBorrowedRegistry() async throws {
        let store = try store(), display = descriptor()
        let (manager, registry, surfaces) = manager(store, discover: { [display] })
        defer { manager.shutdown(); registry.stop() }
        let effect = TestOverlay(); effect.controlled = true; manager.register(.particles) { _ in effect }
        try manager.configure(configuration()); try await wait { effect.completion != nil }
        manager.shutdown(); effect.finish(); try await Task.sleep(nanoseconds: 15_000_000)
        XCTAssertTrue(manager.states.isEmpty); XCTAssertEqual(surfaces.created, 0); XCTAssertEqual(effect.disposals, 1)
        registry.refresh(); XCTAssertEqual(registry.displays.map(\.id), [display.id])
    }
    func testFortyEnableDisableCyclesReleaseEveryInstance() async throws {
        let store = try store(), display = descriptor()
        let (manager, registry, _) = manager(store, discover: { [display] })
        defer { manager.shutdown(); registry.stop() }
        var effects: [TestOverlay] = []; manager.register(.particles) { _ in let e = TestOverlay(); effects.append(e); return e }
        var value = configuration()
        for _ in 0..<40 {
            value.isEnabled = true; try manager.configure(value); try await wait { manager.states.first?.lifecycle == .running }
            value.isEnabled = false; try manager.configure(value)
        }
        XCTAssertEqual(effects.count, 40); XCTAssertTrue(effects.allSatisfy { $0.disposals == 1 })
    }
    func testNativeWindowIsTransparentBelowIconsClickThroughAndDoesNotAlterWallpaperWindow() throws {
        let display = DesktopDisplay(id: 1, frame: .init(x: -5000, y: -5000, width: 640, height: 400), backingScaleFactor: 2)
        let wallpaper = DesktopWallpaperWindow(frame: display.frame, identifier: .init("Overlay.Test.Wallpaper"))
        let wallpaperView = NSView(frame: .init(origin: .zero, size: display.frame.size)); wallpaper.contentView = wallpaperView
        let owner = OverlayWindowOwner(displayID: .init("display-A"))
        defer { owner.close(); wallpaper.close() }
        let id = UUID(); try owner.present(OverlayTestView(frame: .zero), for: id, display: display)
        let window = try XCTUnwrap(owner.window), stage = try XCTUnwrap(window.contentView)
        // Same level as the wallpaper and Finder's icons; ordered between them (DesktopWindowRuntimeTests).
        XCTAssertEqual(window.level, wallpaper.level)
        XCTAssertLessThan(window.level.rawValue, NSWindow.Level.normal.rawValue)
        XCTAssertTrue(window.ignoresMouseEvents); XCTAssertFalse(window.canBecomeKey); XCTAssertFalse(window.canBecomeMain)
        XCTAssertFalse(window.isOpaque); XCTAssertFalse(stage.isOpaque); XCTAssertEqual(window.backgroundColor?.alphaComponent, 0)
        XCTAssertNil(stage.hitTest(.init(x: 20, y: 20))); XCTAssertTrue(window.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenNone)); XCTAssertTrue(wallpaper.contentView === wallpaperView)
        let bitmap = try XCTUnwrap(stage.bitmapImageRepForCachingDisplay(in: stage.bounds)); stage.cacheDisplay(in: stage.bounds, to: bitmap)
        XCTAssertEqual(bitmap.colorAt(x: 0, y: 0)?.alphaComponent ?? 1, 0, accuracy: 0.01)
        let screenshots = TestWorkspaceDirectory.make(".build/Module33/Snapshots").deletingLastPathComponent()
        try FileManager.default.createDirectory(at: screenshots, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: screenshots.appendingPathComponent("transparent-overlay.png"))
        owner.remove(id); XCTAssertNil(owner.window); XCTAssertTrue(wallpaper.contentView === wallpaperView)
    }
    func testLiveMonitorLockUnlockHonorsManualOverlayPause() async throws {
        let store = try store(), display = descriptor(), probe = OverlayProbe()
        let workspace = NotificationCenter(), distributed = NotificationCenter(), application = NotificationCenter()
        let monitor = SmartPauseMonitor(probe: probe, workspaceNotifications: workspace, distributedNotifications: distributed,
            applicationNotifications: application, desktopWindowIdentifier: .init("test.none"), onChange: { _ in })
        let registry = DisplayRegistry(discover: { [display] }, applicationNotifications: application, workspaceNotifications: workspace)
        let manager = OverlayManager(store: store, registry: registry, readReduceMotion: { false }, makeSurface: { _ in TestOverlaySurface() })
        defer { manager.shutdown(); monitor.stop(); registry.stop() }
        monitor.start(); manager.start(monitor: monitor); registry.start()
        let effect = TestOverlay(); manager.register(.particles) { _ in effect }
        let value = configuration(); try manager.configure(value); try await wait { manager.states.first?.lifecycle == .running }
        probe.isScreenLocked = true; distributed.post(name: SmartPauseMonitor.screenLockedNotification, object: nil)
        try await wait { manager.states.first?.lifecycle == .paused }
        try store.setManuallyPaused(true, for: value.id)
        probe.isScreenLocked = false; distributed.post(name: SmartPauseMonitor.screenUnlockedNotification, object: nil)
        try await Task.sleep(nanoseconds: 20_000_000); XCTAssertEqual(manager.states.first?.lifecycle, .paused)
        try store.setManuallyPaused(false, for: value.id)
        XCTAssertEqual(manager.states.first?.lifecycle, .running); XCTAssertEqual(effect.prepares, 1)
    }
    func testRejectedEditStillHonorsSystemSafetyPause() async throws {
        let store = try store(), display = descriptor()
        let (manager, registry, _) = manager(store, discover: { [display] })
        defer { manager.shutdown(); registry.stop() }
        let effect = TestOverlay(); manager.register(.particles) { _ in effect }
        var value = configuration(); try manager.configure(value); try await wait { manager.states.first?.lifecycle == .running }
        effect.rejectUpdates = true; value.parameters = ["speed": .number(3)]; try manager.configure(value)
        manager.setPolicy(.init(isSuspended: true))
        XCTAssertGreaterThan(effect.pauses, 0, "A failed edit cannot bypass lock / sleep / critical-pressure suspension")
        XCTAssertFalse(effect.disposed); XCTAssertEqual(manager.states.first?.lifecycle, .failed)
    }
    func testSynchronousFailureDuringInitialUpdateOrPlayCannotPublishRunningState() async throws {
        for phase in ["update", "play"] {
            let store = try store(), display = descriptor()
            let (manager, registry, surfaces) = manager(store, discover: { [display] })
            defer { manager.shutdown(); registry.stop() }
            let effect = TestOverlay(); effect.failOnUpdate = phase == "update"; effect.failOnPlay = phase == "play"
            manager.register(.particles) { _ in effect }; try manager.configure(configuration())
            try await Task.sleep(nanoseconds: 20_000_000)
            XCTAssertEqual(manager.states.first?.lifecycle, .failed); XCTAssertEqual(effect.disposals, 1)
            XCTAssertTrue(surfaces.surfaces[display.id]?.views.isEmpty ?? true)
            if phase == "update" { XCTAssertEqual(surfaces.created, 0) }
        }
    }
    func testSynchronousFailureDuringActiveUpdateCannotReviveDisposedContent() async throws {
        let store = try store(), display = descriptor()
        let (manager, registry, surfaces) = manager(store, discover: { [display] })
        defer { manager.shutdown(); registry.stop() }
        let effect = TestOverlay(); manager.register(.particles) { _ in effect }
        var value = configuration(); try manager.configure(value); try await wait { manager.states.first?.lifecycle == .running }
        effect.failOnUpdate = true; value.parameters = ["speed": .number(2)]; try manager.configure(value)
        XCTAssertEqual(manager.states.first?.lifecycle, .failed); XCTAssertEqual(effect.disposals, 1)
        XCTAssertTrue(surfaces.surfaces[display.id]?.closed ?? false)
    }
    func testDroppingManagerWithoutShutdownReleasesSurfaceAndEffect() async throws {
        let store = try store(), display = descriptor(), surfaces = SurfaceTracker()
        let registry = DisplayRegistry(discover: { [display] }, applicationNotifications: NotificationCenter(), workspaceNotifications: NotificationCenter())
        defer { registry.stop() }
        var manager: OverlayManager? = OverlayManager(store: store, registry: registry,
            readReduceMotion: { false }, makeSurface: { surfaces.make($0) })
        weak var retained = manager
        let effect = TestOverlay(); manager?.register(.particles) { _ in effect }
        manager?.start(); registry.start(); try manager?.configure(configuration())
        try await wait { manager?.states.first?.lifecycle == .running }
        manager = nil
        try await wait { retained == nil && effect.disposed }
        XCTAssertTrue(surfaces.surfaces[display.id]?.closed ?? false); XCTAssertEqual(effect.disposals, 1)
    }
    func testStartupAlreadyLockedSuppliesPausedPreparationContext() async throws {
        let store = try store(), display = descriptor(), probe = OverlayProbe(); probe.isScreenLocked = true
        try store.upsert(configuration())
        let monitor = SmartPauseMonitor(probe: probe, workspaceNotifications: NotificationCenter(), distributedNotifications: NotificationCenter(),
            applicationNotifications: NotificationCenter(), desktopWindowIdentifier: .init("test.none"), onChange: { _ in })
        let registry = DisplayRegistry(discover: { [display] }, applicationNotifications: NotificationCenter(), workspaceNotifications: NotificationCenter())
        let manager = OverlayManager(store: store, registry: registry, readReduceMotion: { false }, makeSurface: { _ in TestOverlaySurface() })
        defer { manager.shutdown(); monitor.stop(); registry.stop() }
        let effect = TestOverlay(); manager.register(.particles) { _ in effect }
        monitor.start(); registry.start(); manager.start(monitor: monitor)
        try await wait { manager.states.first?.lifecycle == .paused }
        XCTAssertEqual(effect.preparedContexts.first?.isPaused, true); XCTAssertEqual(effect.plays, 0)
    }
}
