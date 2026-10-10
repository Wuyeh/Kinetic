import AppKit
import AVFoundation

enum VideoRendererError: LocalizedError {
    case invalidLifecycle, unsupportedWallpaper, unsupportedResource
    case missingFile, unplayable, invalidDuration, noVideoTrack, preparationTimedOut
    case playbackFailed(String)

    var errorDescription: String? {
        let key: String
        switch self {
        case .invalidLifecycle: key = "video.error.lifecycle"
        case .unsupportedWallpaper: key = "video.error.type"
        case .unsupportedResource: key = "video.error.resource"
        case .missingFile: key = "video.error.missing"
        case .unplayable: key = "video.error.unplayable"
        case .invalidDuration: key = "video.error.duration"
        case .noVideoTrack: key = "video.error.track"
        case .preparationTimedOut: key = "video.error.timeout"
        case .playbackFailed: key = "video.error.playback"
        }
        return NSLocalizedString(key, comment: "Video Renderer error")
    }
}

/// Module 3：一个实例只准备一份 Wallpaper。调用方先 await prepare，再注入桌面窗口。
/// 不写入全局 PlaybackState，不决定 Apply、Smart Pause 或 Crossfade。
@MainActor
final class VideoRenderer {
    static var optionsProvider: ((Wallpaper.ID) -> VideoPlaybackOptions)?
    let wallpaper: Wallpaper
    private(set) var options: VideoPlaybackOptions
    let contentView = VideoContentView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
    private(set) var player: AVQueuePlayer?
    private(set) var looper: AVPlayerLooper?
    private(set) var failure: Error?
    var onFailure: (@MainActor (Error) -> Void)?

    private enum Lifecycle { case idle, preparing, ready, failed, disposed }
    private var lifecycle = Lifecycle.idle
    private var asset: AVURLAsset?
    private var imageGenerator: AVAssetImageGenerator?
    private var optionsImageGenerator: AVAssetImageGenerator?
    private var processingComposition: AVVideoComposition?
    private var loopTemplate: AVPlayerItem?
    private var optionsGeneration = UUID()
    private var savedOptionsTask: Task<Void, Never>?
    private var savedOptionsGeneration = UUID()
    private var usesUpdatedPausedPoster = false
    private(set) var posterTime: CMTime = .zero
    private var observations: [NSKeyValueObservation] = []
    private var itemObservation: NSKeyValueObservation?
    private var itemFailureObserver: NSObjectProtocol?

    var isPrepared: Bool { lifecycle == .ready }
    var currentTime: CMTime { player?.currentTime() ?? .zero }
    var completedLoopCount: Int { looper?.loopCount ?? 0 }
    var isMuted: Bool { player?.isMuted ?? true }

    init(wallpaper: Wallpaper, options: VideoPlaybackOptions? = nil) {
        self.wallpaper = wallpaper
        self.options = options ?? Self.optionsProvider?(wallpaper.id) ?? .init()
    }

