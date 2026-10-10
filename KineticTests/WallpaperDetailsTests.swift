import AppKit
import SwiftUI
import XCTest
@testable import Kinetic

/// R4 第 45、50–51 节：标签目录、BBCode 描述、详情数据与独立详情窗口。
@MainActor
final class WallpaperDetailsTests: XCTestCase {
    private let key = "0123456789ABCDEF0123456789ABCDEF"
    private var roots: [URL] = []

    override func tearDown() {
        WallpaperDetailsWindows.shared.closeAll()
        for root in roots { try? FileManager.default.removeItem(at: root) }
        super.tearDown()
    }

    // MARK: - 标签目录

    func testTheCatalogHasAllNineGroupsAndNinetyFourCandidates() {
        XCTAssertEqual(SteamTagGroup.allCases.count, 9)
        XCTAssertEqual(SteamTagGroup.allCases.map { $0.tags.count }, [4, 10, 3, 25, 20, 3, 11, 10, 8])
        XCTAssertEqual(SteamTagCatalog.allTags.count, 94)
        XCTAssertEqual(Set(SteamTagCatalog.allTags.map { $0.value.lowercased() }).count, 94, "No duplicates")
        XCTAssertEqual(SteamTagGroup.genre.tags.first?.value, "Abstract")
        XCTAssertEqual(SteamTagGroup.genre.tags.last?.value, "Unspecified", "Both genre screenshots merged")
        XCTAssertEqual(SteamTagGroup.type.tags.map(\.value), ["Scene", "Web", "Video", "Application"])
        XCTAssertEqual(SteamTagGroup.allCases.filter(\.isExpandedByDefault), [.miscellaneous, .genre])
        XCTAssertEqual(SteamTagCatalog.group(of: "audio responsive"), .miscellaneous)
        XCTAssertEqual(SteamTagCatalog.group(of: "Preset"), .category)
        XCTAssertEqual(SteamTagCatalog.group(of: "1920 x 1080"), .resolution, "Real resolution tags outside the screenshots")
        XCTAssertEqual(SteamTagCatalog.label(for: "1920 x 1080"), "1920 × 1080")
        XCTAssertEqual(SteamTagCatalog.label(for: "Pixel art"), "像素艺术")
        XCTAssertNil(SteamTagCatalog.group(of: "Some author tag"))
        let grouped = SteamTagCatalog.grouped(["Scene", "Everyone", "Anime", "Game", "3840 x 2160", "Approved", "HDR"])
        XCTAssertEqual(grouped[.genre], ["动漫", "游戏"], "Several tags of one group stay side by side")
        XCTAssertEqual(grouped[.miscellaneous], ["已审核", "HDR"])
        XCTAssertNil(grouped[.assetType])
    }

    // MARK: - 描述

    func testBBCodeKeepsTheAuthorsTextAndOnlyRendersSafeFormatting() {
        let source = """
        [h1]Neon City[/h1]
        Line one
        [b]Bold[/b] and [i]italic[/i] [u]u[/u] [strike]gone[/strike]
        [list][*]First[*]Second[/list]
        [olist][*]One[*]Two[/olist]
        [url=https://example.com/page]Site[/url] [url=javascript:alert(1)]Bad[/url] [url]https://example.org[/url]
        [img]https://example.com/a.png[/img] [noparse][b]raw[/b][/noparse] [不是标签] 日本語テキスト
        """
        let text = SteamDescriptionText.attributed(source)
        let plain = String(text.characters)
        XCTAssertTrue(plain.hasPrefix("Neon City\nLine one\nBold and italic u gone"), plain)
        XCTAssertTrue(plain.contains("• First\n• Second"), plain)
        XCTAssertTrue(plain.contains("1. One\n2. Two"), plain)
        XCTAssertTrue(plain.contains("[b]raw[/b]"), "noparse keeps the text")
        XCTAssertTrue(plain.contains("[不是标签]"), "Brackets that are not BBCode stay")
        XCTAssertTrue(plain.contains("日本語テキスト"), "Never translated")
        XCTAssertFalse(plain.contains("https://example.com/a.png"), "Images are not loaded or shown as raw URLs")
        let links = text.runs.compactMap(\.link)
        XCTAssertTrue(links.contains(URL(string: "https://example.com/page")!))
        XCTAssertTrue(links.contains(URL(string: "https://example.org")!))
        XCTAssertTrue(links.contains(URL(string: "https://example.com/a.png")!), "The image becomes a plain link")
        XCTAssertFalse(links.contains { $0.scheme == "javascript" }, "Only http(s) links")
        XCTAssertTrue(plain.contains("Bad"), "The text of an unsafe link stays")
        XCTAssertEqual(SteamDescriptionText.safeURL("file:///etc/passwd"), nil)
    }

