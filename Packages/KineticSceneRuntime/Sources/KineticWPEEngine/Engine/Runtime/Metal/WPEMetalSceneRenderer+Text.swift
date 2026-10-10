#if !LITE_BUILD
import AppKit
import MetalKit

struct WPETextFrameState {
    let pipeline: WPEPreparedRenderPipeline
    let payloads: [String: WPETextRenderPayload]
    let obsoleteTargetNames: Set<String>
}

extension WPEMetalSceneRenderer {
    // MARK: - Per-frame text graph state

    func prepareTextFrame(
        pipeline: WPEPreparedRenderPipeline,
        liveTextByID: [String: String],
        transforms: LiveScriptTransforms,
        parallaxFrame: WPECameraParallaxFrame
    ) -> WPETextFrameState {
        #if DEBUG
        WPECanonicalTraceRecorder.shared.recordOracleMediaInput(oracleMediaInputReceipt)
        #endif
        guard let textMeshRenderer, let fonts = textFontResolver, !textRenderPlans.isEmpty else {
            return WPETextFrameState(pipeline: pipeline, payloads: [:], obsoleteTargetNames: [])
        }

        let layerByID = Dictionary(
            pipeline.layers.map { ($0.graphLayer.objectID, $0.graphLayer) },
            uniquingKeysWith: { first, _ in first }
        )
        var updates: [String: (layout: WPETextLayoutSnapshot, initial: WPETextLayoutSnapshot)] = [:]
        var payloads: [String: WPETextRenderPayload] = [:]
        var obsoleteTargetNames: Set<String> = []
        var measuredSizes: [String: SIMD2<Double>] = [:]
        // Scripts read these as `layer.size` on their next tick.
        defer { sceneScriptSharedState?.publishTextLayerSizes(measuredSizes) }

        for plan in textRenderPlans {
            guard let layer = layerByID[plan.object.id] else { continue }
            let resolvedText = liveTextByID[plan.object.id] ?? plan.object.text
            // Kinetic: the frame layer already carries the timeline claim (a `startpaused` track holds its first
            // key until a script plays it); the object's own track would free-run and show hidden text.
            let resolvedAlpha = liveTextAlpha[plan.object.id]
                ?? layer.geometry.alphaAnimation?.scalar(at: lastRuntimeUniforms?.time ?? 0)
                ?? layer.geometry.alpha
            let liveObject = plan.object.withLiveText(
                resolvedText,
                alpha: plan.mode == .offscreen ? 1 : resolvedAlpha,
                color: transforms.colors[plan.object.id],
                pointSize: liveTextPointSizes[plan.object.id],
                horizontalAlignment: liveLayerPresentation[plan.object.id]?.horizontalAlignment,
                verticalAlignment: liveLayerPresentation[plan.object.id]?.verticalAlignment
            )
            let key = WPETextRenderPlanner.layoutKey(for: liveObject)
            let previous = textLayoutCache[plan.object.id]
            let layout: WPETextLayoutSnapshot
            if previous?.key == key {
                layout = previous!.snapshot
            } else {
                layout = WPETextRenderPlanner.snapshot(for: liveObject, fonts: fonts)
                textLayoutCache[plan.object.id] = WPETextLayoutCacheEntry(key: key, snapshot: layout)
                if plan.mode == .offscreen,
                   let previous,
                   previous.snapshot.surfaceSize != layout.surfaceSize {
                    obsoleteTargetNames.formUnion(layer.textOwnedTargetNames)
                }
            }
            updates[plan.object.id] = (layout, plan.initialLayout)
            measuredSizes[plan.object.id] = Self.scriptTextSize(layout, padding: liveObject.padding)

            let isVisible = (liveTextVisibility[plan.object.id] ?? plan.object.visible)
                && ancestorChainVisible(plan.object.id)
            #if DEBUG
            defer {
                WPECanonicalTraceRecorder.shared.recordTextInput(
                    layerID: plan.object.id, resolvedText: resolvedText, mode: plan.mode, layoutKey: key,
                    surfaceSize: layout.surfaceSize, visible: isVisible, alpha: resolvedAlpha,
                    hasMesh: payloads[plan.object.id]?.mesh != nil
                )
            }
            #endif
            guard isVisible, resolvedAlpha > 0 else {
                // Offscreen effects must receive a cleared empty surface; Direct
                // has no target and a nil mesh is simply a no-op on the scene.
                payloads[plan.object.id] = WPETextRenderPayload(
                    mode: plan.mode,
                    mesh: nil,
                    backgroundColor: offscreenBackground(for: plan.object, mode: plan.mode),
                    copiesSceneBackground: plan.copiesSceneBackground
                )
                continue
            }

            let placement: WPETextMeshPlacement?
            switch plan.mode {
            case .direct:
                let groupSize = layer.groupRenderTarget.flatMap { target in
                    pipeline.layers.lazy
                        .flatMap { $0.graphLayer.localFBOs }
                        .first { $0.name == target }?
                        .pixelSize
                }
                placement = directTextPlacement(
                    layer: layer,
                    initialLayout: plan.initialLayout,
                    parallaxFrame: parallaxFrame,
                    groupSize: groupSize
                )
            case .offscreen:
                placement = WPETextMeshPlacement(
                    originTopLeft: layout.meshOrigin,
                    scale: SIMD2<Double>(1, 1),
                    rotation: 0
                )
            }
            payloads[plan.object.id] = WPETextRenderPayload(
                mode: plan.mode,
                mesh: placement.flatMap { textMeshRenderer.payload(for: liveObject, placement: $0) },
                backgroundColor: offscreenBackground(for: plan.object, mode: plan.mode),
                copiesSceneBackground: plan.copiesSceneBackground
            )
        }

        return WPETextFrameState(
            pipeline: pipeline.applyingTextLayouts(updates),
            payloads: payloads,
            obsoleteTargetNames: obsoleteTargetNames
        )
    }

