import AppKit
import AVFoundation
import VideoToolbox
import XCTest
@testable import Kinetic

final class VideoRendererTests: XCTestCase {
    @MainActor
    private func model(_ name: String = "loop", extension ext: String = "mp4") throws -> Wallpaper {
        let url = try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
        return Wallpaper(name: name, type: .video, source: .local, resourceURL: url)
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 8, _ predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !predicate() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                XCTFail("Timed out waiting for real AVFoundation playback")
                throw VideoRendererError.preparationTimedOut
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @MainActor
    func testAudioToggleChangesRealPlayerMuteWithoutRestartingVideo() async throws {
        let renderer = VideoRenderer(wallpaper: try model())
        defer { renderer.dispose() }
        try await renderer.prepare()
        let player = try XCTUnwrap(renderer.player)
        XCTAssertTrue(renderer.isMuted)

        renderer.play()
        try await waitUntil { renderer.currentTime.seconds > 0.2 }
        let item = player.currentItem
        let time = renderer.currentTime.seconds
        renderer.setMuted(false)
        XCTAssertFalse(renderer.isMuted)
        renderer.setMuted(true)
        XCTAssertTrue(renderer.isMuted)
        try await waitUntil { renderer.currentTime.seconds > time + 0.2 }
        XCTAssertTrue(player.currentItem === item, "Audio switch must not restart the wallpaper")
    }

    @MainActor
    func testMP4AndMOVLoopPauseRetainsFrameAndResumeRetainsPosition() async throws {
        // 1.0 Module 8：M4V 与 MP4 / MOV 经过同样的播放、暂停、继续与循环验证。
        for ext in ["mp4", "mov", "m4v"] {
            let renderer = VideoRenderer(wallpaper: try model(extension: ext))
            let desktop = DesktopWindowRuntime(identifier: NSUserInterfaceItemIdentifier("Kinetic.Video.UnitTest"))
            defer { desktop.stop(); renderer.dispose() }
            try await renderer.prepare()
            let player = try XCTUnwrap(renderer.player)
            XCTAssertTrue(renderer.isMuted)
            XCTAssertEqual(player.rate, 0, "Preparation must not autoplay")
            XCTAssertTrue(renderer.contentView.hasPoster)
            XCTAssertFalse(player.preventsDisplaySleepDuringVideoPlayback)
            let asset = try XCTUnwrap(player.currentItem?.asset)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            XCTAssertFalse(audioTracks.isEmpty, "Mute test fixture must contain audio")
            XCTAssertTrue(desktop.present(renderer.contentView))
            renderer.play()
            try await waitUntil { renderer.currentTime.seconds > 0.7 && renderer.contentView.playerLayer.isReadyForDisplay }
            try await waitUntil { !renderer.contentView.playerLayer.isHidden }
            renderer.pause()
            let pausedItem = player.currentItem
            let pausedTime = renderer.currentTime.seconds
            try await Task.sleep(nanoseconds: 450_000_000)
            XCTAssertEqual(renderer.currentTime.seconds, pausedTime, accuracy: 0.025)
            XCTAssertTrue(player.currentItem === pausedItem)
            XCTAssertTrue(renderer.contentView.playerLayer.isReadyForDisplay)
            XCTAssertFalse(renderer.contentView.playerLayer.isHidden)
            XCTAssertTrue(renderer.contentView.playerLayer.player === player)
            renderer.resume()
            try await waitUntil { renderer.currentTime.seconds > pausedTime + 0.2 }
            XCTAssertTrue(player.currentItem === pausedItem, "Resume must not replace or rewind the current item")
            try await waitUntil(timeout: 12) { renderer.completedLoopCount >= 3 }
            XCTAssertTrue(renderer.isMuted, "All looper replicas inherit player mute")
            XCTAssertNil(renderer.failure)
            XCTAssertTrue(renderer.contentView.hasPoster)
            print("MODULE3 \(ext): paused=\(pausedTime), loops=\(renderer.completedLoopCount), ready=\(renderer.contentView.playerLayer.isReadyForDisplay)")
        }
    }

    @MainActor
    func testSuppliedMOVDecodesAndResumesOnDesktop() async throws {
        guard let url = Bundle.main.url(forResource: "5115FE36-676D-450D-B436-C9A45D8286D1", withExtension: "mov") else {
            throw XCTSkip("用户原始 MOV 不随仓库分发；生成的 MP4/MOV 循环与暂停测试仍必须通过。")
        }
        let renderer = VideoRenderer(wallpaper: Wallpaper(name: "用户提供的 MOV", type: .video, source: .local, resourceURL: url))
        let desktop = DesktopWindowRuntime(identifier: NSUserInterfaceItemIdentifier("Kinetic.Video.UnitTest"))
        defer { desktop.stop(); renderer.dispose() }
        try await renderer.prepare()
        let asset = try XCTUnwrap(renderer.player?.currentItem?.asset)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let formats = try await track.load(.formatDescriptions)
        let format = try XCTUnwrap(formats.first)
        let codec = CMFormatDescriptionGetMediaSubType(format)
        let size = CMVideoFormatDescriptionGetDimensions(format)
        print("MODULE3 supplied MOV: duration=\(duration.seconds), size=\(size.width)x\(size.height), codec=\(codec), hardwareAvailable=\(VTIsHardwareDecodeSupported(codec))")
        XCTAssertTrue(desktop.present(renderer.contentView))
        renderer.play()
        try await waitUntil { renderer.currentTime.seconds > 0.6 && renderer.contentView.playerLayer.isReadyForDisplay }
        renderer.pause()
        let time = renderer.currentTime.seconds
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(renderer.currentTime.seconds, time, accuracy: 0.025)
        renderer.resume()
        try await waitUntil { renderer.currentTime.seconds > time + 0.2 }
        XCTAssertNil(renderer.failure)
    }

    @MainActor
    func testInvalidInputsDoNotReplaceExistingDesktopContent() async throws {
        var wrongType = try model()
        wrongType = Wallpaper(name: "web", type: .web, source: .local, resourceURL: wrongType.resourceURL)
        var remote = try model()
        remote.resourceURL = URL(string: "https://invalid.example/video.mp4")!
        var unsupported = try model()
        unsupported.resourceURL = URL(fileURLWithPath: "/not-a-video.html")
        var missing = try model()
        missing.resourceURL = Bundle.main.bundleURL.appendingPathComponent("missing.mov")
        let corrupt = try model("corrupt")
        let desktop = DesktopWindowRuntime(identifier: NSUserInterfaceItemIdentifier("Kinetic.Video.UnitTest"))
        let existing = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        desktop.present(existing)
        defer { desktop.stop() }
        for wallpaper in [wrongType, remote, unsupported, missing, corrupt] {
            let renderer = VideoRenderer(wallpaper: wallpaper)
            do {
                try await renderer.prepare()
                XCTFail("Invalid input unexpectedly prepared")
            } catch {
                XCTAssertFalse(renderer.isPrepared)
                XCTAssertNil(renderer.player)
                XCTAssertNil(renderer.looper)
                XCTAssertFalse(renderer.contentView.hasPoster)
                XCTAssertTrue(desktop.window?.contentView === existing)
            }
            renderer.dispose()
        }
    }

    @MainActor
    func testCancellationAndDisposalDuringPreparationCannotLaterPlay() async throws {
        let cancelled = VideoRenderer(wallpaper: try model())
        let task = Task { @MainActor in try await cancelled.prepare() }
        task.cancel()
        do { try await task.value; XCTFail("Cancelled preparation succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(cancelled.player)
        cancelled.dispose()

        let disposed = VideoRenderer(wallpaper: try model())
        let preparing = Task { @MainActor in try await disposed.prepare() }
        await Task.yield()
        disposed.dispose()
        do { try await preparing.value; XCTFail("Disposed preparation succeeded") }
        catch { }
        disposed.resume()
        XCTAssertFalse(disposed.isPrepared)
        XCTAssertNil(disposed.player)
        XCTAssertFalse(disposed.contentView.hasPoster)
    }

    @MainActor
    func testPlaybackFailureKeepsStaticFallbackAndReportsOnce() async throws {
        let renderer = VideoRenderer(wallpaper: try model())
        defer { renderer.dispose() }
        try await renderer.prepare()
        var failures = 0
        renderer.onFailure = { _ in failures += 1 }
        // 让 currentItem 的 KVO 初始回调安装该 item 的失败通知观察者。
        try await Task.sleep(nanoseconds: 50_000_000)
        let item = try XCTUnwrap(renderer.player?.currentItem)
        let error = NSError(domain: "Kinetic.Module3.Test", code: 1)
        for _ in 0..<2 {
            NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: item,
                userInfo: [AVPlayerItemFailedToPlayToEndTimeErrorKey: error])
        }
        try await waitUntil { renderer.failure != nil }
        XCTAssertEqual(failures, 1)
        XCTAssertTrue(renderer.contentView.hasPoster)
        XCTAssertTrue(renderer.contentView.playerLayer.isHidden)
        XCTAssertEqual(renderer.player?.rate, 0)
        renderer.resume()
        XCTAssertEqual(renderer.player?.rate, 0, "Failure cannot silently restart")
    }

    @MainActor
    func testDisposeReleasesPlayerLooperAndViewAndIsIdempotent() async throws {
        var renderer: VideoRenderer? = VideoRenderer(wallpaper: try model())
        try await renderer?.prepare()
        weak var player: AVQueuePlayer?
        weak var looper: AVPlayerLooper?
        weak var view: VideoContentView?
        weak var weakRenderer: VideoRenderer?
        player = renderer?.player
        looper = renderer?.looper
        view = renderer?.contentView
        weakRenderer = renderer
        renderer?.dispose()
        renderer?.dispose()
        renderer = nil
        try await waitUntil { weakRenderer == nil && player == nil && looper == nil && view == nil }
    }
}
