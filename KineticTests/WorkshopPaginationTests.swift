import Foundation
import XCTest
@testable import Kinetic

final class WorkshopPaginationTests: XCTestCase {
    func testPageEntriesAreOnlyEndpointsAndTwoNeighboursWithoutDuplicates() {
        XCTAssertEqual(WorkshopPageEntry.entries(current: 5), [.page(1), .gap(after: 1), .page(3), .page(4), .page(5), .page(6), .page(7), .gap(after: 7), .page(500)])
        for current in 1...500 {
            let entries = WorkshopPageEntry.entries(current: current)
            let numbers = entries.compactMap { if case .page(let n) = $0 { return n }; return nil }
            XCTAssertEqual(numbers.first, 1); XCTAssertEqual(numbers.last, 500)
            XCTAssertEqual(Set(numbers).count, numbers.count)
            XCTAssertTrue(numbers.contains(current)); XCTAssertTrue(numbers.allSatisfy { $0 == 1 || $0 == 500 || abs($0 - current) <= 2 })
        }
    }
    func testEveryNumberedPageAndPageSizeUsesServerPageWithoutACursorAndDistinctCacheKey() throws {
        var keys = Set<String>()
        for size in [15, 20, 30, 50, 65] {
            for page in [1, 3, 5, 90, 499, 500] {
                var query = SteamStoreQuery(); query.numberedPage = page; query.resultsPerPage = size
                query.searchText = "SpongeBob"; query.sortMode = .mostPopular
                let params = try XCTUnwrap(URLComponents(url: query.url(key: "fake-test-key", cursor: "*"), resolvingAgainstBaseURL: false)?.queryItems)
                XCTAssertNil(params.first { $0.name == "cursor" })
                XCTAssertEqual(params.first { $0.name == "page" }?.value, String(page))
                XCTAssertEqual(params.first { $0.name == "numperpage" }?.value, String(size))
                XCTAssertEqual(params.first { $0.name == "query_type" }?.value, "3")
                XCTAssertEqual(params.first { $0.name == "search_text" }?.value, "SpongeBob")
                XCTAssertTrue(keys.insert(query.cacheKey).inserted)
            }
        }
    }
    @MainActor func testDirectJumpReplacesItemsKeepsServerRankAndNeverLoadsAutomatically() async throws {
        var pages: [Int] = []
        let store = SteamStoreService(keyStore: MemorySteamAPIKeyStore(String(repeating: "a", count: 32)), cacheDirectory: nil,
            fetch: { url in
                let params = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
                let page = Int(params.first { $0.name == "page" }!.value!)!
                pages.append(page)
                let data = try JSONSerialization.data(withJSONObject: ["response": ["total": 40000, "next_cursor": "next",
                    "publishedfiledetails": [["publishedfileid": String(page), "title": "Page \(page)", "result": 1, "tags": [["tag": "Scene"]]]]]])
                return (data, 200)
            })
        store.update(numberedPages: true); try await loaded(store)
        XCTAssertEqual(store.items.map(\.workshopID), ["1"])
        store.goToPage(500); try await loaded(store)
        XCTAssertEqual(store.items.map(\.workshopID), ["500"])
        XCTAssertEqual(store.items.first?.serverRankIndex, 499 * 30)
        store.loadMore(); try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(pages, [1, 500]); XCTAssertFalse(store.canLoadMore)
        store.setResultsPerPage(65); try await loaded(store)
        XCTAssertEqual(store.query.numberedPage, 1); XCTAssertEqual(store.query.resultsPerPage, 65)
        store.goToPage(5); try await loaded(store)
        store.update(searchText: "new search"); try await loaded(store)
        XCTAssertEqual(store.query.numberedPage, 1)
        store.setResultsPerPage(66); XCTAssertEqual(store.query.resultsPerPage, 65)
    }
    @MainActor func testLateHighPageCannotReplaceNewPageOrUseAnotherPagesCache() async throws {
        let store = SteamStoreService(keyStore: MemorySteamAPIKeyStore(String(repeating: "a", count: 32)), cacheDirectory: nil,
            fetch: { url in
                let params = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
                let page = Int(params.first { $0.name == "page" }!.value!)!
                if page == 500 { try await Task.sleep(nanoseconds: 180_000_000) }
                return (try JSONSerialization.data(withJSONObject: ["response": ["total": 40000,
                    "publishedfiledetails": [["publishedfileid": String(page), "title": String(page), "result": 1]]]]), 200)
            })
        store.update(numberedPages: true); try await loaded(store)
        store.goToPage(500); store.goToPage(4); try await loaded(store)
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(store.query.numberedPage, 4); XCTAssertEqual(store.items.map(\.workshopID), ["4"])
        store.goToPage(1); try await loaded(store)
        XCTAssertEqual(store.items.map(\.workshopID), ["1"])
        store.goToPage(4); try await loaded(store)
        XCTAssertEqual(store.items.map(\.workshopID), ["4"])
    }
    func testDefaultsDoNotRewriteAnExistingUserChoice() throws {
        let state = SettingsState(); XCTAssertTrue(state.steamHideQuestionable); XCTAssertTrue(state.steamHideMature)
        let old = try JSONDecoder().decode(SettingsState.self, from: Data(#"{"steamHideQuestionable":false,"steamHideMature":false}"#.utf8))
        XCTAssertFalse(old.steamHideQuestionable); XCTAssertFalse(old.steamHideMature)
    }
    @MainActor private func loaded(_ store: SteamStoreService) async throws {
        for _ in 0..<100 {
            if store.phase == .loaded { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Page did not finish loading: \(store.phase)")
    }
}