    // MARK: - 数据

    private final class FakeSteam {
        var requests: [URL] = []
        var description: String? = "[b]Hello[/b]\n第二段"
        var fail = false
        var removed = false
        func fetch(_ url: URL) async throws -> (Data, Int) {
            requests.append(url)
            if fail { throw URLError(.timedOut) }
            if url.path.contains("GetPlayerSummaries") {
                return (try JSONSerialization.data(withJSONObject: ["response": ["players": [
                    ["steamid": "76561198000000001", "personaname": "北境"]]]]), 200)
            }
            if url.path.contains("GetDetails") {
                var detail: [String: Any] = ["publishedfileid": "123", "result": removed ? 9 : 1, "title": "极光",
                                             "creator": "76561198000000001", "file_size": "2048000",
                                             "time_created": 1_700_000_000, "time_updated": 1_700_086_400,
                                             "tags": [["tag": "Scene"], ["tag": "Anime"], ["tag": "3840 x 2160"]]]
                if let description { detail["file_description"] = description }
                return (try JSONSerialization.data(withJSONObject: ["response": ["publishedfiledetails": [detail]]]), 200)
            }
            return (Data(), 404)
        }
    }

    private func makeStore(_ fake: FakeSteam, key: String?) -> SteamStoreService {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KineticDetails-\(UUID().uuidString)")
        roots.append(root)
        return SteamStoreService(keyStore: MemorySteamAPIKeyStore(key), cacheDirectory: root,
                                 posters: SteamPosterCache(directory: nil, fetch: { try await fake.fetch($0) }),
                                 fetch: { try await fake.fetch($0) })
    }

    func testDetailsComeFromGetDetailsWithTheRealAuthorAndAreCachedPerRun() async throws {
        let fake = FakeSteam()
        let store = makeStore(fake, key: key)
        let details = try await store.details(workshopID: "123")
        let request = try XCTUnwrap(fake.requests.first { $0.path.contains("GetDetails") })
        let items = URLComponents(url: request, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "publishedfileids[0]" }?.value, "123")
        XCTAssertEqual(items.first { $0.name == "short_description" }?.value, "false", "The full description, not a summary")
        XCTAssertEqual(items.first { $0.name == "strip_description_bbcode" }?.value, "false")
        XCTAssertEqual(details.item.title, "极光")
        XCTAssertEqual(details.item.authorName, "北境")
        XCTAssertEqual(details.item.fileSize, 2_048_000)
        XCTAssertEqual(details.description, "[b]Hello[/b]\n第二段")
        _ = try await store.details(workshopID: "123")
        XCTAssertEqual(fake.requests.filter { $0.path.contains("GetDetails") }.count, 1, "Cached for this run")

