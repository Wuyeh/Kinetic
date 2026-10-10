import AppKit
import SwiftUI
import XCTest
@testable import Kinetic

@MainActor
private final class WeatherTestSurface: OverlaySurface {
    var views: [UUID: NSView] = [:]
    func present(_ view: NSView, for id: UUID, display: DesktopDisplay) throws { views[id] = view }
    func remove(_ id: UUID) { views[id] = nil }
    func realign(_ display: DesktopDisplay) {}
    func setOrder(_ ids: [UUID]) {}
    func close() { views = [:] }
}

@MainActor
final class WeatherResponseTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() { roots.forEach { try? FileManager.default.removeItem(at: $0) }; super.tearDown() }
    private func root() throws -> URL {
        let root = TestWorkspaceDirectory.make(".build/Module35-36/Fixtures")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); roots.append(root); return root
    }
    private func display(_ id: String = "display-A") -> DisplayDescriptor {
        .init(id: .init(id), name: id, desktop: .init(id: 1, frame: .init(x: -5000, y: -5000, width: 640, height: 400), backingScaleFactor: 2), isPersistent: true)
    }
    private func configuration(_ id: String = "display-A", enabled: Bool = true) throws -> OverlayConfiguration {
        var options = ParticleOptions(); options.preset = .embers; options.wind = -0.2; options.reduceMotion = true
        var value = OverlayConfiguration(kind: .particles, displayID: .init(id)); value.isEnabled = enabled
        return try options.applying(to: value)
    }
    private func context(paused: Bool = false) -> OverlayContext {
        .init(frame: .init(x: 0, y: 0, width: 640, height: 400), backingScaleFactor: 2,
              maximumFramesPerSecond: 30, allowsAnimation: false, isPaused: paused)
    }
    private func environment(_ displays: [DisplayDescriptor] = []) throws -> (WeatherService, WeatherResponseStore, OverlayStore, DisplayRegistry, WeatherTestClient) {
        let storage = LibraryStorageLocation(rootURL: try root()), client = WeatherTestClient()
        let weather = WeatherService(store: WeatherStore(storage: storage, now: { WeatherTestFixture.now }), client: client,
                                     location: WeatherTestLocation(), now: { WeatherTestFixture.now }); weather.start()
        let registry = DisplayRegistry(discover: { displays }); registry.start()
        return (weather, WeatherResponseStore(storage: storage), OverlayStore(storage: storage), registry, client)
    }
    private func wait(_ condition: @escaping @MainActor () -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + 3
        while !condition() { guard ProcessInfo.processInfo.systemUptime < end else { throw WeatherError.network }; try await Task.sleep(nanoseconds: 10_000_000) }
    }
    private func fetch(_ weather: WeatherService) async throws {
        try weather.configure(.init(mode: .manual, manualPlace: WeatherTestFixture.place()))
        try await wait { !weather.isFetching && weather.reading.activity == .ready }
    }
    func testConditionDayNightStrengthWindAreFiniteAndManualOptionsRemainUnchanged() throws {
        let value = try configuration(), manual = try ParticleOptions(configuration: value)
        let policy = WeatherResponseConfiguration(overlayID: value.id, displayID: value.displayID, isEnabled: true)
        for (code, preset): (Int, ParticlePreset) in [(0, .bokeh), (3, .mist), (45, .mist), (51, .rain), (65, .rain), (75, .snow), (99, .rain)] {
            let snapshot = WeatherTestFixture.snapshot(code: code)
            let options = WeatherResponsePlan.options(manual: manual, policy: policy, snapshot: snapshot, now: WeatherTestFixture.now)
            XCTAssertEqual(options.preset, preset); XCTAssertNoThrow(try options.validated()); XCTAssertTrue(options.reduceMotion)
            XCTAssertGreaterThan(options.wind, 0)
        }
        var night = WeatherTestFixture.snapshot(code: 0); night.isDay = false
        XCTAssertEqual(WeatherResponsePlan.options(manual: manual, policy: policy, snapshot: night, now: WeatherTestFixture.now).preset, .stars)
        XCTAssertEqual(try ParticleOptions(configuration: value), manual)
    }
    func testEachFollowSwitchLeavesItsManualFieldUntouched() throws {
        let value = try configuration(), manual = try ParticleOptions(configuration: value), snapshot = WeatherTestFixture.snapshot()
        var policy = WeatherResponseConfiguration(overlayID: value.id, displayID: value.displayID, isEnabled: true)
        policy.followsType = false
        XCTAssertEqual(WeatherResponsePlan.options(manual: manual, policy: policy, snapshot: snapshot, now: WeatherTestFixture.now).preset, manual.preset)
        policy.followsIntensity = false
        let options = WeatherResponsePlan.options(manual: manual, policy: policy, snapshot: snapshot, now: WeatherTestFixture.now)
        XCTAssertEqual(options.density, manual.density); XCTAssertEqual(options.intensity, manual.intensity)
        policy.followsWind = false
        XCTAssertEqual(WeatherResponsePlan.options(manual: manual, policy: policy, snapshot: snapshot, now: WeatherTestFixture.now), manual)
    }
    func testInvalidUnknownMissingExpiredAndDisabledWeatherRestoreManual() throws {
        let value = try configuration(), manual = try ParticleOptions(configuration: value)
        var policy = WeatherResponseConfiguration(overlayID: value.id, displayID: value.displayID, isEnabled: true)
        var invalid = WeatherTestFixture.snapshot(); invalid.windSpeedMetresPerSecond = .nan
        let unknown = WeatherTestFixture.snapshot(code: 123)
        for snapshot in [Optional<WeatherSnapshot>.none, unknown, invalid,
                         WeatherTestFixture.snapshot(date: WeatherTestFixture.now.addingTimeInterval(-7 * 3_600))] {
            XCTAssertEqual(WeatherResponsePlan.options(manual: manual, policy: policy, snapshot: snapshot, now: WeatherTestFixture.now), manual)
        }
        policy.isEnabled = false
        XCTAssertEqual(WeatherResponsePlan.options(manual: manual, policy: policy, snapshot: WeatherTestFixture.snapshot(), now: WeatherTestFixture.now), manual)
    }
    func testMeteorologicalWindDirectionProjectionAndClamp() throws {
        let value = try configuration(), manual = try ParticleOptions(configuration: value)
        let policy = WeatherResponseConfiguration(overlayID: value.id, displayID: value.displayID, isEnabled: true)
        for (direction, expected): (Double, Double) in [(90, -1), (270, 1), (0, 0), (180, 0)] {
            var snapshot = WeatherTestFixture.snapshot(); snapshot.windDirectionDegrees = direction; snapshot.windSpeedMetresPerSecond = 100
            XCTAssertEqual(WeatherResponsePlan.options(manual: manual, policy: policy, snapshot: snapshot, now: WeatherTestFixture.now).wind, expected, accuracy: 0.0001)
        }
    }
    func testResponsePersistenceIdentityValidationAndCorruptFileProtection() throws {
        let root = try root(), storage = LibraryStorageLocation(rootURL: root), store = WeatherResponseStore(storage: storage), config = try configuration()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        let policy = WeatherResponseConfiguration(overlayID: config.id, displayID: config.displayID, isEnabled: true, followsWind: false)
        try store.upsert(policy)
        XCTAssertEqual(WeatherResponseStore(storage: storage).configurations, [policy])
        var invalid = policy; invalid.displayID = .main; XCTAssertThrowsError(try store.upsert(invalid)); XCTAssertEqual(store.configurations, [policy])
        let bytes = Data(#"{"version":2,"configurations":[]}"#.utf8); try bytes.write(to: store.fileURL)
        let broken = WeatherResponseStore(storage: storage); XCTAssertNotNil(broken.loadError); XCTAssertThrowsError(try broken.upsert(policy))
        XCTAssertEqual(try Data(contentsOf: broken.fileURL), bytes)
    }
    func testResponseSymlinkAndFailedWriteDoNotOverwriteOrPublish() throws {
        let root = try root(), target = root.appendingPathComponent("target"), file = root.appendingPathComponent("weather-response.json")
        try Data("preserve".utf8).write(to: target); try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        let store = WeatherResponseStore(storage: .init(rootURL: root)), config = try configuration()
        let policy = WeatherResponseConfiguration(overlayID: config.id, displayID: config.displayID, isEnabled: true)
        XCTAssertThrowsError(try store.upsert(policy)); XCTAssertEqual(try Data(contentsOf: target), Data("preserve".utf8))
        let block = root.appendingPathComponent("block"); try Data().write(to: block)
        let blocked = WeatherResponseStore(storage: .init(rootURL: block)); XCTAssertThrowsError(try blocked.upsert(policy)); XCTAssertTrue(blocked.configurations.isEmpty)
    }
    func testLiveWeatherChangesOnlyAssignedLayerAndOffRestoresSavedManualBytes() async throws {
        let (weather, responses, overlays, registry, _) = try environment(); defer { weather.shutdown(); registry.stop() }
        let a = try configuration(), b = try configuration("display-B")
        try overlays.upsert(a); try overlays.upsert(b); let original = try Data(contentsOf: overlays.fileURL)
        try responses.upsert(.init(overlayID: a.id, displayID: a.displayID, isEnabled: true))
        let first = WeatherResponsiveParticleOverlay(weather: weather, responses: responses, now: { WeatherTestFixture.now })
        let second = WeatherResponsiveParticleOverlay(weather: weather, responses: responses, now: { WeatherTestFixture.now })
        defer { first.dispose(); second.dispose() }
        try await first.prepare(configuration: a, context: context()); first.play()
        try await second.prepare(configuration: b, context: context()); second.play()
        try await fetch(weather)
        XCTAssertEqual(first.particles.view.simulation.options.preset, .rain)
        XCTAssertEqual(second.particles.view.simulation.options, try ParticleOptions(configuration: b))
        XCTAssertFalse(first.displayView.isOpaque); XCTAssertNil(first.displayView.hitTest(.zero))
        try weather.configure(.init())
        XCTAssertEqual(first.particles.view.simulation.options, try ParticleOptions(configuration: a))
        XCTAssertEqual(try Data(contentsOf: overlays.fileURL), original)
    }
    func testManualPauseHoldsFrameWeatherChangesWaitForResumeAndDisableDoesNotPlay() async throws {
        let (weather, responses, _, registry, client) = try environment(); defer { weather.shutdown(); registry.stop() }
        let a = try configuration(); try responses.upsert(.init(overlayID: a.id, displayID: a.displayID, isEnabled: true)); try await fetch(weather)
        let overlay = WeatherResponsiveParticleOverlay(weather: weather, responses: responses, now: { WeatherTestFixture.now }); defer { overlay.dispose() }
        try await overlay.prepare(configuration: a, context: context()); overlay.play()
        overlay.pause(); try overlay.update(configuration: a, context: context(paused: true))
        let particles = overlay.particles.view.simulation.particles
        await client.setCode(75); weather.refresh(); try await wait { !weather.isFetching }
        XCTAssertEqual(overlay.particles.view.simulation.options.preset, .rain)
        XCTAssertEqual(overlay.particles.view.simulation.particles, particles); XCTAssertFalse(overlay.particles.isPlaying)
        try overlay.update(configuration: a, context: context()); overlay.play()
        XCTAssertEqual(overlay.particles.view.simulation.options.preset, .snow)
        var policy = responses.configurations[0]; policy.isEnabled = false; try responses.upsert(policy)
        XCTAssertEqual(overlay.particles.view.simulation.options, try ParticleOptions(configuration: a))
    }
    func testPolicyWindChangeUpdatesCurrentSimulationWithoutReset() async throws {
        let (weather, responses, _, registry, _) = try environment(); defer { weather.shutdown(); registry.stop() }
        var manual = ParticleOptions(); manual.preset = .rain; manual.reduceMotion = true
        var a = OverlayConfiguration(kind: .particles, displayID: .init("display-A")); a.isEnabled = true; a = try manual.applying(to: a)
        var policy = WeatherResponseConfiguration(overlayID: a.id, displayID: a.displayID, isEnabled: true, followsIntensity: false)
        try responses.upsert(policy); try await fetch(weather)
        let overlay = WeatherResponsiveParticleOverlay(weather: weather, responses: responses, now: { WeatherTestFixture.now }); defer { overlay.dispose() }
        try await overlay.prepare(configuration: a, context: context()); overlay.play(); overlay.particles.view.advance(by: 0.02)
        let positions = overlay.particles.view.simulation.particles, time = overlay.particles.view.simulation.elapsed
        policy.followsWind = false; try responses.upsert(policy)
        XCTAssertEqual(overlay.particles.view.simulation.particles, positions); XCTAssertEqual(overlay.particles.view.simulation.elapsed, time)
        XCTAssertEqual(overlay.particles.view.simulation.options.wind, manual.wind)
    }
    func testManagerDisconnectReconnectAndDisabledLayerNeverFallsBackOrStarts() async throws {
        let (weather, responses, overlays, oldRegistry, _) = try environment(); oldRegistry.stop(); defer { weather.shutdown() }
        let a = display(), b = display("display-B"); var connected = [a, b]
        let registry = DisplayRegistry(discover: { connected }); registry.start(); defer { registry.stop() }
        let configA = try configuration(), configB = try configuration("display-B", enabled: false)
        try overlays.upsert(configA); try overlays.upsert(configB)
        for config in [configA, configB] { try responses.upsert(.init(overlayID: config.id, displayID: config.displayID, isEnabled: true)) }
        try await fetch(weather)
        var effects: [WeatherResponsiveParticleOverlay] = [], surfaces: [DisplayID: WeatherTestSurface] = [:]
        let manager = OverlayManager(store: overlays, registry: registry, readReduceMotion: { true }, makeSurface: { id in
            let surface = WeatherTestSurface(); surfaces[id] = surface; return surface
        })
        manager.register(.particles) { _ in
            let overlay = WeatherResponsiveParticleOverlay(weather: weather, responses: responses, now: { WeatherTestFixture.now }); effects.append(overlay); return overlay
        }
        manager.start(); defer { manager.shutdown() }
        try await wait { manager.states.first { $0.id == configA.id }?.lifecycle == .running }
        XCTAssertEqual(effects.count, 1); XCTAssertNil(surfaces[b.id]); XCTAssertEqual(manager.states.first { $0.id == configB.id }?.lifecycle, .disabled)
        connected = [b]; registry.refresh(); XCTAssertTrue(effects[0].isDisposed); XCTAssertNil(surfaces[b.id])
        XCTAssertEqual(manager.states.first { $0.id == configA.id }?.lifecycle, .waitingForDisplay)
        connected = [a, b]; registry.refresh(); try await wait { effects.count == 2 && manager.states.first { $0.id == configA.id }?.lifecycle == .running }
        XCTAssertEqual(effects[1].particles.view.simulation.options.preset, .rain); XCTAssertNil(surfaces[b.id])
    }
    func testSettingsDraftSelectionNoSaveSideEffectsAndMissingTargetsStaySelected() async throws {
        let (weather, responses, overlays, oldRegistry, client) = try environment(); oldRegistry.stop(); defer { weather.shutdown() }
        let a = display(), b = display("display-B"); var connected = [a, b]
        let registry = DisplayRegistry(discover: { connected }); registry.start(); defer { registry.stop() }
        let config = try configuration(); try overlays.upsert(config)
        let model = WeatherSettingsModel(weather: weather, responses: responses, overlays: overlays, registry: registry); model.opened()
        model.locationDraft.mode = .manual; model.choosePlace(WeatherTestFixture.place())
        model.responseEnabled = true; model.followsWind = false
        XCTAssertEqual(weather.store.configuration.mode, .off); XCTAssertTrue(responses.configurations.isEmpty)
        let calls = await client.calls; XCTAssertTrue(calls.isEmpty)
        model.saveResponse(); XCTAssertEqual(responses.configurations.first?.overlayID, config.id)
        XCTAssertEqual(weather.store.configuration.mode, .off)
        connected = [b]; registry.refresh(); XCTAssertEqual(model.selectedDisplayID, a.id); XCTAssertEqual(model.selectedOverlayID, config.id)
        XCTAssertFalse(model.canSaveResponse); model.responseEnabled = false; XCTAssertTrue(model.canSaveResponse); model.saveResponse()
        XCTAssertEqual(responses.configurations.first?.displayID, a.id); XCTAssertEqual(responses.configurations.first?.isEnabled, false)
        model.closed(); model.opened(); XCTAssertEqual(model.locationDraft.mode, .off)
    }
    func testExplicitManualEditsRemainStoredAndRestoredAfterAutomationTurnsOff() async throws {
        let (weather, responses, _, registry, _) = try environment(); defer { weather.shutdown(); registry.stop() }
        let a = try configuration(); try responses.upsert(.init(overlayID: a.id, displayID: a.displayID, isEnabled: true)); try await fetch(weather)
        let overlay = WeatherResponsiveParticleOverlay(weather: weather, responses: responses, now: { WeatherTestFixture.now }); defer { overlay.dispose() }
        try await overlay.prepare(configuration: a, context: context()); overlay.play()
        var manual = try ParticleOptions(configuration: a); manual.preset = .sakura; manual.density = 0.8; manual.wind = -0.7
        let updated = try manual.applying(to: a); try overlay.update(configuration: updated, context: context())
        XCTAssertEqual(overlay.particles.view.simulation.options.preset, .rain)
        try weather.configure(.init()); XCTAssertEqual(overlay.particles.view.simulation.options, manual)
        XCTAssertEqual(try ParticleOptions(configuration: updated), manual)
    }
    func testDisposedProviderDoesNotReactToLaterWeatherAndFortyInstancesRelease() async throws {
        let (weather, responses, _, registry, _) = try environment(); defer { weather.shutdown(); registry.stop() }
        let a = try configuration(); try responses.upsert(.init(overlayID: a.id, displayID: a.displayID, isEnabled: true))
        for _ in 0..<40 {
            weak var weakOverlay: WeatherResponsiveParticleOverlay?
            do {
                let overlay = WeatherResponsiveParticleOverlay(weather: weather, responses: responses, now: { WeatherTestFixture.now }); weakOverlay = overlay
                try await overlay.prepare(configuration: a, context: context()); overlay.play(); overlay.dispose(); overlay.dispose()
                XCTAssertTrue(overlay.particles.isDisposed); XCTAssertFalse(overlay.particles.isPlaying)
            }
            try await Task.sleep(nanoseconds: 1_000_000); XCTAssertNil(weakOverlay)
        }
        let overlay = WeatherResponsiveParticleOverlay(weather: weather, responses: responses, now: { WeatherTestFixture.now })
        try await overlay.prepare(configuration: a, context: context()); overlay.play(); overlay.dispose(); try await fetch(weather)
        XCTAssertNil(overlay.applied); XCTAssertFalse(overlay.particles.isPlaying)
    }
    func testNativeWeatherSettingsLightDarkLayoutAndChineseLabels() async throws {
        let (weather, responses, overlays, registry, _) = try environment([display()]); defer { weather.shutdown(); registry.stop() }
        try overlays.upsert(configuration()); try await fetch(weather)
        let model = WeatherSettingsModel(weather: weather, responses: responses, overlays: overlays, registry: registry)
        let folder = TestWorkspaceDirectory.make(".build/Module35-36/Snapshots").deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertEqual(NSLocalizedString("weather.response.title", comment: ""), "天气联动")
        let oldAppearance = NSApp.appearance
        defer { NSApp.appearance = oldAppearance }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            let host = NSHostingView(rootView: ScrollView {
                WeatherSettingsView(model: model, weather: weather, store: weather.store, responses: responses, onEditParticles: nil)
                    .padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }.environment(\.locale, Locale(identifier: "zh-Hans"))
                .environment(\.colorScheme, name == "dark" ? .dark : .light)
                .background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: .init(x: -5000, y: -5000, width: 570, height: 620), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: appearance); window.contentView = host
            defer { window.contentView = nil; window.close() }
            host.frame = .init(x: 0, y: 0, width: 570, height: 620); host.layoutSubtreeIfNeeded()
            window.orderFrontRegardless()
            try await Task.sleep(nanoseconds: 100_000_000)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            window.effectiveAppearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
            XCTAssertEqual(host.frame.width, 570)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("weather-\(name).png"))
        }
    }
}
