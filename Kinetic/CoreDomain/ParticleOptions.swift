import Foundation

enum ParticlePreset: String, CaseIterable, Codable, Identifiable, Sendable {
    case snow, rain, bokeh, fireflies, dust, stars, leaves, sakura, mist, embers, bubbles, meteors
    var id: String { rawValue }
    var title: String { NSLocalizedString("particles.preset.\(rawValue)", comment: "") }
}

/// Values belong to the independent overlay, never to a Wallpaper or its renderer.
struct ParticleOptions: Equatable, Sendable {
    var preset: ParticlePreset = .snow
    var density = 0.35
    var intensity = 0.5
    /// Signed horizontal wind: negative goes left, positive goes right.
    var wind = 0.0
    var reduceMotion = false

    func validated() throws -> Self {
        guard density.isFinite, (0...1).contains(density),
              intensity.isFinite, (0...1).contains(intensity),
              wind.isFinite, (-1...1).contains(wind) else { throw OverlayError.invalidConfiguration }
        return self
    }

    init() {}
    init(configuration: OverlayConfiguration) throws {
        _ = try configuration.validated()
        guard configuration.kind == .particles,
              Set(configuration.parameters.keys).isSubset(of: ["preset", "density", "intensity", "wind", "reduceMotion"]) else {
            throw OverlayError.invalidConfiguration
        }
        if let value = configuration.parameters["preset"] {
            guard case .text(let name) = value, let preset = ParticlePreset(rawValue: name) else { throw OverlayError.invalidConfiguration }
            self.preset = preset
        }
        for key in ["density", "intensity", "wind"] {
            guard let value = configuration.parameters[key] else { continue }
            guard case .number(let number) = value else { throw OverlayError.invalidConfiguration }
            switch key { case "density": density = number; case "intensity": intensity = number; default: wind = number }
        }
        if let value = configuration.parameters["reduceMotion"] {
            guard case .boolean(let flag) = value else { throw OverlayError.invalidConfiguration }
            reduceMotion = flag
        }
        self = try validated()
    }

    func applying(to configuration: OverlayConfiguration) throws -> OverlayConfiguration {
        _ = try validated()
        guard configuration.kind == .particles else { throw OverlayError.invalidConfiguration }
        var result = configuration
        result.parameters = ["preset": .text(preset.rawValue), "density": .number(density),
                             "intensity": .number(intensity), "wind": .number(wind), "reduceMotion": .boolean(reduceMotion)]
        return try result.validated()
    }
}
