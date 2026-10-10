import Foundation

struct OverlayParticle: Equatable, Sendable {
    var x: Double
    var y: Double
    var variation: Double
    var phase: Double
    var angle: Double
}

/// Bounded, normalized geometry keeps positions across edits, resizing and Retina changes.
/// No renderer, timer, display, file or application dependency.
struct ParticleSimulation {
    static let maximumParticles = 320
    private(set) var options = ParticleOptions()
    private(set) var particles: [OverlayParticle] = []
    private(set) var elapsed = 0.0
    private var randomState: UInt64

    init(seed: UInt64 = UInt64.random(in: 1...UInt64.max)) { randomState = seed == 0 ? 1 : seed }

    mutating func configure(_ options: ParticleOptions) throws {
        let next = try options.validated()
        // A new preset deliberately changes the pattern; parameter edits retain existing particles.
        if next.preset != self.options.preset { particles.removeAll(); elapsed = 0 }
        self.options = next
        let limit: Int
        switch next.preset {
        case .mist: limit = 24
        case .meteors: limit = 18
        case .bokeh, .bubbles: limit = 80
        default: limit = Self.maximumParticles
        }
        let count = Int((Double(limit) * next.density).rounded())
        if particles.count > count { particles.removeLast(particles.count - count) }
        while particles.count < count {
            particles.append(.init(x: random(), y: random(), variation: random(),
                                   phase: random() * .pi * 2, angle: random() * .pi * 2))
        }
    }

    mutating func advance(by duration: TimeInterval) {
        guard duration.isFinite, duration > 0 else { return }
        // Never catch up after sleep, run-loop stalls or pause: bound work and displacement.
        let dt = min(duration, 0.1), speed = 0.35 + options.intensity * 1.65
        elapsed += dt
        for index in particles.indices {
            var p = particles[index]
            let drift = sin(elapsed * 0.8 + p.phase) * 0.008
            var vx = options.wind * 0.055, vy = 0.0
            switch options.preset {
            case .snow: vx += drift; vy = -(0.025 + p.variation * 0.035)
            case .rain: vx += 0.014; vy = -(0.32 + p.variation * 0.2)
            case .bokeh: vx += drift * 0.3; vy = 0.004 + p.variation * 0.007
            case .fireflies: vx += sin(elapsed + p.phase) * 0.018; vy = cos(elapsed * 0.7 + p.phase) * 0.015
            case .dust: vx += drift * 0.6; vy = 0.004 + p.variation * 0.009
            case .stars: vx += drift * 0.08
            case .leaves, .sakura: vx += sin(elapsed * 1.3 + p.phase) * 0.024; vy = -(0.026 + p.variation * 0.035)
            case .mist: vx += 0.008 + p.variation * 0.006; vy = drift * 0.15
            case .embers: vx += drift; vy = 0.025 + p.variation * 0.06
            case .bubbles: vx += drift * 0.5; vy = 0.018 + p.variation * 0.04
            case .meteors: vx += 0.26 + p.variation * 0.14; vy = -(0.2 + p.variation * 0.13)
            }
            p.x = wrapped(p.x + vx * speed * dt)
            p.y = wrapped(p.y + vy * speed * dt)
            p.angle += (options.preset == .leaves || options.preset == .sakura ? 0.8 : 0.1) * dt * speed
            // Keep long-running angles small without a visible discontinuity.
            if p.angle > .pi * 2 { p.angle -= .pi * 2 }
            particles[index] = p
        }
        if elapsed > 86_400 { elapsed.formTruncatingRemainder(dividingBy: .pi * 20) }
    }

    private func wrapped(_ value: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: 1)
        return remainder < 0 ? remainder + 1 : remainder
    }
    private mutating func random() -> Double {
        randomState = randomState &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(randomState >> 11) / 9_007_199_254_740_992
    }
}
