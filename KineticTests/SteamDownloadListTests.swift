import XCTest
@testable import Kinetic

/// R4 用户要求：Poster 右下角圆环加粗；House 是按钮，向上弹出「正在下载」列表（名称、比例、胶囊进度条）。
@MainActor
final class SteamDownloadListTests: XCTestCase {
    func testTheRingIsThickerThanBefore() {
        XCTAssertGreaterThan(SteamDownloadRing.lineWidth, 2, "R4: the ring was 2 pt")
        XCTAssertLessThanOrEqual(SteamDownloadRing.lineWidth, 4, "Only a little thicker")
    }

    func testResolutionTagsBecomeAspectRatios() {
        typealias R = SteamResolutionTag
        XCTAssertEqual(R.ratioLabel(tags: ["Scene", "3840 x 2160"]), "16:9")
        XCTAssertEqual(R.ratioLabel(tags: ["Ultrawide 2560 x 1080"]), "21:9")
        XCTAssertEqual(R.ratioLabel(tags: ["Ultrawide 3440 x 1440"]), "21:9")
        XCTAssertEqual(R.ratioLabel(tags: ["Dual 3840 x 1080"]), "32:9")
        XCTAssertEqual(R.ratioLabel(tags: ["Triple 4096 x 768"]), "48:9")
        XCTAssertEqual(R.ratioLabel(tags: ["Portrait 1080 x 1920"]), "9:16")
        XCTAssertEqual(R.ratioLabel(tags: ["Portrait Standard Definition"]), "9:16")
        XCTAssertEqual(R.ratioLabel(tags: ["1920 x 1200"]), "16:10")
        XCTAssertEqual(R.ratioLabel(tags: ["Dynamic resolution"]), NSLocalizedString("steam.ratio.dynamic", comment: ""))
        XCTAssertNil(R.ratioLabel(tags: ["Other resolution", "Anime"]), "No guess without a resolution tag")
        XCTAssertNil(R.ratioLabel(tags: []))
    }

    func testRowsListOnlyActiveDownloadsInTheOrderTheyStarted() {
        let presentation = SteamDownloadPresentation()
        presentation.register(.init(id: "1", title: "极光", posterURL: nil, type: .video, tags: ["3840 x 2160"]))
        presentation.register(.init(id: "2", title: "雨夜", posterURL: nil, type: .web, tags: []))
        presentation.register(.init(id: "3", title: "完成", posterURL: nil, type: .scene, tags: []))
        let rows = presentation.downloadRows(tasks: ["2": .queued, "1": .downloading(progress: 0.4),
                                                     "3": .finished(UUID()), "4": .verifying])
        XCTAssertEqual(rows.map(\.id), ["1", "2", "4"], "Registration order; finished tasks leave the list")
        XCTAssertEqual(rows[0].title, "极光")
        XCTAssertEqual(rows[0].ratio, "16:9")
        XCTAssertEqual(rows[0].progress, 0.4)
        XCTAssertNil(rows[1].progress, "Queued has no invented percentage")
        XCTAssertNil(rows[1].ratio)
        XCTAssertEqual(rows[2].title, String(format: NSLocalizedString("steam.item.untitled", comment: ""), "4"),
                       "A download started elsewhere still appears")
        XCTAssertEqual(rows[2].progress, 1)
        XCTAssertTrue(presentation.downloadRows(tasks: ["1": .failed("x")]).isEmpty)
    }
}
