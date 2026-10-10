import Combine
import Foundation

@MainActor
protocol SystemMetricsSchedule: AnyObject { func invalidate() }
@MainActor
protocol SystemMetricsScheduling {
    func schedule(every interval: TimeInterval, action: @escaping @MainActor () -> Void) -> any SystemMetricsSchedule
}

@MainActor
struct LiveSystemMetricsScheduler: SystemMetricsScheduling {
    func schedule(every interval: TimeInterval, action: @escaping @MainActor () -> Void) -> any SystemMetricsSchedule {
        LiveSystemMetricsSchedule(interval: interval, action: action)
    }
}

@MainActor
private final class LiveSystemMetricsSchedule: SystemMetricsSchedule {
    private let timer: Timer
    init(interval: TimeInterval, action: @escaping @MainActor () -> Void) {
        timer = Timer(timeInterval: interval, repeats: true) { _ in MainActor.assumeIsolated { action() } }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
    }
    func invalidate() { timer.invalidate() }
    deinit { timer.invalidate() }
}

/// Future widgets acquire one lease each; hiding/pausing a widget makes its lease invisible.
/// A lease never owns the service and cannot keep sampling alive after it is released.
@MainActor
final class SystemMetricsSubscription {
    private weak var service: SystemMetricsService?
    private let id: UUID
    fileprivate init(service: SystemMetricsService, id: UUID) { self.service = service; self.id = id }
    func setVisible(_ visible: Bool) { service?.setVisible(visible, for: id) }
    func cancel() { service?.unsubscribe(id); service = nil }
    deinit {
        let id = id, service = service
        Task { @MainActor [weak service] in service?.unsubscribe(id) }
    }
}

/// Module 38: one App-owned pipeline; no metrics UI, per-widget sampler or wallpaper control.
@MainActor
final class SystemMetricsService: ObservableObject {
    static let normalInterval: TimeInterval = 1
    static let energySavingInterval: TimeInterval = 5
    @Published private(set) var snapshot = SystemMetricsSnapshot.unavailable(.noVisibleSubscribers)
    private(set) var isSampling = false
    private(set) var isDisposed = false
    var visibleSubscriberCount: Int { subscribers.values.filter { $0 }.count }
    var subscriberCount: Int { subscribers.count }
    private let sampler: any SystemMetricsSampling
    private let scheduler: any SystemMetricsScheduling
    private var subscribers: [UUID: Bool] = [:]
    private var schedule: (any SystemMetricsSchedule)?
    private var sampleTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var needsBaselineReset = true
    private var suspended = false
    private var interval = normalInterval
    private var monitorSubscription: AnyCancellable?

    init(sampler: any SystemMetricsSampling, scheduler: any SystemMetricsScheduling) {
        self.sampler = sampler; self.scheduler = scheduler
    }
    static func live() -> SystemMetricsService {
        .init(sampler: LiveSystemMetricsSampler(), scheduler: LiveSystemMetricsScheduler())
    }

    func start(monitor: SmartPauseMonitor?) {
        guard !isDisposed, monitorSubscription == nil else { return }
        monitorSubscription = monitor?.$conditions.removeDuplicates().sink { [weak self] in self?.updateSystemConditions($0) }
    }

    func subscribe(isVisible: Bool = true) -> SystemMetricsSubscription {
        let id = UUID()
        if !isDisposed { subscribers[id] = isVisible; reconcile() }
        return .init(service: self, id: id)
    }
    fileprivate func setVisible(_ visible: Bool, for id: UUID) {
        guard !isDisposed, let current = subscribers[id], current != visible else { return }
        subscribers[id] = visible; reconcile()
    }
    fileprivate func unsubscribe(_ id: UUID) {
        guard subscribers.removeValue(forKey: id) != nil else { return }; reconcile()
    }

    func updateSystemConditions(_ conditions: SmartPauseConditions) {
        guard !isDisposed else { return }
        suspended = conditions.systemAsleep || conditions.screenLocked || conditions.displayAsleep
            || conditions.criticalThermal || conditions.criticalMemory
        let newInterval = conditions.lowPowerMode || conditions.batteryLow ? Self.energySavingInterval : Self.normalInterval
        if interval != newInterval {
            interval = newInterval
            if isSampling { schedule?.invalidate(); schedule = makeSchedule() }
        }
        reconcile()
    }

    private func reconcile() {
        guard !isDisposed else { return }
        guard visibleSubscriberCount > 0, !suspended else {
            if isSampling {
                isSampling = false; generation &+= 1; schedule?.invalidate(); schedule = nil; sampleTask?.cancel()
            }
            let unavailable = SystemMetricsSnapshot.unavailable(suspended ? .paused : .noVisibleSubscribers)
            if snapshot != unavailable { snapshot = unavailable }
            return
        }
        guard !isSampling else { return }
        isSampling = true; generation &+= 1; needsBaselineReset = true; schedule = makeSchedule(); requestSample()
    }
    private func makeSchedule() -> any SystemMetricsSchedule {
        scheduler.schedule(every: interval) { [weak self] in self?.requestSample() }
    }
    private func requestSample() {
        guard isSampling, !isDisposed, sampleTask == nil else { return }
        let generation = generation, reset = needsBaselineReset, sampler = sampler
        needsBaselineReset = false
        sampleTask = Task { [weak self] in
            let result = await sampler.sample(resetBaselines: reset)
            guard let self else { return }
            self.sampleTask = nil
            guard self.isSampling, !self.isDisposed, self.generation == generation, !Task.isCancelled else {
                // A stopped request must finish before another starts; ignore its late result.
                if self.isSampling && !self.isDisposed { self.requestSample() }
                return
            }
            self.snapshot = result
        }
    }

    func shutdown() {
        guard !isDisposed else { return }; isDisposed = true; isSampling = false; generation &+= 1
        schedule?.invalidate(); schedule = nil; sampleTask?.cancel(); monitorSubscription = nil
        subscribers = [:]; snapshot = .unavailable(.disposed)
    }
    deinit {
        sampleTask?.cancel()
        let schedule = schedule
        Task { @MainActor in schedule?.invalidate() }
    }
}
