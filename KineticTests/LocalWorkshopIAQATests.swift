import AppKit
import XCTest
@testable import Kinetic

/// Module 61: run the complete Local / Workshop journey against isolated storage.
@MainActor
final class LocalWorkshopIAQATests: XCTestCase {
    private final class Online {
        var requests: [URL] = []
        func fetch(_ url: URL) throws -> (Data, Int) {
            requests.append(url)
            let detail: [String: Any] = ["publishedfileid": "610", "result": 1, "title": "海浪 Workshop B",
                                        "tags": [["tag": "Web"], ["tag": "Everyone"]]]
            return (try JSONSerialization.data(withJSONObject: ["response": [
                "total": 10000, "publishedfiledetails": [detail], "next_cursor": "*"]]), 200)
        }
    }
    private func browser(_ h: WallpaperFlowQAHarness, _ online: Online) -> SteamStoreService {
        SteamStoreService(keyStore: MemorySteamAPIKeyStore(String(repeating: "0", count: 32)),
            cacheDirectory: h.root.appendingPathComponent("StoreCache"), posters: SteamPosterCache(directory: nil),
            fetch: { try online.fetch($0) })
    }
    private func importedVideo(_ h: WallpaperFlowQAHarness) async throws -> Wallpaper {
        let fixture = try XCTUnwrap(Bundle.main.url(forResource: "loop", withExtension: "mp4", subdirectory: "Fixtures"))
        let source = h.root.appendingPathComponent("海浪 Finder A.mp4")
        let bytes = try Data(contentsOf: fixture); try bytes.write(to: source)
        let provider = try XCTUnwrap(NSItemProvider(contentsOf: source))
        let urls = await FinderDropDelegate.loadFileURLs(from: [provider])
        XCTAssertEqual(urls, [source])
        let outcomes = await LocalImportService(library: h.library).importItems(at: urls)
        let outcome = try XCTUnwrap(outcomes.first), wallpaper = try outcome.result.get()
        XCTAssertTrue(outcome.sourceUnchanged)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertNotEqual(wallpaper.resourceURL, source)
        XCTAssertTrue(wallpaper.resourceURL.path.hasPrefix(h.library.storage.rootURL.path + "/"))
        XCTAssertEqual(wallpaper.acquisitionOrigin, .localImport)
        return wallpaper
    }

    func testFinderAndOrdinaryWorkshopDownloadBecomeLocalWithoutChangingAnyDisplay() async throws {
        let h = try WallpaperFlowQAHarness(count: 2); defer { h.cleanup() }
        try await h.start()
        let a = try await importedVideo(h), online = Online(), store = browser(h, online)
        let beforeBrowse = try Data(contentsOf: h.library.storage.libraryFileURL)
        store.update(searchText: "海浪", numberedPages: true); store.reload()
        try await waitForSteam { store.phase == .loaded }
        let b = try XCTUnwrap(store.items.first)
        XCTAssertFalse(online.requests.isEmpty)
        XCTAssertNil(h.library.wallpaper(workshopID: b.id), "Browsing B must not create a local record")
        XCTAssertEqual(SteamStoreCardState.resolve(item: b, record: nil, task: nil), .remote)
        XCTAssertEqual(try Data(contentsOf: h.library.storage.libraryFileURL), beforeBrowse)
        XCTAssertTrue(h.library.wallpapers(in: .local).contains { $0.id == a.id })

        let downloaded = try await h.download(b.id)
        XCTAssertTrue(h.library.wallpapers(in: .local).contains { $0.id == downloaded.id })
        XCTAssertEqual(downloaded.acquisitionOrigin, .steamWorkshop)
        XCTAssertEqual(store.items.map(\.id), [b.id], "The online card must remain in its original place")
        XCTAssertEqual(SteamStoreCardState.resolve(item: b, record: downloaded, task: h.steam.tasks[b.id]),
                       .inLibrary(downloaded.id))
        for id in h.ids { XCTAssertEqual(h.runtime.activeWallpaper(on: id)?.id, h.initial[id]?.id) }
        let restored = WallpaperLibrary(storage: h.library.storage)
        XCTAssertNotNil(restored.wallpaper(id: a.id)); XCTAssertNotNil(restored.wallpaper(workshopID: b.id))
        XCTAssertEqual(restored.wallpapers(in: .local).count, h.library.wallpapers(in: .local).count)
        let result = await h.steam.acquire(b.acquisitionInfo)
        XCTAssertEqual(result.failure, .alreadyInLibrary(downloaded.id))
        XCTAssertEqual(h.fake.processes.count, 1)
        XCTAssertEqual(h.library.wallpapers.filter { $0.steamMetadata?.workshopID == b.id }.count, 1)
    }