    /// WPE reports a text layer's size as its text surface: the laid-out block plus the padding gutter, zero when empty.
    static func scriptTextSize(_ layout: WPETextLayoutSnapshot, padding: Double) -> SIMD2<Double> {
        guard layout.blockSize.width > 0 || layout.blockSize.height > 0 else { return .zero }
        let gutter = max(padding, 0) * 2
        return SIMD2<Double>(Double(layout.blockSize.width) + gutter, Double(layout.blockSize.height) + gutter)
    }

    private func offscreenBackground(
        for object: WPESceneTextObject,
        mode: WPETextRenderMode
    ) -> SIMD4<Float>? {
        guard mode == .offscreen, object.opaqueBackground else { return nil }
        return Self.opaqueTextBackground(object.backgroundColor, brightness: object.backgroundBrightness)
    }

    /// Background and glyphs share the same authored-number target.
    static func opaqueTextBackground(_ color: SIMD3<Double>, brightness: Double) -> SIMD4<Float> {
        let tint = WPEMetalShaderInputs.layerTint(color)
        let brightness = Float(max(brightness, 0))
        return SIMD4<Float>(tint.x * brightness, tint.y * brightness, tint.z * brightness, 1)
    }

    /// Recovers the current object-origin anchor from the transformed synthetic
    /// layer, then maps it to the glyph renderer's top-left pixel coordinates.
    private func directTextPlacement(
        layer: WPERenderLayer,
        initialLayout: WPETextLayoutSnapshot,
        parallaxFrame: WPECameraParallaxFrame,
        groupSize: CGSize?
    ) -> WPETextMeshPlacement? {
        let isGroupDraw = groupSize != nil && layer.groupLocalGeometry != nil
        let geometry = isGroupDraw ? layer.groupLocalGeometry! : layer.geometry
        let offset = Self.transformedTextOffset(
            initialLayout.centerOffsetFromObjectOrigin,
            scale: geometry.scale,
            angle: geometry.angles.z
        )
        let textOrigin = geometry.origin - SIMD3<Double>(offset.x, offset.y, 0)
        let canvasSize = groupSize ?? sceneRenderSize
        let width = Double(canvasSize.width)
        let height = Double(canvasSize.height)
        let originTopLeft: SIMD2<Double>
        let depthScale: Double
        if !isGroupDraw, cameraUniforms.usesPerspectiveProjection {
            guard let projection = cameraUniforms.projectedCenterInScenePixels(
                worldPoint: textOrigin,
                sceneSize: sceneRenderSize
            ) else { return nil }
            let rootCenter = executor.parallaxObjectCenter(for: layer, fallback: projection.center)
            let parallax = parallaxFrame.pixelOffset(
                objectCenter: rootCenter,
                depth: layer.parallaxDepth,
                sceneSize: sceneRenderSize
            )
            originTopLeft = SIMD2<Double>(
                Double(projection.center.x + parallax.x) + width * 0.5,
                height * 0.5 - Double(projection.center.y + parallax.y)
            )
            depthScale = Double(projection.depthScale)
        } else {
            let centered = SIMD2<Float>(
                Float(textOrigin.x - width * 0.5),
                Float(textOrigin.y - height * 0.5)
            )
            let parallax: SIMD2<Float>
            if isGroupDraw {
                parallax = .zero
            } else {
                let rootCenter = executor.parallaxObjectCenter(for: layer, fallback: centered)
                parallax = parallaxFrame.pixelOffset(
                    objectCenter: rootCenter,
                    depth: layer.parallaxDepth,
                    sceneSize: sceneRenderSize
                )
            }
            originTopLeft = SIMD2<Double>(
                textOrigin.x + Double(parallax.x),
                height - (textOrigin.y + Double(parallax.y))
            )
            depthScale = 1
        }
        return WPETextMeshPlacement(
            originTopLeft: originTopLeft,
            scale: SIMD2<Double>(geometry.scale.x, geometry.scale.y) * depthScale,
            rotation: geometry.angles.z
        )
    }

