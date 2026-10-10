import Foundation

/// Automation selects an existing layer explicitly; it never changes its manual options.
struct WeatherResponseConfiguration: Codable, Equatable, Identifiable, Sendable {
    var overlayID: UUID
    var displayID: DisplayID
    var isEnabled = false
    var followsType = true
    var followsIntensity = true
    var followsWind = true
    var id: UUID { overlayID }
    func validated() throws -> Self {
        guard !displayID.rawValue.isEmpty, displayID.rawValue.count <= 256,
              displayID != .main, !displayID.rawValue.hasPrefix("session-display-") else { throw OverlayError.invalidConfiguration }
        return self
    }
}

enum WeatherResponsePlan {
    /// A temporary projection of verified weather onto independent particles only.
    static func options(manual: ParticleOptions, policy: WeatherResponseConfiguration?,
                        snapshot: WeatherSnapshot?, now: Date) -> ParticleOptions {
        guard let policy, policy.isEnabled, (try? policy.validated()) != nil,
              let snapshot, snapshot.permitsResponse(at: now) else { return manual }
        var result = manual
        let preset: ParticlePreset, strength: Double
        switch snapshot.condition {
        case .clear: preset = snapshot.isDay ? .bokeh : .stars; strength = 0.15
        case .cloudy: preset = .mist; strength = 0.15
        case .fog: preset = .mist; strength = 0.35
        case .drizzle: preset = .rain; strength = min(0.6, 0.2 + snapshot.precipitationMillimetres / 4)
        case .rain: preset = .rain; strength = min(1, 0.35 + snapshot.precipitationMillimetres / 10)
        case .snow: preset = .snow; strength = min(1, 0.25 + snapshot.precipitationMillimetres / 8)
        case .thunderstorm: preset = .rain; strength = min(1, 0.65 + snapshot.precipitationMillimetres / 20)
        case .unknown: return manual
        }
        if policy.followsType { result.preset = preset }
        if policy.followsIntensity { result.intensity = strength; result.density = strength }
        if policy.followsWind {
            // Meteorological wind is where it comes FROM; west (270°) moves right.
            result.wind = max(-1, min(1, -sin(snapshot.windDirectionDegrees * .pi / 180) * snapshot.windSpeedMetresPerSecond / 15))
        }
        return (try? result.validated()) ?? manual
    }
}
