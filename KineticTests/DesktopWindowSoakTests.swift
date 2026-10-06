import AppKit
import XCTest
@testable import Kinetic

/// 显式运行专用 scheme 才执行，正常单元测试不会等待 30 分钟或覆盖桌面。
final class DesktopWindowSoakTests: XCTestCase {
    @MainActor
    func testThirtyMinuteDesktopSession() async throws {
        guard ProcessInfo.processInfo.environment["KINETIC_DESKTOP_SOAK"] == "1" else {
            throw XCTSkip("使用 Kinetic-Module2 验收 scheme 显式执行 30 分钟桌面测试。")
        }
        executionTimeAllowance = 2100
        let identifier = AppDelegate.desktopWallpaperWindowIdentifier
        let runtime = DesktopWindowRuntime(identifier: identifier)
        let events = SpaceEventCounter()
        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        workspaceNotifications.addObserver(events, selector: #selector(SpaceEventCounter.spaceChanged),
                                           name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        defer {
            runtime.stop()
            workspaceNotifications.removeObserver(events)
        }
        XCTAssertTrue(runtime.present(DesktopTestPatternView(frame: .zero)))
        let firstWindow = try XCTUnwrap(runtime.window)
        let firstNumber = firstWindow.windowNumber
        let started = ProcessInfo.processInfo.systemUptime
        print("MODULE2_SOAK_BEGIN \(Date().ISO8601Format()) window=\(firstNumber) requiredSeconds=1800")
        fflush(stdout)

        var sample = 0
        while ProcessInfo.processInfo.systemUptime - started < 1800 {
            try await Task.sleep(nanoseconds: 10_000_000_000)
            let window = try XCTUnwrap(runtime.window)
            XCTAssertTrue(window === firstWindow)
            XCTAssertEqual(window.windowNumber, firstNumber)
            XCTAssertEqual(NSApp.windows.filter { $0.identifier == identifier }.count, 1)
            XCTAssertFalse(window.isKeyWindow)
            XCTAssertFalse(window.isMainWindow)
            XCTAssertTrue(window.ignoresMouseEvents)
            XCTAssertEqual(window.level, DesktopWallpaperWindow.wallpaperLevel)
            if let primary = DesktopDisplay.primary() {
                XCTAssertEqual(window.frame, primary.frame)
                XCTAssertEqual(runtime.targetDisplay?.id, primary.id)
                XCTAssertTrue(window.isVisible)
            } else {
                XCTAssertFalse(window.isVisible)
            }
            sample += 1
            if sample % 6 == 0 {
                let elapsed = Int(ProcessInfo.processInfo.systemUptime - started)
                print("MODULE2_SOAK_SAMPLE elapsed=\(elapsed) window=\(firstNumber) spaces=\(events.count) frame=\(window.frame) screens=\(NSScreen.screens.count)")
                fflush(stdout)
            }
        }

        // 真正的系统通知，不用单元测试伪造的通知来替代人工 Spaces 操作。
        XCTAssertGreaterThanOrEqual(events.count, 4, "验收期间至少进行 4 次真实 Spaces/全屏空间切换。")
        print("MODULE2_SOAK_END \(Date().ISO8601Format()) elapsed=\(Int(ProcessInfo.processInfo.systemUptime - started)) spaces=\(events.count)")
        fflush(stdout)
    }
}

@MainActor
private final class SpaceEventCounter: NSObject {
    private(set) var count = 0
    @objc func spaceChanged(_ notification: Notification) { count += 1 }
}
