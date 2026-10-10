import Combine
import Foundation

protocol AgentSessionReading: Sendable {
    func read(roots: [AgentProvider: URL], now: Date) async -> AgentSessionReader.Result
}
extension AgentSessionReader: AgentSessionReading {}

enum AgentSessionError: LocalizedError {
    case noSessionsFolder(AgentProvider)
    case bookmarkFailed
    var errorDescription: String? {
        switch self {
        case .noSessionsFolder(let provider):
            return String(format: NSLocalizedString("agentSessions.error.noSessions", comment: ""),
                          provider.title, provider.homeFolderName, provider.sessionsFolderName)
        case .bookmarkFailed: return NSLocalizedString("agentSessions.error.bookmark", comment: "")
        }
    }
}

/// Each visible Agent Session widget holds one lease; a lease never owns the service.
@MainActor
final class AgentSessionSubscription {
    private weak var service: AgentSessionService?
    private let id: UUID
    fileprivate init(service: AgentSessionService, id: UUID) { self.service = service; self.id = id }
    func setVisible(_ visible: Bool) { service?.setVisible(visible, for: id) }
    func cancel() { service?.unsubscribe(id); service = nil }
    deinit {
        let id = id, service = service
        Task { @MainActor [weak service] in service?.unsubscribe(id) }
    }
}

/// Module 41: one App-owned reader of the folders the user granted. Nothing is read, and no folder is
/// opened, while no Agent Session widget is visible, or while the Mac sleeps, locks or is under critical load.
@MainActor
final class AgentSessionService: ObservableObject {
    static let normalInterval: TimeInterval = 2
    static let energySavingInterval: TimeInterval = 10
    static func bookmarkKey(_ provider: AgentProvider) -> String { "Kinetic.AgentSessions." + provider.rawValue + ".Bookmark" }

    @Published private(set) var snapshot: AgentSessionSnapshot
    @Published private(set) var folders: [AgentProvider: String] = [:]
    private(set) var isReading = false
    private(set) var isDisposed = false
    var visibleSubscriberCount: Int { subscribers.values.filter { $0 }.count }
    var subscriberCount: Int { subscribers.count }

    private let reader: any AgentSessionReading
    private let scheduler: any SystemMetricsScheduling
    private let defaults: UserDefaults
    private let bookmarks: EngineAssetsBookmarks
    private let now: () -> Date
    private var subscribers: [UUID: Bool] = [:]
    private var schedule: (any SystemMetricsSchedule)?
    private var readTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var scoped: [AgentProvider: URL] = [:]
    private var roots: [AgentProvider: URL] = [:]
    private var resolveFailures: Set<AgentProvider> = []
    private var suspended = false
    private var interval = normalInterval
    private var monitorSubscription: AnyCancellable?

    init(reader: any AgentSessionReading, scheduler: any SystemMetricsScheduling,
         defaults: UserDefaults = .standard, bookmarks: EngineAssetsBookmarks = .securityScoped,
         now: @escaping () -> Date = Date.init) {
        self.reader = reader; self.scheduler = scheduler; self.defaults = defaults; self.bookmarks = bookmarks; self.now = now
        snapshot = .waiting(.idle, sources: [:])
        refreshFolders()
        snapshot = .waiting(.idle, sources: storedSources())
    }

    static func live() -> AgentSessionService {
        .init(reader: AgentSessionReader(), scheduler: LiveSystemMetricsScheduler())
    }

    func isConnected(_ provider: AgentProvider) -> Bool { defaults.data(forKey: Self.bookmarkKey(provider)) != nil }

    func start(monitor: SmartPauseMonitor?) {
        guard !isDisposed, monitorSubscription == nil else { return }
        monitorSubscription = monitor?.$conditions.removeDuplicates().sink { [weak self] in self?.updateSystemConditions($0) }
    }

