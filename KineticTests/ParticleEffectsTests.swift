import AppKit
import SwiftUI
import XCTest
@testable import Kinetic

@MainActor
private final class ParticleTestSurface: OverlaySurface {
    var views: [UUID: NSView] = [:]
    func present(_ view: NSView, for id: UUID, display: DesktopDisplay) throws { views[id] = view }
    func remove(_ id: UUID) { views[id] = nil }
    func realign(_ display: DesktopDisplay) {}
    func setOrder(_ ids: [UUID]) {}
    func close() { views.removeAll() }
}

@MainActor
final class ParticleEffectsTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() { roots.forEach { try? FileManager.default.removeItem(at: $0) }; super.tearDown() }
    private func store() throws -> OverlayStore {
        let root = TestWorkspaceDirectory.make(".build/Module34/Fixtures")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); roots.append(root)
        return OverlayStore(storage: .init(rootURL: root))
    }
    private func display(_ name: String = "display-A", scale: CGFloat = 2) -> DisplayDescriptor {
        .init(id: .init(name), name: name, desktop: .init(id: 1,
            frame: .init(x: -5000, y: -5000, width: 640, height: 400), backingScaleFactor: scale), isPersistent: true)
    }
    private func context(fps: Int = 30, paused: Bool = false, animated: Bool = true) -> OverlayContext {
        .init(frame: .init(x: 0, y: 0, width: 640, height: 400), backingScaleFactor: 2,
              maximumFramesPerSecond: fps, allowsAnimation: animated, isPaused: paused)
    }
    private func configuration(_ options: ParticleOptions = .init(), display: String = "display-A") throws -> OverlayConfiguration {
        var value = OverlayConfiguration(kind: .particles, displayID: .init(display)); value.isEnabled = true
        return try options.applying(to: value)
    }
    private func wait(_ condition: () -> Bool, timeout: Double = 3) async throws {
        let end = ProcessInfo.processInfo.systemUptime + timeout
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < end else { throw OverlayError.preparationTimedOut }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testTwelvePresetsHaveChineseLabelsAndBoundedRoundTripValues() throws {
        XCTAssertEqual(ParticlePreset.allCases.count, 12)
        XCTAssertEqual(Set(ParticlePreset.allCases.map(\.title)).count, 12)
        for preset in ParticlePreset.allCases {
            XCTAssertFalse(preset.title.hasPrefix("particles."))
            var options = ParticleOptions(); options.preset = preset; options.wind = -0.75; options.reduceMotion = true
            let config = try configuration(options), data = try JSONEncoder().encode(config)
            let decoded = try JSONDecoder().decode(OverlayConfiguration.self, from: data)
            XCTAssertEqual(try ParticleOptions(configuration: decoded), options)
        }
    }
    func testWrongTypesUnknownPresetAndNonfiniteOutOfRangeValuesAreRejected() throws {
        var value = try configuration()
        for parameters: [String: OverlayParameter] in [
            ["preset": .text("unknown")], ["preset": .number(1)], ["density": .boolean(true)],
            ["density": .number(1.01)], ["wind": .number(-1.01)], ["intensity": .number(-0.01)],
            ["reduceMotion": .text("true")], ["density": .number(.nan)], ["wind": .number(.infinity)], ["typo": .number(1)]
        ] {
            value.parameters = parameters; XCTAssertThrowsError(try ParticleOptions(configuration: value))
        }
        value = try configuration(); value.kind = .weather
        XCTAssertThrowsError(try ParticleOptions(configuration: value))
    }
    func testParameterEditsContinueExistingPositionsAndOnlyDensityAddsOrRemoves() throws {
        var sim = ParticleSimulation(seed: 42), options = ParticleOptions()
        try sim.configure(options); sim.advance(by: 0.05)
        let before = sim.particles, elapsed = sim.elapsed
        options.intensity = 1; options.wind = -1; options.reduceMotion = true
        try sim.configure(options); XCTAssertEqual(sim.particles, before); XCTAssertEqual(sim.elapsed, elapsed)
        options.density = 0.9; try sim.configure(options)
        XCTAssertEqual(Array(sim.particles.prefix(before.count)), before)
        options.density = 0.1; try sim.configure(options)
        XCTAssertEqual(sim.particles, Array(before.prefix(sim.particles.count)))
        let valid = sim.particles; options.density = -1
        XCTAssertThrowsError(try sim.configure(options)); XCTAssertEqual(sim.particles, valid)
    }
    func testWindAndIntensityChangeMotionFromCurrentFrameWithoutReset() throws {
        var left = ParticleSimulation(seed: 9), right = ParticleSimulation(seed: 9)
        var options = ParticleOptions(); options.preset = .rain
        try left.configure(options); try right.configure(options)
        left.advance(by: 0.03); right.advance(by: 0.03)
        let positions = left.particles
        options.wind = -1; options.intensity = 0; try left.configure(options)
        options.wind = 1; options.intensity = 1; try right.configure(options)
        XCTAssertEqual(left.particles, positions); XCTAssertEqual(right.particles, positions)
        left.advance(by: 0.02); right.advance(by: 0.02)
        XCTAssertNotEqual(left.particles, right.particles)
        XCTAssertEqual(left.elapsed, right.elapsed, accuracy: 0.0001)
    }
    func testAllPresetsStayFiniteWithinBudgetThroughLongRunAndZeroDensityIsEmpty() throws {
        for preset in ParticlePreset.allCases {
            var sim = ParticleSimulation(seed: 8), options = ParticleOptions()
            options.preset = preset; options.density = 1; options.intensity = 1; options.wind = -1
            try sim.configure(options)
            for _ in 0..<3_000 { sim.advance(by: 0.1) }
            XCTAssertLessThanOrEqual(sim.particles.count, ParticleSimulation.maximumParticles)
            XCTAssertFalse(sim.particles.isEmpty)
            XCTAssertTrue(sim.particles.allSatisfy { $0.x.isFinite && $0.y.isFinite && (0..<1).contains($0.x) && (0..<1).contains($0.y) && $0.angle.isFinite })
            let before = sim.particles; sim.advance(by: .nan); sim.advance(by: -1); XCTAssertEqual(sim.particles, before)
            options.density = 0; try sim.configure(options); XCTAssertTrue(sim.particles.isEmpty)
        }
    }
    func testStallIsBoundedRatherThanCatchingUpFromSleep() throws {
        var a = ParticleSimulation(seed: 5), b = ParticleSimulation(seed: 5)
        try a.configure(.init()); try b.configure(.init())
        a.advance(by: 3600); b.advance(by: 0.1)
        XCTAssertEqual(a.particles, b.particles); XCTAssertEqual(a.elapsed, 0.1)
    }
    func testPauseResumePreservesFrameAndDisposeNeverResurrectsTimer() async throws {
        let overlay = ParticleOverlay(seed: 42), value = try configuration()
        try await overlay.prepare(configuration: value, context: context()); overlay.play()
        try await wait { overlay.tickCount >= 2 }; overlay.pause()
        let frame = overlay.view.simulation.particles, count = overlay.tickCount
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(overlay.view.simulation.particles, frame); XCTAssertEqual(overlay.tickCount, count)
        XCTAssertNil(overlay.timerFramesPerSecond)
        overlay.play(); try await wait { overlay.tickCount > count }
        overlay.dispose(); overlay.dispose(); overlay.play()
        XCTAssertTrue(overlay.isDisposed); XCTAssertNil(overlay.timerFramesPerSecond)
        XCTAssertTrue(overlay.view.simulation.particles.isEmpty)
        XCTAssertThrowsError(try overlay.update(configuration: value, context: context()))
    }
    func testSystemAndLocalReduceMotionKeepStaticFrameWithNoTimer() async throws {
        let overlay = ParticleOverlay(seed: 7); defer { overlay.dispose() }
        let value = try configuration()
        try await overlay.prepare(configuration: value, context: context(animated: false)); overlay.play()
        XCTAssertNil(overlay.timerFramesPerSecond); let frame = overlay.view.simulation.particles
        try await Task.sleep(nanoseconds: 80_000_000); XCTAssertEqual(overlay.view.simulation.particles, frame)
        try overlay.update(configuration: value, context: context()); overlay.play()
        XCTAssertEqual(overlay.timerFramesPerSecond, 30)
        var options = ParticleOptions(); options.reduceMotion = true
        try overlay.update(configuration: configuration(options), context: context())
        XCTAssertNil(overlay.timerFramesPerSecond); XCTAssertEqual(overlay.view.simulation.particles, frame)
    }
    func testFPSPolicyChangesTimerInPlaceAndPausedUpdatesDoNotMoveParticles() async throws {
        let overlay = ParticleOverlay(seed: 3); defer { overlay.dispose() }
        let value = try configuration(); try await overlay.prepare(configuration: value, context: context()); overlay.play()
        let view = overlay.displayView, before = overlay.view.simulation.particles
        try overlay.update(configuration: value, context: context(fps: 15)); XCTAssertEqual(overlay.timerFramesPerSecond, 15)
        XCTAssertTrue(overlay.displayView === view); XCTAssertEqual(overlay.view.simulation.particles, before)
        try overlay.update(configuration: value, context: context(paused: true)); overlay.play()
        XCTAssertNil(overlay.timerFramesPerSecond); XCTAssertEqual(overlay.view.simulation.particles, before)
        var options = ParticleOptions(); options.density = 0
        try overlay.update(configuration: configuration(options), context: context()); overlay.play()
        XCTAssertNil(overlay.timerFramesPerSecond)
    }
    func testInvalidEditKeepsPreviousLiveSettingsAndView() async throws {
        let overlay = ParticleOverlay(seed: 3); defer { overlay.dispose() }
        let valid = try configuration(); try await overlay.prepare(configuration: valid, context: context()); overlay.play()
        var bad = valid; bad.parameters["wind"] = .number(2)
        let frame = overlay.view.simulation.particles, settings = overlay.view.simulation.options
        XCTAssertThrowsError(try overlay.update(configuration: bad, context: context()))
        XCTAssertEqual(overlay.view.simulation.options, settings); XCTAssertEqual(overlay.view.simulation.particles, frame)
        XCTAssertEqual(overlay.timerFramesPerSecond, 30)
    }
    func testGeometryAndDPIEditsKeepNormalizedParticlePositions() async throws {
        let overlay = ParticleOverlay(seed: 3); defer { overlay.dispose() }
        let value = try configuration(); try await overlay.prepare(configuration: value, context: context(paused: true))
        let frame = overlay.view.simulation.particles
        var changed = context(paused: true); changed.frame = .init(x: -1900, y: 30, width: 1900, height: 1000); changed.backingScaleFactor = 1
        try overlay.update(configuration: value, context: changed)
        XCTAssertEqual(overlay.view.simulation.particles, frame); XCTAssertEqual(overlay.displayView.frame.size, changed.frame.size)
        XCTAssertEqual(overlay.context?.backingScaleFactor, 1)
    }
    func testDraftNeverWritesOrCreatesDesktopAndDisplayPagePreviewDrawsIt() throws {
        let store = try store(), d = display()
        let registry = DisplayRegistry(discover: { [d] }); registry.start()
        let manager = OverlayManager(store: store, registry: registry, readReduceMotion: { false }, makeSurface: { _ in ParticleTestSurface() })
        manager.register(.particles) { _ in ParticleOverlay() }; manager.start()
        defer { manager.shutdown(); registry.stop() }
        let editor = ParticleEditorModel(manager: manager, registry: registry, readReduceMotion: { false })
        editor.opened()
        editor.options.preset = .embers; editor.options.wind = 0.75; editor.options.intensity = 0.9; editor.isEnabled = true
        XCTAssertTrue(store.configurations.isEmpty); XCTAssertTrue(manager.states.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        XCTAssertEqual(editor.draft(on: d.id).options, editor.options); XCTAssertTrue(editor.canApply(on: d.id))
        // The display page draws the draft at its own size; paused while hidden.
        let page = DisplayParticlePreviewState(); defer { page.stop() }
        page.update(options: editor.draft(on: d.id).options, context: editor.previewContext(size: .init(width: 640, height: 416), visible: true))
        let preview = try XCTUnwrap(page.overlay)
        XCTAssertEqual(preview.view.simulation.options, editor.options); XCTAssertEqual(preview.timerFramesPerSecond, 30)
        XCTAssertEqual(preview.displayView.frame.size, CGSize(width: 640, height: 416))
        page.update(options: editor.options, context: editor.previewContext(size: .init(width: 640, height: 416), visible: false))
        XCTAssertNil(preview.timerFramesPerSecond)
        page.stop(); XCTAssertTrue(preview.isDisposed); XCTAssertNil(page.overlay)
        // Closing the window keeps the draft; the display page still shows it until it is applied.
        editor.closed(); editor.opened(); XCTAssertEqual(editor.options.preset, .embers); XCTAssertTrue(editor.isDirty(on: d.id))
        editor.apply(on: d.id); XCTAssertNil(editor.error); XCTAssertFalse(editor.isDirty(on: d.id))
        XCTAssertEqual(editor.saved(on: d.id).options.preset, .embers); XCTAssertTrue(editor.saved(on: d.id).isEnabled)
        editor.closed()
    }
    func testSaveExplicitTargetPersistenceAndDisableDoNotTouchOtherScreen() async throws {
        let store = try store(), a = display(), b = display("display-B")
        let registry = DisplayRegistry(discover: { [a,b] }); registry.start()
        let surfaces = [a.id: ParticleTestSurface(), b.id: ParticleTestSurface()]
        let manager = OverlayManager(store: store, registry: registry, readReduceMotion: { false }, makeSurface: { surfaces[$0]! })
        var overlays: [ParticleOverlay] = []
        manager.register(.particles) { _ in let overlay = ParticleOverlay(); overlays.append(overlay); return overlay }; manager.start()
        defer { manager.shutdown(); registry.stop() }
        let editor = ParticleEditorModel(manager: manager, registry: registry, readReduceMotion: { false }); editor.opened()
        defer { editor.closed() }
        editor.selectDisplay(b.id); editor.isEnabled = true; editor.options.preset = .sakura; editor.save()
        XCTAssertNil(editor.error); try await wait { manager.states.first?.lifecycle == .running }
        let saved = try XCTUnwrap(editor.savedConfiguration)
        XCTAssertEqual(saved.displayID, b.id); XCTAssertEqual(surfaces[a.id]?.views.count, 0)
        XCTAssertEqual(surfaces[b.id]?.views.count, 1)
        XCTAssertEqual(try ParticleOptions(configuration: OverlayStore(storage: .init(rootURL: store.fileURL.deletingLastPathComponent())).configurations[0]).preset, .sakura)
        let overlay = overlays[0], before = overlay.view.simulation.particles
        editor.options.wind = -0.75; XCTAssertEqual(overlay.view.simulation.options.wind, 0)
        editor.save(); XCTAssertEqual(overlays.count, 1); XCTAssertEqual(overlay.view.simulation.particles, before)
        XCTAssertEqual(overlay.view.simulation.options.wind, -0.75)
        editor.isEnabled = false; editor.save(); XCTAssertTrue(overlay.isDisposed); XCTAssertEqual(surfaces[b.id]?.views.count, 0)
        XCTAssertEqual(manager.states.first?.lifecycle, .disabled)
    }
    func testDisconnectKeepsSelectedTargetNoFallbackAndReconnectRestoresThatTarget() async throws {
        let store = try store(), a = display(), b = display("display-B"); var connected = [a,b]
        let registry = DisplayRegistry(discover: { connected }); registry.start()
        let manager = OverlayManager(store: store, registry: registry, readReduceMotion: { false }, makeSurface: { _ in ParticleTestSurface() })
        var overlays: [ParticleOverlay] = []
        manager.register(.particles) { _ in let overlay = ParticleOverlay(); overlays.append(overlay); return overlay }; manager.start()
        defer { manager.shutdown(); registry.stop() }
        let editor = ParticleEditorModel(manager: manager, registry: registry); editor.opened(); defer { editor.closed() }
        editor.selectDisplay(b.id); editor.isEnabled = true; editor.save()
        try await wait { manager.states.first?.lifecycle == .running }
        connected = [a]; registry.refresh()
        XCTAssertEqual(editor.selectedDisplayID, b.id); XCTAssertFalse(editor.canSave); XCTAssertTrue(overlays[0].isDisposed)
        editor.save(); XCTAssertNotNil(editor.error); XCTAssertEqual(store.configurations[0].displayID, b.id)
        connected = [a,b]; registry.refresh(); try await wait { manager.states.first?.lifecycle == .running }
        XCTAssertEqual(overlays.count, 2); XCTAssertEqual(manager.states[0].displayID, b.id)
        connected = [a]; registry.refresh(); editor.isEnabled = false; editor.save()
        XCTAssertNil(editor.error); XCTAssertFalse(store.configurations[0].isEnabled)
    }
    func testManualPauseAndSystemPolicyDoNotResetParticlesOrEnableOtherEffects() async throws {
        let store = try store(), a = display(), registry = DisplayRegistry(discover: { [self.display()] }); registry.start()
        let manager = OverlayManager(store: store, registry: registry, readReduceMotion: { false }, makeSurface: { _ in ParticleTestSurface() })
        let overlay = ParticleOverlay(seed: 19); manager.register(.particles) { _ in overlay }; manager.start()
        defer { manager.shutdown(); registry.stop() }
        try manager.configure(configuration(display: a.id.rawValue)); try await wait { manager.states.first?.lifecycle == .running }
        manager.setPolicy(.init(isSuspended: true)); let frame = overlay.view.simulation.particles
        XCTAssertNil(overlay.timerFramesPerSecond); try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(overlay.view.simulation.particles, frame)
        let id = store.configurations[0].id; try store.setManuallyPaused(true, for: id)
        manager.setPolicy(.init()); XCTAssertEqual(manager.states[0].lifecycle, .paused); XCTAssertNil(overlay.timerFramesPerSecond)
        try store.setManuallyPaused(false, for: id); manager.setPolicy(.init(lowPowerMode: true))
        XCTAssertEqual(overlay.timerFramesPerSecond, 15)
        manager.setPolicy(.init(reduceMotion: true)); XCTAssertNil(overlay.timerFramesPerSecond)
        XCTAssertEqual(overlay.view.simulation.particles, frame)
    }
    func testRepeatedPreviewCloseAndOverlayDisposeLeaveNoTimersAndWeakReferencesRelease() async throws {
        for _ in 0..<40 {
            weak var released: ParticleOverlay?
            do {
                let overlay = ParticleOverlay(); released = overlay
                try await overlay.prepare(configuration: configuration(), context: context()); overlay.play(); overlay.dispose()
                XCTAssertNil(overlay.timerFramesPerSecond)
            }
            XCTAssertNil(released)
        }
    }
    func testNativeDrawingsAreDistinctTransparentAndClickThrough() async throws {
        let folder = TestWorkspaceDirectory.make(".build/Module34/Snapshots").deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var images = Set<Data>()
        for preset in ParticlePreset.allCases {
            let overlay = ParticleOverlay(seed: 28); defer { overlay.dispose() }
            var options = ParticleOptions(); options.preset = preset; options.density = 0.65
            try await overlay.prepare(configuration: configuration(options), context: context(paused: true))
            let view = overlay.view
            XCTAssertFalse(view.isOpaque); XCTAssertNil(view.hitTest(.init(x: 20, y: 20)))
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:])); images.insert(data)
            var painted = 0, clear = 0
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
                    let alpha = bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 1
                    if alpha > 0.001 { painted += 1 }; if alpha < 0.001 { clear += 1 }
                }
            }
            XCTAssertGreaterThan(painted, 0, preset.rawValue); XCTAssertGreaterThan(clear, 0, preset.rawValue)
            try data.write(to: folder.appendingPathComponent(preset.rawValue + ".png"))
        }
        XCTAssertEqual(images.count, 12)
    }
    func testEditorWindowHasNoPreviewAndClosingLeavesSavedDesktop() async throws {
        let store = try store(), a = display(), registry = DisplayRegistry(discover: { [self.display()] }); registry.start()
        let manager = OverlayManager(store: store, registry: registry, readReduceMotion: { false }, makeSurface: { _ in ParticleTestSurface() })
        let desktop = ParticleOverlay(); manager.register(.particles) { _ in desktop }; manager.start()
        defer { manager.shutdown(); registry.stop() }
        let model = ParticleEditorModel(manager: manager, registry: registry, readReduceMotion: { false })
        let window = ParticleSettingsWindow(model: model); let native = window.show(activate: false)
        native.setFrameOrigin(.init(x: -5000, y: -5000))
        XCTAssertTrue(native.styleMask.contains(.fullSizeContentView)); XCTAssertEqual(native.titleVisibility, .hidden)
        XCTAssertLessThanOrEqual(native.frame.width, 400, "Only the settings column remains")
        model.selectDisplay(a.id); model.isEnabled = true; model.save()
        try await wait { manager.states.first?.lifecycle == .running }
        XCTAssertEqual(desktop.timerFramesPerSecond, 30)
        window.close(); XCTAssertFalse(desktop.isDisposed)
        XCTAssertNil(window.window); XCTAssertEqual(manager.states.first?.lifecycle, .running)
    }
    func testEditorLayoutInBothAppearancesProducesBoundedWindow() throws {
        let store = try store(), registry = DisplayRegistry(discover: { [self.display()] }); registry.start()
        let manager = OverlayManager(store: store, registry: registry, readReduceMotion: { false }, makeSurface: { _ in ParticleTestSurface() })
        manager.start(); defer { manager.shutdown(); registry.stop() }
        let folder = TestWorkspaceDirectory.make(".build/Module34/Snapshots").deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let model = ParticleEditorModel(manager: manager, registry: registry, readReduceMotion: { true })
            model.opened(); defer { model.closed() }
            let host = NSHostingView(rootView: ParticleSettingsView(model: model, manager: manager, registry: registry)
                .environment(\.locale, Locale(identifier: "zh-Hans")))
            let window = NSWindow(contentRect: .init(x: -5000, y: -5000, width: 340, height: 580), styleMask: [.titled], backing: .buffered, defer: false)
            defer { window.contentView = nil; window.close() }
            window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: appearance); window.contentView = host
            host.frame = .init(x: 0, y: 0, width: 340, height: 580); host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
            XCTAssertGreaterThan(bitmap.pixelsWide, 0); XCTAssertEqual(host.frame.width, 340)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("editor-\(name).png"))
        }
    }
}
