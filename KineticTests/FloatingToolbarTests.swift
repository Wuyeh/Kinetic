import AppKit
import XCTest
@testable import Kinetic

/// Kinetic 1.0 Module 23 — Floating Toolbar：＋ / 播放暂停 / 停止 / 声音作用于全部显示器，
/// 状态来自全部显示器的汇总；只有一台显示器时与 v0.1 单显示器工具条相同。
final class FloatingToolbarTests: XCTestCase {
    private let displayA = DisplayID("display-A")
    private let displayB = DisplayID("display-B")
    private let rain = UUID()
    private let snow = UUID()

    private func summary(_ states: [(DisplayID, WallpaperRuntimeState)]) -> RuntimeSummary {
        RuntimeSummary(displays: states.map { DisplayRuntimeState(displayID: $0.0, displayName: "", runtime: $0.1) })
    }

    private func state(_ playback: PlaybackState, active: UUID? = nil, preparing: UUID? = nil,
                       last: UUID? = nil) -> WallpaperRuntimeState {
        WallpaperRuntimeState(playbackState: playback, activeWallpaperID: active,
                              preparingWallpaperID: preparing, lastActiveWallpaperID: last)
    }

    private func toolbar(_ states: [(DisplayID, WallpaperRuntimeState)],
                         library: Set<UUID>? = nil) -> FloatingToolbarState {
        let inLibrary = library ?? [rain, snow]
        return FloatingToolbarState(summary: summary(states), isInLibrary: { inLibrary.contains($0) })
    }

    // MARK: - 一台显示器：与 v0.1 相同

    func testSingleDisplayMatchesTheOriginalToolbar() {
        let playing = toolbar([(.main, state(.playing, active: rain, last: rain))])
        XCTAssertEqual(playing.playbackAction, .pauseAll)
        XCTAssertTrue(playing.showsPauseSymbol)
        XCTAssertEqual(playing.playbackHelpKey, "shell.toolbar.pause")
        XCTAssertTrue(playing.canStop)
        XCTAssertEqual(playing.nowPlaying, .wallpaper(rain, display: .main))

        let paused = toolbar([(.main, state(.manualPaused, active: rain, last: rain))])
        XCTAssertEqual(paused.playbackAction, .resumeAll)
        XCTAssertFalse(paused.showsPauseSymbol)
        XCTAssertEqual(paused.playbackHelpKey, "shell.toolbar.resume")
        XCTAssertTrue(paused.canStop)
        XCTAssertEqual(paused.nowPlaying, .wallpaper(rain, display: .main))

        let smart = toolbar([(.main, state(.smartPaused, active: rain, last: rain))])
        XCTAssertEqual(smart.playbackAction, .none, "Smart pause follows system conditions")
        XCTAssertFalse(smart.canTogglePlayback)
        XCTAssertEqual(smart.playbackHelpKey, "shell.toolbar.resume")
        XCTAssertTrue(smart.canStop)

        let preparing = toolbar([(.main, state(.preparing, preparing: snow))])
        XCTAssertEqual(preparing.playbackAction, .none)
        XCTAssertEqual(preparing.playbackHelpKey, "shell.toolbar.play")
        XCTAssertTrue(preparing.canStop, "A wallpaper that is still loading can be stopped")
        XCTAssertNil(preparing.nowPlaying)

        let stopped = toolbar([(.main, state(.stopped, last: rain))])
        XCTAssertEqual(stopped.playbackAction, .reenableAll)
        XCTAssertEqual(stopped.playbackHelpKey, "shell.toolbar.reenable")
        XCTAssertFalse(stopped.canStop)
        XCTAssertNil(stopped.nowPlaying)

        let deleted = toolbar([(.main, state(.stopped, last: rain))], library: [snow])
        XCTAssertEqual(deleted.playbackAction, .none, "A deleted wallpaper cannot be re-enabled")
        XCTAssertEqual(deleted.playbackHelpKey, "shell.toolbar.reenable")

        let empty = toolbar([(.main, state(.noWallpaper))])
        XCTAssertEqual(empty.playbackAction, .none)
        XCTAssertEqual(empty.playbackHelpKey, "shell.toolbar.play")
        XCTAssertFalse(empty.canStop)
        XCTAssertNil(empty.nowPlaying)

        let failed = toolbar([(.main, state(.failed, last: rain))])
        XCTAssertEqual(failed.playbackAction, .none)
        XCTAssertEqual(failed.playbackHelpKey, "shell.toolbar.play")
    }

