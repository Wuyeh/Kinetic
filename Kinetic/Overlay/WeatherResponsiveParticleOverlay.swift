import AppKit
import Combine

/// A provider decorator; Overlay Core and Wallpaper Runtime remain unaware of weather.
@MainActor
final class WeatherResponsiveParticleOverlay: DesktopOverlay {
    let particles: ParticleOverlay
    var displayView: NSView { particles.displayView }
    var onFailure: (@MainActor (Error) -> Void)?
    private var subscriptions = Set<AnyCancellable>()
    private var reading: WeatherReading
    private var policies: [WeatherResponseConfiguration]
    private var manual: OverlayConfiguration?
    private var context: OverlayContext?
    private(set) var applied: OverlayConfiguration?
    private let now: () -> Date
    private var prepared = false
    private var playing = false
    private(set) var isDisposed = false

    init(weather: WeatherService, responses: WeatherResponseStore, particles: ParticleOverlay? = nil,
         now: @escaping () -> Date = Date.init) {
        self.particles = particles ?? ParticleOverlay(); self.now = now; reading = weather.reading; policies = responses.configurations
        weather.$reading.sink { [weak self] value in self?.reading = value; self?.refreshLive() }.store(in: &subscriptions)
        responses.$configurations.sink { [weak self] value in self?.policies = value; self?.refreshLive() }.store(in: &subscriptions)
        self.particles.onFailure = { [weak self] error in self?.onFailure?(error) }
    }
    private func effective(_ configuration: OverlayConfiguration) throws -> OverlayConfiguration {
        let options = try ParticleOptions(configuration: configuration)
        let policy = policies.first { $0.overlayID == configuration.id && $0.displayID == configuration.displayID }
        let snapshot = reading.activity == .off || reading.activity == .unavailable ? nil : reading.snapshot
        return try WeatherResponsePlan.options(manual: options, policy: policy, snapshot: snapshot, now: now()).applying(to: configuration)
    }
    func prepare(configuration: OverlayConfiguration, context: OverlayContext) async throws {
        guard !isDisposed else { throw OverlayError.invalidConfiguration }
        _ = try ParticleOptions(configuration: configuration)
        let value = context.isPaused ? configuration : try effective(configuration)
        manual = configuration; self.context = context
        try await particles.prepare(configuration: value, context: context)
        try Task.checkCancellation(); guard !isDisposed else { throw CancellationError() }
        prepared = true; applied = value
    }
    func update(configuration: OverlayConfiguration, context: OverlayContext) throws {
        guard !isDisposed else { throw OverlayError.invalidConfiguration }
        _ = try ParticleOptions(configuration: configuration)
        let explicitEdit = manual?.parameters != configuration.parameters
        var value = configuration
        if context.isPaused {
            // Automation holds the paused frame. Explicit edits remain user actions.
            if !explicitEdit, let applied { value.parameters = applied.parameters }
        } else { value = try effective(configuration) }
        try particles.update(configuration: value, context: context)
        manual = configuration; self.context = context; applied = value
    }
    private func refreshLive() {
        guard !isDisposed, prepared, playing, let manual, let context, !context.isPaused else { return }
        do {
            let value = try effective(manual)
            guard value != applied else { return }
            try particles.update(configuration: value, context: context); applied = value
        } catch {
            // Weather failure cannot dispose the wallpaper or a valid manual particle layer.
            if (try? particles.update(configuration: manual, context: context)) != nil { applied = manual }
        }
    }
    func play() { guard !isDisposed else { return }; playing = true; refreshLive(); particles.play() }
    func pause() { playing = false; particles.pause() }
    func dispose() {
        guard !isDisposed else { return }; isDisposed = true; playing = false
        subscriptions.removeAll(); particles.onFailure = nil; particles.dispose(); onFailure = nil; manual = nil; context = nil; applied = nil
    }
    deinit {
        let particles = particles
        Task { @MainActor in particles.dispose() }
    }
}
