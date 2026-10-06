import Foundation
import simd

struct ScenePuppetVertex: Sendable {
    let position: SIMD4<Float>
    let weights: SIMD4<Float>
    let bones: SIMD4<UInt32>
    let uv: SIMD2<Float>
}
struct ScenePuppetMesh: Sendable {
    let material: String
    let vertices: [ScenePuppetVertex]
    let indices: [UInt32]
}
struct ScenePuppet: Sendable {
    struct Bone: Sendable { let parent: Int?; let bind: simd_float4x4 }
    struct Key: Sendable {
        let translation: SIMD3<Float>, rotation: simd_quatf, scale: SIMD3<Float>
        var matrix: simd_float4x4 { Self.matrix(translation, rotation, scale) }
        static func matrix(_ translation: SIMD3<Float>, _ rotation: simd_quatf, _ scale: SIMD3<Float>) -> simd_float4x4 {
            var matrix = simd_float4x4(rotation)
            matrix.columns.0 *= scale.x; matrix.columns.1 *= scale.y; matrix.columns.2 *= scale.z
            matrix.columns.3 = SIMD4(translation, 1)
            return matrix
        }
    }
    struct Animation: Sendable {
        let id: Int, fps: Float, frames: Int, channels: [[Key]]
    }
    let meshes: [ScenePuppetMesh]
    let bones: [Bone]
    let animations: [Animation]
    let inverseWorldBind: [simd_float4x4]
    let animationID: Int?
    let speed: Double

    func palette(at time: Double) throws -> [simd_float4x4] {
        guard time.isFinite, time >= 0, time <= 100 * 365.25 * 86_400 else { throw SceneRuntimeError.malformed("Puppet animation time") }
        guard !bones.isEmpty else { return [matrix_identity_float4x4] }
        guard let id = animationID, let animation = animations.first(where: { $0.id == id }) else {
            return Array(repeating: matrix_identity_float4x4, count: bones.count)
        }
        let frame = (max(0, time) * speed * Double(animation.fps)).truncatingRemainder(dividingBy: Double(animation.frames))
        let index = Int(frame), fraction = Float(frame - Double(index))
        var world: [simd_float4x4] = [], result: [simd_float4x4] = []
        for bone in bones.indices {
            let keys = animation.channels[bone], a = keys[index], b = keys[index + 1]
            let local = Key.matrix(simd_mix(a.translation, b.translation, SIMD3(repeating: fraction)),
                                   simd_slerp(a.rotation, b.rotation, fraction),
                                   simd_mix(a.scale, b.scale, SIMD3(repeating: fraction)))
            let current = try checkedSceneMatrix(bones[bone].parent.map { world[$0] * local } ?? local, context: "Puppet animated hierarchy")
            world.append(current)
            result.append(try checkedSceneMatrix(current * inverseWorldBind[bone], context: "Puppet skin palette"))
        }
        return result
    }

