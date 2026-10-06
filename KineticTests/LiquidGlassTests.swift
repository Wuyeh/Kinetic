import AppKit
import SwiftUI
import XCTest
@testable import Kinetic

/// Module 22：系统 Liquid Glass 的接入。
@MainActor
final class LiquidGlassTests: XCTestCase {
    private func subview<T: NSView>(of type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews {
            if let match = subview(of: type, in: child) { return match }
        }
        return nil
    }

    /// 整窗玻璃：窗口不再绘制不透明背景，底层是系统玻璃（macOS 26+ 为 NSGlassEffectView）。
    func testWindowGlassBackgroundMakesTheWindowTransparentOverSystemGlass() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        XCTAssertTrue(window.isOpaque)
        let hosting = NSHostingView(rootView: Text("Kinetic")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { WindowGlassBackground().ignoresSafeArea() })
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertFalse(window.isOpaque)
        XCTAssertEqual(window.backgroundColor, .clear)
        if #available(macOS 26.0, *) {
            XCTAssertTrue(KineticGlass.isAvailable)
            XCTAssertNotNil(subview(of: NSGlassEffectView.self, in: hosting))
        } else {
            XCTAssertFalse(KineticGlass.isAvailable)
            XCTAssertNotNil(subview(of: NSVisualEffectView.self, in: hosting))
        }
    }

    /// 用户调整：主窗口玻璃上叠一半系统窗口底色，文字清晰；底色是随外观变化的系统颜色。
    func testWindowBackdropIsHalfOpaqueSystemBackground() {
        XCTAssertEqual(WindowGlassBackground.backdropOpacity, 0.5, accuracy: 0.001)
    }

    /// 用户要求：设置窗口与主窗口侧栏使用同一种系统侧栏材质。
    func testSettingsBackdropUsesTheSidebarMaterial() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let hosting = NSHostingView(rootView: Color.clear
            .background { WindowGlassBackground(style: .sidebar).ignoresSafeArea() })
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertFalse(window.isOpaque)
        let effect = subview(of: NSVisualEffectView.self, in: hosting)
        XCTAssertEqual(effect?.material, .sidebar)
        XCTAssertEqual(effect?.blendingMode, .behindWindow)
    }
}
