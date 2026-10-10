import AppKit
import Combine
import XCTest
@testable import Kinetic

private enum MetricsTestError: Error { case deadline }
private enum MetricsFixture {
    static func raw(_ time: Double = 10, user: UInt64 = 10, system: UInt64 = 20, idle: UInt64 = 70,
                    nice: UInt64 = 0, cores: Int = 8, received: UInt64 = 100, sent: UInt64 = 200,
                    index: UInt32 = 1) -> SystemMetricsRawSample {
        .init(date: Date(timeIntervalSince1970: time), uptime: time,
              cpu: .available(.init(user: user, system: system, idle: idle, nice: nice, processorCount: cores)),
              memory: .available(.init(physicalBytes: 1_000, freeBytes: 100, activeBytes: 200, inactiveBytes: 300,
                                      wiredBytes: 100, compressedBytes: 50, speculativeBytes: 10)),
              network: .available(["test-interface": .init(index: index, received: received, sent: sent)]),
              disk: .available(.init(totalBytes: 10_000, availableBytes: 4_000,
                                    readBytesPerSecond: .unavailable(.unsupported), writtenBytesPerSecond: .unavailable(.unsupported))),
              power: .available(.init(source: .external, isLowPowerModeEnabled: false, battery: .unavailable(.notPresent))),
              thermal: .available(.nominal))
    }
    static func replacing(_ raw: SystemMetricsRawSample, cpu: SystemMetric<SystemCPUTicks>? = nil,
                          network: SystemMetric<[String: SystemInterfaceCounters]>? = nil) -> SystemMetricsRawSample {
        .init(date: raw.date, uptime: raw.uptime, cpu: cpu ?? raw.cpu, memory: raw.memory,
              network: network ?? raw.network, disk: raw.disk, power: raw.power, thermal: raw.thermal)
    }
    static func snapshot(_ time: Double = 10) -> SystemMetricsSnapshot {
        var accumulator = SystemMetricsAccumulator(); return accumulator.consume(raw(time))
    }
}

@MainActor private final class MetricsTestSchedule: SystemMetricsSchedule {
    let interval: Double
    var isValid = true
    private var action: (@MainActor () -> Void)?
    init(_ interval: Double, _ action: @escaping @MainActor () -> Void) { self.interval = interval; self.action = action }
    func fire() { if isValid { action?() } }
    func invalidate() { isValid = false; action = nil }
}
@MainActor private final class MetricsTestScheduler: SystemMetricsScheduling {
    private(set) var schedules: [MetricsTestSchedule] = []
    var active: [MetricsTestSchedule] { schedules.filter(\.isValid) }
    func schedule(every interval: TimeInterval, action: @escaping @MainActor () -> Void) -> any SystemMetricsSchedule {
        let schedule = MetricsTestSchedule(interval, action); schedules.append(schedule); return schedule
    }
    func fire() { active.forEach { $0.fire() } }
}
private actor MetricsTestSampler: SystemMetricsSampling {
    private(set) var resets: [Bool] = []
    func sample(resetBaselines: Bool) -> SystemMetricsSnapshot {
        resets.append(resetBaselines); return MetricsFixture.snapshot(Double(resets.count))
    }
}
private actor MetricsGateSampler: SystemMetricsSampling {
    private(set) var resets: [Bool] = []
    private var waiting: [Int: CheckedContinuation<SystemMetricsSnapshot, Never>] = [:]
    private(set) var maximumInFlight = 0
    func sample(resetBaselines: Bool) async -> SystemMetricsSnapshot {
        resets.append(resetBaselines); let number = resets.count
        return await withCheckedContinuation {
            waiting[number] = $0; maximumInFlight = max(maximumInFlight, waiting.count)
        }
    }
    func resolve(_ number: Int) { waiting.removeValue(forKey: number)?.resume(returning: MetricsFixture.snapshot(Double(number))) }
}

@MainActor private final class MetricsMonitorProbe: SmartPauseSystemProbe {
    var isScreenLocked = false, isDisplayAsleep = false, isFullScreenAppActive = false
    var isBatteryLow = false, isLowPowerModeEnabled = false, isOnBatteryPower = false
    func startObservingPowerSource(_ onChange: @escaping @MainActor () -> Void) {}
    func stopObservingPowerSource() {}
}

