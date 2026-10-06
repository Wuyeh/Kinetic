import Foundation
import simd

struct SceneRenderNode: Sendable {
    let id: String
    let transform: simd_float3x3
    let size: SIMD2<Float>
    let color: SIMD4<Float>
    let blend: SceneBlend
    let texture: SceneTexture
    let fragment: String
    let preprocessFragments: [String]
    /// One row per material pass, including the final pass; slot zero is the primary/previous input.
    let passTextures: [[SceneTexture?]]
    let particles: SceneParticleDefinition?
    let puppet: ScenePuppet?
    let puppetMeshIndex: Int?
}

/// Resource resolution happens once during prepare, not on the frame path.
struct SceneRenderGraph: Sendable {
    let document: SceneDocument
    let nodes: [SceneRenderNode]
    let residentBytes: Int
    let limits: SceneLimits

    static func load(root: URL, engineAssets: URL? = nil, limits: SceneLimits = .init()) throws -> SceneRenderGraph {
        let resolver = try SceneAssetResolver(root: root, additionalRoots: engineAssets.map { [$0] } ?? [], limits: limits)
        let project = try SceneJSON.parse(resolver.readSceneOwned("project.json", maximumBytes: limits.maximumJSONBytes), limits: limits)
        guard project["type"].string?.lowercased() == "scene", let entry = project["file"].string else {
            throw SceneRuntimeError.malformed("project.json is not a Scene project")
        }
        if let dependencies = project["dependencies"].array, !dependencies.isEmpty {
            throw SceneRuntimeError.unsupported("external Workshop dependencies")
        }
        let document = try SceneDocument.parse(resolver.readSceneOwned(entry, maximumBytes: limits.maximumJSONBytes), limits: limits)
        let index = Dictionary(uniqueKeysWithValues: document.layers.map { ($0.id, $0) })
        var transforms: [String: simd_float3x3] = [:], visibility: [String: Bool] = [:]
        func world(_ layer: SceneLayer) throws -> (simd_float3x3, Bool) {
            if let matrix = transforms[layer.id] { return (matrix, visibility[layer.id]!) }
            let parent = try layer.parentID.flatMap { index[$0] }.map(world) ?? (matrix_identity_float3x3, true)
            let matrix = try checkedSceneMatrix(parent.0 * layer.transform.matrix, context: "layer hierarchy: \(layer.id)")
            let visible = parent.1 && layer.visible
            transforms[layer.id] = matrix; visibility[layer.id] = visible
            return (matrix, visible)
        }
        var nodes: [SceneRenderNode] = [], total = 0, shaderBytes = 0, particleCount = 0
        var shaderPrograms = Set<String>()
        var textures: [String: SceneTexture] = [:]
        func resource(_ reference: String) throws -> (SceneTexture, String, [String], [[SceneTexture?]]) {
            let material = try resolve(reference: reference, resolver: resolver)
            var pending = 0
            func texture(_ path: String) throws -> SceneTexture {
                let texture: SceneTexture
                if let cached = textures[path] { texture = cached }
                else { texture = try SceneTexture.decode(resolver.read(path), limits: limits) }
                guard texture.residentBytes <= limits.maximumResidentBytes - total - pending else {
                    throw SceneRuntimeError.budgetExceeded("resident scene material textures")
                }
                pending += texture.residentBytes; textures[path] = texture
                return texture
            }
            let primary = try texture(material.texture)
            let auxiliary = try material.auxiliary.map { row in try row.map { try $0.map(texture) } }
            return (primary, material.shader, material.preprocess, auxiliary)
        }
        func admit(_ texture: SceneTexture, fragment: String, preprocess: [String], passTextures: [[SceneTexture?]], extraBytes: Int = 0) throws {
            for fragment in preprocess + [fragment] where shaderPrograms.insert(fragment).inserted {
                guard shaderPrograms.count <= limits.maximumShaderPrograms, fragment.utf8.count <= limits.maximumShaderBytes - shaderBytes else {
                    throw SceneRuntimeError.budgetExceeded("scene shader programs")
                }
                shaderBytes += fragment.utf8.count
            }
            let targetBytes = Int(ceil(texture.logicalSize.x)) * Int(ceil(texture.logicalSize.y)) * 4 * preprocess.count
            let auxiliaryBytes = passTextures.flatMap { $0 }.compactMap { $0 }.reduce(0) { $0 + $1.residentBytes }
            guard texture.residentBytes + auxiliaryBytes + extraBytes + targetBytes <= limits.maximumResidentBytes - total, nodes.count < limits.maximumObjects else {
                throw SceneRuntimeError.budgetExceeded("resident scene textures / draw nodes")
            }
            total += texture.residentBytes + auxiliaryBytes + extraBytes + targetBytes
        }
        layers: for layer in document.layers {
            try Task.checkCancellation()
            let (transform, visible) = try world(layer)
            // A script may show a currently hidden layer or parent after prepare.
            guard visible || !document.scripts.isEmpty else { continue }
            let texture: SceneTexture, fragment: String
            let preprocess: [String]
            let passTextures: [[SceneTexture?]]
            let particles: SceneParticleDefinition?
            switch layer.kind {
            case .text(let text, let font, let pointSize):
                particles = nil
                let fontData: Data?
                if ["ttf", "otf"].contains((font as NSString).pathExtension.lowercased()) {
                    fontData = try resolver.read(font, maximumBytes: min(limits.maximumAssetBytes, 8 * 1_024 * 1_024))
                } else { fontData = nil }
                texture = try .text(text, font: font, pointSize: pointSize, size: layer.size, limits: limits, fontData: fontData)
                fragment = SceneShader.imageFragment
                preprocess = []
                passTextures = [[]]
            case .image, .particles:
                let reference: String
                if case .particles(let path) = layer.kind {
                    let definition = try SceneParticleDefinition.parse(SceneJSON.parse(
                        resolver.read(path, maximumBytes: limits.maximumJSONBytes), limits: limits), limits: limits)
                    particleCount += definition.count
                    guard particleCount <= limits.maximumSceneParticles else { throw SceneRuntimeError.budgetExceeded("scene particle count") }
                    particles = definition
                    reference = definition.material
                    let bufferBytes = definition.count * MemoryLayout<SceneParticleInstance>.stride
                    guard bufferBytes <= limits.maximumResidentBytes - total else { throw SceneRuntimeError.budgetExceeded("particle instance buffers") }
                    total += bufferBytes
                } else if case .image(let path) = layer.kind { reference = path; particles = nil }
                else { throw SceneRuntimeError.malformed("particle / image layer") }
                if (reference as NSString).pathExtension.lowercased() == "mdl" {
                    let object = document.source["objects"].array?.first {
                        ($0["id"].string ?? $0["id"].number.map { String($0) }) == layer.id
                    } ?? .null
                    let puppet = try ScenePuppet.parse(resolver.read(reference), animationLayers: object["animationlayers"], limits: limits)
                    for (index, mesh) in puppet.meshes.enumerated() {
                        let (texture, fragment, preprocess, passTextures) = try resource(layer.material ?? mesh.material)
                        let extra = mesh.vertices.count * MemoryLayout<ScenePuppetVertex>.stride + mesh.indices.count * 4 +
                            max(1, puppet.bones.count) * MemoryLayout<simd_float4x4>.stride
                        try admit(texture, fragment: fragment, preprocess: preprocess, passTextures: passTextures, extraBytes: extra)
                        nodes.append(.init(id: layer.id, transform: transform, size: layer.size ?? texture.logicalSize, color: layer.color,
                            blend: layer.blend, texture: texture, fragment: fragment, preprocessFragments: preprocess,
                            passTextures: passTextures,
                            particles: nil, puppet: puppet, puppetMeshIndex: index))
                    }
                    continue layers
                }
                (texture, fragment, preprocess, passTextures) = try resource(layer.material ?? reference)
            }
            try admit(texture, fragment: fragment, preprocess: preprocess, passTextures: passTextures)
            nodes.append(.init(id: layer.id, transform: transform, size: layer.size ?? texture.logicalSize, color: layer.color,
                               blend: layer.blend, texture: texture, fragment: fragment, preprocessFragments: preprocess,
                               passTextures: passTextures,
                               particles: particles, puppet: nil, puppetMeshIndex: nil))
        }
        return .init(document: document, nodes: nodes, residentBytes: total, limits: limits)
    }

