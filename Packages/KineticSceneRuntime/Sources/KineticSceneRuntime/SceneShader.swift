import Foundation

/// Explicit small compatibility surface. Unsupported GLSL is rejected before GPU compilation.
/// Full upstream shader translation remains a separate extraction task; no shader is silently replaced.
struct SceneShader {
    static let vertex = """
    #include <metal_stdlib>
    using namespace metal;
    struct SceneVertex { float2 position; float2 uv; };
    struct SceneVarying { float4 position [[position]]; float2 uv; float4 tint; };
    struct SceneUniforms { float4 color; float4 inputs; float4 sampling; };
    vertex SceneVarying sceneVertex(uint id [[vertex_id]], constant SceneVertex *vertices [[buffer(0)]]) {
        SceneVarying out;
        out.position = float4(vertices[id].position, 0, 1);
        out.uv = vertices[id].uv;
        out.tint = float4(1);
        return out;
    }
    """
    static let imageFragment = """
    fragment float4 sceneFragment(SceneVarying in [[stage_in]],
        texture2d<float> g_Texture0 [[texture(0)]], sampler s [[sampler(0)]],
        constant SceneUniforms &u [[buffer(0)]]) {
        float4 pixel = g_Texture0.sample(s, in.uv * u.sampling.xy);
        if (u.sampling.z == 1) pixel = float4(pixel.rrr, pixel.g);
        if (u.sampling.z == 2) pixel = float4(pixel.rrr, 1);
        return pixel * u.color * in.tint;
    }
    """
    static let particleVertex = """
    struct SceneParticle { float4 geometry; float4 color; };
    struct SceneParticleUniforms { float3x3 transform; float4 projection; float4 view; };
    vertex SceneVarying sceneParticleVertex(uint vertexIndex [[vertex_id]], uint instance [[instance_id]],
        constant SceneParticle *particles [[buffer(1)]], constant SceneParticleUniforms &u [[buffer(2)]]) {
        const float2 corners[6] = {float2(-.5,-.5),float2(.5,-.5),float2(-.5,.5),
            float2(-.5,.5),float2(.5,-.5),float2(.5,.5)};
        const float2 uv[6] = {float2(0,1),float2(1,1),float2(0,0),float2(0,0),float2(1,1),float2(1,0)};
        SceneParticle p = particles[instance];
        float2 corner = corners[vertexIndex] * p.geometry.z;
        float c=cos(p.geometry.w),s=sin(p.geometry.w);
        float2 local = p.geometry.xy + float2(c*corner.x-s*corner.y,s*corner.x+c*corner.y);
        float3 world = u.transform * float3(local,1);
        SceneVarying out;
        out.position = float4((world.xy-u.projection.xy/2-u.view.yz)*u.view.x/u.projection.zw*2,0,1);
        out.uv=uv[vertexIndex];out.tint=p.color;return out;
    }
    """
    static let puppetVertex = """
    struct ScenePuppetVertex { float4 position; float4 weights; uint4 bones; float2 uv; };
    vertex SceneVarying scenePuppetVertex(uint vertexIndex [[vertex_id]],
        constant ScenePuppetVertex *vertices [[buffer(0)]], constant SceneParticleUniforms &u [[buffer(2)]],
        constant float4x4 *bones [[buffer(3)]]) {
        ScenePuppetVertex v = vertices[vertexIndex];
        float4 position=v.position;
        if(dot(v.weights,float4(1))>0) {
            position=float4(0);
            for(uint i=0;i<4;i++) if(v.weights[i]>0) position+=(bones[v.bones[i]]*v.position)*v.weights[i];
        }
        float3 world=u.transform*float3(position.xy,1);
        SceneVarying out;
        out.position=float4((world.xy-u.projection.xy/2-u.view.yz)*u.view.x/u.projection.zw*2,0,1);
        out.uv=v.uv;out.tint=float4(1);return out;
    }
    """

    static func fragment(_ path: String, resolver: SceneAssetResolver, combos: [String: Int] = [:],
                         constants: [String: SceneJSON] = [:], textureSlots: Set<Int> = [0]) throws -> String {
        let processor = try SceneShaderPreprocessor(combos: combos, constants: constants, maximumBytes: resolver.limits.maximumShaderBytes)
        let source = try processor.file(path, resolver: resolver)
        try processor.constants.validateConsumed()
        return try translated(processor.constants.bind(source), textureSlots: textureSlots)
    }

    static func translate(_ source: String, combos: [String: Int] = [:], constants: [String: SceneJSON] = [:],
                          textureSlots: Set<Int> = [0]) throws -> String {
        let processor = try SceneShaderPreprocessor(combos: combos, constants: constants)
        let source = try processor.process(source)
        try processor.constants.validateConsumed()
        return try translated(processor.constants.bind(source), textureSlots: textureSlots)
    }