        let noKey = makeStore(FakeSteam(), key: nil)
        do { _ = try await noKey.details(workshopID: "123"); XCTFail("Needs a key") }
        catch { XCTAssertEqual(error as? SteamStoreError, .missingKey) }
        let removed = FakeSteam(); removed.removed = true
        do { _ = try await makeStore(removed, key: key).details(workshopID: "123"); XCTFail("Removed item") }
        catch { XCTAssertEqual(error as? SteamStoreError, .itemUnavailable) }
    }

    private func steamItem() -> SteamStoreItem {
        SteamStoreItem(workshopID: "123", title: "极光", previewURL: nil, creatorSteamID: "76561198000000001",
                       authorName: nil, timeCreated: nil, timeUpdated: nil, fileSize: nil, type: .scene, tags: ["Scene"])
    }

    private func spin(until predicate: () -> Bool, timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !predicate() { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }

    func testModelStatesEndAndRetryKeepsContent() {
        let fake = FakeSteam()
        fake.fail = true
        let model = WallpaperDetailsModel(subject: .steam(steamItem()), store: makeStore(fake, key: key))
        model.start()
        XCTAssertEqual(model.state, .loading)
        spin(until: { if case .failed = model.state { return true }; return false })
        guard case .failed = model.state else { return XCTFail("A failure ends loading") }
        XCTAssertEqual(model.title, "极光", "Known content stays")
        fake.fail = false
        model.retry()
        spin(until: { model.state == .loaded })
        XCTAssertEqual(model.state, .loaded)
        XCTAssertEqual(model.author, "北境")
        XCTAssertEqual(SteamTagCatalog.grouped(model.tags)[.genre], ["动漫"])

        let empty = FakeSteam(); empty.description = nil
        let noDescription = WallpaperDetailsModel(subject: .steam(steamItem()), store: makeStore(empty, key: key))
        noDescription.start()
        spin(until: { noDescription.state == .loaded })
        XCTAssertNil(noDescription.details?.description, "Shown as 作者暂未提供描述")

        let local = Wallpaper(name: "本地视频", type: .video, acquisitionOrigin: .localImport,
                              resourceURL: URL(fileURLWithPath: "/tmp/none.mp4"))
        let localModel = WallpaperDetailsModel(subject: .local(local), store: makeStore(FakeSteam(), key: key))
        localModel.start()
        XCTAssertEqual(localModel.state, .noSteamInfo, "No Steam source: no request, no endless spinner")
    }

    // MARK: - 窗口

    func testTheWindowStartsAtThreeQuartersOfTheMainDefaultAndFitsTheScreen() {
        let size = WallpaperDetailsWindowMetrics.defaultSize
        XCTAssertEqual(size.width, 885, accuracy: 0.01)
        XCTAssertEqual(size.height, 570, accuracy: 0.01)
        XCTAssertEqual(size.width / size.height, MainWindowDesignTokens.Window.defaultWidth / MainWindowDesignTokens.Window.defaultHeight,
                       accuracy: 0.001, "Same aspect ratio as the main window default")
        let small = WallpaperDetailsWindowMetrics.initialSize(visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 500))
        XCTAssertLessThanOrEqual(small.width, 720)
        XCTAssertLessThanOrEqual(small.height, 420)
        let minimum = WallpaperDetailsWindowMetrics.minimumSize(visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 500))
        XCTAssertLessThanOrEqual(minimum.width, small.width)
        XCTAssertLessThanOrEqual(minimum.height, small.height)
    }

    func testSameWallpaperReusesItsWindowAndDifferentWallpapersGetTheirOwn() throws {
        let windows = WallpaperDetailsWindows.shared
        let store = makeStore(FakeSteam(), key: key)
        let online = windows.show(.steam(steamItem()), store: store, activate: false)
        XCTAssertTrue(online.styleMask.contains(.resizable))
        XCTAssertTrue(online.styleMask.contains(.titled))
        XCTAssertTrue(online.styleMask.contains(.closable))
        XCTAssertNil(online.sheetParent, "Not a sheet")
        let downloaded = Wallpaper(name: "极光", type: .scene, acquisitionOrigin: .steamWorkshop,
                                   resourceURL: URL(fileURLWithPath: "/tmp/123"), steamMetadata: SteamMetadata(workshopID: "123"))
        XCTAssertTrue(windows.show(.local(downloaded), store: store, activate: false) === online,
                      "The downloaded copy of the same Steam wallpaper shares the window")
        let other = Wallpaper(name: "雨夜", type: .video, acquisitionOrigin: .localImport, resourceURL: URL(fileURLWithPath: "/tmp/b.mp4"))
        let second = windows.show(.local(other), store: store, activate: false)
        XCTAssertFalse(second === online)
        XCTAssertEqual(windows.openKeys.count, 2)
        online.close()
        XCTAssertEqual(windows.openKeys, ["local:\(other.id.uuidString)"], "Closing releases only that window")
    }

    // MARK: - 外观（人工查看）

    func testDetailsLayoutSnapshot() throws {
        let fake = FakeSteam()
        fake.description = """
        [h1]极光 Aurora[/h1]
        A calm aurora over snowy mountains. 适合夜间使用。

        [b]Features[/b]
        [list][*]Audio responsive[*]Custom colors[/list]
        More on [url=https://example.com]the author's page[/url].
        """
        let model = WallpaperDetailsModel(subject: .steam(steamItem()), store: makeStore(fake, key: key))
        model.start()
        spin(until: { model.state == .loaded })
        try R4SnapshotTests.render(WallpaperDetailsView(model: model), size: WallpaperDetailsWindowMetrics.defaultSize,
                                   name: "details-window")
    }
}
