import AVFoundation
import CoreImage

/// Optional native AVFoundation composition; neutral settings do not install any compositor.
/// Built-in Core Image filters preserve HDR values; no custom decoder or app architecture.
enum VideoProcessingPipeline {
    static func filtered(_ image: CIImage, options: VideoPlaybackOptions) -> CIImage {
        var result = image
        if options.brightness != 0 || options.contrast != 1 || options.saturation != 1 {
            result = result.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: options.brightness, kCIInputContrastKey: options.contrast,
                kCIInputSaturationKey: options.saturation
            ])
        }
        switch options.effect {
        case .none: break
        case .grayscale: result = result.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        case .sepia: result = result.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: 0.7])
        }
        return result.cropped(to: image.extent)
    }

    static func composition(asset: AVAsset, options: VideoPlaybackOptions,
                            forcePassthrough: Bool = false) async throws -> AVVideoComposition? {
        guard options.needsComposition || forcePassthrough else { return nil }
        let composition: AVMutableVideoComposition = try await withCheckedThrowingContinuation { continuation in
            AVMutableVideoComposition.videoComposition(with: asset, applyingCIFiltersWithHandler: { request in
                request.finish(with: filtered(request.sourceImage, options: options), context: nil)
            }, completionHandler: { composition, error in
                if let composition { continuation.resume(returning: composition) }
                else { continuation.resume(throwing: error ?? VideoOptionsError.composition) }
            })
        }
        try Task.checkCancellation()
        // Estimated three float16 work surfaces + an 8-byte/pixel static fallback. Native decoder
        // allocations remain owned by AVFoundation. Never read the whole movie into a memory cache.
        try validatePreparationSize(composition.renderSize, options: options)
        if options.frameRate != .source {
            // Frame duration is on the media timeline: compensate for playback speed so the target
            // is a presentation-rate ceiling, not an accidental increase when playing at 2x.
            composition.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid
            let sourceInterval = composition.frameDuration.seconds
            let interval = max(sourceInterval.isFinite && sourceInterval > 0 ? sourceInterval : 0,
                               options.speed / Double(options.frameRate.rawValue))
            composition.frameDuration = CMTime(seconds: interval, preferredTimescale: 60_000)
        }
        if options.dynamicRange == .sdr {
            // AVFoundation tone-maps HDR into Rec.709 before filtering. Automatic leaves all three
            // unset so source color space / HLG / PQ propagate through the native compositor.
            composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
            composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
            composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        }
        if #available(macOS 14, *), options.brightness != 0 || options.contrast != 1
            || options.saturation != 1 || options.effect != .none {
            composition.perFrameHDRDisplayMetadataPolicy = .generate
        }
        return composition
    }

    static func validatePreparationSize(_ size: CGSize, options: VideoPlaybackOptions) throws {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              size.width <= 16_384, size.height <= 16_384,
              size.width * size.height * 32 <= Double(options.preloadBudgetBytes) else {
            throw VideoOptionsError.preparationBudget
        }
    }
}
