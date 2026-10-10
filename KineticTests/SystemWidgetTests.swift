import AppKit
import XCTest
@testable import Kinetic

enum WidgetMetricsFixture {
    static func snapshot(_ sample: Int = 1, cpu: Double = 37.5,
                         battery: SystemMetric<SystemBatteryMetrics> = .available(.init(chargePercent: 72, isCharging: true)),
                         gpu: SystemMetric<Double> = .unavailable(.unsupported)) -> SystemMetricsSnapshot {
        .init(sampledAt: Date(timeIntervalSince1970: Double(sample)),
            cpu: .available(.init(utilizationPercent: cpu, logicalProcessorCount: 12)),
            memory: .available(.init(physicalBytes: 16 << 30, freeBytes: 4 << 30, activeBytes: 5 << 30,
                inactiveBytes: 2 << 30, wiredBytes: 3 << 30, compressedBytes: 1 << 30, speculativeBytes: 128 << 20)),
            gpuUtilizationPercent: gpu,
            network: .available(.init(receivedBytesPerSecond: 2_048, sentBytesPerSecond: 1_024, interfaceCount: 2)),
            disk: .available(.init(totalBytes: 512 << 30, availableBytes: 128 << 30,
                readBytesPerSecond: .unavailable(.unsupported), writtenBytesPerSecond: .unavailable(.unsupported))),
            power: .available(.init(source: .external, isLowPowerModeEnabled: true, battery: battery)),
            thermal: .available(.fair), temperatureCelsius: .unavailable(.unsupported), fanRevolutionsPerMinute: .unavailable(.unsupported))
    }
    static func context(paused: Bool = false, size: CGSize = .init(width: 160, height: 160)) -> OverlayContext {
        .init(frame: .init(origin: .zero, size: size), backingScaleFactor: 2, maximumFramesPerSecond: 15, allowsAnimation: false, isPaused: paused)
    }
}

actor WidgetMetricsSampler: SystemMetricsSampling {
    private(set) var calls = 0
    func sample(resetBaselines: Bool) -> SystemMetricsSnapshot { calls += 1; return WidgetMetricsFixture.snapshot(calls) }
}
@MainActor
final class WidgetMetricsSchedule: SystemMetricsSchedule {
    let interval: TimeInterval
    var action: (@MainActor () -> Void)?
    init(_ interval: TimeInterval, _ action: @escaping @MainActor () -> Void) { self.interval = interval; self.action = action }
    func invalidate() { action = nil }
}
@MainActor
final class WidgetMetricsScheduler: SystemMetricsScheduling {
    private(set) var schedules: [WidgetMetricsSchedule] = []
    var active: [WidgetMetricsSchedule] { schedules.filter { $0.action != nil } }
    func schedule(every interval: TimeInterval, action: @escaping @MainActor () -> Void) -> any SystemMetricsSchedule {
        let schedule = WidgetMetricsSchedule(interval, action); schedules.append(schedule); return schedule
    }
    func fire() { active.forEach { $0.action?() } }
}

