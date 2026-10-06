import Foundation
import simd

/// Authored sprite emitters are evaluated from birth time, avoiding frame-rate-dependent
/// integration, a catch-up backlog after pause, or an ever-growing list of dead particles.
struct SceneParticleDefinition: Sendable {
    struct Change: Sendable {
        var start: Float = 0, end: Float = 1, from: Float = 1, to: Float = 1
        func value(_ age: Float) -> Float {
            let fraction = min(1, max(0, (age - start) / max(0.0001, end - start)))
            return from + (to - from) * fraction
        }
    }
    let material: String
    var count = 128
    var rate: Float = 5, burst = 0, delay: Float = 0, duration: Float = 0
    var box = false
    var origin = SIMD2<Float>(repeating: 0)
    var distanceMin = SIMD2<Float>(repeating: 0), distanceMax = SIMD2<Float>(repeating: 0)
    var speed = SIMD2<Float>(repeating: 0)
    var lifetime = SIMD2<Float>(repeating: 1), size = SIMD2<Float>(repeating: 4)
    var velocityMin = SIMD2<Float>(repeating: 0), velocityMax = SIMD2<Float>(repeating: 0)
    var colorMin = SIMD3<Float>(repeating: 1), colorMax = SIMD3<Float>(repeating: 1)
    var alpha = SIMD2<Float>(repeating: 1), rotation = SIMD2<Float>(repeating: 0), spin = SIMD2<Float>(repeating: 0)
    var gravity = SIMD2<Float>(repeating: 0), drag: Float = 0
    var fadeIn: Float = 0.1, fadeOut: Float = 0
    var alphaChange = Change(), sizeChange = Change()