    func testNoDisplaySessionDisablesEverything() {
        let none = toolbar([])
        XCTAssertEqual(none.playbackAction, .none)
        XCTAssertFalse(none.canStop)
        XCTAssertNil(none.nowPlaying)
    }

    // MARK: - 多台显示器：作用于全部显示器

    func testSeveralDisplaysAreSummarisedForTheWholeToolbar() {
        // 只要有一台在播放，按钮就是「暂停全部」。
        let mixed = toolbar([(displayA, state(.playing, active: rain, last: rain)),
                             (displayB, state(.manualPaused, active: snow, last: snow))])
        XCTAssertEqual(mixed.playbackAction, .pauseAll)
        XCTAssertEqual(mixed.nowPlaying, .multiple(displayCount: 2))
        XCTAssertTrue(mixed.canStop)

        // 没有在播放、有一台手动暂停：继续全部。
        let resume = toolbar([(displayA, state(.manualPaused, active: rain, last: rain)),
                              (displayB, state(.stopped, last: snow))])
        XCTAssertEqual(resume.playbackAction, .resumeAll)
        XCTAssertEqual(resume.nowPlaying, .wallpaper(rain, display: displayA), "Stopped displays show nothing")

        // 全部停止：只要有一台停止前的壁纸还在资料库中，就可以重新启用。
        let stopped = toolbar([(displayA, state(.stopped, last: rain)), (displayB, state(.stopped, last: snow))],
                              library: [snow])
        XCTAssertEqual(stopped.playbackAction, .reenableAll)
        XCTAssertFalse(stopped.canStop)
        let stoppedAndEmpty = toolbar([(displayA, state(.stopped, last: rain)), (displayB, state(.noWallpaper))])
        XCTAssertEqual(stoppedAndEmpty.playbackAction, .reenableAll)
        let nothingLeft = toolbar([(displayA, state(.stopped, last: rain)), (displayB, state(.stopped))],
                                  library: [])
        XCTAssertEqual(nothingLeft.playbackAction, .none)

        // 一台准备中、一台停止：不能切换，但可以停止准备中的那台。
        let loading = toolbar([(displayA, state(.preparing, preparing: rain)), (displayB, state(.stopped, last: snow))])
        XCTAssertEqual(loading.playbackAction, .none)
        XCTAssertTrue(loading.canStop)

        // 两台显示同一张壁纸：中间显示这张壁纸，而不是「多台显示器」。
        let same = toolbar([(displayA, state(.playing, active: rain, last: rain)),
                            (displayB, state(.smartPaused, active: rain, last: rain))])
        XCTAssertEqual(same.nowPlaying, .wallpaper(rain, display: displayA))
        XCTAssertEqual(same.playbackAction, .pauseAll)

        // 两台都智能暂停：跟随系统条件，不能从工具条强行继续。
        let smart = toolbar([(displayA, state(.smartPaused, active: rain, last: rain)),
                             (displayB, state(.smartPaused, active: snow, last: snow))])
        XCTAssertEqual(smart.playbackAction, .none)
        XCTAssertEqual(smart.nowPlaying, .multiple(displayCount: 2))
    }

    func testLabels() {
        XCTAssertEqual(FloatingToolbarAddItem.allCases, [.importVideo, .importWebFolder, .openSteamWorkshop])
        XCTAssertEqual(NSLocalizedString(FloatingToolbarAddItem.importVideo.titleKey, comment: ""), "从 Mac 导入…")
        XCTAssertEqual(NSLocalizedString(FloatingToolbarAddItem.importWebFolder.titleKey, comment: ""),
                       "导入网页壁纸文件夹…")
        XCTAssertEqual(NSLocalizedString(FloatingToolbarAddItem.openSteamWorkshop.titleKey, comment: ""),
                       "前往 Steam 创意工坊")
        XCTAssertEqual(String(format: NSLocalizedString("shell.toolbar.nowPlaying.multiple", comment: ""), 2),
                       "2 个显示器使用不同的壁纸")
        for key in ["shell.toolbar.pause", "shell.toolbar.resume", "shell.toolbar.reenable", "shell.toolbar.play",
                    "shell.toolbar.stop", "shell.toolbar.mute", "shell.toolbar.unmute"] {
            XCTAssertNotEqual(NSLocalizedString(key, comment: ""), key, key)
        }
    }

