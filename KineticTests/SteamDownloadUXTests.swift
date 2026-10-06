import AppKit
import XCTest
@testable import Kinetic

final class SteamDownloadUXTests: XCTestCase {
    @MainActor
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            if Date() > deadline { XCTFail("Download animation queue timed out"); return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    @MainActor
    func testCompletionOrderIsFIFOAndOnlyOneCloneRunsWhileHouseWaitsForDownloads() async throws {
        let presentation = SteamDownloadPresentation()
        presentation.durationScale = 0.04
        for id in ["A", "B", "C"] { presentation.begin(.init(id: id, image: nil, frame: .zero), reduceMotion: false) }
        let movedFrame = CGRect(x: 220, y: 80, width: 190, height: 190)
        presentation.updateFrames(["B": movedFrame])
        presentation.finish("B", succeeded: true)
        XCTAssertEqual(presentation.current?.poster.frame, movedFrame)
        presentation.finish("A", succeeded: true)
        XCTAssertEqual(presentation.current?.id, "B")
        XCTAssertEqual(presentation.pendingIDs, ["A"])
        try await wait { presentation.current?.id == "A" }
        try await wait { presentation.current == nil }
        XCTAssertTrue(presentation.isVisible)
        XCTAssertNil(presentation.exitStartedAt, "House cannot exit while C is downloading")
        presentation.finish("C", succeeded: false)
        XCTAssertNotNil(presentation.exitStartedAt)
        try await wait { !presentation.isVisible }
    }

    @MainActor
    func testFailedAndSkippedItemsNeverEnterSuccessQueueAndDuplicateStartIsIgnored() {
        let presentation = SteamDownloadPresentation()
        XCTAssertTrue(presentation.begin(.init(id: "A", image: nil, frame: .zero), reduceMotion: false))
        XCTAssertFalse(presentation.begin(.init(id: "A", image: nil, frame: .zero), reduceMotion: false))
        presentation.finish("A", succeeded: false)
        presentation.finish("skipped", succeeded: true)
        XCTAssertNil(presentation.current)
        XCTAssertNil(presentation.exitStartedAt)
        XCTAssertFalse(presentation.isVisible)
    }

    @MainActor
    func testReducedMotionPreservesQueueAndNewDownloadCancelsFinalExit() async throws {
        let presentation = SteamDownloadPresentation()
        presentation.durationScale = 0.12
        presentation.begin(.init(id: "A", image: nil, frame: .zero), reduceMotion: true)
        presentation.finish("A", succeeded: true)
        XCTAssertEqual(presentation.current?.reduceMotion, true)
        try await wait { presentation.exitStartedAt != nil }
        presentation.begin(.init(id: "B", image: nil, frame: .zero), reduceMotion: true)
        XCTAssertNil(presentation.exitStartedAt)
        try await Task.sleep(nanoseconds: 70_000_000)
        XCTAssertTrue(presentation.activeIDs.contains("B"))
        XCTAssertTrue(presentation.isVisible)
        presentation.finish("B", succeeded: true)
        try await wait { !presentation.isVisible }
    }

    func testTargetAvoidsToolbarAtNarrowAndWideWidthsAndMotionHasExactlyTwoCycles() {
        for width: CGFloat in [500, 720, 960, 1400] {
            let center = DownloadAnimationMetrics.houseCenter(in: CGSize(width: width, height: 700))
            XCTAssertGreaterThan(center.x - 19, 0)
            XCTAssertLessThan(center.x + 19, width)
            let toolbarRight = (width + min(650, width - 32)) / 2
            XCTAssertTrue(center.x - 19 >= toolbarRight || center.y + 19 < 700 - 28 - 56)
        }
        XCTAssertEqual(DownloadAnimationMetrics.bounce(at: 0), 0)
        XCTAssertEqual(DownloadAnimationMetrics.bounce(at: 1), 0, accuracy: 0.000001)
        XCTAssertGreaterThan(DownloadAnimationMetrics.bounce(at: 0.125), 0)
        XCTAssertLessThan(DownloadAnimationMetrics.bounce(at: 0.375), 0)
        XCTAssertGreaterThan(DownloadAnimationMetrics.bounce(at: 0.625), 0)
        XCTAssertLessThan(DownloadAnimationMetrics.bounce(at: 0.875), 0)
    }
}
