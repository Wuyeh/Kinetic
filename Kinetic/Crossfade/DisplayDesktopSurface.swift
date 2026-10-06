import AppKit

/// Kinetic 1.0 Module 6：一台显示器的桌面表面 = 它自己的桌面窗口 + 它自己的 Crossfade 舞台。
///
/// Crossfade 必须按显示器进行（规格 22、25）：每台显示器的会话持有一个表面，淡入、停止、释放都只发生在
/// 这台显示器的舞台上，另一台显示器的画面、Renderer 与正在进行的淡入不受影响。
/// 一个表面只能交给一个显示器会话（`WallpaperRuntimeManager.addDisplay` 会拒绝共用）。
/// 显示器的发现与稳定 ID 属于 Module 16；这里通过 `resolveDisplay` 注入“这台显示器现在在哪里”。
@MainActor
struct DisplayDesktopSurface {
    let desktop: DesktopWindowRuntime
    let host: CrossfadeDesktopHost

    /// - Parameters:
    ///   - windowIdentifier: 这台显示器的桌面窗口标识；不同显示器应使用不同标识。
    ///   - resolveDisplay: 返回这台显示器当前的位置；返回 nil 时隐藏窗口、保留内容（与 Module 2 相同）。
    init(
        windowIdentifier: NSUserInterfaceItemIdentifier,
        resolveDisplay: @escaping @MainActor () -> DesktopDisplay? = { DesktopDisplay.primary() },
        duration: TimeInterval = CrossfadeDesktopHost.standardDuration
    ) {
        desktop = DesktopWindowRuntime(identifier: windowIdentifier, primaryDisplay: resolveDisplay)
        host = CrossfadeDesktopHost(desktop: desktop, duration: duration)
    }
}
