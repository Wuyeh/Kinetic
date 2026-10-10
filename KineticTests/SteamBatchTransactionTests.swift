import XCTest
@testable import Kinetic

/// R4 UI-MS5–MS9：Steam 批量下载 / 加入列表 / 喜爱。远程项目先下载入库，本地项目跳过，失败项目不加入，
/// 绝不应用；重复执行不产生重复记录或引用；数字是真实结果。
@MainActor
final class SteamBatchTransactionTests: XCTestCase {
    private var root: URL!
    private var installation: SteamCMDInstallation!
    private var library: WallpaperLibrary!
    private var organization: LocalOrganizationStore!
    private var steam: SteamAcquisitionService!
    private let fake = FakeSteamCMD()
    private var failing: Set<String> = []

    private final class SignedIn: UserDefaults {
        override func string(forKey defaultName: String) -> String? {
            defaultName == SteamAcquisitionService.usernameKey ? "fixture-user" : nil
        }
    }

    override func setUp() async throws {
        root = TestWorkspaceDirectory.make(".build/R4/BatchWorkspaces")
        installation = SteamCMDInstallation(rootURL: root.appendingPathComponent("SteamCMD"))
        try FileManager.default.createDirectory(at: installation.rootURL, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: installation.scriptURL)
        library = WallpaperLibrary(storage: .init(rootURL: root.appendingPathComponent("Library")))
        organization = LocalOrganizationStore(storage: library.storage)
        let installation = installation!
        fake.configure = { [unowned self] process in
            process.script = { process in
                guard let index = process.arguments.firstIndex(of: "+workshop_download_item") else { return process.finish(0) }
                let id = process.arguments[index + 2]
                if self.failing.contains(id) {
                    process.emit("ERROR! Download item \(id) failed (Timeout).\n")
                    return process.finish(1)
                }
                let folder = installation.contentURL(for: id)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try? Data(#"{"type":"web","file":"index.html"}"#.utf8).write(to: folder.appendingPathComponent("project.json"))
                try? Data("<html>\(id)</html>".utf8).write(to: folder.appendingPathComponent("index.html"))
                process.emit("Success. Downloaded item \(id) to \"\(folder.path)\" (20 bytes)\n")
                process.finish(0)
            }
        }
        steam = SteamAcquisitionService(installation: installation, library: library, defaults: SignedIn(),
                                        makeProcess: fake.factory)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func item(_ id: String) -> SteamStoreItem {
        SteamStoreItem(workshopID: id, title: "Item \(id)", previewURL: nil, creatorSteamID: nil, authorName: nil,
                       timeCreated: nil, timeUpdated: nil, fileSize: nil, type: .web, tags: ["Web"])
    }

    private func downloadedIDs() -> [String] {
        fake.processes.compactMap { process in
            process.arguments.firstIndex(of: "+workshop_download_item").map { process.arguments[$0 + 2] }
        }
    }

    private func transaction(_ presentation: SteamDownloadPresentation? = nil) -> SteamBatchTransaction {
        let transaction = SteamBatchTransaction(steam: steam, library: library, organization: organization,
                                                presentation: presentation)
        transaction.pollInterval = 0.02
        return transaction
    }

    func testBatchDownloadSkipsLocalItemsDeduplicatesAndOnlyAddsToTheLibrary() async throws {
        _ = await steam.acquire(item("1").acquisitionInfo)
        let before = fake.processes.count
        let presentation = SteamDownloadPresentation()
        presentation.durationScale = 0.01
        let summary = await transaction(presentation).run([item("1"), item("2"), item("3"), item("2")], action: .download)
        XCTAssertEqual(Array(downloadedIDs().dropFirst(before)).sorted(), ["2", "3"], "Already-local and duplicate items are not downloaded")
        XCTAssertEqual(summary.downloaded, 2)
        XCTAssertEqual(summary.alreadyLocal, 1)
        XCTAssertEqual(summary.totalFailed, 0)
        XCTAssertEqual(library.wallpapers.count, 3, "One record per workshop item")
        XCTAssertEqual(Set(library.wallpapers.compactMap { $0.steamMetadata?.workshopID }), ["1", "2", "3"])
        XCTAssertNil(presentation.infos["1"], "An already-local item gets no 'just downloaded' animation")
        XCTAssertNotNil(presentation.infos["2"])
        XCTAssertEqual(summary.message, "已将 2 个壁纸添加到本地资料库 ✓，1 个已在本地资料库")

        // 再执行一次：不下载、不建记录。
        let again = await transaction().run([item("1"), item("2"), item("3")], action: .download)
        XCTAssertEqual(again.alreadyLocal, 3)
        XCTAssertEqual(library.wallpapers.count, 3)
    }

    func testAddToListDownloadsRemoteItemsFirstAndLeavesFailuresOut() async throws {
        failing = ["4"]
        _ = await steam.acquire(item("1").acquisitionInfo)
        let listID = try organization.createList(name: "夜间")
        let summary = await transaction().run([item("1"), item("2"), item("4")], action: .addToList(id: listID, name: "夜间"))
        let list = try XCTUnwrap(organization.lists.first { $0.id == listID })
        let expected = Set(["1", "2"].compactMap { library.wallpaper(workshopID: $0)?.id })
        XCTAssertEqual(Set(list.wallpaperIDs), expected, "Only local records join the list; the failed item does not")
        XCTAssertNil(library.wallpaper(workshopID: "4"))
        XCTAssertEqual(summary.succeeded, 2)
        XCTAssertEqual(summary.totalFailed, 1)
        XCTAssertEqual(summary.message, "已将 2 个壁纸添加到“夜间”，1 个下载失败")

        _ = await transaction().run([item("1"), item("2")], action: .addToList(id: listID, name: "夜间"))
        XCTAssertEqual(organization.lists.first { $0.id == listID }?.wallpaperIDs.count, 2, "No duplicate references")
    }

    func testFavoriteDownloadsFirstAndNeverFakesARemoteFavorite() async throws {
        failing = ["9"]
        let summary = await transaction().run([item("5"), item("9")], action: .favorite)
        XCTAssertEqual(library.wallpaper(workshopID: "5")?.isFavorite, true)
        XCTAssertNil(library.wallpaper(workshopID: "9"), "A failed download is not marked")
        XCTAssertEqual(summary.message, "已将 1 个壁纸添加到喜爱，1 个下载失败")
        let favoritedAt = library.wallpaper(workshopID: "5")?.favoritedAt
        let again = await transaction().run([item("5")], action: .favorite)
        XCTAssertEqual(again.message, "已将 1 个壁纸添加到喜爱 ✓")
        XCTAssertEqual(library.wallpaper(workshopID: "5")?.favoritedAt, favoritedAt, "Already favorite: unchanged")
    }

    func testSummariesUseRealCountsAndNoSuccessCheckWhenSomethingFailed() {
        typealias S = SteamBatchTransaction.Summary
        XCTAssertEqual(S(action: .download, downloaded: 8, alreadyLocal: 0, failed: 0).message, "已将 8 个壁纸添加到本地资料库 ✓")
        XCTAssertEqual(S(action: .download, downloaded: 6, alreadyLocal: 0, failed: 2).message, "已添加 6 个壁纸，2 个下载失败")
        XCTAssertFalse(S(action: .download, downloaded: 0, alreadyLocal: 0, failed: 3).message.contains("✓"))
        XCTAssertEqual(S(action: .addToList(id: UUID(), name: "夜间"), downloaded: 4, alreadyLocal: 2, failed: 2).message,
                       "已将 6 个壁纸添加到“夜间”，2 个下载失败")
    }

    func testFailedDownloadsNeverJoinTheSuccessAnimationQueue() {
        let presentation = SteamDownloadPresentation()
        presentation.durationScale = 0.01
        XCTAssertTrue(presentation.begin(item: item("7"), posterURL: nil, reduceMotion: true))
        XCTAssertFalse(presentation.begin(item: item("7"), posterURL: nil, reduceMotion: true), "One visual per item")
        presentation.finish("7", succeeded: false)
        XCTAssertNil(presentation.current)
        XCTAssertTrue(presentation.pendingIDs.isEmpty)
        XCTAssertFalse(presentation.isVisible, "An all-failed batch just fades the House out")
    }
}

/// R4 第 24、28 节 + 用户 9/25 规定：单选与多选是同一个菜单，不显示数量；只有三类动作；双击规则。
final class SteamCardMenuPlanTests: XCTestCase {
    func testSingleAndMultipleSelectionShareOneMenuWithoutCounts() {
        let menu = SteamCardMenuPlan.entries(allTargetsLocal: false)
        XCTAssertEqual(menu, [.details, .separator, .download, .addToList, .favorite])
        let titles = menu.map(SteamCardMenuPlan.title).filter { !$0.isEmpty }
        XCTAssertEqual(titles, ["查看详情…", "下载到本地资料库", "添加到壁纸列表", "标记为喜爱"])
        XCTAssertFalse(titles.contains { $0.contains(where: \.isNumber) }, "No selection count in any title")
        XCTAssertFalse(titles.contains { $0.contains("这") }, "No batch wording")
        XCTAssertEqual(SteamCardMenuPlan.entries(allTargetsLocal: true)[2], .inLibrary,
                       "Only when every selected item is already local")
    }

    func testDoubleClickOnASelectedMemberDownloadsTheWholeSelection() {
        XCTAssertTrue(SteamCardMenuPlan.doubleClickDownloadsSelection(selectionCount: 3, clickedIsSelected: true))
        XCTAssertFalse(SteamCardMenuPlan.doubleClickDownloadsSelection(selectionCount: 3, clickedIsSelected: false),
                       "An unselected card keeps the single double-click")
        XCTAssertFalse(SteamCardMenuPlan.doubleClickDownloadsSelection(selectionCount: 1, clickedIsSelected: true))
    }
}
