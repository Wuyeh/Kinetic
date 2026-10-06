import AppKit
import AVFoundation
import XCTest
@testable import Kinetic

final class ErrorRecoveryTests: XCTestCase {
    @MainActor
    private final class Harness {
        let desktop = DesktopWindowRuntime(identifier: NSUserInterfaceItemIdentifier("Kinetic.RecoveryTests"))
        let host: CrossfadeDesktopHost
        let runtime: WallpaperRuntimeManager
        init(duration: TimeInterval = 0.35) {
            host = CrossfadeDesktopHost(desktop: desktop, duration: duration)
            runtime = WallpaperRuntimeManager(desktop: host)
        }
    }

    @MainActor
    private func fixture(_ name: String = "loop") throws -> Wallpaper {
        let url = try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: "mp4", subdirectory: "Fixtures"))
        return Wallpaper(name: name, type: .video, source: .local, resourceURL: url)
    }

    @MainActor
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                XCTFail("Timed out waiting for recovery")
                throw VideoRendererError.preparationTimedOut
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @MainActor
    func testCorruptMissingAndRemoteVideoKeepCurrentDesktop() async throws {
        let harness = Harness()
        defer { harness.runtime.shutdown() }
        let original = try fixture()
        harness.runtime.apply(original)
        try await wait { harness.runtime.state.playbackState == .playing }
        let content = try XCTUnwrap(harness.host.stage.topContent)
        let window = try XCTUnwrap(harness.desktop.window)
        let invalid = [
            try fixture("corrupt"),
            Wallpaper(name: "丢失的文件", type: .video, source: .local,
                      resourceURL: URL(fileURLWithPath: "/kinetic-missing-file.mp4")),
            Wallpaper(name: "离线远程文件", type: .video, source: .local,
                      resourceURL: URL(string: "https://invalid.example/offline.mp4")!)
        ]
        for wallpaper in invalid {
            harness.runtime.apply(wallpaper)
            try await wait { harness.runtime.lastFailure?.wallpaperID == wallpaper.id }
            XCTAssertEqual(harness.runtime.state.activeWallpaperID, original.id)
            XCTAssertEqual(harness.runtime.state.playbackState, .playing)
            XCTAssertTrue(harness.host.stage.topContent === content)
            XCTAssertTrue(harness.desktop.window === window)
            XCTAssertEqual(harness.host.completedTransitionCount, 0)
            harness.runtime.dismissFailure()
            XCTAssertNil(harness.runtime.lastFailure)
        }
    }

    @MainActor
    func testUnavailableWebSceneAndSteamResourceLeaveWallpaperUntouched() async throws {
        let harness = Harness()
        defer { harness.runtime.shutdown() }
        let original = try fixture()
        harness.runtime.apply(original)
        try await wait { harness.runtime.state.playbackState == .playing }
        let before = harness.runtime.state
        for type in [WallpaperType.web, .scene] {
            let wallpaper = Wallpaper(name: "尚未接入", type: type, source: .steam,
                                      resourceURL: URL(fileURLWithPath: "/unavailable/index.html"))
            harness.runtime.apply(wallpaper)
            try await wait { harness.runtime.lastFailure?.wallpaperID == wallpaper.id }
            XCTAssertEqual(harness.runtime.lastFailure?.wallpaperID, wallpaper.id)
            XCTAssertEqual(harness.runtime.state, before)
        }
        let steam = Wallpaper(name: "工坊文件不存在", type: .video, source: .steam,
                              resourceURL: URL(fileURLWithPath: "/unavailable/workshop.mp4"))
        harness.runtime.apply(steam)
        try await wait { harness.runtime.lastFailure?.wallpaperID == steam.id }
        XCTAssertEqual(harness.runtime.state, before)
        XCTAssertEqual(harness.host.stage.contents.count, 1)
    }

    @MainActor
    func testFailedFirstApplyLeavesNativeDesktopAndCanRetryRepairedFile() async throws {
        // 测试宿主启用 App Sandbox：临时媒体必须位于其临时目录，并在测试结束时移除。
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Kinetic-Recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("repair.mp4")
        try Data("broken".utf8).write(to: url)
        let wallpaper = Wallpaper(name: "可修复视频", type: .video, source: .local, resourceURL: url)
        let harness = Harness()
        defer { harness.runtime.shutdown() }
        harness.runtime.apply(wallpaper)
        try await wait { harness.runtime.lastFailure != nil }
        XCTAssertNil(harness.desktop.window)
        XCTAssertEqual(harness.runtime.state.playbackState, .noWallpaper)
        try Data(contentsOf: fixture().resourceURL).write(to: url, options: .atomic)
        harness.runtime.apply(wallpaper)
        XCTAssertNil(harness.runtime.lastFailure)
        try await wait { harness.runtime.state.playbackState == .playing }
        XCTAssertEqual(harness.runtime.state.activeWallpaperID, wallpaper.id)
        XCTAssertNotNil(harness.desktop.window)
    }

    @MainActor
    func testFailureDuringCrossfadeKeepsPosterAndRetryReplacesFailedRenderer() async throws {
        let desktop = DesktopWindowRuntime(identifier: NSUserInterfaceItemIdentifier("Kinetic.RecoveryTests"))
        let host = CrossfadeDesktopHost(desktop: desktop, duration: 0.7)
        var videos: [VideoRenderer] = []
        let runtime = WallpaperRuntimeManager(desktop: host) { wallpaper in
            let video = VideoRenderer(wallpaper: wallpaper)
            videos.append(video)
            return video
        }
        defer { runtime.shutdown() }
        runtime.apply(try fixture())
        try await wait { runtime.state.playbackState == .playing }
        let next = try fixture("loop-warm")
        runtime.apply(next)
        try await wait { runtime.state.activeWallpaperID == next.id }
        let failed = try XCTUnwrap(videos.last)
        try await Task.sleep(nanoseconds: 50_000_000)
        let item = try XCTUnwrap(failed.player?.currentItem)
        NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: item)
        try await wait { runtime.state.playbackState == .failed }
        XCTAssertTrue(host.isTransitioning)
        XCTAssertTrue(failed.contentView.hasPoster)
        XCTAssertTrue(failed.contentView.playerLayer.isHidden)
        XCTAssertEqual(host.stage.contents.count, 2)
        runtime.setSmartPauseActive(true)
        runtime.setSmartPauseActive(false)
        XCTAssertEqual(runtime.state.playbackState, .failed, "Wake must not restart a failed renderer")
        XCTAssertEqual(failed.player?.rate, 0)
        try await wait { !host.isTransitioning }
        XCTAssertTrue(host.stage.topContent === failed.contentView)
        runtime.apply(next)
        try await wait { runtime.state.playbackState == .playing }
        XCTAssertNil(runtime.lastFailure)
        XCTAssertFalse(videos.last === failed)
        try await wait { !host.isTransitioning }
        XCTAssertNil(failed.player)
        XCTAssertEqual(host.stage.contents.count, 1)
    }

    @MainActor
    func testInterruptedAnimationStillLeavesOpaqueIncomingFrameAndReleasesOutgoing() async throws {
        let harness = Harness()
        defer { harness.runtime.shutdown() }
        harness.runtime.apply(try fixture())
        try await wait { harness.runtime.state.playbackState == .playing }
        let outgoing = try XCTUnwrap(harness.host.stage.topContent)
        let next = try fixture("loop-warm")
        harness.runtime.apply(next)
        try await wait { harness.runtime.state.activeWallpaperID == next.id }
        let incoming = try XCTUnwrap(harness.host.stage.topContent)
        harness.host.stage.slot(containing: incoming)?.layer?.removeAllAnimations()
        try await wait { !harness.host.isTransitioning }
        XCTAssertEqual(harness.host.stage.slot(containing: incoming)?.alphaValue, 1)
        XCTAssertNil(outgoing.superview)
        XCTAssertEqual(harness.host.stage.contents.count, 1)
        XCTAssertNotNil(harness.desktop.window)
    }

    @MainActor
    func testCorruptApplyPreservesManualPauseAcrossSleepWakeAndSuccessfulRetry() async throws {
        let harness = Harness()
        defer { harness.runtime.shutdown() }
        let original = try fixture()
        harness.runtime.apply(original)
        try await wait { harness.runtime.state.playbackState == .playing }
        harness.runtime.pause()
        harness.runtime.setSmartPauseActive(true)
        harness.runtime.apply(try fixture("corrupt"))
        try await wait { harness.runtime.lastFailure != nil }
        harness.runtime.setSmartPauseActive(false)
        XCTAssertEqual(harness.runtime.state.playbackState, .manualPaused)
        let next = try fixture("loop-warm")
        harness.runtime.apply(next)
        try await wait { harness.runtime.state.activeWallpaperID == next.id }
        XCTAssertNil(harness.runtime.lastFailure)
        XCTAssertEqual(harness.runtime.state.playbackState, .manualPaused)
    }

    @MainActor
    func testStartupCleanupOnlyClosesOwnedOrphanWindowsAndDetachesContents() {
        let identifier = NSUserInterfaceItemIdentifier("Kinetic.RecoveryOrphanTest")
        let orphan = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 80),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let ordinary = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 80),
                                styleMask: .titled, backing: .buffered, defer: false)
        orphan.isReleasedWhenClosed = false
        ordinary.isReleasedWhenClosed = false
        orphan.identifier = identifier
        ordinary.identifier = NSUserInterfaceItemIdentifier("main")
        let orphanContent = NSView()
        let ordinaryContent = NSView()
        orphan.contentView = orphanContent
        ordinary.contentView = ordinaryContent
        defer { ordinary.close() }
        DesktopWindowRuntime.closeOrphanedWindows(in: [orphan, ordinary], identifier: identifier)
        XCTAssertNil(orphan.contentView)
        XCTAssertNil(orphanContent.window)
        XCTAssertTrue(ordinary.contentView === ordinaryContent)
        DesktopWindowRuntime.closeOrphanedWindows(in: [orphan, ordinary], identifier: identifier)
        XCTAssertTrue(ordinary.contentView === ordinaryContent, "Repeated cleanup is safe")
    }
}