    private static func translated(_ source: String, textureSlots: Set<Int>) throws -> String {
        guard textureSlots.allSatisfy({ (0..<8).contains($0) }) else { throw SceneRuntimeError.unsupported("shader texture slot") }
        var text = source
        var nested = 0
        for character in text {
            if character == "(" || character == "{" { nested += 1 }
            if character == ")" || character == "}" { nested -= 1 }
            guard nested <= 32, nested >= 0 else { throw SceneRuntimeError.budgetExceeded("shader syntax depth") }
        }
        guard nested == 0 else { throw SceneRuntimeError.malformed("shader syntax brackets") }
        guard !matches(text, pattern: #"\b(for|while|do|switch|samplerCube|imageStore|atomic\w*|buffer|device|thread|threadgroup|constant|reinterpret_cast|static_cast|auto|class|struct|namespace|template|typedef)\b|\[|\]|(?:float[234]?|int|uint)\s*\*"#) else {
            throw SceneRuntimeError.unsupported("shader control flow / resource operation")
        }
        let declarations = [
            #"\buniform\s+sampler2D\s+g_Texture[0-7]\s*;"#,
            #"\buniform\s+float\s+g_Time\s*;"#,
            #"\buniform\s+vec4\s+g_Color\s*;"#,
            #"\bvarying\s+vec2\s+v_TexCoord\s*;"#,
            #"\bprecision\s+(lowp|mediump|highp)\s+float\s*;"#
        ]
        for pattern in declarations { text = replace(text, pattern: pattern, with: "") }
        text = replace(text, pattern: #"(?m)^\s*#version[^\n]*$"#, with: "")
        guard !text.contains("#"), !matches(text, pattern: #"\b(uniform|varying|attribute|layout)\b"#),
              !text.contains("\""), !text.contains("'"),
              let main = text.range(of: #"\bvoid\s+main\s*\(\s*\)\s*\{"#, options: .regularExpression) else {
            throw SceneRuntimeError.unsupported("shader declarations / directives")
        }
        let helpers = try SceneShaderExpansion.helpers(String(text[..<main.lowerBound]))
        var body = String(text[main.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.last == "}" else { throw SceneRuntimeError.malformed("shader main") }
        body.removeLast()
        guard !matches(body, pattern: #"\breturn\b"#) else { throw SceneRuntimeError.unsupported("shader early return") }
        let references = try NSRegularExpression(pattern: #"\bg_Texture([0-9]+)\b"#)
        let usedSlots = Set(try references.matches(in: body, range: NSRange(body.startIndex..., in: body)).map { match -> Int in
            guard let range = Range(match.range(at: 1), in: body), let slot = Int(body[range]), textureSlots.contains(slot) else {
                throw SceneRuntimeError.unsupported("unbound shader texture slot")
            }
            return slot
        })
        // Every slot uses its own address/filter mode and padded TEX sampling transform.
        for slot in usedSlots {
            body = replace(body, pattern: "\\btexture2D\\s*\\(\\s*g_Texture" + String(slot) + "\\s*,",
                with: "kinetic_sample(g_Texture\(slot),s\(slot),textureSampling[\(slot)],")
        }
        func convert(_ code: String) -> String {
            var code = code
            for (from, to) in [("vec2", "float2"), ("vec3", "float3"), ("vec4", "float4"),
                           ("mat2", "float2x2"), ("mat3", "float3x3"), ("mat4", "float4x4"),
                           ("v_TexCoord", "in.uv"), ("g_Time", "u.inputs.x"), ("g_Color", "u.color"),
                           ("gl_FragColor", "result"), ("fract", "fract"), ("mod", "kinetic_mod")] {
                code = replace(code, pattern: "\\b" + from + "\\b", with: to)
            }
            return code
        }
        body = convert(body)
        body = replace(body, pattern: #"\bdiscard\s*;"#, with: "discard_fragment();")
        guard !body.contains("texture2D"), !matches(body, pattern: #"\bgl_\w+"#) else {
            throw SceneRuntimeError.unsupported("shader resource / builtin")
        }
        let resources = usedSlots.sorted().map { "texture2d<float> g_Texture\($0) [[texture(\($0))]], sampler s\($0) [[sampler(\($0))]]," }.joined(separator: "\n")
        return """
        \(SceneShaderExpansion.modulo)
        float4 kinetic_sample(texture2d<float> texture, sampler filter, float4 sampling, float2 uv) {
            float4 pixel = texture.sample(filter, uv * sampling.xy);
            if (sampling.z == 1) return float4(pixel.rrr, pixel.g);
            if (sampling.z == 2) return float4(pixel.rrr, 1);
            return pixel;
        }
        \(convert(helpers))
        fragment float4 sceneFragment(SceneVarying in [[stage_in]],
            \(resources)
            constant float4 *textureSampling [[buffer(1)]],
            constant SceneUniforms &u [[buffer(0)]]) {
            float4 result = float4(0);
            \(body)
            return result * in.tint;
        }
        """
    }
    private static func replace(_ text: String, pattern: String, with replacement: String) -> String {
        text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }
    private static func matches(_ text: String, pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }
}
