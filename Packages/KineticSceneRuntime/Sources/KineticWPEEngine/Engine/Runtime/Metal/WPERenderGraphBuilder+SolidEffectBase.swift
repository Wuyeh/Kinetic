#if !LITE_BUILD
import Foundation

/// Kinetic: a solid layer's colour must reach its first effect even when the layer is transparent.
///
/// Wallpaper Engine's solid layer writes `vec4(g_Color, g_Alpha)` straight into the layer buffer, so an effect that
/// replaces alpha (tint with BLENDMODE 0 sets `albedo.a = 1`) still finds the colour. Layer composites here are
/// premultiplied: a solid layer that parses to alpha 0 (an unauthored alpha under effects) stored `(0, 0, 0, 0)` and
/// Workshop 3326873240's tinted panel body came out black. For the base → first-effect hand-off only, the solid
/// pass writes straight and that effect reads its input without un-premultiplying; the effect's own output and
/// everything after it keep the premultiplied contract.
extension WPERenderGraphBuilder {
    static func keepingSolidBaseColorForEffects(in pipeline: WPEPreparedRenderPipeline) -> WPEPreparedRenderPipeline {
        var changed = false
        let layers = pipeline.layers.map { layer -> WPEPreparedRenderLayer in
            guard layer.effectPublication == nil, layer.passes.count >= 2 else { return layer }
            let base = layer.passes[0], effect = layer.passes[1]
            guard base.shader?.isBuiltin == true,
                  WPEBuiltinShaderKind(normalizing: base.pass.shader) == .solidLayer,
                  base.alphaContract == nil, base.pass.visibilityGate == nil,
                  case let .layerComposite(composite) = base.pass.target,
                  Self.storesSourceUnchanged(base.pass.blending),
                  effect.shader?.isBuiltin == false, case .effect = effect.pass.phase,
                  effect.alphaContract == nil, effect.pass.visibilityGate == nil,
                  effect.pass.source == .fbo(composite),
                  effect.pass.target != .layerComposite(name: composite),
                  Self.onlyNextPassReads(composite, in: layer, others: pipeline.layers) else { return layer }
            let inputSlots = WPEMetalRenderExecutor.premultipliedInputSlots(for: effect)
                .filter { Self.reference(at: $0, in: effect) != .fbo(composite) }
            var passes = layer.passes
            passes[0] = base.replacingAlphaContract(.init(unpremultipliedInputSlots: [], premultipliedOutput: false))
            passes[1] = effect.replacingAlphaContract(.init(
                unpremultipliedInputSlots: inputSlots,
                premultipliedOutput: WPEMetalRenderExecutor.usesPremultipliedOutput(blendMode: effect.pass.blending)
            ))
            changed = true
            return layer.replacing(passes: passes)
        }
        return changed ? WPEPreparedRenderPipeline(layers: layers) : pipeline
    }

    /// Into a cleared composite, a source factor of one keeps exactly what the fragment wrote.
    private static func storesSourceUnchanged(_ blending: String) -> Bool {
        let blend = blending.lowercased()
        return blend.hasPrefix("premultiplied") || blend == "disabled"
    }

    private static func reference(at slot: Int, in pass: WPEPreparedRenderPass) -> WPETextureReference? {
        pass.textureBindings[slot] ?? pass.pass.binds[slot] ?? pass.pass.textures[slot] ?? (slot == 0 ? pass.pass.source : nil)
    }

    private static func reads(_ composite: String, _ pass: WPEPreparedRenderPass) -> Bool {
        let target = WPETextureReference.fbo(composite)
        return pass.pass.source == target || pass.textureBindings.values.contains(target)
            || pass.pass.binds.values.contains(target) || pass.pass.textures.values.contains(target)
    }

    private static func writes(_ composite: String, _ pass: WPEPreparedRenderPass) -> Bool {
        switch pass.pass.target {
        case .layerComposite(let name), .fbo(let name): return name == composite
        case .scene: return false
        }
    }

    /// The straight values may only be seen by the first effect: no other layer may sample the composite, and in
    /// this layer no later pass may read it before something rewrites it.
    private static func onlyNextPassReads(
        _ composite: String, in layer: WPEPreparedRenderLayer, others: [WPEPreparedRenderLayer]
    ) -> Bool {
        for other in others where other.id != layer.id {
            if other.passes.contains(where: { reads(composite, $0) }) { return false }
        }
        for pass in layer.passes.dropFirst(2) {
            if reads(composite, pass) { return false }
            if writes(composite, pass) { break }
        }
        return true
    }
}

private extension WPEPreparedRenderPass {
    func replacingAlphaContract(_ contract: WPEShaderAlphaContract) -> WPEPreparedRenderPass {
        WPEPreparedRenderPass(
            pass: pass, shader: shader, textureBindings: textureBindings, comboValues: comboValues,
            uniformValues: uniformValues, materialUniformNames: materialUniformNames,
            stageUniformBindings: stageUniformBindings, layerTintOverride: layerTintOverride,
            alphaContract: contract, publicationVertexRole: publicationVertexRole, reusingAccess: access
        )
    }
}
#endif
