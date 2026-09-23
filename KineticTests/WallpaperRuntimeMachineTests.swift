import XCTest
@testable import Kinetic

/// 纯状态规则测试，不创建窗口、Renderer 或媒体。
final class WallpaperRuntimeMachineTests: XCTestCase {
    private let a = UUID()
    private let b = UUID()
    private let c = UUID()

    private func playing(_ id: UUID) -> WallpaperRuntimeMachine {
        var machine = WallpaperRuntimeMachine()
        _ = machine.handle(.apply(id))
        _ = machine.handle(.preparationSucceeded(id))
        return machine
    }

    func testInitialStateMatchesCoreDomainDefaults() {
        let machine = WallpaperRuntimeMachine()
        XCTAssertEqual(machine.snapshot, WallpaperRuntimeState())
        XCTAssertEqual(machine.playbackState, .noWallpaper)
    }

    func testFirstApplyPreparesThenPromotesAndPlays() {
        var machine = WallpaperRuntimeMachine()
        XCTAssertEqual(machine.handle(.apply(a)), [.prepareCandidate(a)])
        XCTAssertEqual(machine.playbackState, .preparing)
        XCTAssertEqual(machine.snapshot.preparingWallpaperID, a)
        XCTAssertNil(machine.snapshot.activeWallpaperID)

        XCTAssertEqual(machine.handle(.preparationSucceeded(a)), [.promoteCandidate, .playActive])
        XCTAssertEqual(machine.playbackState, .playing)
        XCTAssertEqual(machine.snapshot.activeWallpaperID, a)
        XCTAssertEqual(machine.snapshot.lastActiveWallpaperID, a)
        XCTAssertNil(machine.snapshot.preparingWallpaperID)
    }

    func testSwitchKeepsOldWallpaperActiveUntilNewOneIsReady() {
        var machine = playing(a)
        XCTAssertEqual(machine.handle(.apply(b)), [.prepareCandidate(b)])
        // 旧壁纸继续显示与播放，候选单独记录。
        XCTAssertEqual(machine.playbackState, .playing)
        XCTAssertEqual(machine.snapshot.activeWallpaperID, a)
        XCTAssertEqual(machine.snapshot.preparingWallpaperID, b)

        XCTAssertEqual(machine.handle(.preparationSucceeded(b)), [.promoteCandidate, .playActive])
        XCTAssertEqual(machine.snapshot.activeWallpaperID, b)
        XCTAssertEqual(machine.playbackState, .playing)
    }

    func testFailedSwitchKeepsOldWallpaperAndReportsOnce() {
        var machine = playing(a)
        _ = machine.handle(.apply(b))
        XCTAssertEqual(machine.handle(.preparationFailed(b)), [.reportFailure(b), .discardCandidate])
        XCTAssertEqual(machine.playbackState, .playing)
        XCTAssertEqual(machine.snapshot.activeWallpaperID, a)
        XCTAssertNil(machine.snapshot.preparingWallpaperID)
        XCTAssertEqual(machine.handle(.preparationFailed(b)), [], "Duplicate failure is ignored")
    }

    func testFirstApplyFailureReturnsToNoWallpaper() {
        var machine = WallpaperRuntimeMachine()
        _ = machine.handle(.apply(a))
        _ = machine.handle(.preparationFailed(a))
        XCTAssertEqual(machine.playbackState, .noWallpaper)
        XCTAssertEqual(machine.snapshot, WallpaperRuntimeState())
    }

    func testManualPauseAndResumeKeepPosition() {
        var machine = playing(a)
        XCTAssertEqual(machine.handle(.pause), [.pauseActive])
        XCTAssertEqual(machine.playbackState, .manualPaused)
        XCTAssertEqual(machine.handle(.pause), [])
        XCTAssertEqual(machine.handle(.resume), [.resumeActive], "Resume continues; it never restarts playback")
        XCTAssertEqual(machine.playbackState, .playing)
        XCTAssertEqual(machine.handle(.resume), [])
    }

    func testSmartPauseAutomaticallyResumesFromSamePosition() {
        var machine = playing(a)
        XCTAssertEqual(machine.handle(.smartPauseChanged(true)), [.pauseActive])
        XCTAssertEqual(machine.playbackState, .smartPaused)
        XCTAssertEqual(machine.handle(.smartPauseChanged(true)), [])
        XCTAssertEqual(machine.handle(.smartPauseChanged(false)), [.resumeActive])
        XCTAssertEqual(machine.playbackState, .playing)
    }

