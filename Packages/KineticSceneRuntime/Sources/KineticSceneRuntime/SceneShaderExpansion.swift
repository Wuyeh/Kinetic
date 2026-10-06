import Foundation

/// Bounded, pure source transformations. No evaluation or native imports.
enum SceneShaderExpansion {
    /// Accept ordinary value-only GLSL helpers. Their call graph must be acyclic and bounded.
    /// Resource uniforms are available in the fragment entry point only.
    static func helpers(_ prefix: String) throws -> String {
        let signature = try NSRegularExpression(pattern:
            #"^\s*(float|int|bool|vec[234]|mat[234])\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(([^()]*)\)\s*\{"#)
        let parameter = try NSRegularExpression(pattern:
            #"^\s*(?:in\s+)?(?:float|int|bool|vec[234]|mat[234])\s+[A-Za-z_][A-Za-z0-9_]*\s*$"#)
        var remaining = prefix, functions: [String: String] = [:], order: [String] = []
        while !remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard functions.count < 32,
                  let match = signature.firstMatch(in: remaining, range: NSRange(remaining.startIndex..., in: remaining)),
                  let nameRange = Range(match.range(at: 2), in: remaining),
                  let argumentRange = Range(match.range(at: 3), in: remaining),
                  let head = Range(match.range, in: remaining) else {
                throw SceneRuntimeError.unsupported("shader helper declaration / count")
            }
            let name = String(remaining[nameRange]), arguments = String(remaining[argumentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard functions[name] == nil, name != "main", !name.hasPrefix("scene"), !name.hasPrefix("kinetic_") else {
                throw SceneRuntimeError.unsupported("shader helper name / overload")
            }
            if !arguments.isEmpty && arguments != "void" {
                let fields = arguments.components(separatedBy: ",")
                guard fields.count <= 16, fields.allSatisfy({
                    parameter.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil
                }) else { throw SceneRuntimeError.unsupported("shader helper parameters") }
            }
            var cursor = head.upperBound, depth = 1
            while cursor < remaining.endIndex, depth > 0 {
                if remaining[cursor] == "{" { depth += 1 }
                if remaining[cursor] == "}" { depth -= 1 }
                cursor = remaining.index(after: cursor)
            }
            guard depth == 0 else { throw SceneRuntimeError.malformed("shader helper braces") }
            let body = String(remaining[head.upperBound..<remaining.index(before: cursor)])
            guard body.range(of: #"\b(?:g_|gl_|v_)\w*\b"#, options: .regularExpression) == nil else {
                throw SceneRuntimeError.unsupported("shader helper global resource access")
            }
            functions[name] = body; order.append(name)
            remaining = String(remaining[cursor...])
        }
        var visiting = Set<String>(), complete = Set<String>(), sorted: [String] = []
        func visit(_ name: String, depth: Int) throws {
            if complete.contains(name) { return }
            guard depth < 16, visiting.insert(name).inserted else { throw SceneRuntimeError.unsupported("recursive shader helpers") }
            for candidate in order where functions[name]!.range(of: "\\b" + candidate + "\\s*\\(", options: .regularExpression) != nil {
                try visit(candidate, depth: depth + 1)
            }
            visiting.remove(name); complete.insert(name); sorted.append(name)
        }
        for name in order { try visit(name, depth: 0) }
        // Reorder definitions so MSL does not require GLSL's optional forward prototypes.
        var definitions: [String: String] = [:], rest = prefix
        for name in order {
            let match = signature.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest))!
            let head = Range(match.range, in: rest)!
            var cursor = head.upperBound, depth = 1
            while depth > 0 {
                if rest[cursor] == "{" { depth += 1 }
                if rest[cursor] == "}" { depth -= 1 }
                cursor = rest.index(after: cursor)
            }
            var definition = String(rest[..<cursor])
            definition = definition.replacingOccurrences(of: #"\bin\s+"#, with: "", options: .regularExpression)
            definition = definition.replacingOccurrences(of: #"\(\s*void\s*\)"#, with: "()", options: .regularExpression)
            definitions[name] = definition; rest = String(rest[cursor...])
        }
        return sorted.compactMap { definitions[$0] }.joined(separator: "\n")
    }

    // GLSL mod is floor-based; Metal fmod is remainder-based and differs for negative x.
    static let modulo = """
    float kinetic_mod(float x,float y){return x-y*floor(x/y);}
    float2 kinetic_mod(float2 x,float2 y){return x-y*floor(x/y);}
    float3 kinetic_mod(float3 x,float3 y){return x-y*floor(x/y);}
    float4 kinetic_mod(float4 x,float4 y){return x-y*floor(x/y);}
    float2 kinetic_mod(float2 x,float y){return x-y*floor(x/y);}
    float3 kinetic_mod(float3 x,float y){return x-y*floor(x/y);}
    float4 kinetic_mod(float4 x,float y){return x-y*floor(x/y);}
    """
}
