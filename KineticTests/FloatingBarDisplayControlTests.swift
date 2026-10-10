import AppKit
import XCTest
@testable import Kinetic

/// R4 第 9–13、54 节：Floating Bar 控制一台显示器（controlledDisplayID），播放 / 暂停、停止与声音只作用于它；
/// Display Bubble 只切换控制对象；背景不透明度 × 1.5。
final class FloatingBarDisplayControlTests: XCTestCase {
    private let a = DisplayID("display-A"), b = DisplayID("display-B")
    private let rain = UUID(), snow = UUID()

    func testControlStartsOnTheMainDisplayAndNeverStealsBackAfterReconnect() {
        var control = FloatingBarDisplayControl()
        XCTAssertNil(control.synchronize(displayIDs: [a, b]), "No toast for the first assignment")
        XCTAssertEqual(control.controlledDisplayID, a, "Main display first")
        XCTAssertTrue(control.select(b, displayIDs: [a, b]))
        XCTAssertEqual(control.controlledDisplayID, b)
        XCTAssertFalse(control.select(DisplayID("gone"), displayIDs: [a, b]))
        XCTAssertEqual(control.controlledDisplayID, b)

        // 受控显示器被拔出：改为控制主屏，并返回主屏用于提示。
        XCTAssertEqual(control.synchronize(displayIDs: [a]), a)
        XCTAssertEqual(control.controlledDisplayID, a)
        // 重连后不抢回控制权。
        XCTAssertNil(control.synchronize(displayIDs: [a, b]))
        XCTAssertEqual(control.controlledDisplayID, a)
        // 排列变化（主屏换成 B）不改变当前控制对象。
        XCTAssertNil(control.synchronize(displayIDs: [b, a]))
        XCTAssertEqual(control.controlledDisplayID, a)
    }

    func testToolbarStateFollowsOnlyTheControlledDisplay() {
        let laptop = DisplayRuntimeState(displayID: a, displayName: "MacBook", runtime:
            WallpaperRuntimeState(playbackState: .playing, activeWallpaperID: rain, lastActiveWallpaperID: rain))
        let studio = DisplayRuntimeState(displayID: b, displayName: "Studio", runtime:
            WallpaperRuntimeState(playbackState: .manualPaused, activeWallpaperID: snow, lastActiveWallpaperID: snow))
        let onLaptop = FloatingToolbarState(display: laptop, isInLibrary: { _ in true })
        XCTAssertEqual(onLaptop.playbackAction, .pauseAll, "Shows Pause for the playing display")
        XCTAssertEqual(onLaptop.nowPlaying, .wallpaper(rain, display: a))
        let onStudio = FloatingToolbarState(display: studio, isInLibrary: { _ in true })
        XCTAssertEqual(onStudio.playbackAction, .resumeAll, "Shows Play for the paused display")
        XCTAssertEqual(onStudio.nowPlaying, .wallpaper(snow, display: b))
        let none = FloatingToolbarState(display: nil, isInLibrary: { _ in true })
        XCTAssertEqual(none.playbackAction, .none)
        XCTAssertFalse(none.canStop)
        XCTAssertNil(none.nowPlaying)
        // 只有一台显示器时与原来的汇总完全相同。
        XCTAssertEqual(FloatingToolbarState(display: laptop, isInLibrary: { _ in true }),
                       FloatingToolbarState(summary: RuntimeSummary(displays: [laptop]), isInLibrary: { _ in true }))
    }

    @MainActor
    func testPlaybackStopAndAudioOnlyAffectTheControlledDisplay() {
        let runtime = WallpaperRuntimeManager { AppControlTestRenderer($0) }
        runtime.addDisplay(a, host: AppControlTestHost())
        runtime.addDisplay(b, host: AppControlTestHost())
        defer { runtime.shutdown() }
        runtime.setAudioEnabled(false)

        runtime.setAudioEnabled(true, on: b)
        XCTAssertTrue(runtime.isAudioEnabled(on: b))
        XCTAssertFalse(runtime.isAudioEnabled(on: a), "The other display keeps its audio")
        XCTAssertFalse(runtime.isAudioEnabled, "The default preference is unchanged")

        // 设置 / 菜单栏的全局开关作用于全部显示器，清除单独设置。
        runtime.setAudioEnabled(true)
        XCTAssertTrue(runtime.isAudioEnabled(on: a))
        XCTAssertTrue(runtime.displayAudioOverrides.isEmpty)
        runtime.setAudioEnabled(false, on: a)
        runtime.setAudioEnabled(true)
        XCTAssertTrue(runtime.isAudioEnabled(on: a), "Global on again clears the per-display mute")
        runtime.setAudioEnabled(false, on: b)
        runtime.removeDisplay(b)
        XCTAssertNil(runtime.displayAudioOverrides[b])

        let stopped = FloatingToolbarState(display: DisplayRuntimeState(displayID: a, displayName: "", runtime:
            WallpaperRuntimeState(playbackState: .stopped, lastActiveWallpaperID: rain)), isInLibrary: { _ in true })
        XCTAssertEqual(stopped.playbackAction, .reenableAll)
    }

    func testBackgroundOpacityIsRaisedOnceByOneAndAHalf() {
        let old = FloatingBarBackground.estimatedGlassOpacity
        XCTAssertEqual(FloatingBarBackground.targetOpacity, min(1, old * 1.5), accuracy: 0.0001)
        let combined = 1 - (1 - old) * (1 - FloatingBarBackground.fillOpacity)
        XCTAssertEqual(combined, FloatingBarBackground.targetOpacity, accuracy: 0.0001,
                       "Glass plus the fill layer reaches alpha_new = min(1, alpha_old × 1.5)")
        XCTAssertGreaterThan(FloatingBarBackground.fillOpacity, 0)
        XCTAssertLessThan(FloatingBarBackground.fillOpacity, 1)
    }
}
