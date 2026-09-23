#if DEBUG
import AppKit

/// 静态测试内容，仅供 Debug 测试使用。
/// 单色背景和一行文字，不读取任何文件、不启动计时动画。
@MainActor
final class DesktopTestPatternView: NSView {
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0.80, green: 0.87, blue: 0.90, alpha: 1).setFill()
        dirtyRect.fill()

        let title = NSString(string: NSLocalizedString("desktop.test.title", comment: "Desktop test pattern title"))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont(name: "PingFangSC-Regular", size: 20) ?? NSFont.systemFont(ofSize: 20),
            .foregroundColor: NSColor(srgbRed: 0.20, green: 0.28, blue: 0.32, alpha: 1)
        ]
        let size = title.size(withAttributes: attributes)
        title.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
                   withAttributes: attributes)
    }
}
#endif
