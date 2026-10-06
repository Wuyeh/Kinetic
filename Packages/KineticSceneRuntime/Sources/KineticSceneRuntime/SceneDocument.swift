import Foundation
import simd

public struct SceneTransform: Sendable, Equatable {
    public let origin: SIMD2<Float>
    public let scale: SIMD2<Float>
    public let rotation: Float
    public var matrix: simd_float3x3 {
        let cosine = cos(rotation), sine = sin(rotation)
        return .init(columns: (SIMD3(cosine * scale.x, sine * scale.x, 0),
                              SIMD3(-sine * scale.y, cosine * scale.y, 0), SIMD3(origin.x, origin.y, 1)))
    }
}

public enum SceneLayerKind: Sendable, Equatable {
    case image(String)
    case text(String, font: String, pointSize: Float)
    case particles(String)
}

public enum SceneBlend: String, Sendable { case normal, additive }

public struct SceneLayer: Sendable, Equatable {
    public let id: String
    public let name: String
    public let parentID: String?
    public let kind: SceneLayerKind
    public let transform: SceneTransform
    public let size: SIMD2<Float>?
    public let color: SIMD4<Float>
    public let visible: Bool
    public let material: String?
    public let blend: SceneBlend
}

/// Typed, renderer-neutral authored defaults. Property overrides/presets belong to Module 29.
public struct SceneDocument: Sendable {
    public let size: SIMD2<Float>
    public let clearColor: SIMD4<Float>
    public let layers: [SceneLayer]
    public let cameraParallax: Float
    public let source: SceneJSON
    let scripts: [SceneScriptBinding]

    public static func parse(_ data: Data, limits: SceneLimits = .init()) throws -> SceneDocument {
        let json = try SceneJSON.parse(data, limits: limits)
        guard json.object != nil, let objects = json["objects"].array else { throw SceneRuntimeError.malformed("scene objects") }
        guard objects.count <= limits.maximumObjects else { throw SceneRuntimeError.budgetExceeded("scene objects") }
        // Only typed layer bindings may reach the isolated executor. Unknown script locations
        // must fail explicitly instead of being ignored or evaluated in another context.
        let scriptFields: Set<String> = ["origin", "scale", "angles", "color", "alpha", "visible"]
        func checkScripts(_ value: SceneJSON, allowedEnvelope: Bool = false) throws {
            if let fields = value.object {
                for (key, child) in fields {
                    if ["script", "scripts"].contains(key.lowercased()), child != .null {
                        guard allowedEnvelope, key == "script", child.string != nil else {
                            throw SceneRuntimeError.unsupported("SceneScript binding location")
                        }
                    } else {
                        try checkScripts(child)
                    }
                }
            } else if let values = value.array { for child in values { try checkScripts(child) } }
        }
        for (key, value) in json.object! where key != "objects" { try checkScripts(value) }
        for object in objects {
            for (key, value) in object.object ?? [:] { try checkScripts(value, allowedEnvelope: scriptFields.contains(key)) }
        }
        let general = json["general"]
        let projection = general["orthogonalprojection"]
        if general.object?.keys.contains("orthogonalprojection") == true && projection == .null {
            throw SceneRuntimeError.unsupported("perspective camera")
        }
        for key in ["bloom", "bloomstrength", "camerashake", "perspective", "enablepostprocessing"] {
            if general[key].seed.bool == true || (general[key].seed.number ?? 0) > 0 {
                throw SceneRuntimeError.unsupported("general.\(key)")
            }
        }
        let size = SIMD2<Float>(try scalar(projection["width"], fallback: 1920), try scalar(projection["height"], fallback: 1080))
        guard size.x > 0, size.y > 0, max(size.x, size.y) <= 32_768 else { throw SceneRuntimeError.malformed("scene projection size") }
        let clear = try vector(general["clearcolor"], fallback: SIMD3(0, 0, 0))
        var ids = Set<String>(), layers: [SceneLayer] = [], scripts: [SceneScriptBinding] = []
        var scriptBytes = 0
        for object in objects {
            guard let fields = object.object else { throw SceneRuntimeError.malformed("scene layer") }
            let id = object["id"].string ?? object["id"].number.map { String($0) }
            guard let id, !id.isEmpty, ids.insert(id).inserted else { throw SceneRuntimeError.malformed("missing / duplicate layer ID") }
            let name = object["name"].string ?? id
            for field in scriptFields.sorted() {
                if let source = object[field]["script"].string, !source.isEmpty {
                    let properties = object[field]["scriptproperties"]
                    guard properties == .null || properties.object != nil else { throw SceneRuntimeError.malformed("SceneScript properties") }
                    scriptBytes += source.utf8.count
                    guard scripts.count < 32, scriptBytes <= 256 * 1_024 else {
                        throw SceneRuntimeError.budgetExceeded("SceneScript source / bindings")
                    }
                    let binding = SceneScriptBinding(id: String(scripts.count), layerID: id, target: field, source: source,
                        value: object[field].seed, properties: properties.object ?? [:])
                    _ = try binding.argument
                    scripts.append(binding)
                }
            }
            for key in ["effects", "animations", "dependencies"] {
                if let value = fields[key], value != .null, value.array?.isEmpty != true {
                    throw SceneRuntimeError.unsupported("\(name): \(key)")
                }
            }
            for key in ["sound", "light", "attachment", "anchor", "perspective", "instance"] {
                if let value = fields[key], value != .null, value != .bool(false) {
                    throw SceneRuntimeError.unsupported("\(name): \(key)")
                }
            }
            let kind: SceneLayerKind
            if let path = object["particle"].seed.string {
                kind = .particles(try ScenePath.canonical(path))
            } else if let path = object["image"].seed.string ?? object["model"].seed.string {
                kind = .image(try ScenePath.canonical(path))
            } else if let text = object["text"].seed.string {
                guard text.utf8.count <= 16_384 else { throw SceneRuntimeError.budgetExceeded("text length") }
                kind = .text(text, font: object["font"].seed.string ?? "Helvetica", pointSize: try scalar(object["pointsize"], fallback: 32))
            } else { throw SceneRuntimeError.unsupported("\(name): unknown layer kind") }
            if let animations = object["animationlayers"].array, !animations.isEmpty {
                guard case .image(let reference) = kind, reference.hasSuffix(".mdl") else {
                    throw SceneRuntimeError.unsupported("Puppet animation on a non-MDL layer")
                }
            }
            let origin = try vector(object["origin"], fallback: SIMD3(0, 0, 0))
            let scale = try vector(object["scale"], fallback: SIMD3(1, 1, 1))
            let angles = try vector(object["angles"], fallback: SIMD3(0, 0, 0))
            guard abs(angles.x) < 0.0001, abs(angles.y) < 0.0001 else { throw SceneRuntimeError.unsupported("3D layer rotation") }
            let authoredSize: SIMD2<Float>?
            if object["size"] != .null {
                let vector = try vector(object["size"], fallback: SIMD3(0, 0, 0))
                guard vector.x > 0, vector.y > 0 else { throw SceneRuntimeError.malformed("layer size") }
                authoredSize = SIMD2(vector.x, vector.y)
            } else { authoredSize = nil }
            let color = try vector(object["color"], fallback: SIMD3(1, 1, 1))
            let alpha = try scalar(object["alpha"], fallback: 1)
            guard (0...1).contains(alpha), abs(origin.x) <= 1_000_000, abs(origin.y) <= 1_000_000,
                  abs(scale.x) <= 1_000, abs(scale.y) <= 1_000 else { throw SceneRuntimeError.malformed("layer transform / alpha") }
            let blendName = object["blendmode"].string ?? "normal"
            guard let blend = SceneBlend(rawValue: blendName) else { throw SceneRuntimeError.unsupported("blend mode: \(blendName)") }
            let parent = object["parent"].string ?? object["parent"].number.map { String($0) }
            let material = try object["material"].string.map(ScenePath.canonical)
            layers.append(.init(id: id, name: name, parentID: parent, kind: kind,
                transform: .init(origin: SIMD2(origin.x, origin.y), scale: SIMD2(scale.x, scale.y), rotation: angles.z * .pi / 180),
                size: authoredSize, color: SIMD4(color.x, color.y, color.z, alpha), visible: object["visible"].seed.bool ?? true,
                material: material, blend: blend))
        }
        let index = Dictionary(uniqueKeysWithValues: layers.map { ($0.id, $0) })
        for layer in layers {
            var visited = Set<String>(), current: SceneLayer? = layer
            while let item = current {
                guard visited.insert(item.id).inserted else { throw SceneRuntimeError.malformed("cyclic layer parents") }
                guard visited.count <= limits.maximumReferenceDepth else { throw SceneRuntimeError.budgetExceeded("layer hierarchy") }
                if let parent = item.parentID {
                    guard let next = index[parent] else { throw SceneRuntimeError.malformed("missing parent: \(parent)") }
                    current = next
                } else { current = nil }
            }
        }
        let parallax = general["cameraparallax"].seed.bool == true ? try scalar(general["cameraparallaxamount"], fallback: 0.05) : 0
        return .init(size: size, clearColor: SIMD4(clear.x, clear.y, clear.z, 1), layers: layers, cameraParallax: parallax,
                     source: json, scripts: scripts)
    }
}