    static func transformedTextOffset(
        _ offset: SIMD2<Double>,
        scale: SIMD3<Double>,
        angle: Double
    ) -> SIMD2<Double> {
        let x = offset.x * scale.x
        let y = offset.y * scale.y
        let cosine = cos(angle)
        let sine = sin(angle)
        return SIMD2<Double>(x * cosine - y * sine, x * sine + y * cosine)
    }

    var liveLayerVisibilityIncludingText: [String: Bool] {
        guard !liveTextVisibility.isEmpty else { return liveLayerVisibility }
        return liveLayerVisibility.merging(liveTextVisibility) { _, text in text }
    }

    var liveLayerAlphaIncludingText: [String: Double] {
        guard !liveTextAlpha.isEmpty else { return liveLayerAlpha }
        return liveLayerAlpha.merging(liveTextAlpha) { _, text in text }
    }

    func releaseTextTargets() {
        textRenderPlans.removeAll(keepingCapacity: false)
        textLayoutCache.removeAll(keepingCapacity: false)
        textFontResolver = nil
        // Drop the atlas pages before the renderer. ARC frees the same textures either way, but only this order takes them out of the weak metadata registry now instead of at its next 256-register sweep.
        textMeshRenderer?.releaseCachedResources()
        textMeshRenderer = nil
    }

    // MARK: - Live script plumbing

    /// Text origin scripts address the anchor, while graph transforms address the synthesized layer centre. Derive that offset from the current live scale/rotation instead of freezing a load-time approximation.
    /// Kinetic: a live scale or rotation without a live origin moves the centre too (a label mirrored by a `scale`
    /// script would otherwise keep its load-time centre and draw on the wrong side of its anchor), so those texts
    /// re-anchor at their authored origin.
    func applyingTextLayerOriginOffsets(
        _ origins: [String: SIMD3<Double>],
        scales: [String: SIMD3<Double>],
        angles: [String: SIMD3<Double>]
    ) -> [String: SIMD3<Double>] {
        guard !origins.isEmpty || !scales.isEmpty || !angles.isEmpty, !textRenderPlans.isEmpty else { return origins }
        var shifted = origins
        for plan in textRenderPlans where Self.textAnchorIsLive(plan.object.id, origins: origins, scales: scales, angles: angles) {
            if shifted[plan.object.id] == nil {
                shifted[plan.object.id] = plan.object.localOrigin ?? plan.object.origin
            }
            let scale = scales[plan.object.id] ?? plan.object.localScale ?? plan.object.scale
            let angle = angles[plan.object.id]?.z ?? (plan.object.localAngles ?? plan.object.angles).z
            let offset = Self.transformedTextOffset(
                plan.initialLayout.centerOffsetFromObjectOrigin,
                scale: scale,
                angle: angle
            )
            shifted[plan.object.id]! += SIMD3<Double>(offset.x, offset.y, 0)
        }
        return shifted
    }