    static func parse(_ data: Data, animationLayers: SceneJSON, limits: SceneLimits) throws -> Self {
        guard data.count <= limits.maximumAssetBytes else { throw SceneRuntimeError.budgetExceeded("Puppet bytes") }
        var reader = SceneByteReader(data: data)
        let tag = try reader.tag()
        guard tag.hasPrefix("MDLV"), let version = Int(tag.suffix(4)), (4...23).contains(version) else {
            throw SceneRuntimeError.unsupported("Puppet MDLV version")
        }
        let headerFlags = try reader.uint32(), skins = try reader.uint32(), meshCount = try reader.uint32()
        guard skins == 1, meshCount > 0, meshCount <= 128 else { throw SceneRuntimeError.budgetExceeded("Puppet mesh / skin count") }
        var meshes: [ScenePuppetMesh] = [], totalVertices = 0, totalIndices = 0
        for _ in 0..<meshCount {
            try Task.checkCancellation()
            let material = try ScenePath.canonical(reader.cString())
            let marker = try reader.uint32()
            guard marker == 0 || marker == 1 || marker == 2 else { throw SceneRuntimeError.unsupported("Puppet mesh marker") }
            if marker == 2 { _ = try reader.uint32() }
            if version >= 17 { for _ in 0..<6 { _ = try reader.float32() } }
            let flags = version >= 15 ? try reader.uint32() : headerFlags
            let known: UInt32 = 0x2 | 0x4 | 0x8 | 0x20 | 0x10000 | 0x800000 | 0x1000000
            guard flags & ~known == 0, flags & 0x8 != 0,
                  (flags & 0x800000 != 0) == (flags & 0x1000000 != 0) else {
                throw SceneRuntimeError.unsupported("Puppet vertex attributes")
            }
            let stride = 12 + (flags & 2 != 0 ? 12 : 0) + (flags & 4 != 0 ? 16 : 0) +
                (flags & 0x10000 != 0 ? 4 : 0) + (flags & 0x800000 != 0 ? 32 : 0) + 8 + (flags & 0x20 != 0 ? 8 : 0)
            let byteCount = Int(try reader.uint32())
            guard byteCount > 0, byteCount % stride == 0, byteCount <= reader.remaining else {
                throw SceneRuntimeError.malformed("Puppet vertex buffer")
            }
            let count = byteCount / stride
            totalVertices += count
            guard totalVertices <= limits.maximumPuppetVertices else { throw SceneRuntimeError.budgetExceeded("Puppet vertices") }
            var vertices: [ScenePuppetVertex] = []; vertices.reserveCapacity(count)
            for _ in 0..<count {
                let position = SIMD4(try reader.float32(), try reader.float32(), try reader.float32(), 1)
                guard abs(position.z) < 0.0001 else { throw SceneRuntimeError.unsupported("3D Puppet mesh") }
                if flags & 2 != 0 { _ = try reader.read(12) }
                if flags & 4 != 0 { _ = try reader.read(16) }
                if flags & 0x10000 != 0 { _ = try reader.read(4) }
                var indices = SIMD4<UInt32>(repeating: 0), weights = SIMD4<Float>(repeating: 0)
                if flags & 0x800000 != 0 {
                    for i in 0..<4 { indices[i] = try reader.uint32() }
                    for i in 0..<4 { weights[i] = try reader.float32() }
                    guard (0..<4).allSatisfy({ weights[$0] >= 0 && weights[$0] <= 1 }) else { throw SceneRuntimeError.malformed("Puppet skin weights") }
                    let sum = weights.sum()
                    guard sum > 0.0001, abs(sum - 1) < 0.01 else { throw SceneRuntimeError.malformed("Puppet weight sum") }
                    weights /= sum
                }
                let uv = SIMD2(try reader.float32(), try reader.float32())
                if flags & 0x20 != 0 { throw SceneRuntimeError.unsupported("Puppet secondary UV") }
                vertices.append(.init(position: position, weights: weights, bones: indices, uv: uv))
            }
            let indexBytes = Int(try reader.uint32()), indexSize = version >= 23 && count > 65_535 ? 4 : 2
            guard indexBytes > 0, indexBytes % (3 * indexSize) == 0, indexBytes <= reader.remaining else {
                throw SceneRuntimeError.malformed("Puppet index buffer")
            }
            totalIndices += indexBytes / indexSize
            guard totalIndices <= limits.maximumPuppetVertices * 6 else { throw SceneRuntimeError.budgetExceeded("Puppet indices") }
            var indices: [UInt32] = []; indices.reserveCapacity(indexBytes / indexSize)
            for _ in 0..<(indexBytes / indexSize) {
                let index = indexSize == 4 ? try reader.uint32() : UInt32(try reader.uint16())
                guard index < count else { throw SceneRuntimeError.malformed("Puppet index outside vertices") }
                indices.append(index)
            }
            if version >= 21 {
                guard try reader.uint8() == 0, try reader.uint8() == 0 else { throw SceneRuntimeError.unsupported("Puppet UV2 / parts") }
            }
            if version >= 22, try reader.uint32() != 0 { throw SceneRuntimeError.unsupported("Puppet clipping masks") }
            meshes.append(.init(material: material, vertices: vertices, indices: indices))
        }
        var bones: [Bone] = [], animations: [Animation] = []
        if reader.remaining > 0 {
            guard try reader.tag() == "MDLS0001" else { throw SceneRuntimeError.unsupported("Puppet skeleton section") }
            let end = Int(try reader.uint32()), count = Int(try reader.uint16())
            guard try reader.uint16() == 0, count > 0, count <= limits.maximumPuppetBones, end >= reader.offset, end <= data.count else {
                throw SceneRuntimeError.malformed("Puppet skeleton bounds")
            }
            for index in 0..<count {
                _ = try reader.cString()
                guard try reader.uint32() == 0 else { throw SceneRuntimeError.unsupported("Puppet physics simulation") }
                let parent = try reader.uint32()
                guard parent == UInt32.max || parent < index else { throw SceneRuntimeError.malformed("Puppet bone hierarchy") }
                guard try reader.uint32() == 64 else { throw SceneRuntimeError.malformed("Puppet bind matrix bytes") }
                let values = try (0..<16).map { _ in try reader.float32() }
                let matrix = simd_float4x4(SIMD4(values[0], values[1], values[2], values[3]), SIMD4(values[4], values[5], values[6], values[7]),
                    SIMD4(values[8], values[9], values[10], values[11]), SIMD4(values[12], values[13], values[14], values[15]))
                guard abs(simd_determinant(matrix)) > 0.000001 else { throw SceneRuntimeError.malformed("singular Puppet bind") }
                guard abs(values[2]) + abs(values[3]) + abs(values[6]) + abs(values[7]) + abs(values[8]) +
                      abs(values[9]) + abs(values[11]) + abs(values[14]) < 0.0001,
                      abs(values[15] - 1) < 0.0001 else { throw SceneRuntimeError.unsupported("Puppet 3D / projective bind") }
                guard try reader.cString().isEmpty else { throw SceneRuntimeError.unsupported("Puppet bone simulation settings") }
                bones.append(.init(parent: parent == UInt32.max ? nil : Int(parent), bind: matrix))
            }
            guard reader.offset == end else { throw SceneRuntimeError.unsupported("Puppet skeleton extras") }
        }
        if reader.remaining > 0 {
            let tag = try reader.tag()
            guard ["MDLA0001", "MDLA0002"].contains(tag) else { throw SceneRuntimeError.unsupported("Puppet animation section") }
            let end = Int(try reader.uint32()), count = Int(try reader.uint32())
            guard count <= 32, end >= reader.offset, end <= data.count else { throw SceneRuntimeError.malformed("Puppet animation bounds") }
            var keys = 0, ids = Set<Int>()
            for _ in 0..<count {
                let id = Int(try reader.uint32())
                guard ids.insert(id).inserted, try reader.uint32() == 0 else { throw SceneRuntimeError.malformed("Puppet animation ID") }
                let name = try reader.cString()
                if name.isEmpty { _ = try reader.cString() }
                let mode = try reader.cString()
                guard ["", "loop"].contains(mode) else { throw SceneRuntimeError.unsupported("Puppet animation mode") }
                let fps = try reader.float32(), frames = Int(try reader.uint32())
                guard try reader.uint32() == 0 else { throw SceneRuntimeError.unsupported("Puppet animation flags") }
                let channels = Int(try reader.uint32())
                guard fps > 0, fps <= 240, frames > 0, frames <= 10_000, channels == bones.count, channels > 0 else {
                    throw SceneRuntimeError.malformed("Puppet animation track count")
                }
                keys += channels * (frames + 1)
                guard keys <= limits.maximumPuppetKeys else { throw SceneRuntimeError.budgetExceeded("Puppet animation keys") }
                var tracks: [[Key]] = []
                for _ in 0..<channels {
                    _ = try reader.uint32()
                    guard Int(try reader.uint32()) == (frames + 1) * 36 else { throw SceneRuntimeError.malformed("Puppet track byte count") }
                    var track: [Key] = []; track.reserveCapacity(frames + 1)
                    for _ in 0...frames {
                        let translation = SIMD3(try reader.float32(), try reader.float32(), try reader.float32())
                        let angles = SIMD3(try reader.float32(), try reader.float32(), try reader.float32())
                        let scale = SIMD3(try reader.float32(), try reader.float32(), try reader.float32())
                        guard abs(translation.z) < 0.0001, abs(angles.x) + abs(angles.y) < 0.0001,
                              (0..<3).allSatisfy({ abs(scale[$0]) <= 1000 && abs(scale[$0]) > 0.000001 }) else {
                            throw SceneRuntimeError.unsupported("Puppet 3D animation / scale")
                        }
                        track.append(.init(translation: translation, rotation: simd_quatf(angle: angles.z, axis: SIMD3(0, 0, 1)), scale: scale))
                    }
                    tracks.append(track)
                }
                guard try reader.uint32() == 0 else { throw SceneRuntimeError.unsupported("Puppet animation events") }
                animations.append(.init(id: id, fps: fps, frames: frames, channels: tracks))
            }
            if reader.offset + 4 == end { guard try reader.uint32() == 0 else { throw SceneRuntimeError.malformed("Puppet animation padding") } }
            guard reader.offset == end else { throw SceneRuntimeError.unsupported("Puppet animation tail") }
        }
        guard reader.remaining == 0 else { throw SceneRuntimeError.unsupported("Puppet trailing sections") }
        for mesh in meshes {
            for vertex in mesh.vertices {
                for i in 0..<4 where vertex.weights[i] > 0 {
                    guard vertex.bones[i] < bones.count else { throw SceneRuntimeError.malformed("Puppet skin bone outside skeleton") }
                }
            }
        }
        var world: [simd_float4x4] = [], inverse: [simd_float4x4] = []
        for bone in bones {
            let matrix = try checkedSceneMatrix(bone.parent.map { world[$0] * bone.bind } ?? bone.bind, context: "Puppet bind hierarchy")
            world.append(matrix)
            inverse.append(try checkedSceneMatrix(simd_inverse(matrix), context: "Puppet inverse bind"))
        }
        let layers = animationLayers.array ?? []
        guard layers.count <= 1 else { throw SceneRuntimeError.unsupported("Puppet animation blending") }
        var id: Int?, speed: Double = 1
        if let layer = layers.first {
            guard layer["additive"].bool != true, try scalar(layer["blend"], fallback: 1) == 1,
                  let number = layer["animation"].number ?? layer["id"].number, number.rounded() == number,
                  abs(number) <= Double(Int32.max) else { throw SceneRuntimeError.unsupported("Puppet animation layer") }
            id = layer["visible"].seed.bool == false ? nil : Int(number)
            speed = Double(try scalar(layer["rate"] == .null ? layer["speed"] : layer["rate"], fallback: 1))
            guard speed >= 0, speed <= 10, animations.contains(where: { $0.id == Int(number) }) else { throw SceneRuntimeError.malformed("Puppet animation layer ID / speed") }
        }
        return .init(meshes: meshes, bones: bones, animations: animations, inverseWorldBind: inverse, animationID: id, speed: speed)
    }
}

extension SceneByteReader {
    mutating func uint8() throws -> UInt8 { try read(1)[0] }
    mutating func uint16() throws -> UInt16 { let bytes = try read(2); return UInt16(bytes[0]) | UInt16(bytes[1]) << 8 }
    mutating func float32() throws -> Float {
        let value = Float(bitPattern: try uint32())
        guard value.isFinite, abs(value) <= 1_000_000 else { throw SceneRuntimeError.malformed("Puppet non-finite / oversized float") }
        return value
    }
    mutating func cString() throws -> String {
        var bytes = Data()
        for _ in 0..<4096 {
            let byte = try uint8()
            if byte == 0 {
                guard let string = String(data: bytes, encoding: .utf8) else { throw SceneRuntimeError.malformed("Puppet string encoding") }
                return string
            }
            bytes.append(byte)
        }
        throw SceneRuntimeError.budgetExceeded("Puppet string length")
    }
}