    static func parse(_ json: SceneJSON, limits: SceneLimits) throws -> Self {
        guard json.object != nil, let material = json["material"].string else { throw SceneRuntimeError.malformed("particle material") }
        for key in ["children", "controlpoint"] where json[key] != .null && json[key].array?.isEmpty != true {
            throw SceneRuntimeError.unsupported("particle \(key)")
        }
        guard (json["flags"].number ?? 0) == 0, json["animationmode"] == .null, json["sequencemultiplier"] == .null else {
            throw SceneRuntimeError.unsupported("particle perspective / animated texture sequence")
        }
        if let renderers = json["renderer"].array {
            guard renderers.count == 1, renderers[0]["name"].string?.lowercased() == "sprite" else {
                throw SceneRuntimeError.unsupported("particle ribbon / trail / renderer")
            }
        }
        var result = Self(material: try ScenePath.canonical(material))
        let count = try scalar(json["maxcount"], fallback: 128)
        guard count >= 1, count <= Float(limits.maximumParticlesPerEmitter), count.rounded() == count else {
            throw SceneRuntimeError.budgetExceeded("particle maxcount")
        }
        result.count = Int(count); result.delay = try scalar(json["starttime"], fallback: 0)
        let emitters = json["emitter"].array ?? []
        guard emitters.count == 1 else { throw SceneRuntimeError.unsupported("particle emitter count") }
        let emitter = emitters[0], name = emitter["name"].string?.lowercased() ?? "sphererandom"
        guard ["boxrandom", "sphererandom"].contains(name) else { throw SceneRuntimeError.unsupported("particle emitter \(name)") }
        for key in ["flags", "audio"] where emitter[key] != .null { throw SceneRuntimeError.unsupported("particle emitter \(key)") }
        result.box = name == "boxrandom"
        result.rate = try scalar(emitter["rate"], fallback: 5)
        result.duration = try scalar(emitter["duration"], fallback: 0)
        let burst = try scalar(emitter["instantaneous"], fallback: 0)
        guard burst >= 0, burst <= count, burst.rounded() == burst else { throw SceneRuntimeError.budgetExceeded("particle burst") }
        result.burst = Int(burst)
        func xy(_ value: SceneJSON, _ fallback: SIMD2<Float> = .zero) throws -> SIMD2<Float> {
            let value = try vector(value, fallback: SIMD3(fallback.x, fallback.y, 0))
            guard abs(value.z) < 0.0001 else { throw SceneRuntimeError.unsupported("particle 3D vector") }
            return SIMD2(value.x, value.y)
        }
        result.origin = try xy(emitter["origin"])
        if result.box {
            result.distanceMin = simd_abs(try xy(emitter["distancemin"]))
            result.distanceMax = simd_abs(try xy(emitter["distancemax"]))
        } else {
            result.distanceMin = .init(repeating: try scalar(emitter["distancemin"], fallback: 0))
            result.distanceMax = .init(repeating: try scalar(emitter["distancemax"], fallback: result.distanceMin.x))
        }
        if emitter["directions"] != .null {
            guard try xy(emitter["directions"]) == SIMD2(repeating: 1) else { throw SceneRuntimeError.unsupported("particle direction mask") }
        }
        if emitter["sign"] != .null {
            guard try xy(emitter["sign"]) == .zero else { throw SceneRuntimeError.unsupported("particle sign mask") }
        }
        let speedMin = try scalar(emitter["speedmin"], fallback: 0)
        result.speed = SIMD2(speedMin, try scalar(emitter["speedmax"], fallback: speedMin))
        var names = Set<String>()
        for entry in json["initializer"].array ?? [] {
            guard let name = entry["name"].string?.lowercased(), names.insert(name).inserted else {
                throw SceneRuntimeError.malformed("particle initializer name")
            }
            func range(_ fallback: SIMD2<Float>) throws -> SIMD2<Float> {
                SIMD2(try scalar(entry["min"], fallback: fallback.x), try scalar(entry["max"], fallback: fallback.y))
            }
            switch name {
            case "lifetimerandom": result.lifetime = try range(result.lifetime)
            case "lifetime": result.lifetime = .init(repeating: try scalar(entry["value"], fallback: 1))
            case "sizerandom":
                guard try scalar(entry["exponent"], fallback: 1) == 1 else { throw SceneRuntimeError.unsupported("particle size exponent") }
                result.size = try range(result.size)
            case "size": result.size = .init(repeating: try scalar(entry["value"], fallback: 4))
            case "velocityrandom": result.velocityMin = try xy(entry["min"], .init(repeating: -32)); result.velocityMax = try xy(entry["max"], .init(repeating: 32))
            case "velocity": result.velocityMin = try xy(entry["value"]); result.velocityMax = result.velocityMin
            case "colorrandom":
                result.colorMin = try vector(entry["min"], fallback: SIMD3(repeating: 255)) / 255
                result.colorMax = try vector(entry["max"], fallback: SIMD3(repeating: 255)) / 255
            case "color": result.colorMin = try vector(entry["value"], fallback: SIMD3(repeating: 255)) / 255; result.colorMax = result.colorMin
            case "alpharandom": result.alpha = try range(SIMD2(0.05, 1))
            case "alpha": result.alpha = .init(repeating: try scalar(entry["value"], fallback: 1))
            case "rotationrandom", "angularvelocityrandom":
                let low = try vector(entry["min"], fallback: SIMD3(0, 0, name == "rotationrandom" ? 0 : -5))
                let high = try vector(entry["max"], fallback: SIMD3(0, 0, name == "rotationrandom" ? 2 * .pi : 5))
                guard abs(low.x) + abs(low.y) + abs(high.x) + abs(high.y) < 0.0001 else { throw SceneRuntimeError.unsupported("particle 3D spin") }
                if name == "rotationrandom" { result.rotation = SIMD2(low.z, high.z) } else { result.spin = SIMD2(low.z, high.z) }
            default: throw SceneRuntimeError.unsupported("particle initializer \(name)")
            }
        }
        names = []
        for entry in json["operator"].array ?? [] {
            guard let name = entry["name"].string?.lowercased(), names.insert(name).inserted else {
                throw SceneRuntimeError.malformed("particle operator name")
            }
            switch name {
            case "movement": result.gravity = try xy(entry["gravity"]); result.drag = try scalar(entry["drag"], fallback: 0)
            case "alphafade": result.fadeIn = try scalar(entry["fadeintime"], fallback: 0.1); result.fadeOut = try scalar(entry["fadeouttime"], fallback: 0.3)
            case "alphachange", "sizechange":
                let change = Change(start: try scalar(entry["starttime"], fallback: 0), end: try scalar(entry["endtime"], fallback: 1),
                    from: try scalar(entry["startvalue"], fallback: 1), to: try scalar(entry["endvalue"], fallback: 1))
                guard change.start >= 0, change.end >= change.start, change.from >= 0, change.to >= 0,
                      max(change.from, change.to) <= 16 else { throw SceneRuntimeError.malformed("particle change") }
                if name == "alphachange" { result.alphaChange = change } else { result.sizeChange = change }
            default: throw SceneRuntimeError.unsupported("particle operator \(name)")
            }
        }
        for range in [result.lifetime, result.size, result.alpha, result.speed, result.rotation, result.spin] {
            guard range.x <= range.y else { throw SceneRuntimeError.malformed("particle random range") }
        }
        guard result.lifetime.x > 0, result.lifetime.y <= 600, result.size.x > 0, result.size.y <= 4096,
              result.alpha.x >= 0, result.alpha.y <= 1, result.rate >= 0, result.rate <= 2000,
              result.delay >= 0, result.delay <= 600, result.duration >= 0, result.duration <= 86400,
              result.drag >= 0, result.drag <= 100, result.fadeIn >= 0, result.fadeOut >= 0,
              ceil(result.rate * result.lifetime.y) + Float(result.burst) <= count else {
            throw SceneRuntimeError.budgetExceeded("particle simulation")
        }
        guard (0...2).allSatisfy({ result.colorMin[$0] >= 0 && result.colorMax[$0] <= 1 && result.colorMin[$0] <= result.colorMax[$0] }),
              (0...1).allSatisfy({ result.distanceMin[$0] >= 0 && result.distanceMax[$0] >= result.distanceMin[$0] &&
                result.distanceMax[$0] <= 1_000_000 && result.velocityMin[$0] <= result.velocityMax[$0] &&
                abs(result.velocityMin[$0]) <= 100_000 && abs(result.velocityMax[$0]) <= 100_000 && abs(result.gravity[$0]) <= 100_000 }) else {
            throw SceneRuntimeError.malformed("particle color / spatial range")
        }
        return result
    }

