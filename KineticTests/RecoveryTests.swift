import AppKit
import SwiftUI
import XCTest
@testable import Kinetic

/// Module 57：意外退出保护、最近的问题、诊断信息。
@MainActor
final class RecoveryTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() async throws {
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        roots = []
    }

    private func directory() -> URL {
        let url = TestWorkspaceDirectory.make(".build/RecoveryTests")
        roots.append(url)
        return url
    }

    private let display = DisplayID("display-1")
    private let other = DisplayID("display-2")

    // MARK: 意外退出保护

    func testCleanExitHoldsNothing() {
        let folder = directory()
        let first = UncleanExitGuard(directory: folder, settleInterval: 0)
        first.beginSession()
        XCTAssertFalse(first.previousSessionEndedUncleanly, "第一次启动")
        first.recordApply(UUID(), name: "雨夜", on: display, displayName: "内建显示器")
        first.endSession()

        let next = UncleanExitGuard(directory: folder, settleInterval: 0)
        next.beginSession()
        XCTAssertFalse(next.previousSessionEndedUncleanly)
        XCTAssertTrue(next.held.isEmpty)
    }

    /// 刚换上的壁纸还没稳定运行就意外退出：下次启动这台显示器暂不恢复它；另一台已经稳定的不受影响。
    func testCrashSoonAfterApplyHoldsThatWallpaperOnThatDisplay() {
        let folder = directory()
        let rain = UUID(), sea = UUID()
        let session = UncleanExitGuard(directory: folder, settleInterval: 0)
        session.beginSession()
        session.recordApply(sea, name: "海", on: other, displayName: "副屏")
        session.settle(other, appliedAt: session.currentJournal.recent[other.rawValue]!.appliedAt)
        session.recordApply(rain, name: "雨夜", on: display, displayName: "内建显示器")
        // 不调用 endSession：模拟崩溃或被强制退出。

        let next = UncleanExitGuard(directory: folder, settleInterval: 0)
        next.beginSession()
        XCTAssertTrue(next.previousSessionEndedUncleanly)
        XCTAssertEqual(next.held, [HeldWallpaper(displayID: display, displayName: "内建显示器", wallpaperID: rain, wallpaperName: "雨夜")])
        XCTAssertTrue(next.isHeld(rain, on: display))
        XCTAssertFalse(next.isHeld(rain, on: other))
        XCTAssertFalse(next.isHeld(sea, on: other), "稳定运行过的不暂停恢复")

        // 这次又意外退出、但期间没有换壁纸：再下一次启动不会一直暂停下去。
        let third = UncleanExitGuard(directory: folder, settleInterval: 0)
        third.beginSession()
        XCTAssertTrue(third.previousSessionEndedUncleanly)
        XCTAssertTrue(third.held.isEmpty)
    }

    func testNewerApplySurvivesTheOlderSettle() {
        let folder = directory()
        let session = UncleanExitGuard(directory: folder, settleInterval: 0)
        session.beginSession()
        session.recordApply(UUID(), name: "旧", on: display, displayName: "")
        let older = session.currentJournal.recent[display.rawValue]!.appliedAt
        let newer = UUID()
        Thread.sleep(forTimeInterval: 0.01)
        session.recordApply(newer, name: "新", on: display, displayName: "")
        session.settle(display, appliedAt: older)
        XCTAssertEqual(session.currentJournal.recent[display.rawValue]?.wallpaperID, newer)
    }

    func testSettlesAfterTheIntervalAndReleaseClearsTheHold() async {
        let folder = directory()
        let session = UncleanExitGuard(directory: folder, settleInterval: 0.05)
        session.beginSession()
        session.recordApply(UUID(), name: "雨夜", on: display, displayName: "")
        XCTAssertNotNil(session.currentJournal.recent[display.rawValue])
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(session.currentJournal.recent[display.rawValue], "稳定运行后删除记录")

        let crashed = UncleanExitGuard(directory: folder, settleInterval: 0)
        crashed.beginSession()
        crashed.recordApply(UUID(), name: "雨夜", on: display, displayName: "")
        let next = UncleanExitGuard(directory: folder, settleInterval: 0)
        next.beginSession()
        XCTAssertEqual(next.held.count, 1)
        next.release(display)
        XCTAssertTrue(next.held.isEmpty)
    }

    // MARK: 最近的问题

    func testProblemLogKeepsTheNewestTwentyAndPersists() {
        let folder = directory()
        let log = ProblemLog(directory: folder)
        for index in 0..<25 {
            log.add(ProblemRecord(date: Date(timeIntervalSince1970: TimeInterval(index)), kind: .wallpaperFailed,
                                  displayName: "内建显示器", wallpaperName: "壁纸\(index)", message: "无法加载"))
        }
        XCTAssertEqual(log.records.count, 20)
        XCTAssertEqual(log.records.first?.wallpaperName, "壁纸24", "新的在前")
        let reopened = ProblemLog(directory: folder)
        XCTAssertEqual(reopened.records, log.records)
        reopened.clear()
        XCTAssertTrue(ProblemLog(directory: folder).records.isEmpty)
    }

    func testRuntimeFailuresAreRecordedOnce() async throws {
        struct Broken: LocalizedError { var errorDescription: String? { "解码失败" } }
        @MainActor final class FailingRenderer: WallpaperRenderer {
            let wallpaper: Wallpaper
            let displayView = NSView()
            var onFailure: (@MainActor (Error) -> Void)?
            init(_ wallpaper: Wallpaper) { self.wallpaper = wallpaper }
            func prepare() async throws { throw Broken() }
            func play() {}
            func pause() {}
            func resume() {}
            func setMuted(_ muted: Bool) {}
            func dispose() {}
        }
        @MainActor final class Host: DesktopContentHost {
            func present(_ view: NSView) -> Bool { true }
            func stop() {}
        }
        let runtime = WallpaperRuntimeManager { FailingRenderer($0) }
        runtime.addDisplay(display, name: "内建显示器", host: Host())
        let log = ProblemLog(directory: directory())
        log.observe(runtime)
        let wallpaper = Wallpaper(name: "雨夜", type: .video, source: .local, resourceURL: URL(fileURLWithPath: "/tmp/rain.mp4"))
        runtime.apply(wallpaper, to: display)
        try await Task.sleep(nanoseconds: 100_000_000)
        runtime.apply(wallpaper, to: display)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(log.records.count, 1, "同一张壁纸在同一台显示器上连续失败只记一次")
        XCTAssertEqual(log.records.first?.kind, .wallpaperFailed)
        XCTAssertEqual(log.records.first?.displayName, "内建显示器")
        XCTAssertEqual(log.records.first?.wallpaperName, "雨夜")
        runtime.shutdown()
    }

    // MARK: 诊断信息

    func testDiagnosticsDropFilePaths() {
        let home = "/Users/someone"
        let records = [
            ProblemRecord(date: Date(timeIntervalSince1970: 0), kind: .libraryUnreadable, displayName: nil, wallpaperName: nil,
                          message: "无法读取 /Users/someone/Library/Containers/com.kinetic.app/Data/library.json：权限不足"),
            ProblemRecord(date: Date(timeIntervalSince1970: 60), kind: .wallpaperFailed, displayName: "Studio Display",
                          wallpaperName: "雨夜", message: "无法加载“雨夜”。 file:///Volumes/Media/rain.mp4"),
        ]
        let text = DiagnosticsReport.text(records: records, appVersion: "0.1.0", build: "202610101044",
                                          systemVersion: "Version 27.0", displayCount: 2, homeDirectory: home,
                                          now: Date(timeIntervalSince1970: 120))
        XCTAssertTrue(text.contains("Kinetic 0.1.0 (202610101044)"))
        XCTAssertTrue(text.contains("显示器：2 台"))
        XCTAssertTrue(text.contains("Studio Display"))
        XCTAssertTrue(text.contains("雨夜"))
        XCTAssertFalse(text.contains("/Users/someone"))
        XCTAssertFalse(text.contains("Containers"))
        XCTAssertFalse(text.contains("/Volumes/Media"))
        XCTAssertTrue(text.contains("〈路径〉"))
        XCTAssertTrue(DiagnosticsReport.text(records: [], appVersion: "0.1.0", build: "1", systemVersion: "x", displayCount: 1)
            .contains("最近没有问题记录"))
    }

    func testNoticeText() {
        let item = HeldWallpaper(displayID: display, displayName: "Studio Display", wallpaperID: UUID(), wallpaperName: "雨夜")
        XCTAssertEqual(LaunchRecoveryNotice.message(item), "上次 Kinetic 意外退出，「雨夜」这次没有在「Studio Display」上自动恢复。")
        let unnamed = HeldWallpaper(displayID: display, displayName: "", wallpaperID: UUID(), wallpaperName: "")
        XCTAssertEqual(LaunchRecoveryNotice.message(unnamed), "上次 Kinetic 意外退出，上次的壁纸这次没有在这台显示器上自动恢复。")
    }

    /// 设置 › 通用「最近的问题」（三种记录）与空状态，浅色 / 深色。
    func testRecentProblemsSnapshots() throws {
        let log = ProblemLog(directory: directory())
        log.add(ProblemRecord(date: Date(timeIntervalSince1970: 1_791_000_000), kind: .libraryUnreadable, displayName: nil,
                              wallpaperName: nil, message: "资料库文件格式不对，已另存备份。"))
        log.add(ProblemRecord(date: Date(timeIntervalSince1970: 1_791_003_600), kind: .wallpaperFailed, displayName: "Studio Display",
                              wallpaperName: "雨夜", message: "无法加载“雨夜”。"))
        log.add(ProblemRecord(date: Date(timeIntervalSince1970: 1_791_007_200), kind: .uncleanExit, displayName: "内建显示器",
                              wallpaperName: "海边", message: "这张壁纸刚换上不久 Kinetic 就意外退出；这次启动没有在这台显示器上自动恢复它。"))
        let view = RecentProblemsSection(log: log, displayCount: { 2 }).padding(28)
        let size = CGSize(width: 628, height: 380)
        try R4SnapshotTests.render(view, size: size, name: "module57-problems")
        try R4SnapshotTests.render(view, size: size, name: "module57-problems-dark", appearance: .darkAqua)
        let empty = RecentProblemsSection(log: ProblemLog(directory: directory()), displayCount: { 1 }).padding(28)
        try R4SnapshotTests.render(empty, size: CGSize(width: 628, height: 200), name: "module57-problems-empty")
    }
}