    func testManualPauseHasPriorityOverSmartPause() {
        var machine = playing(a)
        _ = machine.handle(.pause)
        XCTAssertEqual(machine.handle(.smartPauseChanged(true)), [])
        XCTAssertEqual(machine.playbackState, .manualPaused)
        XCTAssertEqual(machine.handle(.smartPauseChanged(false)), [])
        XCTAssertEqual(machine.playbackState, .manualPaused, "Smart condition ending never clears Manual Pause")
        XCTAssertEqual(machine.handle(.resume), [.resumeActive])
        XCTAssertEqual(machine.playbackState, .playing)
    }

    func testManualPauseDuringSmartPauseThenResumeWhileConditionStillActive() {
        var machine = playing(a)
        _ = machine.handle(.smartPauseChanged(true))
        XCTAssertEqual(machine.handle(.pause), [], "Already paused by system condition")
        XCTAssertEqual(machine.playbackState, .manualPaused)
        XCTAssertEqual(machine.handle(.resume), [], "System condition still holds the renderer")
        XCTAssertEqual(machine.playbackState, .smartPaused)
        XCTAssertEqual(machine.handle(.smartPauseChanged(false)), [.resumeActive])
        XCTAssertEqual(machine.playbackState, .playing)
    }

    func testApplyWhileManualPausedBecomesActiveButStaysPaused() {
        var machine = playing(a)
        _ = machine.handle(.pause)
        _ = machine.handle(.apply(b))
        XCTAssertEqual(machine.playbackState, .manualPaused)
        XCTAssertEqual(machine.handle(.preparationSucceeded(b)), [.promoteCandidate], "New wallpaper must not autoplay")
        XCTAssertEqual(machine.snapshot.activeWallpaperID, b)
        XCTAssertEqual(machine.playbackState, .manualPaused)
        XCTAssertEqual(machine.handle(.resume), [.playActive], "First start of the new renderer")
        XCTAssertEqual(machine.playbackState, .playing)
    }

    func testApplyWhileSmartPausedWaitsForConditionToEnd() {
        var machine = playing(a)
        _ = machine.handle(.smartPauseChanged(true))
        _ = machine.handle(.apply(b))
        XCTAssertEqual(machine.handle(.preparationSucceeded(b)), [.promoteCandidate])
        XCTAssertEqual(machine.playbackState, .smartPaused)
        XCTAssertEqual(machine.handle(.smartPauseChanged(false)), [.playActive])
        XCTAssertEqual(machine.playbackState, .playing)
    }

    func testStopRestoresNativeWallpaperThenReleasesRenderer() {
        var machine = playing(a)
        XCTAssertEqual(machine.handle(.stop), [.removeDesktopContent, .disposeActive])
        XCTAssertEqual(machine.playbackState, .stopped)
        XCTAssertNil(machine.snapshot.activeWallpaperID)
        XCTAssertEqual(machine.snapshot.lastActiveWallpaperID, a)
        XCTAssertEqual(machine.handle(.stop), [])
        XCTAssertEqual(machine.handle(.pause), [], "Pause is meaningless while stopped")
        XCTAssertEqual(machine.handle(.resume), [])
        XCTAssertEqual(machine.handle(.smartPauseChanged(true)), [])
        XCTAssertEqual(machine.playbackState, .stopped)
    }

    func testReenableUsesLastActiveWallpaperAndPlays() {
        var machine = playing(a)
        _ = machine.handle(.pause)
        _ = machine.handle(.stop)
        XCTAssertEqual(machine.handle(.reenable), [.prepareCandidate(a)])
        XCTAssertEqual(machine.playbackState, .preparing)
        XCTAssertEqual(machine.handle(.reenable), [])
        XCTAssertEqual(machine.handle(.preparationSucceeded(a)), [.promoteCandidate, .playActive],
                       "Stop is not Pause: re-enable plays")
        XCTAssertEqual(machine.playbackState, .playing)
    }

    func testFailedReenableStaysStopped() {
        var machine = playing(a)
        _ = machine.handle(.stop)
        _ = machine.handle(.reenable)
        XCTAssertEqual(machine.handle(.preparationFailed(a)), [.reportFailure(a), .discardCandidate])
        XCTAssertEqual(machine.playbackState, .stopped)
        XCTAssertEqual(machine.snapshot.lastActiveWallpaperID, a)
    }

    func testApplyWhileStoppedReenablesWithNewWallpaper() {
        var machine = playing(a)
        _ = machine.handle(.pause)
        _ = machine.handle(.stop)
        XCTAssertEqual(machine.handle(.apply(b)), [.prepareCandidate(b)])
        XCTAssertEqual(machine.handle(.preparationSucceeded(b)), [.promoteCandidate, .playActive])
        XCTAssertEqual(machine.playbackState, .playing)
        XCTAssertEqual(machine.snapshot.lastActiveWallpaperID, b)
    }

