import AppKit
import XCTest
@testable import Kinetic

final class DesktopWindowRuntimeTests: XCTestCase {
    private let identifier = NSUserInterfaceItemIdentifier("Kinetic.DesktopWallpaper.UnitTest")

    @MainActor
    func testDesktopLayerDoesNotTakeFocusOrMouseInput() async throws {
        let window = DesktopWallpaperWindow(frame: NSRect(x: 0, y: 0, width: 640, height: 480), identifier: identifier)
        defer { window.close() }

        XCTAssertGreaterThan(window.level.rawValue, Int(CGWindowLevelForKey(.desktopWindow)))
        XCTAssertLessThan(window.level.rawValue, Int(CGWindowLevelForKey(.desktopIconWindow)))
        XCTAssertLessThan(window.level.rawValue, NSWindow.Level.normal.rawValue)
        XCTAssertLessThan(window.level.rawValue, Int(CGWindowLevelForKey(.dockWindow)))
        XCTAssertLessThan(window.level.rawValue, Int(CGWindowLevelForKey(.mainMenuWindow)))
        XCTAssertFalse(window.canBecomeKey)
        XCTAssertFalse(window.canBecomeMain)
        XCTAssertTrue(window.ignoresMouseEvents)
        XCTAssertFalse(window.canHide)
        XCTAssertFalse(window.hidesOnDeactivate)
        XCTAssertFalse(window.isRestorable)
        XCTAssertTrue(window.isExcludedFromWindowsMenu)
        XCTAssertTrue(window.collectionBehavior.contains([.canJoinAllSpaces, .stationary, .ignoresCycle]))
        XCTAssertFalse(window.collectionBehavior.contains(.fullScreenAuxiliary))
    }

    @MainActor
    func testFrameIsNotReducedToVisibleWorkArea() async {
        let fullFrame = NSRect(x: 0, y: 0, width: 1728, height: 1117)
        let window = DesktopWallpaperWindow(frame: fullFrame, identifier: identifier)
        defer { window.close() }
        XCTAssertEqual(window.constrainFrameRect(fullFrame, to: NSScreen.screens.first), fullFrame)
        XCTAssertEqual(window.frame, fullFrame)
    }

    @MainActor
    func testRepeatedPresentationReusesOneWindowAndKeepsFocus() async throws {
        let display = try XCTUnwrap(DesktopDisplay.primary())
        let runtime = DesktopWindowRuntime(identifier: identifier, primaryDisplay: { display })
        defer { runtime.stop() }
        let originalKeyWindow = NSApp.keyWindow
        XCTAssertTrue(runtime.present(NSView()))
        let firstWindow = try XCTUnwrap(runtime.window)
        let replacement = NSView()
        XCTAssertTrue(runtime.present(replacement))
        XCTAssertTrue(runtime.window === firstWindow)
        XCTAssertTrue(firstWindow.contentView === replacement)
        XCTAssertTrue(NSApp.keyWindow === originalKeyWindow)
        XCTAssertEqual(NSApp.windows.filter { $0.identifier == identifier }.count, 1)
    }

    @MainActor
    func testScreenChangesRealignExistingWindowWithoutDiscardingContent() async throws {
        let applicationNotifications = NotificationCenter()
        var display = DesktopDisplay(id: 1, frame: NSRect(x: 0, y: 0, width: 1200, height: 800), backingScaleFactor: 2)
        let runtime = DesktopWindowRuntime(identifier: identifier, primaryDisplay: { display }, applicationNotifications: applicationNotifications)
        defer { runtime.stop() }
        let content = NSView()
        runtime.present(content)
        let original = try XCTUnwrap(runtime.window)
        display = DesktopDisplay(id: 2, frame: NSRect(x: 0, y: 0, width: 1440, height: 900), backingScaleFactor: 1)
        applicationNotifications.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertTrue(runtime.window === original)
        XCTAssertTrue(original.contentView === content)
        XCTAssertEqual(original.frame, display.frame)
        XCTAssertEqual(runtime.targetDisplay, display)
    }

    @MainActor
    func testMissingPrimaryDisplayWaitsThenRecoversAndDoesNotCreateExtraWindows() async throws {
        let applicationNotifications = NotificationCenter()
        var display: DesktopDisplay?
        let runtime = DesktopWindowRuntime(identifier: identifier, primaryDisplay: { display }, applicationNotifications: applicationNotifications)
        defer { runtime.stop() }
        let content = NSView()
        XCTAssertFalse(runtime.present(content))
        XCTAssertNil(runtime.window)

        display = try XCTUnwrap(DesktopDisplay.primary())
        applicationNotifications.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let firstWindow = try XCTUnwrap(runtime.window)
        XCTAssertTrue(firstWindow.isVisible)
        display = nil
        applicationNotifications.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertFalse(firstWindow.isVisible)
        XCTAssertNil(runtime.targetDisplay)

        display = try XCTUnwrap(DesktopDisplay.primary())
        applicationNotifications.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertTrue(runtime.window === firstWindow)
        XCTAssertTrue(firstWindow.contentView === content)
        XCTAssertTrue(firstWindow.isVisible)
    }

    @MainActor
    func testStopReleasesWindowAndContentAndUnsubscribesFromEvents() async throws {
        let applicationNotifications = NotificationCenter()
        let workspaceNotifications = NotificationCenter()
        let runtime = DesktopWindowRuntime(identifier: identifier, applicationNotifications: applicationNotifications, workspaceNotifications: workspaceNotifications)
        weak var releasedWindow: NSWindow?
        weak var releasedContent: NSView?
        autoreleasepool {
            let content = NSView()
            runtime.present(content)
            releasedWindow = runtime.window
            releasedContent = content
            runtime.stop()
            runtime.stop()
        }
        applicationNotifications.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        workspaceNotifications.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        XCTAssertNil(runtime.window)
        XCTAssertNil(runtime.targetDisplay)
        XCTAssertNil(releasedWindow)
        XCTAssertNil(releasedContent)
    }

    @MainActor
    func testWorkspaceEventsPreserveSingleWindowAndContent() async throws {
        let workspaceNotifications = NotificationCenter()
        let runtime = DesktopWindowRuntime(identifier: identifier, workspaceNotifications: workspaceNotifications)
        defer { runtime.stop() }
        let content = NSView()
        runtime.present(content)
        let firstWindow = try XCTUnwrap(runtime.window)
        for _ in 0..<20 {
            for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
                workspaceNotifications.post(name: name, object: nil)
            }
        }
        XCTAssertTrue(runtime.window === firstWindow)
        XCTAssertTrue(firstWindow.contentView === content)
        XCTAssertEqual(firstWindow.frame, try XCTUnwrap(DesktopDisplay.primary()).frame)
        XCTAssertEqual(NSApp.windows.filter { $0.identifier == identifier }.count, 1)
    }

    @MainActor
    func testSystemPrimaryDisplayMatchesQuartzInsteadOfKeyboardFocus() async throws {
        let display = try XCTUnwrap(DesktopDisplay.primary())
        XCTAssertEqual(display.id, CGMainDisplayID())
        XCTAssertEqual(display.frame, try XCTUnwrap(NSScreen.screens.first).frame)
    }
}