    func subscribe(isVisible: Bool = true) -> AgentSessionSubscription {
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

    /// The user picked `folder` in the system open panel: its `.claude` / `.codex` folder or the sessions folder inside.
    func connect(_ provider: AgentProvider, folder: URL) throws {
        guard !isDisposed else { return }
        let started = folder.startAccessingSecurityScopedResource()
        defer { if started { folder.stopAccessingSecurityScopedResource() } }
        guard Self.sessionsRoot(provider, in: folder) != nil else { throw AgentSessionError.noSessionsFolder(provider) }
        let data: Data
        do { data = try bookmarks.make(folder) } catch { throw AgentSessionError.bookmarkFailed }
        defaults.set(data, forKey: Self.bookmarkKey(provider))
        restartReading()
    }
    func disconnect(_ provider: AgentProvider) {
        guard !isDisposed else { return }
        defaults.removeObject(forKey: Self.bookmarkKey(provider))
        restartReading()
    }

    func updateSystemConditions(_ conditions: SmartPauseConditions) {
        guard !isDisposed else { return }
        suspended = conditions.systemAsleep || conditions.screenLocked || conditions.displayAsleep
            || conditions.criticalThermal || conditions.criticalMemory
        let next = conditions.lowPowerMode || conditions.batteryLow ? Self.energySavingInterval : Self.normalInterval
        if interval != next {
            interval = next
            if isReading { schedule?.invalidate(); schedule = makeSchedule() }
        }
        reconcile()
    }

    static func sessionsRoot(_ provider: AgentProvider, in folder: URL) -> URL? {
        var isDirectory: ObjCBool = false
        let inside = folder.appendingPathComponent(provider.sessionsFolderName, isDirectory: true)
        if FileManager.default.fileExists(atPath: inside.path, isDirectory: &isDirectory), isDirectory.boolValue { return inside }
        if folder.lastPathComponent == provider.sessionsFolderName,
           FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue { return folder }
        return nil
    }

    private func restartReading() {
        refreshFolders()
        if isReading { stopReading() }
        reconcile()
        if !isReading { snapshot = .waiting(snapshot.activity, sources: storedSources()) }
    }

    private func reconcile() {
        guard !isDisposed else { return }
        // With no folder granted there is nothing to read; the tile explains how to connect one.
        guard visibleSubscriberCount > 0, !suspended, AgentProvider.allCases.contains(where: isConnected) else {
            if isReading { stopReading() }
            let waiting = AgentSessionSnapshot.waiting(suspended ? .paused : .idle, sources: storedSources())
            if snapshot != waiting { snapshot = waiting }
            return
        }
        guard !isReading else { return }
        isReading = true; generation &+= 1
        openFolders()
        schedule = makeSchedule(); requestRead()
    }
    private func stopReading() {
        isReading = false; generation &+= 1; schedule?.invalidate(); schedule = nil; readTask?.cancel()
        closeFolders()
    }
    private func makeSchedule() -> any SystemMetricsSchedule {
        scheduler.schedule(every: interval) { [weak self] in self?.requestRead() }
    }
    private func requestRead() {
        guard isReading, !isDisposed, readTask == nil else { return }
        let generation = generation, roots = roots, reader = reader, time = now(), failures = resolveFailures
        readTask = Task { [weak self] in
            let result = await reader.read(roots: roots, now: time)
            guard let self else { return }
            self.readTask = nil
            guard self.isReading, !self.isDisposed, self.generation == generation, !Task.isCancelled else {
                // A stopped read finishes before another starts; its late result is ignored.
                if self.isReading && !self.isDisposed { self.requestRead() }
                return
            }
            var sources = self.storedSources()
            for provider in failures.union(result.unreadable) where sources[provider] == .connected { sources[provider] = .unreadable }
            let next = AgentSessionSnapshot(activity: .live, sources: sources, sessions: result.sessions, sampledAt: time)
            if self.snapshot != next { self.snapshot = next }
        }
    }

    /// Security scope stays open only while reading.
    private func openFolders() {
        closeFolders(); resolveFailures = []
        for provider in AgentProvider.allCases {
            guard let data = defaults.data(forKey: Self.bookmarkKey(provider)) else { continue }
            guard let resolved = try? bookmarks.resolve(data) else { resolveFailures.insert(provider); continue }
            if resolved.url.startAccessingSecurityScopedResource() { scoped[provider] = resolved.url }
            if resolved.isStale, let fresh = try? bookmarks.make(resolved.url) { defaults.set(fresh, forKey: Self.bookmarkKey(provider)) }
            if let root = Self.sessionsRoot(provider, in: resolved.url) { roots[provider] = root }
            else { resolveFailures.insert(provider) }
        }
    }
    private func closeFolders() {
        for url in scoped.values { url.stopAccessingSecurityScopedResource() }
        scoped = [:]; roots = [:]
    }
    private func storedSources() -> [AgentProvider: AgentSourceStatus] {
        Dictionary(uniqueKeysWithValues: AgentProvider.allCases.map { ($0, isConnected($0) ? .connected : .notConnected) })
    }
    /// Display paths for Settings, resolved without opening the folders.
    private func refreshFolders() {
        var next: [AgentProvider: String] = [:]
        for provider in AgentProvider.allCases {
            guard let data = defaults.data(forKey: Self.bookmarkKey(provider)), let url = try? bookmarks.resolve(data).url else { continue }
            next[provider] = (url.path as NSString).abbreviatingWithTildeInPath
        }
        if folders != next { folders = next }
    }

    func shutdown() {
        guard !isDisposed else { return }
        isDisposed = true; isReading = false; generation &+= 1
        schedule?.invalidate(); schedule = nil; readTask?.cancel(); monitorSubscription = nil
        closeFolders(); subscribers = [:]
        snapshot = .waiting(.disposed, sources: storedSources())
    }
    deinit {
        readTask?.cancel()
        let schedule = schedule, scoped = scoped
        Task { @MainActor in schedule?.invalidate(); for url in scoped.values { url.stopAccessingSecurityScopedResource() } }
    }
}