    /// Kinetic: how far each text layer's synthesized quad origin sits from its text origin (the anchor its children
    /// are authored against), in its parent's space. Mirrors the shift baked into the layer's geometry at load
    /// (`localScale ?? scale`, authored angles) or applied to a live script origin (`applyingTextLayerOriginOffsets`).
    func textParentOriginShifts(
        liveOrigins: [String: SIMD3<Double>],
        scales: [String: SIMD3<Double>],
        angles: [String: SIMD3<Double>]
    ) -> [String: SIMD3<Double>] {
        guard !textRenderPlans.isEmpty else { return [:] }
        var shifts: [String: SIMD3<Double>] = [:]
        for plan in textRenderPlans {
            let isLive = Self.textAnchorIsLive(plan.object.id, origins: liveOrigins, scales: scales, angles: angles)
            let scale = isLive ? (scales[plan.object.id] ?? plan.object.localScale ?? plan.object.scale)
                : (plan.object.localScale ?? plan.object.scale)
            let authoredAngle = (plan.object.localAngles ?? plan.object.angles).z
            let angle = isLive ? (angles[plan.object.id]?.z ?? authoredAngle) : authoredAngle
            let offset = Self.transformedTextOffset(plan.initialLayout.centerOffsetFromObjectOrigin, scale: scale, angle: angle)
            shifts[plan.object.id] = SIMD3<Double>(offset.x, offset.y, 0)
        }
        return shifts
    }

    static func textAnchorIsLive(
        _ id: String,
        origins: [String: SIMD3<Double>],
        scales: [String: SIMD3<Double>],
        angles: [String: SIMD3<Double>]
    ) -> Bool {
        origins[id] != nil || scales[id] != nil || angles[id] != nil
    }

    func layerColorsExcludingText(
        _ colors: [String: SIMD3<Double>]
    ) -> [String: SIMD3<Double>] {
        guard !textRenderPlans.isEmpty, !colors.isEmpty else { return colors }
        let textIDs = Set(textRenderPlans.map { $0.object.id })
        return colors.filter { !textIDs.contains($0.key) }
    }

    // MARK: - Loading

    func loadTextPipeline(
        from document: WPESceneDocument,
        scriptLoadToken: WPESceneScriptInstanceLimitToken
    ) {
        textObjects = document.textObjects
        guard !textObjects.isEmpty else {
            textMeshRenderer = nil
            textScriptInstances.removeAll(keepingCapacity: false)
            return
        }
        textMeshRenderer = WPETextMeshRenderer(
            device: executor.textureSourceDevice,
            resolver: resourceResolver,
            fonts: textFontResolver
        )
        textLayoutCache.removeAll(keepingCapacity: true)
        for plan in textRenderPlans {
            textLayoutCache[plan.object.id] = WPETextLayoutCacheEntry(
                key: WPETextRenderPlanner.layoutKey(for: plan.object),
                snapshot: plan.initialLayout
            )
        }
        textScriptInstances.removeAll(keepingCapacity: false)
        guard isCurrentSceneScriptLoad(scriptLoadToken),
              scriptLoadToken.allows(.setup) else { return }
        let sharedState = sceneScriptSharedState
            ?? WPESharedScriptState(sceneScriptLoadToken: scriptLoadToken)
        sceneScriptSharedState = sharedState
        for object in textObjects {
            guard let script = object.textScript else { continue }
            do {
                guard let instance = try constructSceneScript(for: scriptLoadToken, {
                    try WPESceneScriptInstance(
                        script: script,
                        initialValue: object.text,
                        scriptProperties: object.scriptProperties,
                        shared: sharedState,
                        batchDispatcher: self.sceneScriptBatchDispatcher,
                        canvasSize: SIMD2<Double>(
                            Double(self.sceneRenderSize.width),
                            Double(self.sceneRenderSize.height)
                        ),
                        screenSize: SIMD2<Double>(
                            max(Double(self.surfaceDrawableSize.width), 1),
                            max(Double(self.surfaceDrawableSize.height), 1)
                        ),
                        ownLayerName: object.name,
                        ownObjectID: object.id,
                        initializationMode: .deferred
                    )
                }) else { return }
                textScriptInstances[object.id] = instance
            } catch {
                _ = latchSceneScriptFailure(error, operation: .setup, token: scriptLoadToken)
                Logger.warning(
                    "Scene \(descriptor.workshopID) [TextScript] init failed for \(object.name): \(error)",
                    category: .wpeRender
                )
            }
        }
    }
}