func scalar(_ raw: SceneJSON, fallback: Float) throws -> Float {
    let value = raw.seed
    if value == .null { return fallback }
    if let number = value.number, number.isFinite, abs(number) <= Double(Float.greatestFiniteMagnitude) { return Float(number) }
    if let string = value.string, let number = Float(string), number.isFinite { return number }
    throw SceneRuntimeError.malformed("numeric authored value")
}

func vector(_ raw: SceneJSON, fallback: SIMD3<Float>) throws -> SIMD3<Float> {
    let value = raw.seed
    if value == .null { return fallback }
    let values: [Float]
    if let string = value.string {
        let components = string.split(whereSeparator: { $0.isWhitespace })
        values = components.compactMap { Float($0) }
        guard values.count == components.count else { throw SceneRuntimeError.malformed("vector component") }
    }
    else if let array = value.array { values = try array.map { try scalar($0, fallback: 0) } }
    else { throw SceneRuntimeError.malformed("vector authored value") }
    guard (2...4).contains(values.count), values.allSatisfy(\.isFinite) else { throw SceneRuntimeError.malformed("vector components") }
    return SIMD3(values[0], values[1], values.count > 2 ? values[2] : 0)
}

func checkedSceneMatrix(_ matrix: simd_float3x3, context: String) throws -> simd_float3x3 {
    guard (0..<3).allSatisfy({ column in (0..<3).allSatisfy { matrix[column][$0].isFinite } }) else {
        throw SceneRuntimeError.malformed("non-finite \(context)")
    }
    return matrix
}

func checkedSceneMatrix(_ matrix: simd_float4x4, context: String) throws -> simd_float4x4 {
    guard (0..<4).allSatisfy({ column in (0..<4).allSatisfy { matrix[column][$0].isFinite } }) else {
        throw SceneRuntimeError.malformed("non-finite \(context)")
    }
    return matrix
}
