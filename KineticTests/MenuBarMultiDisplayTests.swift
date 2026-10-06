import Combine
import XCTest
@testable import Kinetic

@MainActor
final class MenuBarMultiDisplayTests: XCTestCase {
    private let a = DisplayID("A"), b = DisplayID("B")
    private func display(_ id: DisplayID, _ state: PlaybackState, wallpaper: Wallpaper.ID? = UUID()) -> DisplayRuntimeState {
        .init(displayID: id, displayName: id.rawValue, runtime: .init(playbackState: state,
            activeWallpaperID: state == .stopped ? nil : wallpaper,
            lastActiveWallpaperID: state == .stopped ? wallpaper : nil))
    }

    func testSecondaryDisplayControlsAccentAndGlobalActionRegardlessOfPrimaryOrder() {
        let screens = [display(a, .stopped), display(b, .playing)]
        for order in [screens, screens.reversed().map { $0 }] {
            let state = MenuBarPlaybackPresentation(summary: .init(displays: order), isInLibrary: { _ in true })
            XCTAssertTrue(state.iconUsesAccent)
            XCTAssertEqual(state.primaryAction, .pause)
            XCTAssertTrue(state.canStop)
            XCTAssertEqual(state.summaryText, "1 个显示器正在播放 · 1 个显示器已停止")
        }
    }

    func testMixedSmartAndManualPauseResumesOnlyManualIntentAndLogoRemainsAccented() {
        let state = MenuBarPlaybackPresentation(summary: .init(displays: [display(a, .manualPaused), display(b, .smartPaused)]),
                                                isInLibrary: { _ in true })
        XCTAssertTrue(state.iconUsesAccent)
        XCTAssertEqual(state.primaryAction, .resume)
        let smart = MenuBarPlaybackPresentation(summary: .init(displays: [display(a, .smartPaused), display(b, .smartPaused)]),
                                                isInLibrary: { _ in true })
        XCTAssertTrue(smart.iconUsesAccent)
        XCTAssertNil(smart.primaryAction, "System conditions cannot be bypassed by the menu")
        let manual = MenuBarPlaybackPresentation(summary: .init(displays: [display(a, .manualPaused), display(b, .manualPaused)]),
                                                 isInLibrary: { _ in true })
        XCTAssertFalse(manual.iconUsesAccent)
        XCTAssertEqual(manual.primaryAction, .resume)
    }

    func testStoppedDeletedRecordsDoNotOfferReenableAndAllStatesHaveChineseSummary() {
        let dead = MenuBarPlaybackPresentation(summary: .init(displays: [display(a, .stopped), display(b, .stopped)]),
                                               isInLibrary: { _ in false })
        XCTAssertNil(dead.primaryAction); XCTAssertFalse(dead.hasWallpaperContext)
        for state in PlaybackState.allCases {
            let result = MenuBarPlaybackPresentation(summary: .init(displays: [display(a, state), display(b, state)]),
                                                     isInLibrary: { _ in true })
            XCTAssertTrue(result.summaryText.hasPrefix("2 个显示器"), result.summaryText)
            XCTAssertFalse(result.summaryText.contains("menu.displays."))
        }
    }

    func testGlobalPauseResumeStopReenableAndAudioUseAllDisplaysWithoutRevivingDeletedRecord() async {
        let first = Wallpaper(name: "A", type: .video, source: .local, resourceURL: URL(fileURLWithPath: "/test/a.mp4"))
        let second = Wallpaper(name: "B", type: .video, source: .local, resourceURL: URL(fileURLWithPath: "/test/b.mp4"))
        var renderers: [AppControlTestRenderer] = []
        let runtime = WallpaperRuntimeManager { let renderer = AppControlTestRenderer($0); renderers.append(renderer); return renderer }
        defer { runtime.shutdown() }
        runtime.addDisplay(a, host: AppControlTestHost()); runtime.addDisplay(b, host: AppControlTestHost())
        runtime.apply(first, to: a); runtime.apply(second, to: b); await settle()
        MenuBarPlaybackPresentation.perform(.pause, on: runtime, isInLibrary: { _ in true })
        XCTAssertEqual(runtime.state(of: a)?.playbackState, .manualPaused)
        XCTAssertEqual(runtime.state(of: b)?.playbackState, .manualPaused)
        runtime.setSmartPauseActive(true)
        MenuBarPlaybackPresentation.perform(.resume, on: runtime, isInLibrary: { _ in true })
        XCTAssertEqual(runtime.state(of: a)?.playbackState, .smartPaused)
        XCTAssertEqual(runtime.state(of: b)?.playbackState, .smartPaused)
        runtime.setSmartPauseActive(false)
        XCTAssertEqual(runtime.state(of: a)?.playbackState, .playing)
        XCTAssertEqual(runtime.state(of: b)?.playbackState, .playing)
        runtime.setAudioEnabled(true)
        XCTAssertTrue(renderers.allSatisfy { !$0.muted })
        runtime.stop(.allDisplays)
        XCTAssertEqual(runtime.state(of: a)?.playbackState, .stopped)
        XCTAssertEqual(runtime.state(of: b)?.playbackState, .stopped)
        MenuBarPlaybackPresentation.perform(.reenable, on: runtime, isInLibrary: { $0 == second.id })
        await settle()
        XCTAssertEqual(runtime.state(of: a)?.playbackState, .stopped)
        XCTAssertEqual(runtime.activeWallpaper(on: b)?.id, second.id)
        XCTAssertEqual(renderers.count, 3, "The deleted record never prepares a renderer")
        XCTAssertFalse(renderers.last!.muted, "A re-enabled session inherits the global audio switch")
        if case .reenable? = runtime.globalUserCommand {} else { XCTFail("Offline assignments must also receive the global user command") }
    }

    func testReenableHandlesNoDisplaysAndPreparesNothingForMissingLibraryRecords() {
        let runtime = WallpaperRuntimeManager { _ in XCTFail("Must not create renderer"); throw WallpaperRuntimeError.unsupportedType }
        MenuBarPlaybackPresentation.perform(.reenable, on: runtime, isInLibrary: { _ in false })
        let empty = MenuBarPlaybackPresentation(summary: runtime.summary, isInLibrary: { _ in false })
        XCTAssertNil(empty.primaryAction)
        XCTAssertFalse(empty.iconUsesAccent)
    }

    func testSteamNavigationSurvivesUntilMainWindowConsumesIt() {
        let navigation = MainWindowNavigation()
        navigation.request(.steam)
        var received: ShellSection?
        let subscription = navigation.requests.compactMap { $0 }.sink { received = $0 }
        XCTAssertEqual(received, .steam)
        navigation.consume()
        XCTAssertNil(navigation.requestedSection)
        subscription.cancel()
        XCTAssertEqual(FloatingToolbarAddItem.allCases.map(\.titleKey),
                       ["shell.toolbar.importMac", "shell.toolbar.importWeb", "shell.toolbar.openSteam"])
    }

    func testOpenMainWindowConsumesNavigationWithoutReplayingItWhenReopened() {
        let navigation = MainWindowNavigation()
        var received: [ShellSection] = []
        let subscription = navigation.requests.compactMap { $0 }.sink {
            received.append($0)
            navigation.consume()
        }
        navigation.request(.steam)
        navigation.request(.steam)
        XCTAssertEqual(received, [.steam, .steam])
        XCTAssertNil(navigation.requestedSection)
        subscription.cancel()
        let reopened = navigation.requests.compactMap { $0 }.sink { _ in XCTFail("Consumed navigation must not replay") }
        reopened.cancel()
    }

    private func settle() async { for _ in 0..<60 { await Task.yield() } }
}
