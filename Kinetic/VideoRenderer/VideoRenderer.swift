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

/// 一个实例只准备一份 Wallpaper。调用方先 await prepare，再注入桌面窗口。
/// 不写入全局 PlaybackState，不决定 Apply、Smart Pause 或 Crossfade。
@MainActor
final class VideoRenderer {
    let wallpaper: Wallpaper
    let contentView = VideoContentView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
    private(set) var player: AVQueuePlayer?
    private(set) var looper: AVPlayerLooper?
    private(set) var failure: Error?
    var onFailure: (@MainActor (Error) -> Void)?

    private enum Lifecycle { case idle, preparing, ready, failed, disposed }
    private var lifecycle = Lifecycle.idle
    private var asset: AVURLAsset?
    private var imageGenerator: AVAssetImageGenerator?
    private var observations: [NSKeyValueObservation] = []
    private var itemObservation: NSKeyValueObservation?
    private var itemFailureObserver: NSObjectProtocol?

    var isPrepared: Bool { lifecycle == .ready }
    var currentTime: CMTime { player?.currentTime() ?? .zero }
    var completedLoopCount: Int { looper?.loopCount ?? 0 }
    var isMuted: Bool { player?.isMuted ?? true }

    init(wallpaper: Wallpaper) { self.wallpaper = wallpaper }

    /// 成功时已解码首帧且播放器 readyToPlay，但不自动播放。
    /// AVPlayerLayer 尚未显示首个视频帧时，内容仍显示静态首帧。
    func prepare() async throws {
        guard lifecycle == .idle else { throw VideoRendererError.invalidLifecycle }
        lifecycle = .preparing
        do {
            try Task.checkCancellation()
            guard wallpaper.type == .video else { throw VideoRendererError.unsupportedWallpaper }
            let url = wallpaper.resourceURL
            guard url.isFileURL, ["mp4", "mov"].contains(url.pathExtension.lowercased()) else {
                throw VideoRendererError.unsupportedResource
            }
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                throw VideoRendererError.missingFile
            }

            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 3840, height: 3840)
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
                let (image, _) = try await generator.image(at: .zero)
                try checkPreparation()
                contentView.setPoster(image)

                let queue = AVQueuePlayer()
                // 原生解码路径由 AVFoundation 选择可用的硬件解码器，不强制软件解码。
                queue.isMuted = true
                queue.preventsDisplaySleepDuringVideoPlayback = false
                queue.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
                player = queue
                contentView.playerLayer.player = queue
                looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(asset: asset))
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
        player?.play()
    }

    /// 保留 player、item 和显示层；不 seek，不移除内容。
    func pause() { player?.pause() }

    func resume() { play() }

    func setMuted(_ muted: Bool) { player?.isMuted = muted }

    /// 调用方先从窗口移除 contentView，再释放 Renderer。此后不能重用此实例。
    func dispose() {
        guard lifecycle != .disposed else { return }
        lifecycle = .disposed
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
                    self.contentView.showVideo(self.contentView.playerLayer.isReadyForDisplay)
                }
            },
            player.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.checkPlaybackFailure() }
            },
            looper.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.checkPlaybackFailure() }
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
        asset?.cancelLoading()
        asset = nil
        player?.pause()
        looper?.disableLooping()
        looper = nil
        player?.removeAllItems()
        contentView.playerLayer.player = nil
        player = nil
    }

    deinit {
        if let itemFailureObserver { NotificationCenter.default.removeObserver(itemFailureObserver) }
        imageGenerator?.cancelAllCGImageGeneration()
        asset?.cancelLoading()
        player?.pause()
        looper?.disableLooping()
        player?.removeAllItems()
    }
}
