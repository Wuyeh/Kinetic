import AppKit
import SwiftUI
import XCTest
@testable import Kinetic

@MainActor
private final class WidgetIntegrationSurface: OverlaySurface {
    var views: [UUID: NSView] = [:]
    func present(_ view: NSView, for id: UUID, display: DesktopDisplay) throws { views[id] = view }
    func remove(_ id: UUID) { views[id] = nil }
    func realign(_ display: DesktopDisplay) {}
    func setOrder(_ ids: [UUID]) {}
    func close() { views = [:] }
}

@MainActor
final class WeatherWidgetTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() { roots.forEach { try? FileManager.default.removeItem(at: $0) }; super.tearDown() }
    private func storage() throws -> LibraryStorageLocation {
        let root = TestWorkspaceDirectory.make(".build/Module39-40/Fixtures")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); roots.append(root); return .init(rootURL: root)
    }
    private func setup() throws -> (WeatherService, WeatherTestClient, WeatherTestLocation) {
        let client = WeatherTestClient(), location = WeatherTestLocation()
        let service = WeatherService(store: .init(storage: try storage(), now: { WeatherTestFixture.now }),
            client: client, location: location, now: { WeatherTestFixture.now })
        service.start(); return (service, client, location)
    }
    private func make(_ service: WeatherService) throws -> WeatherWidgetContent {
        let config = Kinetic.WidgetConfiguration(kind: .weather)
        let content = try WeatherWidgetContent(configuration: config, service: service, now: { WeatherTestFixture.now })
        try content.update(configuration: config, context: WidgetMetricsFixture.context()); return content
    }
    private func wait(_ condition: @escaping @MainActor () async -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !(await condition()) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw WidgetBoardError.invalidLayout }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
    func testOffAndUnavailableNeverCreateWeatherOrShowZero() {
        for reading in [WeatherReading(), .init(activity: .loading), .init(activity: .unavailable, message: "offline"),
                        .init(activity: .off, snapshot: WeatherTestFixture.snapshot())] {
            let data = WeatherWidgetPresentation.make(reading: reading, at: WeatherTestFixture.now)
            XCTAssertTrue(data.isUnavailable); XCTAssertEqual(data.value, "—"); XCTAssertNil(data.symbol)
            XCTAssertTrue(data.rows.isEmpty); XCTAssertNil(data.fraction)
        }
        XCTAssertEqual(WeatherWidgetPresentation.make(reading: .init(activity: .unavailable, message: "offline"), at: WeatherTestFixture.now).note, "offline")
    }
    func testRealConditionsAndNightIconsWithoutInventedSunnyFallback() throws {
        for (code, condition) in [(0, WeatherCondition.clear), (3, .cloudy), (45, .fog), (51, .drizzle), (61, .rain), (71, .snow), (95, .thunderstorm), (999, .unknown)] {
            var snapshot = WeatherTestFixture.snapshot(code: code); snapshot.isDay = false
            let data = WeatherWidgetPresentation.make(reading: .init(activity: .ready, snapshot: snapshot), at: WeatherTestFixture.now)
            XCTAssertFalse(data.isUnavailable); XCTAssertEqual(data.caption, snapshot.place.name)
            XCTAssertEqual(data.value, WidgetDataFormat.number(12.5) + " °C")
            XCTAssertEqual(data.rows[0].value, condition.title + " · " + WidgetDataFormat.text("weather.night"))
            XCTAssertEqual(data.symbol, WeatherWidgetPresentation.symbol(condition: condition, isDay: false))
            XCTAssertNotNil(NSImage(systemSymbolName: try XCTUnwrap(data.symbol), accessibilityDescription: nil))
            if condition == .unknown { XCTAssertEqual(data.symbol, "questionmark") }
        }
        XCTAssertEqual(WeatherWidgetPresentation.symbol(condition: .clear, isDay: true), "sun.max")
        XCTAssertEqual(WeatherWidgetPresentation.symbol(condition: .clear, isDay: false), "moon.stars")
    }
    func testWeatherRowsKeepActualUnitsTimestampAndProviderAttribution() {
        let snapshot = WeatherTestFixture.snapshot(), data = WeatherWidgetPresentation.make(reading: .init(activity: .ready, snapshot: snapshot), at: WeatherTestFixture.now)
        XCTAssertEqual(data.rows[1].value, "7 m/s · 270°"); XCTAssertEqual(data.rows[2].value, "1 mm")
        let formatter = DateFormatter(); formatter.locale = .autoupdatingCurrent
        formatter.timeZone = TimeZone(identifier: snapshot.place.timeZone); formatter.dateStyle = .short; formatter.timeStyle = .short
        XCTAssertEqual(data.rows[3].value, formatter.string(from: snapshot.observedAt))
        XCTAssertTrue(data.note.contains("Open-Meteo")); XCTAssertTrue(data.note.contains(WidgetDataFormat.text("weatherWidget.live")))
    }
    func testCachedExpiredAndLoadingReadingsRetainRealTemperatureWithHonestStatus() {
        let snapshot = WeatherTestFixture.snapshot()
        for age in [0.0, 46.0 * 60, 7.0 * 60 * 60] {
            let now = WeatherTestFixture.now.addingTimeInterval(age), cached = snapshot.cached(at: now)
            let data = WeatherWidgetPresentation.make(reading: .init(activity: .ready, snapshot: cached, message: "offline"), at: now)
            XCTAssertFalse(data.isUnavailable); XCTAssertEqual(data.value, WidgetDataFormat.number(snapshot.temperatureCelsius) + " °C")
            XCTAssertTrue(data.note.contains(age == 0 ? WidgetDataFormat.text("weatherWidget.cached") : WidgetDataFormat.text("weatherWidget.stale")))
            XCTAssertTrue(data.note.contains("offline")); XCTAssertFalse(data.note.contains(WidgetDataFormat.text("weatherWidget.live")))
        }
        let updating = WeatherWidgetPresentation.make(reading: .init(activity: .loading, snapshot: snapshot), at: WeatherTestFixture.now)
        XCTAssertFalse(updating.isUnavailable); XCTAssertTrue(updating.note.contains(WidgetDataFormat.text("weatherWidget.updating")))
        // Recompute age from the observation time; never trust an old isStale=false flag forever.
        let oldLive = WeatherWidgetPresentation.make(reading: .init(activity: .ready, snapshot: snapshot), at: WeatherTestFixture.now.addingTimeInterval(3_600))
        XCTAssertTrue(oldLive.note.contains(WidgetDataFormat.text("weatherWidget.stale")))
    }
    func testInvalidSnapshotIsNotRenderedAsRealWeather() {
        var snapshot = WeatherTestFixture.snapshot(); snapshot.temperatureCelsius = .nan
        let data = WeatherWidgetPresentation.make(reading: .init(activity: .ready, snapshot: snapshot), at: WeatherTestFixture.now)
        XCTAssertTrue(data.isUnavailable); XCTAssertEqual(data.value, "—"); XCTAssertNil(data.symbol)
    }
    func testWidgetCreationAndUpdatesDoNotEnableFetchLocateOrWrite() async throws {
        let (service, client, location) = try setup(); defer { service.shutdown() }
        let registry = WidgetContentRegistry(); registry.registerWeatherWidget(service: service)
        XCTAssertNil(try registry.make(.init(kind: .agentSession)))
        let content = try XCTUnwrap(try registry.make(.init(kind: .weather)) as? WeatherWidgetContent); defer { content.dispose() }
        for size in WidgetSize.allCases {
            var config = Kinetic.WidgetConfiguration(kind: .weather); config.size = size
            try content.update(configuration: config, context: WidgetMetricsFixture.context(size: size.dimensions)); content.play(); content.pause()
        }
        XCTAssertEqual(service.store.configuration.mode, .off); XCTAssertFalse(service.hasRefreshTimer)
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.store.fileURL.path))
        XCTAssertTrue(location.requests.isEmpty); let calls = await client.calls; XCTAssertTrue(calls.isEmpty)
    }
    func testManyWidgetsReadSameWeatherWithoutAdditionalQueriesAndSettingsKeepIdentity() async throws {
        let (service, client, location) = try setup(); defer { service.shutdown() }
        var widgets: [WeatherWidgetContent] = []; defer { widgets.forEach { $0.dispose() } }
        for _ in 0..<16 { let widget = try make(service); widgets.append(widget); widget.play() }
        try service.configure(.init(mode: .manual, manualPlace: WeatherTestFixture.place()))
        try await wait { service.reading.activity == .ready && service.reading.snapshot != nil && !service.isFetching }
        let calls = await client.calls; XCTAssertEqual(calls.count, 1); XCTAssertTrue(location.requests.isEmpty)
        for widget in widgets { XCTAssertEqual(widget.reading, service.reading) }
        let identity = ObjectIdentifier(widgets[0].displayView), snapshot = widgets[0].reading
        for i in 1...50 {
            var config = Kinetic.WidgetConfiguration(kind: .weather); config.scale = 0.5 + Double(i) / 50; config.opacity = 0.7
            try widgets[0].update(configuration: config, context: WidgetMetricsFixture.context(size: .init(width: 160 * config.scale, height: 160 * config.scale)))
            widgets[0].play(); XCTAssertEqual(widgets[0].reading, snapshot); XCTAssertEqual(ObjectIdentifier(widgets[0].displayView), identity)
        }
        let finalCalls = await client.calls; XCTAssertEqual(finalCalls.count, 1)
    }
    func testPauseFreezesWeatherWhileOtherWidgetUpdatesAndResumeReadsLatest() async throws {
        let (service, client, _) = try setup(); defer { service.shutdown() }
        let a = try make(service), b = try make(service); defer { a.dispose(); b.dispose() }; a.play(); b.play()
        try service.configure(.init(mode: .manual, manualPlace: WeatherTestFixture.place()))
        try await wait { a.reading.snapshot != nil && !service.isFetching }; a.pause(); let frozen = a.reading
        await client.setCode(0); service.refresh(); try await wait { !service.isFetching && b.reading.snapshot?.weatherCode == 0 }
        XCTAssertEqual(a.reading, frozen); XCTAssertNotEqual(a.reading, b.reading)
        try a.update(configuration: .init(kind: .weather), context: WidgetMetricsFixture.context(paused: true)); a.play(); XCTAssertFalse(a.isPlaying)
        try a.update(configuration: .init(kind: .weather), context: WidgetMetricsFixture.context()); a.play(); XCTAssertEqual(a.reading, b.reading)
        a.dispose(); a.dispose(); a.play(); XCTAssertFalse(a.isPlaying)
        XCTAssertThrowsError(try a.update(configuration: .init(kind: .weather), context: WidgetMetricsFixture.context()))
        XCTAssertTrue(b.isPlaying); XCTAssertTrue(service.isStarted)
    }
    func testNetworkFailureDisplaysSameCityCacheAndChangingCityNeverShowsPreviousWeather() async throws {
        let (service, client, _) = try setup(); defer { service.shutdown() }
        try service.store.saveSnapshot(WeatherTestFixture.snapshot(), system: false); await client.setFailure(.network)
        let widget = try make(service); defer { widget.dispose() }; widget.play()
        try service.configure(.init(mode: .manual, manualPlace: WeatherTestFixture.place()))
        try await wait { !service.isFetching && widget.reading.snapshot != nil }
        XCTAssertEqual(widget.reading.snapshot?.availability, .cached); XCTAssertFalse(widget.presentation.isUnavailable)
        XCTAssertTrue(widget.presentation.note.contains(WidgetDataFormat.text("weatherWidget.cached")))
        try service.configure(.init(mode: .manual, manualPlace: WeatherTestFixture.place("B")))
        XCTAssertNil(widget.reading.snapshot); try await wait { !service.isFetching }
        XCTAssertNil(widget.reading.snapshot); XCTAssertTrue(widget.presentation.isUnavailable); XCTAssertEqual(widget.presentation.value, "—")
        try service.configure(.init()); XCTAssertEqual(widget.reading.activity, .off); XCTAssertNil(widget.reading.snapshot)
    }
    func testFortyWeatherProviderReleasesNeverStopBorrowedService() async throws {
        let (service, client, _) = try setup(); defer { service.shutdown() }
        for _ in 0..<40 {
            weak var released: WeatherWidgetContent?
            do { let widget = try make(service); released = widget; widget.play(); widget.pause(); widget.play() }
            await Task.yield(); XCTAssertNil(released); XCTAssertTrue(service.isStarted)
        }
        let calls = await client.calls; XCTAssertTrue(calls.isEmpty); XCTAssertFalse(service.hasRefreshTimer)
    }
    func testSavedBoardsAndEditorSharePipelineDisconnectNeverRetargets() async throws {
        let root = try storage(), a = display("display-A"), b = display("display-B"); var connected = [a, b]
        let displays = DisplayRegistry(discover: { connected }); displays.start(); defer { displays.stop() }
        let sampler = WidgetMetricsSampler(), scheduler = WidgetMetricsScheduler()
        let metrics = SystemMetricsService(sampler: sampler, scheduler: scheduler); defer { metrics.shutdown() }
        let (weather, client, location) = try setup(); defer { weather.shutdown() }
        let registry = WidgetContentRegistry(); registry.registerSystemWidgets(service: metrics); registry.registerWeatherWidget(service: weather)
        let repository = WidgetLayoutRepository(storage: root)
        let manager = OverlayManager(store: .init(storage: root), registry: displays, readReduceMotion: { false }, makeSurface: { _ in WidgetIntegrationSurface() })
        manager.register(.widgets) { _ in WidgetBoardOverlay(repository: repository, registry: registry) }; manager.start(); defer { manager.shutdown() }
        var configs: [OverlayConfiguration] = []
        for target in [a, b] {
            let layout = WidgetBoardLayout(widgets: [.init(kind: .cpu), .init(kind: .weather)])
            let revision = try repository.write(layout, keeping: Set(configs.compactMap { try? WidgetBoardReference(configuration: $0).layoutID }))
            var config = OverlayConfiguration(kind: .widgets, displayID: target.id); config.isEnabled = true
            config = try WidgetBoardReference.applying(revision, to: config); configs.append(config); try manager.configure(config)
        }
        try await wait { manager.states.count == 2 && manager.states.allSatisfy { $0.lifecycle == .running } }
        XCTAssertEqual(metrics.visibleSubscriberCount, 2); XCTAssertEqual(scheduler.active.count, 1)
        // The display page preview (formerly the editor window's preview) shares the same sampling.
        let editor = WidgetBoardEditorModel(manager: manager, registry: displays, repository: repository, contents: registry, readReduceMotion: { false })
        let page = DisplayWidgetPreview(); defer { page.stop() }
        page.update(editor, layout: editor.draft(on: a.id).layout, context: editor.previewContext(on: a.id, visible: true), floating: [:])
        XCTAssertEqual(metrics.visibleSubscriberCount, 3); XCTAssertEqual(scheduler.active.count, 1)
        page.pause(); XCTAssertEqual(metrics.visibleSubscriberCount, 2)
        connected = [b]; displays.refresh()
        XCTAssertEqual(manager.states.first { $0.displayID == a.id }?.lifecycle, .waitingForDisplay)
        XCTAssertEqual(manager.states.first { $0.displayID == b.id }?.lifecycle, .running)
        XCTAssertEqual(metrics.visibleSubscriberCount, 1)
        connected = [a, b]; displays.refresh(); try await wait { manager.states.allSatisfy { $0.lifecycle == .running } }
        XCTAssertEqual(metrics.visibleSubscriberCount, 2)
        var paused = configs[0]; paused.isManuallyPaused = true; try manager.configure(paused)
        XCTAssertEqual(metrics.visibleSubscriberCount, 1)
        page.stop(); manager.shutdown(); XCTAssertEqual(metrics.subscriberCount, 0); XCTAssertTrue(scheduler.active.isEmpty)
        let calls = await client.calls; XCTAssertTrue(calls.isEmpty); XCTAssertTrue(location.requests.isEmpty)
    }
    private func display(_ id: String) -> DisplayDescriptor {
        .init(id: .init(id), name: id, desktop: .init(id: 1, frame: .init(x: -5000, y: -5000, width: 800, height: 600), backingScaleFactor: 2), isPersistent: true)
    }
    func testNativeDataContentSmallMediumLargeLightDarkLayoutWithoutGlassSnapshotAssumptions() throws {
        let folder = TestWorkspaceDirectory.make(".build/Module39-40/Snapshots").deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let reading = WeatherReading(activity: .ready, snapshot: WeatherTestFixture.snapshot())
        for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
            for kind in [WidgetKind.weather, .cpu, .memory, .power] {
              for size in WidgetSize.allCases {
                let config = Kinetic.WidgetConfiguration(kind: kind, size: size)
                let presentation = kind == .weather ? WeatherWidgetPresentation.make(reading: reading, at: WeatherTestFixture.now)
                    : SystemWidgetPresentation.make(kind: kind, snapshot: WidgetMetricsFixture.snapshot())
                let state = WidgetDataViewState(configuration: config, presentation: presentation)
                let dimensions = size.dimensions
                let content = WidgetDataView(state: state).frame(width: dimensions.width - 28, height: dimensions.height - 52)
                    .padding(14).frame(width: dimensions.width, height: dimensions.height)
                    .background(scheme == .dark ? Color(nsColor: .darkGray) : Color.white)
                    .environment(\.colorScheme, scheme).environment(\.locale, Locale(identifier: "zh_Hans"))
                let renderer = ImageRenderer(content: content); renderer.scale = 2
                let image = try XCTUnwrap(renderer.cgImage); XCTAssertEqual(image.width, Int(dimensions.width * 2)); XCTAssertEqual(image.height, Int(dimensions.height * 2))
                let bitmap = NSBitmapImageRep(cgImage: image)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("\(kind.rawValue)-data-\(name)-\(size.rawValue).png"))
              }
            }
        }
    }
}
