import AppKit
import XCTest
@testable import Kinetic

/// Workshop 两指滑动（用户 2026-10-08，参考 Safari）：停留过的页的历史，以及跟手的滑出手势。
@MainActor
final class WorkshopSwipeNavigationTests: XCTestCase {
    private func makeStore() -> SteamStoreService {
        SteamStoreService(keyStore: MemorySteamAPIKeyStore(String(repeating: "a", count: 32)), cacheDirectory: nil,
            fetch: { url in
                let params = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
                let page = Int(params.first { $0.name == "page" }!.value!)!
                let search = params.first { $0.name == "search_text" }?.value ?? ""
                let data = try JSONSerialization.data(withJSONObject: ["response": ["total": 40000,
                    "publishedfiledetails": [["publishedfileid": "\(search)\(page)", "title": "Page \(page)", "result": 1]]]])
                return (data, 200)
            })
    }
    private func loaded(_ store: SteamStoreService) async throws {
        for _ in 0..<100 {
            if store.phase == .loaded { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Page did not finish loading: \(store.phase)")
    }

    func testBackAndForwardFollowTheVisitedPagesLikeSafari() async throws {
        let store = makeStore()
        store.update(numberedPages: true); try await loaded(store)
        XCTAssertFalse(store.canGoBack, "entering the page is not a visit to go back to")
        store.goToPage(3); try await loaded(store)
        store.goToPage(100); try await loaded(store)
        store.goToPage(7); try await loaded(store)
        XCTAssertFalse(store.canGoForward, "nothing after the newest page")
        store.goBack(); try await loaded(store)
        XCTAssertEqual(store.query.numberedPage, 100); XCTAssertEqual(store.items.map(\.workshopID), ["100"])
        store.goBack(); try await loaded(store)
        XCTAssertEqual(store.query.numberedPage, 3)
        store.goForward(); try await loaded(store)
        XCTAssertEqual(store.query.numberedPage, 100)
        store.goForward(); try await loaded(store)
        XCTAssertEqual(store.query.numberedPage, 7); XCTAssertFalse(store.canGoForward)
        // A new page after going back drops the pages that were ahead (Safari).
        store.goBack(); try await loaded(store)
        store.goToPage(20); try await loaded(store)
        XCTAssertFalse(store.canGoForward)
        XCTAssertEqual(store.backHistory.map(\.numberedPage), [1, 3, 100])
        // Going back past the start does nothing.
        for _ in 0..<5 { store.goBack(); try await loaded(store) }
        XCTAssertEqual(store.query.numberedPage, 1); XCTAssertFalse(store.canGoBack)
    }

    func testSearchConditionsAreRestoredButSettingsStayCurrent() async throws {
        let store = makeStore()
        store.update(numberedPages: true); try await loaded(store)
        store.goToPage(4); try await loaded(store)
        var filters = SteamFilterState(); filters.toggleType("Scene")
        store.update(searchText: "ocean", filters: filters); try await loaded(store)
        store.setResultsPerPage(50); try await loaded(store)
        store.goToPage(2); try await loaded(store)
        store.setHiddenAgeRatings(["Mature"]); try await loaded(store)
        XCTAssertEqual(store.backHistory.count, 4, "page 4, the search, the page size, then page 2; the age setting is not a visit")
        store.goBack(); try await loaded(store)
        XCTAssertEqual(store.query.numberedPage, 1); XCTAssertEqual(store.query.resultsPerPage, 50)
        store.goBack(); try await loaded(store)
        XCTAssertEqual(store.query.resultsPerPage, 30); XCTAssertEqual(store.query.trimmedSearch, "ocean")
        XCTAssertEqual(store.query.filters, filters)
        store.goBack(); try await loaded(store)
        XCTAssertEqual(store.query.numberedPage, 4); XCTAssertEqual(store.query.trimmedSearch, "")
        XCTAssertEqual(store.query.filters, SteamFilterState())
        XCTAssertEqual(store.query.hiddenAgeRatings, ["Mature"], "settings are not rolled back by history")
        XCTAssertEqual(store.items.map(\.workshopID), ["4"])
    }

    func testHistoryIsBounded() async throws {
        let store = makeStore()
        store.update(numberedPages: true); try await loaded(store)
        for page in 2...(SteamStoreService.maximumHistory + 20) { store.goToPage(page) }
        XCTAssertEqual(store.backHistory.count, SteamStoreService.maximumHistory)
    }

    // MARK: Gesture

    private func navigator(back: Bool, forward: Bool) -> WorkshopSwipeNavigator {
        let navigator = WorkshopSwipeNavigator()
        navigator.canGo = { $0 == .back ? back : forward }
        navigator.reduceMotion = true
        return navigator
    }
    @discardableResult
    private func swipe(_ navigator: WorkshopSwipeNavigator, _ deltas: [CGVector], end: Bool = true, width: CGFloat = 1000) -> [Bool] {
        var consumed: [Bool] = []
        var time: TimeInterval = 100
        for (index, delta) in deltas.enumerated() {
            time += 0.016
            consumed.append(navigator.handle(phase: index == 0 ? .began : .changed, momentumPhase: [], fingerDelta: delta,
                                             time: time, width: width))
        }
        if end { consumed.append(navigator.handle(phase: .ended, momentumPhase: [], fingerDelta: .zero, time: time + 0.2, width: width)) }
        return consumed
    }

    func testThePageFollowsTheFingersAndSlidesOutPastTheThreshold() {
        let navigator = navigator(back: true, forward: false)
        let consumed = swipe(navigator, [CGVector(dx: 6, dy: 1), CGVector(dx: 40, dy: 3), CGVector(dx: 25.5, dy: -2)], end: false)
        XCTAssertEqual(consumed, [true, true, true], "the scroll view does not also scroll")
        XCTAssertEqual(navigator.offset, 71.5, accuracy: 1e-9, "1:1 with the fingers, to the right")
        swipe(navigator, [], end: false)
        _ = navigator.handle(phase: .changed, momentumPhase: [], fingerDelta: CGVector(dx: 300, dy: 0), time: 101, width: 1000)
        XCTAssertNil(navigator.request)
        _ = navigator.handle(phase: .ended, momentumPhase: [], fingerDelta: .zero, time: 101.5, width: 1000)
        XCTAssertEqual(navigator.request?.direction, .back, "fingers to the right go back (Safari)")
        XCTAssertEqual(navigator.offset, 1000, "slid out of the window")
        XCTAssertTrue(navigator.isCovered)
        // The momentum after lifting the fingers belongs to the swipe.
        XCTAssertTrue(navigator.handle(phase: [], momentumPhase: .began, fingerDelta: CGVector(dx: 20, dy: 0), time: 102, width: 1000))
        XCTAssertTrue(navigator.handle(phase: [], momentumPhase: .ended, fingerDelta: .zero, time: 102.1, width: 1000))
        XCTAssertFalse(navigator.handle(phase: [], momentumPhase: .changed, fingerDelta: CGVector(dx: 0, dy: 5), time: 103, width: 1000))
        navigator.didNavigate()
        XCTAssertEqual(navigator.offset, 0); XCTAssertFalse(navigator.isCovered); XCTAssertNil(navigator.request)
    }

    func testForwardIsTheOtherWayAndShortSwipesSnapBack() {
        let navigator = navigator(back: true, forward: true)
        swipe(navigator, [CGVector(dx: -8, dy: 0), CGVector(dx: -150, dy: 0)])
        XCTAssertNil(navigator.request, "a short, slow swipe returns")
        XCTAssertEqual(navigator.offset, 0)
        swipe(navigator, [CGVector(dx: -8, dy: 0), CGVector(dx: -400, dy: 0)])
        XCTAssertEqual(navigator.request?.direction, .forward, "fingers to the left go forward")
        XCTAssertEqual(navigator.offset, -1000)
    }

    func testNoPageThatWayMeansNoMovementAtAll() {
        let navigator = navigator(back: false, forward: false)
        let consumed = swipe(navigator, [CGVector(dx: 10, dy: 0), CGVector(dx: 300, dy: 0)])
        XCTAssertEqual(consumed, [false, false, false], "events go on to the scroll view untouched")
        XCTAssertEqual(navigator.offset, 0); XCTAssertNil(navigator.request)
        // Only forward exists: a swipe to the right cannot move, a swipe to the left can, and it stops at zero on the way back.
        let onlyForward = self.navigator(back: false, forward: true)
        swipe(onlyForward, [CGVector(dx: 10, dy: 0), CGVector(dx: 200, dy: 0)])
        XCTAssertEqual(onlyForward.offset, 0); XCTAssertNil(onlyForward.request)
        swipe(onlyForward, [CGVector(dx: -10, dy: 0), CGVector(dx: -100, dy: 0), CGVector(dx: 500, dy: 0)], end: false)
        XCTAssertEqual(onlyForward.offset, 0, "cannot be pulled past its place towards a missing page")
    }

    func testVerticalScrollingIsLeftAlone() {
        let navigator = navigator(back: true, forward: true)
        let consumed = swipe(navigator, [CGVector(dx: 2, dy: 10), CGVector(dx: 30, dy: 60), CGVector(dx: 300, dy: 10)])
        XCTAssertEqual(consumed, [false, false, false, false])
        XCTAssertEqual(navigator.offset, 0); XCTAssertNil(navigator.request)
    }

    func testAQuickFlickCompletesAShortSwipe() {
        let navigator = navigator(back: true, forward: true)
        var time: TimeInterval = 10
        _ = navigator.handle(phase: .began, momentumPhase: [], fingerDelta: CGVector(dx: 10, dy: 0), time: time, width: 1000)
        for _ in 0..<4 {
            time += 0.008
            _ = navigator.handle(phase: .changed, momentumPhase: [], fingerDelta: CGVector(dx: 30, dy: 0), time: time, width: 1000)
        }
        XCTAssertLessThan(navigator.offset, 250)
        _ = navigator.handle(phase: .ended, momentumPhase: [], fingerDelta: .zero, time: time, width: 1000)
        XCTAssertEqual(navigator.request?.direction, .back)
    }
}