@MainActor
final class SystemWidgetTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() { roots.forEach { try? FileManager.default.removeItem(at: $0) }; super.tearDown() }
    private func storage() throws -> LibraryStorageLocation {
        let root = TestWorkspaceDirectory.make(".build/Module39-40/Fixtures")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); roots.append(root); return .init(rootURL: root)
    }
    private func setup() -> (SystemMetricsService, WidgetMetricsSampler, WidgetMetricsScheduler) {
        let sampler = WidgetMetricsSampler(), scheduler = WidgetMetricsScheduler()
        return (.init(sampler: sampler, scheduler: scheduler), sampler, scheduler)
    }
    private func wait(_ condition: @escaping @MainActor () async -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !(await condition()) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw WidgetBoardError.invalidLayout }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
    func testActualZeroCPUIsAValueAndUnavailableNeverBecomesZero() {
        let zero = SystemWidgetPresentation.make(kind: .cpu, snapshot: WidgetMetricsFixture.snapshot(cpu: 0))
        XCTAssertEqual(zero.value, "0%"); XCTAssertEqual(zero.fraction, 0); XCTAssertFalse(zero.isUnavailable)
        for reason in [SystemMetricUnavailable.warmingUp, .counterReset, .readFailed, .paused, .unsupported] {
            let absent = SystemWidgetPresentation.make(kind: .cpu, snapshot: .unavailable(reason))
            XCTAssertTrue(absent.isUnavailable); XCTAssertNil(absent.fraction); XCTAssertFalse(absent.value.contains("0"))
        }
        XCTAssertTrue(SystemWidgetPresentation.make(kind: .cpu, snapshot: WidgetMetricsFixture.snapshot(cpu: .nan)).isUnavailable)
    }
    func testMemoryLabelsRawVMCategoriesWithoutInventingTotalUsed() {
        let data = SystemWidgetPresentation.make(kind: .memory, snapshot: WidgetMetricsFixture.snapshot())
        XCTAssertEqual(data.value, "4 GiB"); XCTAssertEqual(data.rows.first?.value, "16 GiB")
        XCTAssertEqual(data.rows.first { $0.key == "systemWidget.compressed" }?.value, "1 GiB")
        XCTAssertEqual(data.rows.count, 6); XCTAssertNil(data.fraction)
        XCTAssertTrue(data.note.contains("Mach VM")); XCTAssertFalse(data.rows.contains { $0.key.lowercased().contains("used") })
    }
    func testNetworkAndDiskDoNotFabricateBandwidthOrIO() {
        let snapshot = WidgetMetricsFixture.snapshot(), network = SystemWidgetPresentation.make(kind: .network, snapshot: snapshot)
        XCTAssertEqual(network.value, "2 KiB/s"); XCTAssertEqual(network.rows[0].value, "1 KiB/s")
        XCTAssertEqual(network.rows[1].value, "2"); XCTAssertTrue(network.note.contains("重复"))
        let disk = SystemWidgetPresentation.make(kind: .disk, snapshot: snapshot)
        XCTAssertEqual(disk.value, "128 GiB"); XCTAssertEqual(disk.fraction, 0.25)
        XCTAssertEqual(disk.rows[1].value, WidgetDataFormat.text("widgetData.unavailable"))
        XCTAssertEqual(disk.rows[2].value, WidgetDataFormat.text("widgetData.unavailable"))
        XCTAssertEqual(WidgetDataFormat.rate(0), "0 B/s")
        XCTAssertEqual(WidgetDataFormat.rate(.infinity), WidgetDataFormat.text("widgetData.unavailable"))
    }
    func testPowerBatteryChargingAndThermalUseActualSnapshot() {
        let power = SystemWidgetPresentation.make(kind: .power, snapshot: WidgetMetricsFixture.snapshot())
        XCTAssertEqual(power.value, "72%"); XCTAssertEqual(power.fraction, 0.72)
        XCTAssertTrue(power.caption.contains(WidgetDataFormat.text("systemWidget.charging")))
        XCTAssertEqual(power.rows[0].value, WidgetDataFormat.text("systemWidget.on"))
        XCTAssertEqual(power.rows[1].value, WidgetDataFormat.text("systemWidget.thermal.fair"))
        let desktop = SystemWidgetPresentation.make(kind: .power, snapshot: WidgetMetricsFixture.snapshot(battery: .unavailable(.notPresent)))
        XCTAssertEqual(desktop.value, WidgetDataFormat.text("systemWidget.power.external")); XCTAssertNil(desktop.fraction)
        XCTAssertFalse(desktop.value.contains("0")); XCTAssertFalse(desktop.rows.contains { $0.key == "systemWidget.battery" })
        let empty = SystemWidgetPresentation.make(kind: .power, snapshot: .unavailable(.readFailed))
        XCTAssertTrue(empty.isUnavailable); XCTAssertFalse(empty.value.contains("0"))
    }
    func testOverviewUsesSameSnapshotAndDoesNotMakeUpTemperatureOrFan() {
        let snapshot = WidgetMetricsFixture.snapshot(), overview = SystemWidgetPresentation.make(kind: .systemOverview, snapshot: snapshot)
        XCTAssertEqual(overview.value, SystemWidgetPresentation.make(kind: .cpu, snapshot: snapshot).value)
        XCTAssertEqual(overview.rows[0].value, "4 GiB")
        for key in ["systemWidget.temperature", "systemWidget.fan"] {
            XCTAssertEqual(overview.rows.first { $0.key == key }?.value, WidgetDataFormat.text("widgetData.unavailable"))
        }
    }
    func testGPUOnlyUsesAnActualTypedReadingAndNeverInventsZero() {
        for value in [0.0, 65.0] {
            let gpu = SystemWidgetPresentation.make(kind: .gpu, snapshot: WidgetMetricsFixture.snapshot(gpu: .available(value)))
            XCTAssertFalse(gpu.isUnavailable); XCTAssertEqual(gpu.value, WidgetDataFormat.number(value) + "%")
            XCTAssertEqual(gpu.fraction, value / 100)
        }
        for value in [Double.nan, .infinity, -1, 101] {
            XCTAssertTrue(SystemWidgetPresentation.make(kind: .gpu, snapshot: WidgetMetricsFixture.snapshot(gpu: .available(value))).isUnavailable)
        }
        let unavailable = SystemWidgetPresentation.make(kind: .gpu, snapshot: WidgetMetricsFixture.snapshot())
        XCTAssertTrue(unavailable.isUnavailable); XCTAssertFalse(unavailable.value.contains("0"))
    }
    func testRegistrationIsLazyAndUnsupportedOnlyBoardHasNoSampling() async throws {
        let (service, sampler, scheduler) = setup(); defer { service.shutdown() }
        let registry = WidgetContentRegistry(); registry.registerSystemWidgets(service: service)
        XCTAssertEqual(service.subscriberCount, 0); XCTAssertTrue(scheduler.active.isEmpty)
        XCTAssertNil(try registry.make(.init(kind: .agentSession))); XCTAssertNil(try registry.make(.init(kind: .weather)))
        for kind in [WidgetKind.gpu, .processes, .aneMemory] {
            let config = WidgetConfiguration(kind: kind)
            let content = try XCTUnwrap(try registry.make(config) as? SystemWidgetContent); defer { content.dispose() }
            try content.update(configuration: config, context: WidgetMetricsFixture.context()); content.play()
            XCTAssertTrue(content.presentation.isUnavailable); XCTAssertFalse(content.presentation.value.contains("0"))
            XCTAssertFalse(content.presentation.note.isEmpty)
        }
        XCTAssertEqual(service.visibleSubscriberCount, 0); XCTAssertTrue(scheduler.active.isEmpty)
        let calls = await sampler.calls; XCTAssertEqual(calls, 0)
    }
    func testAllProvidersShareOneTimerAndIdenticalSnapshot() async throws {
        let (service, sampler, scheduler) = setup(); defer { service.shutdown() }
        var contents: [SystemWidgetContent] = []; defer { contents.forEach { $0.dispose() } }
        for _ in 0..<3 {
            for kind in SystemWidgetPresentation.kinds {
                let config = WidgetConfiguration(kind: kind), content = try SystemWidgetContent(configuration: config, service: service)
                contents.append(content); try content.update(configuration: config, context: WidgetMetricsFixture.context()); content.play()
            }
        }
        try await wait { service.snapshot.sampledAt != nil }
        XCTAssertEqual(service.visibleSubscriberCount, 18); XCTAssertEqual(scheduler.active.count, 1)
        let calls = await sampler.calls; XCTAssertEqual(calls, 1)
        for content in contents { XCTAssertEqual(content.snapshot, service.snapshot) }
        scheduler.fire(); try await wait { service.snapshot.sampledAt == Date(timeIntervalSince1970: 2) }
        for content in contents { XCTAssertEqual(content.snapshot, service.snapshot) }
        contents.forEach { $0.pause() }; XCTAssertEqual(service.visibleSubscriberCount, 0); XCTAssertTrue(scheduler.active.isEmpty)
        XCTAssertEqual(service.subscriberCount, 18)
        contents.forEach { $0.dispose() }; XCTAssertEqual(service.subscriberCount, 0)
    }
    func testPauseFreezesOneWidgetWhileSiblingContinuesAndResumeGetsLatest() async throws {
        let (service, _, scheduler) = setup(); defer { service.shutdown() }
        let config = WidgetConfiguration(kind: .cpu)
        let a = try SystemWidgetContent(configuration: config, service: service), b = try SystemWidgetContent(configuration: config, service: service)
        defer { a.dispose(); b.dispose() }
        for p in [a, b] { try p.update(configuration: config, context: WidgetMetricsFixture.context()); p.play() }
        try await wait { a.snapshot.sampledAt != nil }; a.pause(); let frozen = a.snapshot
        scheduler.fire(); try await wait { b.snapshot != frozen }
        XCTAssertEqual(a.snapshot, frozen); XCTAssertEqual(service.visibleSubscriberCount, 1)
        a.play(); XCTAssertEqual(a.snapshot, b.snapshot); XCTAssertEqual(service.visibleSubscriberCount, 2)
    }
    func testSafetyPauseKeepsLastRealFrameAndLowPowerUsesSharedCadence() async throws {
        let (service, _, scheduler) = setup(); defer { service.shutdown() }
        let config = WidgetConfiguration(kind: .cpu), content = try SystemWidgetContent(configuration: config, service: service)
        defer { content.dispose() }; try content.update(configuration: config, context: WidgetMetricsFixture.context()); content.play()
        try await wait { content.snapshot.sampledAt != nil }; let frozen = content.presentation
        service.updateSystemConditions(.init(screenLocked: true)); XCTAssertFalse(service.isSampling); XCTAssertEqual(content.presentation, frozen)
        try content.update(configuration: config, context: WidgetMetricsFixture.context(paused: true)); content.play()
        XCTAssertFalse(content.isPlaying); XCTAssertEqual(content.presentation, frozen)
        service.updateSystemConditions(.init(lowPowerMode: true))
        try content.update(configuration: config, context: WidgetMetricsFixture.context()); content.play()
        try await wait { service.snapshot.sampledAt != nil }
        XCTAssertEqual(scheduler.active.count, 1); XCTAssertEqual(scheduler.active.first?.interval, 5)
    }
    func testContinuousGeometrySettingsPreserveProviderAndLease() async throws {
        let (service, sampler, scheduler) = setup(); defer { service.shutdown() }
        var config = WidgetConfiguration(kind: .cpu), ctx = WidgetMetricsFixture.context()
        let content = try SystemWidgetContent(configuration: config, service: service); defer { content.dispose() }
        try content.update(configuration: config, context: ctx); content.play(); try await wait { content.snapshot.sampledAt != nil }
        let identity = ObjectIdentifier(content.displayView), snapshot = content.snapshot
        for i in 1...50 {
            config.scale = 0.5 + Double(i) / 50; config.customTitle = "CPU \(i)"; config.opacity = 0.8
            ctx.frame.size = .init(width: 160 * config.scale, height: 160 * config.scale)
            try content.update(configuration: config, context: ctx); content.play()
            XCTAssertEqual(ObjectIdentifier(content.displayView), identity); XCTAssertEqual(content.snapshot, snapshot)
        }
        XCTAssertEqual(service.subscriberCount, 1); XCTAssertEqual(scheduler.active.count, 1)
        let calls = await sampler.calls; XCTAssertEqual(calls, 1)
        config.kind = .memory; XCTAssertThrowsError(try content.update(configuration: config, context: ctx))
    }
    func testBoardRemoveAndCloseReleaseRealProvidersAndKeepOtherTiles() async throws {
        let (service, _, scheduler) = setup(), registry = WidgetContentRegistry(); defer { service.shutdown() }
        registry.registerSystemWidgets(service: service)
        let board = WidgetBoardOverlay(repository: .init(storage: try storage()), registry: registry); defer { board.dispose() }
        var layout = WidgetBoardLayout(widgets: [.init(kind: .cpu), .init(kind: .memory), .init(kind: .gpu)])
        let ctx = WidgetMetricsFixture.context(size: .init(width: 640, height: 400))
        try board.updatePreview(layout: layout, context: ctx); board.play()
        try await wait { service.snapshot.sampledAt != nil }
        let memoryID = layout.widgets[1].id, identity = board.contentIdentity(memoryID)
        layout.widgets.removeFirst(); try board.updatePreview(layout: layout, context: ctx)
        XCTAssertEqual(service.subscriberCount, 1); XCTAssertEqual(board.contentIdentity(memoryID), identity)
        board.pause(); XCTAssertFalse(service.isSampling); XCTAssertTrue(scheduler.active.isEmpty)
        board.play(); XCTAssertEqual(service.visibleSubscriberCount, 1)
        board.dispose(); board.dispose(); XCTAssertEqual(service.subscriberCount, 0); XCTAssertTrue(board.widgetIDs.isEmpty)
    }
    func testFortyProviderReleasesWithoutExplicitDisposeStopAllSampling() async throws {
        let (service, _, scheduler) = setup(); defer { service.shutdown() }
        for _ in 0..<40 {
            weak var released: SystemWidgetContent?
            do {
                let config = WidgetConfiguration(kind: .cpu), content = try SystemWidgetContent(configuration: config, service: service)
                released = content; try content.update(configuration: config, context: WidgetMetricsFixture.context()); content.play()
                try await wait { content.snapshot.sampledAt != nil }
            }
            try await wait { service.subscriberCount == 0 }
            XCTAssertNil(released); XCTAssertEqual(service.visibleSubscriberCount, 0); XCTAssertTrue(scheduler.active.isEmpty)
        }
    }
    func testNativeSmallMediumLargeTilesHaveRealDataAndPreserveGlassContainer() async throws {
        let (service, _, _) = setup(), registry = WidgetContentRegistry(); defer { service.shutdown() }
        registry.registerSystemWidgets(service: service)
        let original = NSApp.appearance; defer { NSApp.appearance = original }
        let folder = TestWorkspaceDirectory.make(".build/Module39-40/Snapshots").deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            for size in WidgetSize.allCases {
                let board = WidgetBoardOverlay(repository: .init(storage: try storage()), registry: registry)
                // Large enough for the grid to hold a large (2×2) tile.
                let window = NSWindow(contentRect: .init(x: -5000, y: -5000, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
                defer { board.dispose(); window.orderOut(nil); window.contentView = nil }
                window.appearance = NSAppearance(named: appearance); window.contentView = board.view
                var config = WidgetConfiguration(kind: size == .large ? .memory : .cpu); config.size = size
                try board.updatePreview(layout: .init(widgets: [config]), context: WidgetMetricsFixture.context(size: .init(width: 800, height: 600)))
                board.play(); try await wait { service.snapshot.sampledAt != nil }
                window.orderFront(nil); try await Task.sleep(nanoseconds: 150_000_000)
                let tile = try XCTUnwrap(board.view.subviews.first); tile.layoutSubtreeIfNeeded(); tile.displayIfNeeded()
                XCTAssertEqual(tile.frame.size, size.dimensions); XCTAssertTrue(tile.window === window)
                XCTAssertNotNil(board.contentIdentity(config.id)); XCTAssertNil(board.view.hitTest(.zero))
                let image = try XCTUnwrap(tile.bitmapImageRepForCachingDisplay(in: tile.bounds))
                tile.effectiveAppearance.performAsCurrentDrawingAppearance { tile.cacheDisplay(in: tile.bounds, to: image) }
                try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("system-\(name)-\(size.rawValue).png"))
            }
        }
    }
}