    func instances(at time: Double, seed: UInt64) -> [SceneParticleInstance] {
        let time = time - Double(delay)
        guard time >= 0, time.isFinite, time <= 3_153_600_000 else { return [] }
        var result: [SceneParticleInstance] = []; result.reserveCapacity(count)
        func add(_ index: UInt64, birth: Double) {
            let age = Float(time - birth)
            var random = SceneParticleRandom(state: seed ^ (index &* 0x9e3779b97f4a7c15))
            func pick(_ range: SIMD2<Float>) -> Float { range.x + (range.y - range.x) * random.next() }
            let life = pick(lifetime)
            guard age >= 0, age < life else { return }
            let angle = random.next() * 2 * .pi, direction = SIMD2(cos(angle), sin(angle))
            var position: SIMD2<Float>
            if box {
                let x = pick(SIMD2(distanceMin.x, distanceMax.x)), y = pick(SIMD2(distanceMin.y, distanceMax.y))
                position = origin + SIMD2(random.next() < 0.5 ? -x : x, random.next() < 0.5 ? -y : y)
            } else { position = origin + direction * pick(SIMD2(distanceMin.x, distanceMax.x)) }
            let velocity = SIMD2(pick(SIMD2(velocityMin.x, velocityMax.x)), pick(SIMD2(velocityMin.y, velocityMax.y))) + direction * pick(speed)
            if drag > 0.0001 {
                let factor = (1 - exp(-drag * age)) / drag
                position += velocity * factor + gravity * ((age - factor) / drag)
            } else { position += velocity * age + gravity * age * age / 2 }
            let size = pick(size) * sizeChange.value(age / life)
            let color = colorMin + (colorMax - colorMin) * SIMD3(random.next(), random.next(), random.next())
            let fade = min(fadeIn > 0 ? min(1, age / fadeIn) : 1, fadeOut > 0 ? min(1, (life - age) / fadeOut) : 1)
            let alpha = min(1, max(0, pick(alpha) * fade * alphaChange.value(age / life)))
            let rotation = pick(rotation) + pick(spin) * age
            result.append(.init(geometry: SIMD4(position.x, position.y, size, rotation), color: SIMD4(color.x, color.y, color.z, alpha)))
        }
        for i in 0..<burst { add(UInt64(i), birth: 0) }
        if rate > 0 {
            let endTime = duration > 0 ? min(time, Double(duration)) : time
            // Use Double for birth indices, retaining stable timing on long-lived desktops.
            let last = floor(endTime * Double(rate))
            let first = max(1, floor((time - Double(lifetime.y)) * Double(rate)) + 1)
            if last >= first {
                let boundedFirst = max(first, last - Double(count) + 1)
                for index in Int64(boundedFirst)...Int64(last) { add(UInt64(index) &+ UInt64(burst), birth: Double(index) / Double(rate)) }
            }
        }
        return result
    }
}

struct SceneParticleInstance { let geometry: SIMD4<Float>; let color: SIMD4<Float> }
private struct SceneParticleRandom {
    var state: UInt64
    mutating func next() -> Float {
        state &+= 0x9e3779b97f4a7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        value ^= value >> 31
        return Float(value >> 40) / 16_777_216
    }
}