    // MARK: - 按钮动作真正作用于每一台显示器

    @MainActor
    private final class ImmediateRenderer: WallpaperRenderer {
        let wallpaper: Wallpaper
        let displayView = NSView()
        var onFailure: (@MainActor (Error) -> Void)?
        init(wallpaper: Wallpaper) { self.wallpaper = wallpaper }
        func prepare() async throws {}
        func play() {}
        func pause() {}
        func resume() {}
        func setMuted(_ muted: Bool) {}
        func dispose() {}
    }

    private final class LibraryIDs {
        var ids: Set<UUID>
        init(_ ids: Set<UUID>) { self.ids = ids }
    }

    @MainActor
    private final class Desktop: DesktopContentHost {
        func present(_ contentView: NSView) -> Bool { true }
        func stop() {}
    }

    @MainActor
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while !predicate() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                XCTFail("Timed out waiting for the runtime")
                throw CancellationError()
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @MainActor
    func testToolbarActionsReachEveryDisplay() async throws {
        let runtime = WallpaperRuntimeManager { ImmediateRenderer(wallpaper: $0) }
        let desktopA = Desktop(), desktopB = Desktop()
        runtime.addDisplay(displayA, name: "A", host: desktopA)
        runtime.addDisplay(displayB, name: "B", host: desktopB)
        let rainWallpaper = Wallpaper(id: rain, name: "雨夜", type: .video, acquisitionOrigin: .localImport,
                                      resourceURL: URL(fileURLWithPath: "/tmp/rain.mp4"))
        let snowWallpaper = Wallpaper(id: snow, name: "雪原", type: .video, acquisitionOrigin: .localImport,
                                      resourceURL: URL(fileURLWithPath: "/tmp/snow.mp4"))
        let library = LibraryIDs([rain, snow])
        let inLibrary: (UUID) -> Bool = { library.ids.contains($0) }
        func states() -> [PlaybackState] { runtime.summary.displays.map(\.runtime.playbackState) }
        func current() -> FloatingToolbarState { FloatingToolbarState(summary: runtime.summary, isInLibrary: inLibrary) }

        runtime.apply(rainWallpaper, to: displayA)
        runtime.apply(snowWallpaper, to: displayB)
        try await waitUntil { states() == [.playing, .playing] }
        XCTAssertEqual(current().nowPlaying, .multiple(displayCount: 2))

        FloatingToolbarState.perform(current().playbackAction, on: runtime, isInLibrary: inLibrary)
        try await waitUntil { states() == [.manualPaused, .manualPaused] }
        XCTAssertEqual(current().playbackAction, .resumeAll)

        FloatingToolbarState.perform(current().playbackAction, on: runtime, isInLibrary: inLibrary)
        try await waitUntil { states() == [.playing, .playing] }

        // 停止作用于全部显示器；之后重新启用只恢复壁纸仍在资料库中的显示器。
        runtime.stop(.allDisplays)
        try await waitUntil { states() == [.stopped, .stopped] }
        library.ids.remove(snow)
        XCTAssertEqual(current().playbackAction, .reenableAll)
        FloatingToolbarState.perform(.reenableAll, on: runtime, isInLibrary: inLibrary)
        try await waitUntil { states() == [.playing, .stopped] }
        XCTAssertEqual(runtime.summary.displays.first?.runtime.activeWallpaperID, rain)
        XCTAssertEqual(current().nowPlaying, .wallpaper(rain, display: displayA))

        // 声音是全局开关：打开后每台显示器都跟随。
        XCTAssertFalse(runtime.isAudioEnabled)
        runtime.setAudioEnabled(true)
        XCTAssertTrue(runtime.isAudioEnabled)
        runtime.setAudioEnabled(false)
        runtime.shutdown()
    }
}
