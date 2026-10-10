import AppKit
import Combine

/// Only fetches weather. It has no Wallpaper/Overlay playback or display commands.
@MainActor
final class WeatherService: ObservableObject {
    @Published private(set) var reading = WeatherReading()
    let store: WeatherStore
    let client: any WeatherFetching
    private let location: any WeatherLocating
    private let now: () -> Date
    private var configuration = WeatherConfiguration()
    private var task: Task<Void, Never>?
    private var timer: Timer?
    private var token = UUID()
    private var subscriptions = Set<AnyCancellable>()
    private var suspended = false
    private(set) var isStarted = false
    private(set) var isFetching = false
    var hasRefreshTimer: Bool { timer != nil }
    static let refreshInterval: TimeInterval = 15 * 60

    init(store: WeatherStore, client: any WeatherFetching = WeatherClient(),
         location: (any WeatherLocating)? = nil, now: @escaping () -> Date = Date.init) {
        self.store = store; self.client = client; self.location = location ?? WeatherSystemLocation(); self.now = now
        self.location.onAccessRevoked = { [weak self] in
            guard let self, self.isStarted, self.configuration.mode == .system else { return }
            self.cancelFetch(); self.reading = .init(activity: .unavailable, message: WeatherError.permissionDenied.localizedDescription)
        }
    }
    func start(monitor: SmartPauseMonitor? = nil) {
        guard !isStarted else { return }; isStarted = true
        if let monitor {
            suspended = Self.safetyPause(monitor.conditions)
            monitor.$conditions.sink { [weak self] in self?.setSuspended(Self.safetyPause($0)) }.store(in: &subscriptions)
        }
        apply(store.configuration, requestAuthorization: false)
    }
    private static func safetyPause(_ conditions: SmartPauseConditions) -> Bool {
        conditions.screenLocked || conditions.displayAsleep || conditions.systemAsleep || conditions.criticalMemory || conditions.criticalThermal
    }
    func configure(_ value: WeatherConfiguration, requestSystemPermission: Bool = false) throws {
        guard isStarted else { throw WeatherError.settingsUnreadable }
        try store.saveConfiguration(value)
        apply(value, requestAuthorization: value.mode == .system && requestSystemPermission)
    }
    private func apply(_ value: WeatherConfiguration, requestAuthorization: Bool) {
        cancelFetch(); timer?.invalidate(); timer = nil; configuration = value
        guard store.loadError == nil else { reading = .init(activity: .unavailable, message: store.loadError); return }
        guard value.mode != .off else { reading = .init(); return }
        let place = value.mode == .manual ? value.manualPlace : store.lastSystemPlace
        reading = .init(activity: .ready, snapshot: place.flatMap { store.cached(for: $0) })
        if reading.snapshot == nil { reading.activity = .unavailable }
        guard !suspended else { return }
        schedule(); refresh(requestAuthorization: requestAuthorization)
    }
    func refresh(requestAuthorization: Bool = false) {
        guard isStarted, !suspended, configuration.mode != .off, store.loadError == nil else { return }
        cancelFetch(); let token = UUID(); self.token = token; isFetching = true
        let configuration = configuration
        let previous = reading.snapshot?.cached(at: now())
        reading = .init(activity: .loading, snapshot: previous)
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            var place: WeatherPlace?
            do {
                if configuration.mode == .manual { place = configuration.manualPlace }
                else { place = try await self.location.locate(requestAuthorization: requestAuthorization) }
                try Task.checkCancellation()
                guard self.token == token, self.isStarted, let place else { return }
                _ = try place.validated()
                // Changing location never displays another city's weather while fetching.
                self.reading = .init(activity: .loading, snapshot: self.store.cached(for: place))
                let snapshot = try await self.client.fetchWeather(for: place, now: self.now())
                try Task.checkCancellation()
                guard self.token == token, self.isStarted else { return }
                _ = try snapshot.validated(now: self.now())
                guard snapshot.place.matches(place) else { throw WeatherError.invalidResponse }
                var message: String?
                do { try self.store.saveSnapshot(snapshot, system: configuration.mode == .system) }
                catch { message = WeatherError.settingsUnreadable.localizedDescription }
                self.reading = .init(activity: .ready, snapshot: snapshot, message: message)
            } catch {
                guard !Task.isCancelled, self.token == token, self.isStarted else { return }
                let permissionFailure: Bool
                switch error { case WeatherError.permissionDenied, WeatherError.permissionRequired, WeatherError.locationUnavailable: permissionFailure = true
                default: permissionFailure = false }
                let cached = permissionFailure ? nil : place.flatMap { self.store.cached(for: $0) }
                let message = (error as? WeatherError)?.localizedDescription ?? WeatherError.network.localizedDescription
                self.reading = .init(activity: cached == nil ? .unavailable : .ready, snapshot: cached, message: message)
            }
            guard self.token == token else { return }; self.task = nil; self.isFetching = false
        }
    }
    func setSuspended(_ value: Bool) {
        guard suspended != value else { return }; suspended = value
        if value {
            cancelFetch(); timer?.invalidate(); timer = nil
            if let snapshot = reading.snapshot { reading = .init(activity: .ready, snapshot: snapshot.cached(at: now()), message: reading.message) }
        } else if isStarted, configuration.mode != .off { schedule(); refresh() }
    }
    private func schedule() {
        guard timer == nil, !suspended, configuration.mode != .off else { return }
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { guard let self, !self.isFetching else { return }; self.refresh() }
        }
        timer.tolerance = 60; self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func cancelFetch() { token = UUID(); task?.cancel(); task = nil; location.cancel(); isFetching = false }
    func shutdown() {
        isStarted = false; cancelFetch(); timer?.invalidate(); timer = nil; subscriptions.removeAll(); reading = .init()
    }
    deinit { task?.cancel(); timer?.invalidate() }
}