    private static func resolve(reference: String, resolver: SceneAssetResolver) throws -> (texture: String, shader: String, preprocess: [String], auxiliary: [[String?]]) {
        func path(_ texture: String) throws -> String {
            let path = try ScenePath.canonical(texture)
            let candidates = [path, path + ".tex", "materials/" + path, "materials/" + path + ".tex"]
            for candidate in candidates {
                do { _ = try resolver.read(candidate); return candidate }
                catch SceneRuntimeError.missingAsset { continue }
            }
            throw SceneRuntimeError.missingAsset("materials/\(path).tex")
        }
        var current = try ScenePath.canonical(reference), visited = Set<String>()
        for _ in 0..<resolver.limits.maximumReferenceDepth {
            guard visited.insert(current).inserted else { throw SceneRuntimeError.malformed("cyclic model / material reference") }
            if (current as NSString).pathExtension.lowercased() == "mdl" { throw SceneRuntimeError.unsupported("Puppet MDL") }
            if (current as NSString).pathExtension.lowercased() != "json" { return (current, SceneShader.imageFragment, [], [[]]) }
            let json = try SceneJSON.parse(resolver.read(current, maximumBytes: resolver.limits.maximumJSONBytes), limits: resolver.limits)
            if let material = json["material"].string { current = try ScenePath.canonical(material); continue }
            guard let passes = json["passes"].array, !passes.isEmpty, passes.count <= 8 else { throw SceneRuntimeError.unsupported("material pass count / unresolved model: \(current)") }
            guard json["usertextures"] == .null || json["usertextures"].array?.isEmpty == true else { throw SceneRuntimeError.unsupported("material usertextures") }
            var fragments: [String] = [], source: String?
            var auxiliary: [[String?]] = []
            for (index, pass) in passes.enumerated() {
                guard let rawInputs = pass["textures"].array, !rawInputs.isEmpty, rawInputs.count <= 8 else {
                    throw SceneRuntimeError.unsupported("material texture inputs")
                }
                let inputs = try rawInputs.map { input -> String? in
                    if input == .null || input.string == "" { return nil }
                    guard let name = input.string ?? input["name"].string, !name.isEmpty else { throw SceneRuntimeError.malformed("material texture path") }
                    return name
                }
                guard let texture = inputs[0] else { throw SceneRuntimeError.malformed("material primary texture") }
                if index == 0 {
                    guard texture != "previous", !texture.hasPrefix("_rt_") else { throw SceneRuntimeError.unsupported("material scene framebuffer input") }
                    source = texture
                } else {
                    guard texture == "previous" else { throw SceneRuntimeError.unsupported("material requires linear previous-pass input") }
                }
                for field in ["constants", "usertextures", "target"] where pass[field] != .null && pass[field].object?.isEmpty != true && pass[field].array?.isEmpty != true {
                    throw SceneRuntimeError.unsupported("material \(field)")
                }
                var extra = [String?](repeating: nil, count: inputs.count)
                for slot in inputs.indices where slot > 0 {
                    if let input = inputs[slot] {
                        guard input != "previous", !input.hasPrefix("_rt_") else { throw SceneRuntimeError.unsupported("secondary framebuffer texture") }
                        extra[slot] = try path(input)
                    }
                }
                auxiliary.append(extra)
                if let blending = pass["blending"].string, !["normal", "translucent"].contains(blending) {
                    throw SceneRuntimeError.unsupported("material blending: \(blending)")
                }
                for field in ["depthtest", "depthwrite"] where pass[field].string != nil && pass[field].string != "disabled" {
                    throw SceneRuntimeError.unsupported("material depth")
                }
                if let cull = pass["cullmode"].string, cull != "nocull" { throw SceneRuntimeError.unsupported("material culling") }
                let shader = pass["shader"].string ?? "genericimage"
                let constants: [String: SceneJSON]
                if pass["constantshadervalues"] == .null { constants = [:] }
                else if let values = pass["constantshadervalues"].object { constants = values }
                else { throw SceneRuntimeError.malformed("material shader constants") }
                var combos: [String: Int] = [:]
                if pass["combos"] != .null {
                    guard let values = pass["combos"].object, values.count <= 64 else { throw SceneRuntimeError.malformed("material shader combos") }
                    for (name, value) in values {
                        if let flag = value.bool { combos[name] = flag ? 1 : 0 }
                        else if let number = value.number, number.rounded() == number, abs(number) <= 1_000_000 { combos[name] = Int(number) }
                        else if let text = value.string, let number = Int(text), number >= -1_000_000, number <= 1_000_000 { combos[name] = number }
                        else { throw SceneRuntimeError.malformed("material shader combo integer") }
                    }
                }
                // The built-in image program has no authored conditional branches.
                let slots = Set(inputs.indices.filter { inputs[$0] != nil })
                guard !["genericimage", "image"].contains(shader) || (combos.isEmpty && constants.isEmpty && slots == [0]) else {
                    throw SceneRuntimeError.unsupported("built-in image shader combos / constants / additional textures")
                }
                fragments.append(["genericimage", "image"].contains(shader) ? SceneShader.imageFragment :
                    try SceneShader.fragment("shaders/\(shader).frag", resolver: resolver, combos: combos, constants: constants, textureSlots: slots))
            }
            let texture = source!, fragment = fragments.removeLast()
            return (try path(texture), fragment, fragments, auxiliary)
        }
        throw SceneRuntimeError.budgetExceeded("model / material reference depth")
    }
}
