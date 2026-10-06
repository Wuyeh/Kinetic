import AppKit
import SwiftUI

/// Module 22：Kinetic 的 Liquid Glass。
///
/// macOS 26 起使用系统的 Liquid Glass（SwiftUI `glassEffect` / `GlassEffectContainer` / `.glass` 按钮，
/// AppKit `NSGlassEffectView`），外观、「降低透明度」「增强对比度」以及系统设置中的 Liquid Glass 样式
/// 都由系统直接调控，Kinetic 不自行模拟、也不覆盖这些设置。更早的系统退回系统材质。
enum KineticGlass {
    /// 当前系统是否提供 Liquid Glass。
    static var isAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }
}

extension View {
    /// 在给定形状内放一层 Liquid Glass（旧系统为系统材质）。放在影响外观的其他修饰符之后。
    /// `clear` 使用更通透的 clear 变体（用于悬浮工具条）。
    @ViewBuilder
    func kineticGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false,
                                clear: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect((clear ? Glass.clear : Glass.regular).tint(tint).interactive(interactive), in: shape)
        } else if clear {
            background(.ultraThinMaterial, in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }

    /// 系统 Liquid Glass 按钮。用户要求（2026-09-25）：所有交互按钮都是无色的普通玻璃，
    /// 不使用强调色填充（不用 glassProminent / borderedProminent），也不继承窗口的 `.tint`。旧系统为 bordered 按钮。
    @ViewBuilder
    func kineticGlassButton() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass).tint(nil)
        } else {
            buttonStyle(.bordered).tint(nil)
        }
    }
}

/// 多个相邻玻璃元素放在同一容器中：渲染更高效，出现 / 消失时可以融合变形。
struct KineticGlassContainer<Content: View>: View {
    var spacing: CGFloat?
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// 整个窗口的透明背景：窗口本身变为透明，背后的桌面（包括正在播放的动态壁纸）透过背景显示。
/// 放在窗口根视图的最底层并忽略安全区域。
struct WindowGlassBackground: View {
    enum Style {
        /// 主窗口：Liquid Glass 上叠一层系统窗口底色（用户调整：原来太透）。
        case glass
        /// 设置窗口：与主窗口侧栏相同的系统侧栏材质（用户要求）。
        case sidebar
    }

    /// 主窗口玻璃上叠加的系统窗口底色不透明度。底色是系统动态颜色，随浅色 / 深色自动变化。
    static let backdropOpacity: Double = 0.5

    var style: Style = .glass

    var body: some View {
        switch style {
        case .glass:
            ZStack {
                WindowGlassView(style: .glass)
                Color(nsColor: .windowBackgroundColor)
                    .opacity(Self.backdropOpacity)
            }
        case .sidebar:
            WindowGlassView(style: .sidebar)
        }
    }
}

private struct WindowGlassView: NSViewRepresentable {
    let style: WindowGlassBackground.Style

    func makeNSView(context: Context) -> NSView {
        let view: NSView
        if style == .sidebar {
            // 与 NavigationSplitView 侧栏相同的系统材质，透过窗口背后的内容，随窗口是否活跃变化。
            let effect = NSVisualEffectView()
            effect.material = .sidebar
            effect.blendingMode = .behindWindow
            effect.state = .followsWindowActiveState
            view = effect
        } else if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 0
            view = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .underWindowBackground
            effect.blendingMode = .behindWindow
            effect.state = .followsWindowActiveState
            view = effect
        }
        let host = TransparentWindowHost()
        host.addSubview(view)
        view.frame = host.bounds
        view.autoresizingMask = [.width, .height]
        return host
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    /// 让所在窗口不再绘制自己的不透明背景，否则会盖住玻璃。
    final class TransparentWindowHost: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
        }
    }
}