    /// 成功时已解码首帧且播放器 readyToPlay，但不自动播放。
    /// AVPlayerLayer 尚未显示首个视频帧时，内容仍显示静态首帧。
    func prepare() async throws {
        guard lifecycle == .idle else { throw VideoRendererError.invalidLifecycle }
        lifecycle = .preparing
        do {
            try Task.checkCancellation()
            _ = try options.validated()
            guard wallpaper.type == .video else { throw VideoRendererError.unsupportedWallpaper }
            let url = wallpaper.resourceURL
            guard url.isFileURL, VideoFormats.hasVideoExtension(url) else {
                throw VideoRendererError.unsupportedResource
            }
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                throw VideoRendererError.missingFile
            }

            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            // Conservative 16 bytes/pixel reservation before generating an image. Keep the legacy
            // 3840 cap when the selected budget can accommodate it; verify actual row storage too.
            let posterEdge = min(3840, floor(sqrt(Double(options.preloadBudgetBytes) / 16)))
            generator.maximumSize = CGSize(width: posterEdge, height: posterEdge)
            self.asset = asset
            imageGenerator = generator

            let watchdog = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 15_000_000_000) }
                catch { return }
                guard let self, self.lifecycle == .preparing else { return }
                self.failure = VideoRendererError.preparationTimedOut
                asset.cancelLoading()
                generator.cancelAllCGImageGeneration()
            }
            defer { watchdog.cancel() }

            try await withTaskCancellationHandler {
                let playable = try await asset.load(.isPlayable)
                try checkPreparation()
                guard playable else { throw VideoRendererError.unplayable }
                let duration = try await asset.load(.duration)
                try checkPreparation()
                guard duration.isNumeric, duration.seconds.isFinite, duration.seconds > 0 else {
                    throw VideoRendererError.invalidDuration
                }
                let tracks = try await asset.loadTracks(withMediaType: .video)
                try checkPreparation()
                guard !tracks.isEmpty else { throw VideoRendererError.noVideoTrack }
                let composition = try await VideoProcessingPipeline.composition(asset: asset, options: options)
                try checkPreparation()
                generator.videoComposition = composition
                processingComposition = composition
                let (image, _) = try await generator.image(at: .zero)
                try checkPreparation()
                guard image.bytesPerRow <= options.preloadBudgetBytes / max(1, image.height) else {
                    throw VideoOptionsError.preparationBudget
                }
                contentView.setDisplayFit(options.displayFit, frame: options.customFrame)
                contentView.setPoster(image)

                let queue = AVQueuePlayer()
                // 原生解码路径由 AVFoundation 选择可用的硬件解码器，不强制软件解码。
                queue.isMuted = true
                queue.volume = Float(options.volume)
                queue.preventsDisplaySleepDuringVideoPlayback = false
                queue.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
                player = queue
                contentView.playerLayer.player = queue
                let template = AVPlayerItem(asset: asset)
                loopTemplate = template
                template.videoComposition = composition
                template.appliesPerFrameHDRDisplayMetadata = options.dynamicRange == .automatic
                // Configure pitch preservation once, before playback; changing the algorithm
                // on a playing item can make AVFoundation rebuild its audio pipeline at first speed edit.
                template.audioTimePitchAlgorithm = .spectral
                looper = AVPlayerLooper(player: queue, templateItem: template)
                while queue.currentItem?.status != .readyToPlay {
                    try checkPreparation()
                    if queue.status == .failed || queue.currentItem?.status == .failed || looper?.status == .failed {
                        throw queue.error ?? queue.currentItem?.error ?? looper?.error ?? VideoRendererError.unplayable
                    }
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                try checkPreparation()
                lifecycle = .ready
                observePlayback()
                imageGenerator = nil
            } onCancel: {
                asset.cancelLoading()
                generator.cancelAllCGImageGeneration()
            }
        } catch {
            let result = failure ?? error
            if lifecycle != .disposed {
                failure = result
                lifecycle = .failed
                releasePlayback()
                contentView.clear()
            }
            throw result
        }
    }

    func play() {
        guard isPrepared else { return }
        let updatedFrame = usesUpdatedPausedPoster
        usesUpdatedPausedPoster = false
        contentView.showVideo(contentView.playerLayer.isReadyForDisplay)
        if options.speed == 1 && !updatedFrame { player?.play() }
        else { player?.playImmediately(atRate: Float(options.speed)) }
    }

    /// 保留 player、item 和显示层；不 seek，不移除内容。
    func pause() { player?.pause() }

    func resume() { play() }

    func setMuted(_ muted: Bool) { player?.isMuted = muted }

    /// Edit the existing media pipeline, never replace its player/item or seek its loop timeline.
    /// Build failures leave all previously applied options and the visible video untouched.
    func updateOptions(_ value: VideoPlaybackOptions) async throws {
        let next = try value.validated()
        guard isPrepared, let asset, let player else { throw VideoRendererError.invalidLifecycle }
        optionsGeneration = UUID(); let token = optionsGeneration
        optionsImageGenerator?.cancelAllCGImageGeneration(); optionsImageGenerator = nil
        try Task.checkCancellation()
        guard options != next else { return }
        let rebuild = options.frameRate != next.frameRate || options.dynamicRange != next.dynamicRange
            || options.brightness != next.brightness || options.contrast != next.contrast
            || options.saturation != next.saturation || options.effect != next.effect
            || (next.frameRate != .source && options.speed != next.speed)
        var composition = processingComposition
        if rebuild {
            // Once active, retain a pass-through compositor when clearing effects. Tearing it
            // down on a paused item can stall the native pipeline; its media timeline stays intact.
            composition = try await VideoProcessingPipeline.composition(asset: asset, options: next,
                forcePassthrough: processingComposition != nil)
        }
        try checkOptionsUpdate(token)
        if let composition { try VideoProcessingPipeline.validatePreparationSize(composition.renderSize, options: next) }
        var poster: (CGImage, CMTime)?
        if rebuild || options.preloadBudgetMiB != next.preloadBudgetMiB {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            let edge = min(3840, floor(sqrt(Double(next.preloadBudgetBytes) / 16)))
            generator.maximumSize = CGSize(width: edge, height: edge)
            generator.videoComposition = composition
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            optionsImageGenerator = generator
            defer { if optionsImageGenerator === generator { optionsImageGenerator = nil } }
            poster = try await withTaskCancellationHandler {
                try await generator.image(at: currentTime)
            } onCancel: { generator.cancelAllCGImageGeneration() }
            try checkOptionsUpdate(token)
            if let image = poster?.0, image.bytesPerRow > next.preloadBudgetBytes / max(1, image.height) {
                throw VideoOptionsError.preparationBudget
            }
        }
        try checkOptionsUpdate(token)
        let wasPlaying = player.rate != 0
        let fitChanged = options.displayFit != next.displayFit || options.customFrame != next.customFrame
        options = next; processingComposition = composition
        if let (image, time) = poster {
            contentView.setPoster(image); posterTime = time
            if !wasPlaying { usesUpdatedPausedPoster = true; contentView.showVideo(false) }
        }
        if fitChanged { contentView.setDisplayFit(next.displayFit, frame: next.customFrame) }
        if rebuild { synchronizeLoopItems() }
        if player.volume != Float(next.volume) { player.volume = Float(next.volume) }
        if wasPlaying, player.rate != Float(next.speed) { player.rate = Float(next.speed) }
    }

    /// 只改「自定义」显示范围：不经过处理管线，立即生效（显示器页预览在拖动时用）。
    func updateCustomFrame(_ frame: CustomDisplayFrame?) {
        guard isPrepared, options.customFrame != frame, frame?.isValid ?? true else { return }
        options.customFrame = frame
        contentView.setDisplayFit(options.displayFit, frame: frame)
    }

    /// Saved desktop configuration has its own cancellable latest-wins operation.
    /// The editor preview instead awaits updateOptions directly and remains independent.
    func scheduleOptionsUpdate(_ value: VideoPlaybackOptions, onError: @escaping @MainActor (Error) -> Void) {
        savedOptionsTask?.cancel(); savedOptionsGeneration = UUID(); let token = savedOptionsGeneration
        savedOptionsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.savedOptionsGeneration == token { self.savedOptionsTask = nil } }
            do { try await self.updateOptions(value) }
            catch { if !Task.isCancelled, self.isPrepared, self.savedOptionsGeneration == token { onError(error) } }
        }
    }

    private func checkOptionsUpdate(_ token: UUID) throws {
        try Task.checkCancellation()
        guard isPrepared, optionsGeneration == token else { throw CancellationError() }
    }

    private func synchronizeLoopItems() {
        guard isPrepared else { return }
        var seen = Set<ObjectIdentifier>()
        for item in [loopTemplate].compactMap({ $0 }) + (looper?.loopingPlayerItems ?? []) + (player?.items() ?? []) {
            guard seen.insert(ObjectIdentifier(item)).inserted else { continue }
            if item.videoComposition !== processingComposition { item.videoComposition = processingComposition }
            let hdr = options.dynamicRange == .automatic
            if item.appliesPerFrameHDRDisplayMetadata != hdr { item.appliesPerFrameHDRDisplayMetadata = hdr }
            if item.audioTimePitchAlgorithm != .spectral { item.audioTimePitchAlgorithm = .spectral }
        }
    }

    /// 调用方先从窗口移除 contentView，再释放 Renderer。此后不能重用此实例。
    func dispose() {
        guard lifecycle != .disposed else { return }
        lifecycle = .disposed
        optionsGeneration = UUID(); savedOptionsGeneration = UUID()
        savedOptionsTask?.cancel(); savedOptionsTask = nil
        onFailure = nil
        releasePlayback()
        contentView.clear()
    }

    private func checkPreparation() throws {
        try Task.checkCancellation()
        if let failure { throw failure }
        guard lifecycle == .preparing else { throw CancellationError() }
    }

    private func observePlayback() {
        guard let player, let looper else { return }
        observations = [
            contentView.playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.isPrepared else { return }
                    self.contentView.showVideo(self.contentView.playerLayer.isReadyForDisplay && !self.usesUpdatedPausedPoster)
                }
            },
            player.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.checkPlaybackFailure() }
            },
            looper.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.checkPlaybackFailure() }
            },
            looper.observe(\.loopingPlayerItems, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.synchronizeLoopItems() }
            },
            player.observe(\.currentItem, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.observeCurrentItem() }
            }
        ]
    }

    private func observeCurrentItem() {
        itemObservation = nil
        if let itemFailureObserver { NotificationCenter.default.removeObserver(itemFailureObserver) }
        itemFailureObserver = nil
        guard isPrepared, let item = player?.currentItem else { return }
        synchronizeLoopItems()
        itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.checkPlaybackFailure() }
        }
        itemFailureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] notification in
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Task { @MainActor [weak self] in
                self?.failPlayback(error ?? VideoRendererError.playbackFailed("AVPlayerItem failed to finish"))
            }
        }
    }

    private func checkPlaybackFailure() {
        guard isPrepared else { return }
        if player?.status == .failed || player?.currentItem?.status == .failed || looper?.status == .failed {
            failPlayback(player?.error ?? player?.currentItem?.error ?? looper?.error
                ?? VideoRendererError.playbackFailed("AVFoundation playback failed"))
        }
    }

    private func failPlayback(_ error: Error) {
        guard isPrepared else { return }
        lifecycle = .failed
        failure = error
        player?.pause()
        // 保留已成功解码的静态首帧兜底，不让失效的视频层覆盖桌面。
        contentView.showVideo(false)
        onFailure?(error)
    }

    private func releasePlayback() {
        observations.removeAll()
        itemObservation = nil
        if let itemFailureObserver { NotificationCenter.default.removeObserver(itemFailureObserver) }
        itemFailureObserver = nil
        imageGenerator?.cancelAllCGImageGeneration()
        imageGenerator = nil
        optionsImageGenerator?.cancelAllCGImageGeneration(); optionsImageGenerator = nil
        asset?.cancelLoading()
        asset = nil
        player?.pause()
        looper?.disableLooping()
        looper = nil
        player?.removeAllItems()
        contentView.playerLayer.player = nil
        player = nil
        processingComposition = nil; loopTemplate = nil
    }

    deinit {
        if let itemFailureObserver { NotificationCenter.default.removeObserver(itemFailureObserver) }
        imageGenerator?.cancelAllCGImageGeneration()
        optionsImageGenerator?.cancelAllCGImageGeneration()
        savedOptionsTask?.cancel()
        asset?.cancelLoading()
        player?.pause()
        looper?.disableLooping()
        player?.removeAllItems()
    }
}