    func testStopDuringSwitchDiscardsCandidateAndActive() {
        var machine = playing(a)
        _ = machine.handle(.apply(b))
        XCTAssertEqual(machine.handle(.stop), [.discardCandidate, .removeDesktopContent, .disposeActive])
        XCTAssertEqual(machine.playbackState, .stopped)
        XCTAssertEqual(machine.snapshot.lastActiveWallpaperID, a)
        XCTAssertEqual(machine.handle(.preparationSucceeded(b)), [], "Late result after stop is ignored")
        XCTAssertEqual(machine.playbackState, .stopped)
    }

    func testStopDuringFirstPreparationReturnsToNoWallpaper() {
        var machine = WallpaperRuntimeMachine()
        _ = machine.handle(.apply(a))
        XCTAssertEqual(machine.handle(.stop), [.discardCandidate])
        XCTAssertEqual(machine.playbackState, .noWallpaper)
        XCTAssertEqual(machine.handle(.reenable), [])
    }

    func testLatestApplyWinsAndStaleResultsAreIgnored() {
        var machine = playing(a)
        _ = machine.handle(.apply(b))
        XCTAssertEqual(machine.handle(.apply(b)), [], "Same candidate is not prepared twice")
        XCTAssertEqual(machine.handle(.apply(a)), [], "Already active and healthy")
        XCTAssertEqual(machine.handle(.apply(c)), [.discardCandidate, .prepareCandidate(c)])
        XCTAssertEqual(machine.handle(.preparationSucceeded(b)), [])
        XCTAssertEqual(machine.handle(.preparationFailed(b)), [])
        XCTAssertEqual(machine.snapshot.activeWallpaperID, a)
        XCTAssertEqual(machine.handle(.preparationSucceeded(c)), [.promoteCandidate, .playActive])
        XCTAssertEqual(machine.snapshot.activeWallpaperID, c)
    }

    func testActiveRendererFailureKeepsContentAndCanBeReplacedOrStopped() {
        var machine = playing(a)
        XCTAssertEqual(machine.handle(.activeFailed(b)), [], "Only the active renderer can fail the runtime")
        XCTAssertEqual(machine.handle(.activeFailed(a)), [.reportFailure(a)])
        XCTAssertEqual(machine.playbackState, .failed)
        XCTAssertEqual(machine.snapshot.activeWallpaperID, a, "Static fallback stays on the desktop")
        XCTAssertEqual(machine.handle(.activeFailed(a)), [])
        XCTAssertEqual(machine.handle(.pause), [])
        XCTAssertEqual(machine.handle(.resume), [])
        XCTAssertEqual(machine.handle(.smartPauseChanged(true)), [])
        _ = machine.handle(.smartPauseChanged(false))

        XCTAssertEqual(machine.handle(.apply(a)), [.prepareCandidate(a)], "A failed wallpaper can be reloaded")
        XCTAssertEqual(machine.playbackState, .failed)
        XCTAssertEqual(machine.handle(.preparationSucceeded(a)), [.promoteCandidate, .playActive])
        XCTAssertEqual(machine.playbackState, .playing)

        _ = machine.handle(.activeFailed(a))
        XCTAssertEqual(machine.handle(.stop), [.removeDesktopContent, .disposeActive])
        XCTAssertEqual(machine.playbackState, .stopped)
    }

    func testPauseRequestedDuringFirstPreparationKeepsNewWallpaperPaused() {
        var machine = WallpaperRuntimeMachine()
        _ = machine.handle(.apply(a))
        XCTAssertEqual(machine.handle(.pause), [])
        XCTAssertEqual(machine.handle(.preparationSucceeded(a)), [.promoteCandidate])
        XCTAssertEqual(machine.playbackState, .manualPaused)
    }

    func testEveryPlaybackStateIsReachable() {
        var reached: Set<PlaybackState> = []
        var machine = WallpaperRuntimeMachine()
        reached.insert(machine.playbackState)
        let script: [WallpaperRuntimeEvent] = [
            .apply(a), .preparationSucceeded(a), .pause, .resume, .smartPauseChanged(true),
            .smartPauseChanged(false), .activeFailed(a), .stop
        ]
        for event in script {
            _ = machine.handle(event)
            reached.insert(machine.playbackState)
        }
        XCTAssertEqual(reached, Set(PlaybackState.allCases))
    }
}
