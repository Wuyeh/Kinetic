import XCTest
@testable import Kinetic

final class MenuBarPresentationTests: XCTestCase {
    func testNoWallpaperAndStoppedStatesDoNotOfferMeaninglessPlaybackActions() {
        let empty = MenuBarPlaybackPresentation(state: WallpaperRuntimeState(), canReenable: false)
        XCTAssertFalse(empty.iconUsesAccent)
        XCTAssertNil(empty.primaryAction)
        XCTAssertFalse(empty.canStop)
        XCTAssertFalse(empty.hasWallpaperContext)

        var stopped = WallpaperRuntimeState()
        stopped.playbackState = .stopped
        stopped.lastActiveWallpaperID = UUID()
        let reusable = MenuBarPlaybackPresentation(state: stopped, canReenable: true)
        XCTAssertFalse(reusable.iconUsesAccent)
        XCTAssertEqual(reusable.primaryAction, .reenable)
        XCTAssertFalse(reusable.canStop)
        XCTAssertTrue(reusable.hasWallpaperContext)

        let deleted = MenuBarPlaybackPresentation(state: stopped, canReenable: false)
        XCTAssertNil(deleted.primaryAction)
        XCTAssertFalse(deleted.hasWallpaperContext)
    }

    func testPlayingManualPauseAndSmartPauseUseDistinctLogoAndActions() {
        var state = WallpaperRuntimeState()
        state.activeWallpaperID = UUID()

        state.playbackState = .playing
        let playing = MenuBarPlaybackPresentation(state: state, canReenable: false)
        XCTAssertTrue(playing.iconUsesAccent)
        XCTAssertEqual(playing.primaryAction, .pause)
        XCTAssertTrue(playing.canStop)

        state.playbackState = .manualPaused
        let manual = MenuBarPlaybackPresentation(state: state, canReenable: false)
        XCTAssertFalse(manual.iconUsesAccent)
        XCTAssertEqual(manual.primaryAction, .resume)
        XCTAssertTrue(manual.canStop)

        state.playbackState = .smartPaused
        let smart = MenuBarPlaybackPresentation(state: state, canReenable: false)
        XCTAssertTrue(smart.iconUsesAccent)
        XCTAssertNil(smart.primaryAction)
        XCTAssertTrue(smart.canStop)

        state.playbackState = .failed
        let failed = MenuBarPlaybackPresentation(state: state, canReenable: false)
        XCTAssertFalse(failed.iconUsesAccent)
        XCTAssertNil(failed.primaryAction)
        XCTAssertTrue(failed.canStop)
    }
}