private extension WPERenderLayer {
    var textOwnedTargetNames: Set<String> {
        Set([compositeA, compositeB] + localFBOs.map(\.name))
    }

    func applyingTextLayout(
        _ layout: WPETextLayoutSnapshot,
        initial: WPETextLayoutSnapshot
    ) -> WPERenderLayer {
        func adjusted(_ geometry: WPERenderLayerGeometry?) -> WPERenderLayerGeometry? {
            guard let geometry else { return nil }
            let oldOffset = WPEMetalSceneRenderer.transformedTextOffset(
                initial.centerOffsetFromObjectOrigin,
                scale: geometry.scale,
                angle: geometry.angles.z
            )
            let newOffset = WPEMetalSceneRenderer.transformedTextOffset(
                layout.centerOffsetFromObjectOrigin,
                scale: geometry.scale,
                angle: geometry.angles.z
            )
            return WPERenderLayerGeometry(
                origin: geometry.origin
                    - SIMD3<Double>(oldOffset.x, oldOffset.y, 0)
                    + SIMD3<Double>(newOffset.x, newOffset.y, 0),
                scale: geometry.scale,
                angles: geometry.angles,
                alignment: geometry.alignment,
                size: layout.surfaceSize,
                puppetMeshCenter: geometry.puppetMeshCenter,
                alpha: geometry.alpha,
                alphaAnimation: geometry.alphaAnimation,
                color: geometry.color,
                colorAnimation: geometry.colorAnimation,
                brightness: geometry.brightness,
                shapePoints: geometry.shapePoints
            )
        }
        return WPERenderLayer(
            objectID: objectID,
            objectName: objectName,
            visible: visible,
            imagePath: imagePath,
            materialPath: materialPath,
            puppetPath: puppetPath,
            parentObjectID: parentObjectID,
            attachment: attachment,
            attachmentOriginOffset: attachmentOriginOffset,
            animationLayers: animationLayers,
            authoredJSON: authoredJSON,
            geometry: adjusted(geometry)!,
            localGeometry: adjusted(localGeometry),
            compositeA: compositeA,
            compositeB: compositeB,
            compositeSourceExtent: compositeSourceExtent,
            localFBOs: localFBOs,
            passes: passes,
            groupRenderTarget: groupRenderTarget,
            groupLocalGeometry: adjusted(groupLocalGeometry),
            groupCompositeSource: groupCompositeSource,
            parallaxDepth: parallaxDepth,
            sortIndex: sortIndex,
            meshMaterialTextures: meshMaterialTextures
        )
    }
}

private extension WPEPreparedRenderPipeline {
    func applyingTextLayouts(
        _ updates: [String: (layout: WPETextLayoutSnapshot, initial: WPETextLayoutSnapshot)]
    ) -> WPEPreparedRenderPipeline {
        guard !updates.isEmpty else { return self }
        return WPEPreparedRenderPipeline(layers: layers.map { layer in
            guard let update = updates[layer.graphLayer.objectID] else { return layer }
            return WPEPreparedRenderLayer(
                graphLayer: layer.graphLayer.applyingTextLayout(update.layout, initial: update.initial),
                puppetModel: layer.puppetModel,
                passes: layer.passes
            )
        })
    }
}
#endif
