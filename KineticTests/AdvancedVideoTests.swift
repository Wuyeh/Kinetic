import AppKit
import AVFoundation
import CoreImage
import XCTest
@testable import Kinetic

final class AdvancedVideoTests: XCTestCase {
    @MainActor private func wallpaper() throws -> Wallpaper {
        Wallpaper(name: "视频验收", type: .video, source: .local, resourceURL:
            try XCTUnwrap(Bundle.main.url(forResource: "loop", withExtension: "mp4", subdirectory: "Fixtures")))
    }
    @MainActor private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while !predicate() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw VideoRendererError.preparationTimedOut }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    func testNumericValidationRejectsInvalidAndNonFiniteValues() throws {
        XCTAssertNoThrow(try VideoPlaybackOptions().validated())
        for change in [
            { (o: inout VideoPlaybackOptions) in o.speed = .infinity },
            { o in o.speed = 0 }, { o in o.volume = -1 }, { o in o.brightness = .nan },
            { o in o.contrast = 100 }, { o in o.saturation = -1 }, { o in o.preloadBudgetMiB = Int.max }
        ] { var options = VideoPlaybackOptions(); change(&options); XCTAssertThrowsError(try options.validated()) }
    }
    func testPreparationBudgetBeforeSurfaceAllocation() throws {
        var options = VideoPlaybackOptions(); options.preloadBudgetMiB = 64
        XCTAssertNoThrow(try VideoProcessingPipeline.validatePreparationSize(.init(width: 1920, height: 1080), options: options))
        XCTAssertThrowsError(try VideoProcessingPipeline.validatePreparationSize(.init(width: 3840, height: 2160), options: options))
        options.preloadBudgetMiB = 256
        XCTAssertNoThrow(try VideoProcessingPipeline.validatePreparationSize(.init(width: 3840, height: 2160), options: options))
        for size in [CGSize.zero, .init(width: CGFloat.infinity, height: 1), .init(width: 20_000, height: 1)] {
            XCTAssertThrowsError(try VideoProcessingPipeline.validatePreparationSize(size, options: options))
        }
    }
    @MainActor func testNeutralOptionsKeepOriginalNativePathAndMute() async throws {
        let renderer = VideoRenderer(wallpaper: try wallpaper(), options: .init())
        defer { renderer.dispose() }
        try await renderer.prepare()
        XCTAssertNil(renderer.player?.currentItem?.videoComposition)
        XCTAssertEqual(renderer.contentView.playerLayer.videoGravity, .resizeAspectFill)
        XCTAssertEqual(renderer.contentView.posterGravity, .resizeAspectFill)
        XCTAssertEqual(renderer.player?.rate, 0)
        XCTAssertTrue(renderer.isMuted)
        XCTAssertEqual(renderer.player?.volume, 1)
    }
    @MainActor func testFitFillStretchApplyEquallyToPosterAndMovie() async throws {
        let choices: [(VideoPlaybackOptions.DisplayFit, AVLayerVideoGravity, CALayerContentsGravity)] = [
            (.fill, .resizeAspectFill, .resizeAspectFill), (.fit, .resizeAspect, .resizeAspect), (.stretch, .resize, .resize)
        ]
        for (fit, videoGravity, posterGravity) in choices {
            var options = VideoPlaybackOptions(); options.displayFit = fit
            let renderer = VideoRenderer(wallpaper: try wallpaper(), options: options)
            try await renderer.prepare()
            XCTAssertEqual(renderer.contentView.playerLayer.videoGravity, videoGravity)
            XCTAssertEqual(renderer.contentView.posterGravity, posterGravity)
            renderer.contentView.setFrameSize(.init(width: 700, height: 200)); renderer.contentView.layoutSubtreeIfNeeded()
            XCTAssertEqual(renderer.contentView.playerLayer.frame, renderer.contentView.bounds)
            renderer.dispose()
        }
    }
    @MainActor func testSpeedVolumePauseResumeAndLooperReplicas() async throws {
        for speed in [0.5, 2.0] {
            var options = VideoPlaybackOptions(); options.speed = speed; options.volume = 0.25
            let renderer = VideoRenderer(wallpaper: try wallpaper(), options: options)
            defer { renderer.dispose() }
            try await renderer.prepare()
            renderer.play()
            try await wait { renderer.currentTime.seconds > 0.15 }
            XCTAssertEqual(renderer.player?.rate, Float(speed))
            XCTAssertEqual(renderer.player?.volume, 0.25)
            XCTAssertTrue(renderer.isMuted, "Volume must not unmute")
            renderer.pause()
            try await Task.sleep(nanoseconds: 60_000_000)
            let time = renderer.currentTime.seconds, item = renderer.player?.currentItem
            try await Task.sleep(nanoseconds: 120_000_000)
            XCTAssertEqual(renderer.currentTime.seconds, time, accuracy: 0.02)
            XCTAssertTrue(renderer.player?.currentItem === item)
            renderer.resume()
            try await wait { renderer.currentTime.seconds > time + 0.1 }
            XCTAssertEqual(renderer.player?.rate, Float(speed))
            if speed == 2 {
                try await wait { renderer.completedLoopCount >= 2 }
                XCTAssertEqual(renderer.player?.rate, 2)
                XCTAssertEqual(renderer.player?.volume, 0.25)
                XCTAssertNil(renderer.failure)
            }
        }
    }
    @MainActor func testNativeCompositionActuallyOutputsTargetCadenceAndGrayscale() async throws {
        let wallpaper = try wallpaper(), original = try Data(contentsOf: wallpaper.resourceURL)
        var options = VideoPlaybackOptions(); options.frameRate = .fps24; options.effect = .grayscale
        let renderer = VideoRenderer(wallpaper: wallpaper, options: options)
        defer { renderer.dispose() }
        try await renderer.prepare()
        let composition = try XCTUnwrap(renderer.player?.currentItem?.videoComposition)
        XCTAssertEqual(composition.frameDuration.seconds, 1 / 24.0, accuracy: 0.00001)
        let asset = AVURLAsset(url: wallpaper.resourceURL)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: try await asset.loadTracks(withMediaType: .video),
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.videoComposition = composition; reader.add(output)
        XCTAssertTrue(reader.startReading())
        var times: [Double] = [], checkedPixel = false
        while let sample = output.copyNextSampleBuffer() {
            times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
            if !checkedPixel, let pixel = CMSampleBufferGetImageBuffer(sample) {
                CVPixelBufferLockBaseAddress(pixel, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
                let ptr = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixel)).assumingMemoryBound(to: UInt8.self)
                let offset = 10 * CVPixelBufferGetBytesPerRow(pixel) + 10 * 4
                XCTAssertEqual(Int(ptr[offset]), Int(ptr[offset+1]), accuracy: 3)
                XCTAssertEqual(Int(ptr[offset+1]), Int(ptr[offset+2]), accuracy: 3)
                checkedPixel = true
            }
        }
        XCTAssertEqual(reader.status, .completed, String(describing: reader.error))
        XCTAssertGreaterThan(times.count, 40)
        for (a, b) in zip(times, times.dropFirst()) { XCTAssertEqual(b - a, 1 / 24.0, accuracy: 0.0001) }
        renderer.play(); try await wait { renderer.completedLoopCount >= 1 }
        XCTAssertNotNil(renderer.player?.currentItem?.videoComposition, "Looper replicas keep the processing pipeline")
        XCTAssertNil(renderer.failure)
        XCTAssertEqual(try Data(contentsOf: wallpaper.resourceURL), original)
        print("MODULE30 real 24fps samples=\(times.count), first=\(times.prefix(5))")
    }
    @MainActor func testSpeedAdjustedFrameTargetAndExplicitSDRColorSpace() async throws {
        let asset = AVURLAsset(url: try wallpaper().resourceURL)
        var options = VideoPlaybackOptions(); options.speed = 2; options.frameRate = .fps30; options.dynamicRange = .sdr
        let built = try await VideoProcessingPipeline.composition(asset: asset, options: options)
        let composition = try XCTUnwrap(built)
        XCTAssertEqual(composition.frameDuration.seconds / options.speed, 1 / 30.0, accuracy: 0.00001)
        XCTAssertEqual(composition.colorPrimaries, AVVideoColorPrimaries_ITU_R_709_2)
        XCTAssertEqual(composition.colorTransferFunction, AVVideoTransferFunction_ITU_R_709_2)
        options.dynamicRange = .automatic
        let builtAutomatic = try await VideoProcessingPipeline.composition(asset: asset, options: options)
        let automatic = try XCTUnwrap(builtAutomatic)
        XCTAssertNil(automatic.colorPrimaries); XCTAssertNil(automatic.colorTransferFunction); XCTAssertNil(automatic.colorYCbCrMatrix)
        options.speed = 0.5; options.frameRate = .fps60
        let slow = try await VideoProcessingPipeline.composition(asset: asset, options: options)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(slow).frameDuration.seconds, 1 / 30.0 - 0.0001,
                                    "Do not duplicate source frames to reach a higher target")
    }
    func testModularEffectsPreserveGeometryAndExtendedRange() throws {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let hdrPixel: [Float] = [2, 1.5, 0.5, 1]
        let pixels = Array(repeating: hdrPixel, count: 64).flatMap { $0 }
        let data = pixels.withUnsafeBytes { Data($0) }
        let image = CIImage(bitmapData: data, bytesPerRow: 8 * 16, size: .init(width: 8, height: 8),
                            format: .RGBAf, colorSpace: space)
        var options = VideoPlaybackOptions(); options.effect = .grayscale
        let filtered = VideoProcessingPipeline.filtered(image, options: options)
        XCTAssertEqual(filtered.extent, image.extent)
        let context = CIContext(options: [.workingColorSpace: space])
        var sourceValues = [Float](repeating: 0, count: 4)
        sourceValues.withUnsafeMutableBytes { context.render(image, toBitmap: $0.baseAddress!, rowBytes: 16,
            bounds: .init(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: space) }
        print("MODULE30 HDR source=\(sourceValues)")
        XCTAssertGreaterThan(sourceValues[0], 1, "Fixture must contain extended-range source pixels")
        var values = [Float](repeating: 0, count: 4)
        values.withUnsafeMutableBytes { context.render(filtered, toBitmap: $0.baseAddress!, rowBytes: 16,
            bounds: .init(x: 0, y: 0, width: 1, height: 1), format: .RGBAf,
            colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)) }
        XCTAssertGreaterThan(values[0], 1, "HDR intensities must not clamp to SDR in a built-in effect")
        print("MODULE30 HDR filtered=\(values)")
        XCTAssertEqual(values[0], values[1], accuracy: 0.02); XCTAssertEqual(values[1], values[2], accuracy: 0.02)
        options.effect = .sepia
        XCTAssertEqual(VideoProcessingPipeline.filtered(image, options: options).extent, image.extent)
    }
    @MainActor func testCancellationAndDisposalDuringAdvancedPreparationCannotActivate() async throws {
        var options = VideoPlaybackOptions(); options.effect = .sepia
        let renderer = VideoRenderer(wallpaper: try wallpaper(), options: options)
        let task = Task { try await renderer.prepare() }
        task.cancel(); renderer.dispose()
        do { try await task.value; XCTFail("Cancelled preparation succeeded") } catch { }
        renderer.resume()
        XCTAssertFalse(renderer.isPrepared); XCTAssertNil(renderer.player); XCTAssertFalse(renderer.contentView.hasPoster)
    }

    @MainActor func testHEVCMain10HLGNativeAndProcessedPlayback() async throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "hlg-hevc", withExtension: "mov", subdirectory: "Fixtures/advanced-video"))
        let original = try Data(contentsOf: url), asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let descriptions = try await track.load(.formatDescriptions)
        let description = try XCTUnwrap(descriptions.first)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(description), kCMVideoCodecType_HEVC)
        XCTAssertEqual(CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String,
                       AVVideoTransferFunction_ITU_R_2100_HLG)
        XCTAssertEqual(CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String,
                       AVVideoColorPrimaries_ITU_R_2020)
        let wallpaper = Wallpaper(name: "HLG", type: .video, source: .local, resourceURL: url)
        for choice in [0, 1, 2] {
            var options = VideoPlaybackOptions()
            if choice > 0 { options.effect = .sepia; options.frameRate = .fps24 }
            if choice == 2 { options.dynamicRange = .sdr }
            let renderer = VideoRenderer(wallpaper: wallpaper, options: options)
            defer { renderer.dispose() }
            try await renderer.prepare()
            XCTAssertTrue(renderer.contentView.hasPoster)
            XCTAssertEqual(renderer.player?.currentItem?.appliesPerFrameHDRDisplayMetadata, choice != 2)
            if choice == 0 { XCTAssertNil(renderer.player?.currentItem?.videoComposition) }
            else { XCTAssertNotNil(renderer.player?.currentItem?.videoComposition) }
            renderer.play(); try await wait { renderer.completedLoopCount >= 1 }
            renderer.pause(); XCTAssertEqual(renderer.player?.rate, 0)
            XCTAssertNil(renderer.failure); XCTAssertTrue(renderer.isMuted)
        }
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
    @MainActor func testVideoTrackRotationSurvivesProcessing() async throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "rotated-h264", withExtension: "mov", subdirectory: "Fixtures/advanced-video"))
        var options = VideoPlaybackOptions(); options.effect = .grayscale; options.displayFit = .fit
        let asset = AVURLAsset(url: url)
        let built = try await VideoProcessingPipeline.composition(asset: asset, options: options)
        let composition = try XCTUnwrap(built)
        XCTAssertEqual(composition.renderSize.width, 108, accuracy: 1)
        XCTAssertEqual(composition.renderSize.height, 192, accuracy: 1)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true; generator.videoComposition = composition
        let (image, _) = try await generator.image(at: .zero)
        XCTAssertEqual(image.width, 108); XCTAssertEqual(image.height, 192)
        let renderer = VideoRenderer(wallpaper: .init(name: "旋转", type: .video, source: .local, resourceURL: url), options: options)
        defer { renderer.dispose() }
        try await renderer.prepare()
        XCTAssertTrue(renderer.contentView.hasPoster)
        XCTAssertEqual(renderer.contentView.playerLayer.videoGravity, .resizeAspect)
    }

    @MainActor func testLiveSpeedAndVolumeKeepPlayerItemAndAdvanceFromCurrentTime() async throws {
        let renderer = VideoRenderer(wallpaper: try wallpaper(), options: .init())
        defer { renderer.dispose() }
        try await renderer.prepare(); renderer.play()
        try await wait { renderer.currentTime.seconds > 0.65 }
        let player = renderer.player, item = player?.currentItem, looper = renderer.looper
        let before = renderer.currentTime.seconds
        var options = VideoPlaybackOptions(); options.speed = 2
        try await renderer.updateOptions(options)
        let fast = renderer.currentTime.seconds
        XCTAssertTrue(renderer.player === player); XCTAssertTrue(renderer.player?.currentItem === item)
        XCTAssertTrue(renderer.looper === looper); XCTAssertGreaterThanOrEqual(fast, before - 0.001)
        XCTAssertLessThan(fast - before, 0.1); XCTAssertEqual(renderer.player?.rate, 2)
        XCTAssertTrue(renderer.isMuted)
        try await Task.sleep(nanoseconds: 100_000_000)
        print("MODULE30 speed transport after100ms=\(renderer.currentTime.seconds), rate=\(player?.rate ?? -1), control=\(String(describing: player?.timeControlStatus)), waiting=\(String(describing: player?.reasonForWaitingToPlay)), item=\(String(describing: item?.status))")
        XCTAssertGreaterThanOrEqual(renderer.currentTime.seconds, fast, "Rate changes must never rewind")
        // AVFoundation retimes its native audio clock asynchronously. Measure the steady rate
        // after it advances, rather than treating the first 100 ms as a synchronous clock API.
        try await wait { renderer.currentTime.seconds > fast + 0.1 }
        let sampleStart = renderer.currentTime.seconds, hostStart = ProcessInfo.processInfo.systemUptime
        try await Task.sleep(nanoseconds: 200_000_000)
        let elapsed = ProcessInfo.processInfo.systemUptime - hostStart
        XCTAssertEqual(renderer.currentTime.seconds - sampleStart, elapsed * 2, accuracy: 0.04)
        options.volume = 0.2; options.displayFit = .fit
        try await renderer.updateOptions(options)
        XCTAssertEqual(renderer.player?.volume, 0.2)
        options.speed = 0.5; let mid = renderer.currentTime.seconds
        try await renderer.updateOptions(options)
        XCTAssertGreaterThanOrEqual(renderer.currentTime.seconds, mid - 0.001)
        XCTAssertEqual(renderer.player?.rate, 0.5)
        XCTAssertTrue(renderer.player?.currentItem === item)
        renderer.pause(); try await Task.sleep(nanoseconds: 30_000_000)
        let paused = renderer.currentTime.seconds
        options.speed = 1.75; try await renderer.updateOptions(options)
        XCTAssertEqual(renderer.currentTime.seconds, paused, accuracy: 0.0001)
        XCTAssertEqual(renderer.player?.rate, 0)
        renderer.resume(); XCTAssertEqual(renderer.player?.rate, 1.75)
        print("MODULE30 continuity speed before=\(before), after=\(fast), same player/item/looper")
    }
    @MainActor func testPausedEffectRendersCurrentFrameWithoutSeekingOrStartingPlayback() async throws {
        let renderer = VideoRenderer(wallpaper: try wallpaper(), options: .init())
        defer { renderer.dispose() }
        try await renderer.prepare(); renderer.play()
        try await wait { renderer.currentTime.seconds > 0.65 }; renderer.pause()
        try await Task.sleep(nanoseconds: 30_000_000)
        let time = renderer.currentTime.seconds, player = renderer.player, item = player?.currentItem
        var options = VideoPlaybackOptions(); options.effect = .grayscale; options.speed = 2
        try await renderer.updateOptions(options)
        XCTAssertTrue(renderer.player === player); XCTAssertTrue(renderer.player?.currentItem === item)
        XCTAssertEqual(renderer.currentTime.seconds, time, accuracy: 0.0001)
        XCTAssertEqual(renderer.posterTime.seconds, time, accuracy: 1 / 30.0 + 0.001)
        XCTAssertEqual(renderer.player?.rate, 0); XCTAssertTrue(renderer.contentView.playerLayer.isHidden)
        let contents = try XCTUnwrap(renderer.contentView.layer?.sublayers?.first?.contents)
        let image = contents as! CGImage
        var rgba = [UInt8](repeating: 0, count: 4)
        let context = CIContext()
        rgba.withUnsafeMutableBytes { context.render(CIImage(cgImage: image), toBitmap: $0.baseAddress!, rowBytes: 4,
            bounds: .init(x: 10, y: 10, width: 1, height: 1), format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) }
        XCTAssertEqual(Int(rgba[0]), Int(rgba[1]), accuracy: 3)
        XCTAssertEqual(Int(rgba[1]), Int(rgba[2]), accuracy: 3)
        let previous = renderer.options, previousComposition = item?.videoComposition
        var invalid = options; invalid.speed = .nan
        do { try await renderer.updateOptions(invalid); XCTFail("Invalid options applied") } catch { }
        XCTAssertEqual(renderer.options, previous); XCTAssertTrue(item?.videoComposition === previousComposition)
        XCTAssertEqual(renderer.currentTime.seconds, time, accuracy: 0.0001)
        renderer.resume(); try await wait { renderer.currentTime.seconds > time + 0.15 }
        XCTAssertEqual(renderer.player?.rate, 2)
        print("MODULE30 continuity paused current=\(time), processed poster=\(renderer.posterTime.seconds), gray=\(rgba)")
    }
    @MainActor func testLiveEffectsRemainOnLoopReplicasAndDisposalCancelsFurtherUpdates() async throws {
        let renderer = VideoRenderer(wallpaper: try wallpaper(), options: .init())
        try await renderer.prepare(); let looper = renderer.looper
        renderer.play(); try await wait { renderer.currentTime.seconds > 0.6 }
        var options = VideoPlaybackOptions(); options.effect = .grayscale; options.frameRate = .fps24; options.speed = 2
        try await renderer.updateOptions(options)
        XCTAssertTrue(renderer.looper === looper)
        try await wait { renderer.completedLoopCount >= 3 }
        for item in renderer.looper?.loopingPlayerItems ?? [] {
            let composition = try XCTUnwrap(item.videoComposition)
            XCTAssertEqual(composition.frameDuration.seconds, 2 / 24.0, accuracy: 0.0001)
        }
        XCTAssertEqual(renderer.player?.rate, 2); XCTAssertNil(renderer.failure)
        options.effect = .sepia
        let task = Task { try await renderer.updateOptions(options) }
        task.cancel(); renderer.dispose()
        do { try await task.value; XCTFail("Disposed update succeeded") } catch { }
        XCTAssertNil(renderer.player); XCTAssertNil(renderer.looper); XCTAssertFalse(renderer.contentView.hasPoster)
    }
}