@MainActor
final class SystemMetricsTests: XCTestCase {
    private func wait(_ condition: @escaping @MainActor () async -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !(await condition()) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw MetricsTestError.deadline }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }
    private func setup() -> (SystemMetricsService, MetricsTestSampler, MetricsTestScheduler) {
        let sampler = MetricsTestSampler(), scheduler = MetricsTestScheduler()
        return (.init(sampler: sampler, scheduler: scheduler), sampler, scheduler)
    }

    func testFirstSampleHasNoFabricatedCPUOrNetworkRate() {
        var accumulator = SystemMetricsAccumulator(); let snapshot = accumulator.consume(MetricsFixture.raw())
        XCTAssertEqual(snapshot.cpu, .unavailable(.warmingUp)); XCTAssertEqual(snapshot.network, .unavailable(.warmingUp))
        XCTAssertEqual(snapshot.memory.value?.physicalBytes, 1_000); XCTAssertEqual(snapshot.thermal, .available(.nominal))
    }
    func testCPUDeltaIsNormalizedAcrossAllCoresAndIncludesNice() throws {
        var accumulator = SystemMetricsAccumulator(); _ = accumulator.consume(MetricsFixture.raw())
        let result = accumulator.consume(MetricsFixture.raw(12, user: 20, system: 30, idle: 140, nice: 10))
        let cpu = try XCTUnwrap(result.cpu.value)
        XCTAssertEqual(cpu.utilizationPercent, 30, accuracy: 0.00001); XCTAssertEqual(cpu.logicalProcessorCount, 8)
    }
    func testTrueIdleAndNoNetworkTrafficCanReportAvailableZero() throws {
        var accumulator = SystemMetricsAccumulator(); _ = accumulator.consume(MetricsFixture.raw())
        let result = accumulator.consume(MetricsFixture.raw(11, idle: 170))
        XCTAssertEqual(result.cpu.value?.utilizationPercent, 0); XCTAssertEqual(result.network.value?.receivedBytesPerSecond, 0)
        XCTAssertEqual(result.network.value?.sentBytesPerSecond, 0)
        XCTAssertNotEqual(result.cpu, .unavailable(.unsupported))
    }
    func testNetworkRatesUseMonotonicElapsedTime() throws {
        var accumulator = SystemMetricsAccumulator(); _ = accumulator.consume(MetricsFixture.raw())
        let result = accumulator.consume(MetricsFixture.raw(12.5, received: 1_100, sent: 700))
        let network = try XCTUnwrap(result.network.value)
        XCTAssertEqual(network.receivedBytesPerSecond, 400, accuracy: 0.00001)
        XCTAssertEqual(network.sentBytesPerSecond, 200, accuracy: 0.00001); XCTAssertEqual(network.interfaceCount, 1)
    }
    func testCounterWrapOrResetProducesUnavailableThenRecovers() {
        var accumulator = SystemMetricsAccumulator(); _ = accumulator.consume(MetricsFixture.raw())
        let reset = accumulator.consume(MetricsFixture.raw(11, user: 1, received: 1))
        XCTAssertEqual(reset.cpu, .unavailable(.counterReset)); XCTAssertEqual(reset.network, .unavailable(.counterReset))
        let next = accumulator.consume(MetricsFixture.raw(12, user: 11, received: 101))
        XCTAssertNotNil(next.cpu.value); XCTAssertEqual(next.network.value?.receivedBytesPerSecond, 100)
    }
    func testResumeAndLongGapsRequireFreshBaselines() {
        for reset in [false, true] {
            var accumulator = SystemMetricsAccumulator(); _ = accumulator.consume(MetricsFixture.raw())
            let result = accumulator.consume(MetricsFixture.raw(reset ? 11 : 21, user: 100, received: 10_000), resetBaselines: reset)
            XCTAssertEqual(result.cpu, .unavailable(.warmingUp)); XCTAssertEqual(result.network, .unavailable(.warmingUp))
        }
    }
    func testInvalidElapsedTimeNeverCreatesInfinityOrNegativeRates() {
        for time in [10.0, 9, .nan, .infinity] {
            var accumulator = SystemMetricsAccumulator(); _ = accumulator.consume(MetricsFixture.raw())
            let result = accumulator.consume(MetricsFixture.raw(time, user: 20, received: 200))
            XCTAssertEqual(result.cpu, .unavailable(.warmingUp)); XCTAssertEqual(result.network, .unavailable(.warmingUp))
        }
    }
    func testProcessorCountAndInterfaceIdentityChangesResetOnlyDeltas() {
        var accumulator = SystemMetricsAccumulator(); _ = accumulator.consume(MetricsFixture.raw())
        let result = accumulator.consume(MetricsFixture.raw(11, user: 20, cores: 12, received: 200, index: 2))
        XCTAssertEqual(result.cpu, .unavailable(.warmingUp)); XCTAssertEqual(result.network, .unavailable(.warmingUp))
        XCTAssertEqual(result.memory.value?.activeBytes, 200)
    }
    func testLinkRemovalOrAdditionDoesNotCreateBandwidthSpike() {
        var accumulator = SystemMetricsAccumulator(); _ = accumulator.consume(MetricsFixture.raw())
        let raw = MetricsFixture.replacing(MetricsFixture.raw(11), network: .available(["other": .init(index: 9, received: 8_000_000, sent: 8_000_000)]))
        XCTAssertEqual(accumulator.consume(raw).network, .unavailable(.warmingUp))
        XCTAssertEqual(accumulator.consume(MetricsFixture.replacing(MetricsFixture.raw(12), network: .available([:]))).network, .unavailable(.notPresent))
    }
    func testReadFailureIsNotZeroAndDoesNotBridgeAcrossMissingSamples() {
        var accumulator = SystemMetricsAccumulator(); _ = accumulator.consume(MetricsFixture.raw())
        let failure = accumulator.consume(MetricsFixture.replacing(MetricsFixture.raw(11), cpu: .unavailable(.readFailed), network: .unavailable(.readFailed)))
        XCTAssertEqual(failure.cpu, .unavailable(.readFailed)); XCTAssertEqual(failure.network, .unavailable(.readFailed))
        let resumed = accumulator.consume(MetricsFixture.raw(12, user: 20, received: 200))
        XCTAssertEqual(resumed.cpu, .unavailable(.warmingUp)); XCTAssertEqual(resumed.network, .unavailable(.warmingUp))
    }
    func testUnsupportedHardwareMetricsAreExplicitAndDoNotClaimZero() {
        let result = MetricsFixture.snapshot()
        XCTAssertEqual(result.gpuUtilizationPercent, .unavailable(.unsupported))
        XCTAssertEqual(result.temperatureCelsius, .unavailable(.unsupported)); XCTAssertEqual(result.fanRevolutionsPerMinute, .unavailable(.unsupported))
        XCTAssertEqual(result.disk.value?.readBytesPerSecond, .unavailable(.unsupported))
        XCTAssertEqual(result.disk.value?.writtenBytesPerSecond, .unavailable(.unsupported))
        XCTAssertEqual(result.power.value?.battery, .unavailable(.notPresent))
    }
    func testLargeCountersDoNotOverflowOrLeakInvalidRates() {
        var accumulator = SystemMetricsAccumulator(); _ = accumulator.consume(MetricsFixture.raw(user: 0, system: 0, idle: 0))
        let result = accumulator.consume(MetricsFixture.raw(11, user: .max, system: .max, idle: .max))
        XCTAssertEqual(result.cpu.value?.utilizationPercent ?? -1, 200.0 / 3.0, accuracy: 0.00001)
    }

    func testDefaultAndInvisibleSubscriptionsDoNoSampling() async throws {
        let (service, sampler, scheduler) = setup(); defer { service.shutdown() }
        let lease = service.subscribe(isVisible: false); defer { lease.cancel() }
        await Task.yield(); let calls = await sampler.resets
        XCTAssertTrue(calls.isEmpty); XCTAssertTrue(scheduler.schedules.isEmpty); XCTAssertFalse(service.isSampling)
        XCTAssertEqual(service.snapshot, .unavailable(.noVisibleSubscribers))
    }
    func testManyWidgetsShareOneTimerAndOneSnapshot() async throws {
        let (service, sampler, scheduler) = setup(); defer { service.shutdown() }
        let leases = (0..<32).map { _ in service.subscribe() }; defer { leases.forEach { $0.cancel() } }
        try await wait { service.snapshot.sampledAt != nil }
        XCTAssertEqual(service.visibleSubscriberCount, 32); XCTAssertEqual(scheduler.active.count, 1)
        var calls = await sampler.resets; XCTAssertEqual(calls, [true])
        scheduler.fire(); try await wait { service.snapshot.sampledAt == Date(timeIntervalSince1970: 2) }
        calls = await sampler.resets; XCTAssertEqual(calls, [true, false]); XCTAssertEqual(scheduler.active.count, 1)
    }
    func testHiddenLastConsumerStopsAndResumeUsesFreshBaseline() async throws {
        let (service, sampler, scheduler) = setup(); defer { service.shutdown() }
        let a = service.subscribe(), b = service.subscribe(); defer { a.cancel(); b.cancel() }
        try await wait { service.snapshot.sampledAt != nil }
        a.setVisible(false); XCTAssertTrue(service.isSampling)
        b.setVisible(false); XCTAssertFalse(service.isSampling); XCTAssertTrue(scheduler.active.isEmpty)
        XCTAssertEqual(service.snapshot, .unavailable(.noVisibleSubscribers)); scheduler.fire(); await Task.yield()
        a.setVisible(true); try await wait { service.snapshot.sampledAt == Date(timeIntervalSince1970: 2) }
        let calls = await sampler.resets; XCTAssertEqual(calls, [true, true])
    }
    func testSleepLockCriticalPressureStopEvenWithVisibleWidgets() async throws {
        for condition in 0..<5 {
            let (service, sampler, scheduler) = setup(); let lease = service.subscribe()
            try await wait { service.snapshot.sampledAt != nil }
            var state = SmartPauseConditions()
            switch condition { case 0: state.screenLocked = true; case 1: state.displayAsleep = true; case 2: state.systemAsleep = true
            case 3: state.criticalThermal = true; default: state.criticalMemory = true }
            service.updateSystemConditions(state)
            XCTAssertFalse(service.isSampling); XCTAssertTrue(scheduler.active.isEmpty); XCTAssertEqual(service.snapshot, .unavailable(.paused))
            service.updateSystemConditions(.init()); try await wait { service.snapshot.sampledAt == Date(timeIntervalSince1970: 2) }
            let calls = await sampler.resets; XCTAssertEqual(calls, [true, true]); lease.cancel(); service.shutdown()
        }
    }
    func testLowPowerCadenceChangesWithoutAddingTimersOrRestartingBaselines() async throws {
        let (service, sampler, scheduler) = setup(); defer { service.shutdown() }
        let lease = service.subscribe(); defer { lease.cancel() }; try await wait { service.snapshot.sampledAt != nil }
        var state = SmartPauseConditions(); state.lowPowerMode = true; service.updateSystemConditions(state)
        XCTAssertEqual(scheduler.active.count, 1); XCTAssertEqual(scheduler.active.first?.interval, 5)
        scheduler.fire(); try await wait { service.snapshot.sampledAt == Date(timeIntervalSince1970: 2) }
        service.updateSystemConditions(.init()); XCTAssertEqual(scheduler.active.count, 1); XCTAssertEqual(scheduler.active.first?.interval, 1)
        let calls = await sampler.resets; XCTAssertEqual(calls, [true, false])
    }
    func testSlowSamplerIsSingleFlightAndLateCancelledResultCannotPublish() async throws {
        let sampler = MetricsGateSampler(), scheduler = MetricsTestScheduler()
        let service = SystemMetricsService(sampler: sampler, scheduler: scheduler), lease = service.subscribe()
        defer { lease.cancel(); service.shutdown() }
        try await wait { await sampler.resets.count == 1 }
        for _ in 0..<50 { scheduler.fire() }; await Task.yield()
        var calls = await sampler.resets; XCTAssertEqual(calls, [true])
        lease.setVisible(false); lease.setVisible(true)
        for _ in 0..<50 { scheduler.fire() }; await Task.yield()
        calls = await sampler.resets; XCTAssertEqual(calls, [true]); XCTAssertNil(service.snapshot.sampledAt)
        await sampler.resolve(1); try await wait { await sampler.resets.count == 2 }
        XCTAssertNil(service.snapshot.sampledAt, "The cancelled generation must never overwrite the new one")
        await sampler.resolve(2); try await wait { service.snapshot.sampledAt == Date(timeIntervalSince1970: 2) }
        let maximum = await sampler.maximumInFlight; XCTAssertEqual(maximum, 1)
        calls = await sampler.resets; XCTAssertEqual(calls, [true, true])
    }
    func testShutdownIgnoresPendingResultAndCannotRestart() async throws {
        let sampler = MetricsGateSampler(), scheduler = MetricsTestScheduler()
        let service = SystemMetricsService(sampler: sampler, scheduler: scheduler), lease = service.subscribe()
        try await wait { await sampler.resets.count == 1 }; service.shutdown(); service.shutdown()
        await sampler.resolve(1); await Task.yield(); await Task.yield()
        lease.setVisible(true); let after = service.subscribe(); defer { after.cancel(); lease.cancel() }
        XCTAssertEqual(service.snapshot, .unavailable(.disposed)); XCTAssertTrue(scheduler.active.isEmpty)
        XCTAssertEqual(service.subscriberCount, 0); XCTAssertFalse(service.isSampling)
    }
    func testDroppedLeaseReleasesSamplingWithoutKeepingServiceAlive() async throws {
        let (service, _, scheduler) = setup(); defer { service.shutdown() }
        var lease: SystemMetricsSubscription? = service.subscribe(); weak var weakLease = lease
        try await wait { service.snapshot.sampledAt != nil }; lease = nil
        try await wait { service.subscriberCount == 0 }; XCTAssertNil(weakLease); XCTAssertTrue(scheduler.active.isEmpty)
    }
    func testRepeatedServiceAndLeaseDisposalLeavesNoTimerOrRetainedOwner() async throws {
        for _ in 0..<40 {
            let scheduler = MetricsTestScheduler(); var service: SystemMetricsService? = .init(sampler: MetricsTestSampler(), scheduler: scheduler)
            weak var weakService = service
            var lease: SystemMetricsSubscription? = service?.subscribe()
            try await wait { service?.snapshot.sampledAt != nil }; service = nil
            try await wait { weakService == nil && scheduler.active.isEmpty }
            lease?.cancel(); lease = nil
        }
    }
    func testCombineConsumersReceiveSameImmutableSnapshot() async throws {
        let (service, _, _) = setup(); defer { service.shutdown() }
        var first: [SystemMetricsSnapshot] = [], second: [SystemMetricsSnapshot] = []
        let one = service.$snapshot.sink { first.append($0) }, two = service.$snapshot.sink { second.append($0) }
        defer { one.cancel(); two.cancel() }; let lease = service.subscribe(); defer { lease.cancel() }
        try await wait { service.snapshot.sampledAt != nil }; XCTAssertEqual(first, second); XCTAssertEqual(first.count, 2)
    }
    func testRealTimerPipelineStopsWhenHiddenAndResetsOnResume() async throws {
        let service = SystemMetricsService.live(), lease = service.subscribe()
        defer { lease.cancel(); service.shutdown() }
        try await wait { service.snapshot.sampledAt != nil }; let firstDate = service.snapshot.sampledAt
        XCTAssertEqual(service.snapshot.cpu, .unavailable(.warmingUp))
        try await wait { service.snapshot.sampledAt != firstDate }
        XCTAssertNotNil(service.snapshot.cpu.value)
        lease.setVisible(false); XCTAssertFalse(service.isSampling)
        try await Task.sleep(nanoseconds: 1_100_000_000)
        XCTAssertEqual(service.snapshot, .unavailable(.noVisibleSubscribers))
        lease.setVisible(true); try await wait { service.snapshot.sampledAt != nil }
        XCTAssertEqual(service.snapshot.cpu, .unavailable(.warmingUp))
    }
    func testMonitorSleepAndWakeNotificationsControlOnlyMetricsLifecycle() async throws {
        let workspace = NotificationCenter(), distributed = NotificationCenter(), app = NotificationCenter()
        let monitor = SmartPauseMonitor(probe: MetricsMonitorProbe(), workspaceNotifications: workspace,
            distributedNotifications: distributed, applicationNotifications: app,
            desktopWindowIdentifier: .init("KineticTests.Metrics.NoDesktop"), onChange: { _ in })
        let (service, sampler, scheduler) = setup()
        monitor.start(); service.start(monitor: monitor)
        let lease = service.subscribe(); defer { lease.cancel(); service.shutdown(); monitor.stop() }
        try await wait { service.snapshot.sampledAt != nil }
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertEqual(service.snapshot, .unavailable(.paused)); XCTAssertTrue(scheduler.active.isEmpty)
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await wait { service.snapshot.sampledAt == Date(timeIntervalSince1970: 2) }
        let calls = await sampler.resets; XCTAssertEqual(calls, [true, true])
        service.shutdown()
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertFalse(service.isSampling); XCTAssertEqual(service.snapshot, .unavailable(.disposed))
    }
    func testNativePublicAPIsInsideSandboxProduceMeasuredData() async throws {
        let sampler = LiveSystemMetricsSampler()
        let first = await sampler.sample(resetBaselines: true)
        try await Task.sleep(nanoseconds: 150_000_000)
        let second = await sampler.sample(resetBaselines: false)
        let cpu = try XCTUnwrap(second.cpu.value), memory = try XCTUnwrap(second.memory.value), disk = try XCTUnwrap(second.disk.value)
        XCTAssertTrue((0...100).contains(cpu.utilizationPercent)); XCTAssertGreaterThan(cpu.logicalProcessorCount, 0)
        XCTAssertEqual(memory.physicalBytes, ProcessInfo.processInfo.physicalMemory); XCTAssertGreaterThan(memory.physicalBytes, 0)
        XCTAssertLessThanOrEqual(memory.freeBytes, memory.physicalBytes); XCTAssertGreaterThan(disk.totalBytes, 0)
        XCTAssertLessThanOrEqual(disk.availableBytes, disk.totalBytes); XCTAssertEqual(first.cpu, .unavailable(.warmingUp))
        if let network = second.network.value { XCTAssertGreaterThanOrEqual(network.receivedBytesPerSecond, 0); XCTAssertGreaterThanOrEqual(network.sentBytesPerSecond, 0) }
        func reading<T>(_ metric: SystemMetric<T>, value: (T) -> Any) -> [String: Any] {
            switch metric { case .available(let sample): return ["availability": "available", "value": value(sample)]
            case .unavailable(let reason): return ["availability": "unavailable", "reason": reason.rawValue] }
        }
        var durations: [Double] = []
        for _ in 0..<20 { let start = ProcessInfo.processInfo.systemUptime; _ = await sampler.sample(resetBaselines: false); durations.append((ProcessInfo.processInfo.systemUptime - start) * 1_000) }
        let report: [String: Any] = [
            "sampledAt": ISO8601DateFormatter().string(from: try XCTUnwrap(second.sampledAt)),
            "cpu": ["utilizationPercent": cpu.utilizationPercent, "logicalProcessorCount": cpu.logicalProcessorCount],
            "memory": ["physicalBytes": memory.physicalBytes, "freeBytes": memory.freeBytes, "activeBytes": memory.activeBytes,
                       "inactiveBytes": memory.inactiveBytes, "wiredBytes": memory.wiredBytes, "compressedBytes": memory.compressedBytes],
            "network": reading(second.network) { ["receivedBytesPerSecond": $0.receivedBytesPerSecond, "sentBytesPerSecond": $0.sentBytesPerSecond, "interfaceCount": $0.interfaceCount] },
            "disk": ["totalBytes": disk.totalBytes, "availableBytes": disk.availableBytes, "throughput": "unsupported"],
            "power": reading(second.power) { ["source": $0.source.rawValue, "lowPowerMode": $0.isLowPowerModeEnabled,
                "battery": reading($0.battery) { ["chargePercent": $0.chargePercent, "isCharging": $0.isCharging] }] },
            "thermal": reading(second.thermal) { $0.rawValue }, "gpu": "unsupported", "temperature": "unsupported", "fan": "unsupported",
            "readMilliseconds": ["mean": durations.reduce(0, +) / Double(durations.count), "maximum": durations.max() ?? 0, "count": durations.count]
        ]
        let root = TestWorkspaceDirectory.make(".build/Module38/Live")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("sandbox-sample.json"))
        print("Module 38 real sandbox sample: \(root.appendingPathComponent("sandbox-sample.json").path)")
    }
}
