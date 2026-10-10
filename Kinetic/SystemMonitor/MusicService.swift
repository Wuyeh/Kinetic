import Combine
import Foundation

@MainActor final class MusicSubscription {
    private weak var service: MusicService?
    private let id: UUID
    fileprivate init(_ service: MusicService, id: UUID) { self.service = service; self.id = id }
    func update(visible: Bool, source: MusicSource, lyrics: Bool) { service?.update(id, visible: visible, source: source, lyrics: lyrics) }
    func cancel() { service?.remove(id); service = nil }
    deinit { let service = service, id = id; Task { @MainActor [weak service] in service?.remove(id) } }
}
enum LyricsAvailability: String { case off, loading, ready, unavailable, instrumental }
struct LyricsSnapshot: Equatable {
    var status: LyricsAvailability = .off
    var trackKey: String?
    var value: TrackLyrics?
}

/// One service for all displays and previews; no background polling with zero visible leases.
@MainActor final class MusicService: ObservableObject {
    @Published private(set) var snapshots: [MusicSource: MusicSnapshot] = [:]
    @Published private(set) var lyrics: [MusicSource: LyricsSnapshot] = [:]
    @Published private(set) var controlError: String?
    private struct Lease: Equatable { var visible: Bool; var source: MusicSource; var lyrics: Bool }
    private var leases: [UUID: Lease] = [:]
    private let reader: any MusicReading
    private let repository: LyricsRepository
    private let scheduler: any SystemMetricsScheduling
    private var schedule: (any SystemMetricsSchedule)?
    private var sampleTask: Task<Void, Never>?
    private var lyricTasks: [MusicSource: Task<Void, Never>] = [:]
    private var lyricGeneration: [MusicSource: UInt64] = [:]
    private var monitor: AnyCancellable?
    private var generation: UInt64 = 0
    private var suspended = false, lowPower = false
    private(set) var isDisposed = false
    private(set) var isSampling = false
    var subscriberCount: Int { leases.count }
    var interval: Double { lowPower ? 10 : 2 }
    init(reader: any MusicReading = LiveMusicReader(), repository: LyricsRepository = .init(), scheduler: (any SystemMetricsScheduling)? = nil) {
        self.reader = reader; self.repository = repository; self.scheduler = scheduler ?? LiveSystemMetricsScheduler()
    }
    func start(monitor: SmartPauseMonitor?) {
        self.monitor = monitor?.$conditions.removeDuplicates().sink { [weak self] in self?.updateConditions($0) }
    }
    func subscribe(source: MusicSource, lyrics: Bool, visible: Bool = false) -> MusicSubscription {
        let id = UUID(); if !isDisposed { leases[id] = .init(visible: visible, source: source, lyrics: lyrics); reconcile() }
        return .init(self, id: id)
    }
    fileprivate func update(_ id: UUID, visible: Bool, source: MusicSource, lyrics: Bool) {
        guard !isDisposed, leases[id] != nil else { return }
        let next = Lease(visible: visible, source: source, lyrics: lyrics)
        guard leases[id] != next else { return }
        leases[id] = next; reconcile()
    }
    fileprivate func remove(_ id: UUID) { leases[id] = nil; reconcile() }
    func updateConditions(_ conditions: SmartPauseConditions) {
        suspended = conditions.systemAsleep || conditions.screenLocked || conditions.displayAsleep || conditions.criticalThermal || conditions.criticalMemory
        let low = conditions.lowPowerMode || conditions.batteryLow
        if low != lowPower { lowPower = low; schedule?.invalidate(); schedule = nil }; reconcile()
    }
    private var sources: Set<MusicSource> { suspended ? [] : Set(leases.values.filter(\.visible).map(\.source)) }
    private func wantsLyrics(_ source: MusicSource) -> Bool { !suspended && leases.values.contains { $0.visible && $0.source == source && $0.lyrics } }
    private func reconcile() {
        guard !isDisposed else { return }
        for source in MusicSource.allCases where !wantsLyrics(source) {
            lyricTasks[source]?.cancel(); lyricTasks[source] = nil; lyricGeneration[source, default: 0] &+= 1
            if lyrics[source]?.status != .off { lyrics[source] = .init() }
        }
        if sources.isEmpty {
            isSampling = false; generation &+= 1; schedule?.invalidate(); schedule = nil; sampleTask?.cancel()
        } else {
            isSampling = true
            if schedule == nil { schedule = scheduler.schedule(every: interval) { [weak self] in self?.sample() } }
            sample()
            for source in sources { fetchLyrics(source) }
        }
    }
    func refresh() { sample() }
    private func sample() {
        guard isSampling, !isDisposed, sampleTask == nil else { return }
        let token = generation, requested = sources, reader = reader
        sampleTask = Task { [weak self] in
            var values: [MusicSource: MusicSnapshot] = [:]
            for source in requested { guard !Task.isCancelled else { break }; values[source] = await reader.read(source) }
            guard let self else { return }; self.sampleTask = nil
            guard !self.isDisposed, self.isSampling, self.generation == token, !Task.isCancelled else {
                if self.isSampling && !self.isDisposed { self.sample() }; return
            }
            for (source, value) in values where self.sources.contains(source) { self.snapshots[source] = value; self.fetchLyrics(source) }
        }
    }
    private func fetchLyrics(_ source: MusicSource) {
        guard wantsLyrics(source), let track = snapshots[source]?.track, snapshots[source]?.availability == .live else {
            if snapshots[source]?.track == nil { lyricTasks[source]?.cancel(); lyricTasks[source] = nil; lyricGeneration[source, default: 0] &+= 1; lyrics[source] = .init() }
            return
        }
        let key = LyricsRepository.key(track)
        guard lyrics[source]?.trackKey != key else { return }
        lyricTasks[source]?.cancel(); lyricGeneration[source, default: 0] &+= 1
        let token = lyricGeneration[source], repository = repository
        lyrics[source] = .init(status: .loading, trackKey: key)
        lyricTasks[source] = Task { [weak self] in
            let value = try? await repository.lyrics(for: track)
            guard let self, !Task.isCancelled, !self.isDisposed, self.lyricGeneration[source] == token, self.wantsLyrics(source),
                  self.snapshots[source]?.track.map(LyricsRepository.key) == key else { return }
            self.lyricTasks[source] = nil
            let empty = value.map { $0.plain.isEmpty && $0.lines.isEmpty && !$0.instrumental } ?? true
            self.lyrics[source] = .init(status: empty ? .unavailable : value?.instrumental == true ? .instrumental : .ready,
                                       trackKey: key, value: value)
        }
    }
    func retryLyrics(_ source: MusicSource) { lyricTasks[source]?.cancel(); lyricTasks[source] = nil; lyrics[source] = .init(); fetchLyrics(source) }
    func authorize(_ source: MusicSource) async -> MusicAvailability { let value = await reader.authorize(source); refresh(); return value }
    func control(_ command: MusicControl, source: MusicSource) async {
        controlError = nil
        if await reader.control(command, source: source) { refresh() }
        else { controlError = NSLocalizedString("music.controlFailed", comment: "") }
    }
    func shutdown() {
        guard !isDisposed else { return }; isDisposed = true; isSampling = false; generation &+= 1
        schedule?.invalidate(); schedule = nil; sampleTask?.cancel(); lyricTasks.values.forEach { $0.cancel() }; lyricTasks = [:]
        monitor = nil; leases = [:]; snapshots = [:]; lyrics = [:]
    }
    deinit { sampleTask?.cancel(); lyricTasks.values.forEach { $0.cancel() }; let schedule = schedule; Task { @MainActor in schedule?.invalidate() } }
}