    func testLocalSearchStaysOfflineAndOnlineSearchPagingDoesNotMutateLocalMembership() async throws {
        let h = try WallpaperFlowQAHarness(count: 1); defer { h.cleanup() }
        try await h.start()
        let a = try await importedVideo(h), online = Online(), store = browser(h, online)
        store.update(searchText: "海浪", numberedPages: true); store.reload()
        try await waitForSteam { store.phase == .loaded }
        let requestsBefore = online.requests.count
        for query in ["海浪", "Finder", "不存在", "", "视频"] { _ = h.library.search(query) }
        XCTAssertEqual(h.library.search("Finder").map(\.id), [a.id])
        XCTAssertEqual(online.requests.count, requestsBefore)
        XCTAssertTrue(h.fake.processes.isEmpty)
        let localBytes = try Data(contentsOf: h.library.storage.libraryFileURL)
        store.update(searchText: "another keyword", numberedPages: true)
        try await waitForSteam { store.phase == .loaded && online.requests.count > requestsBefore }
        let afterSearch = online.requests.count
        store.goToPage(500)
        try await waitForSteam { store.phase == .loaded && online.requests.count > afterSearch }
        XCTAssertTrue(online.requests.contains { url in
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains {
                $0.name == "page" && $0.value == "500"
            } == true
        })
        XCTAssertEqual(try Data(contentsOf: h.library.storage.libraryFileURL), localBytes)
        XCTAssertNil(h.library.wallpaper(workshopID: "610"))
        XCTAssertEqual(Set(ShellSection.allCases), Set([.search, .local, .steam, .favorites]))
        XCTAssertEqual(ShellSection(storedValue: "all"), .local, "Legacy All must migrate into Local")
        XCTAssertNil(ShellSection.steam.filter)
    }

    func testOnlineDownloadAndApplyToSecondDisplayCreatesLocalRecordAndOnlyChangesSecondDisplay() async throws {
        let h = try WallpaperFlowQAHarness(count: 2); defer { h.cleanup() }
        try await h.start()
        _ = try await importedVideo(h)
        let online = Online(), store = browser(h, online)
        store.reload(); try await waitForSteam { store.phase == .loaded }
        let b = try XCTUnwrap(store.items.first)
        XCTAssertNil(h.library.wallpaper(workshopID: b.id))
        h.coordinator.request(b.acquisitionInfo, to: h.ids[1])
        try await h.waitForDownload(b.id)
        for id in h.ids { XCTAssertEqual(h.runtime.activeWallpaper(on: id)?.id, h.initial[id]?.id) }
        try h.finishDownload(b.id)
        try await waitForSteam { h.library.wallpaper(workshopID: b.id) != nil }
        let downloaded = try XCTUnwrap(h.library.wallpaper(workshopID: b.id))
        try await h.checkOnlyTargetChanged(to: downloaded, on: h.ids[1])
        XCTAssertEqual(h.notices.map(\.outcome), [.downloadedAndApplied])
        XCTAssertEqual(store.items.map(\.id), [b.id])
        XCTAssertEqual(h.library.search("Workshop B").map(\.id), [downloaded.id])
        XCTAssertEqual(h.fake.processes.count, 1)
    }

    func testInvalidDownloadDoesNotCreateLocalRecordOrChangeDisplays() async throws {
        let h = try WallpaperFlowQAHarness(count: 2); defer { h.cleanup() }
        try await h.start()
        let online = Online(), store = browser(h, online)
        store.reload(); try await waitForSteam { store.phase == .loaded }
        let b = try XCTUnwrap(store.items.first)
        let originalIDs = h.library.wallpapers.map(\.id)
        h.coordinator.request(b.acquisitionInfo, to: h.ids[1])
        try await h.waitForDownload(b.id); try h.finishDownload(b.id, valid: false)
        try await waitForSteam { !h.notices.isEmpty }
        XCTAssertEqual(h.notices.map(\.outcome), [.downloadFailed])
        XCTAssertEqual(h.library.wallpapers.map(\.id), originalIDs)
        XCTAssertNil(h.library.wallpaper(workshopID: b.id))
        XCTAssertEqual(store.items.map(\.id), [b.id])
        for id in h.ids { XCTAssertEqual(h.runtime.activeWallpaper(on: id)?.id, h.initial[id]?.id) }
        if case .failed = SteamStoreCardState.resolve(item: b, record: nil, task: h.steam.tasks[b.id]) {} else {
            XCTFail("The remote card must expose the failed acquisition, not claim it is local")
        }
    }
}

private extension Result where Failure == SteamAcquisitionError {
    var failure: SteamAcquisitionError? { if case .failure(let error) = self { return error }; return nil }
}
