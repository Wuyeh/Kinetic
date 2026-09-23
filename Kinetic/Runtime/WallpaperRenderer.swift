import AppKit

/// Runtime 与具体渲染器之间唯一的抽象。
/// 各类渲染器都通过它接入；
/// Runtime 不依赖任何具体渲染技术。一个实例只服务一张 Wallpaper，dispose 后不可重用。
@MainActor
protocol WallpaperRenderer: AnyObject {
    var wallpaper: Wallpaper { get }
    /// 交给桌面窗口显示的内容。调用方必须在 prepare 成功后才放上桌面。
    var displayView: NSView { get }
    /// 运行中失败时通知 Runtime；Renderer 自己保留静态画面，不决定 App 状态。
    var onFailure: (@MainActor (Error) -> Void)? { get set }

    /// 成功表示首帧已经可以显示，但不自动播放。
    func prepare() async throws
    func play()
    func pause()
    func resume()
    func setMuted(_ muted: Bool)
    /// 调用方先把 displayView 从窗口移除，再释放。必须幂等。
    func dispose()
}

/// Runtime 需要的桌面层能力；由 DesktopWindowRuntime 提供。
@MainActor
protocol DesktopContentHost: AnyObject {
    @discardableResult
    func present(_ contentView: NSView) -> Bool
    /// 移除桌面窗口及其内容，露出用户原本的 macOS 壁纸。必须幂等。
    func stop()
    /// 旧内容保持显示，新内容就位后调用 completion；调用方在 completion 中释放旧 Renderer。
    @discardableResult
    func transition(to contentView: NSView, completion: @escaping @MainActor () -> Void) -> Bool
}

extension DesktopContentHost {
    /// 默认硬切：先显示新内容，再立即通知释放旧内容。
    /// 交叉淡化由 CrossfadeDesktopHost 提供。
    @discardableResult
    func transition(to contentView: NSView, completion: @escaping @MainActor () -> Void) -> Bool {
        let shown = present(contentView)
        completion()
        return shown
    }
}

/// 仅做接口适配，不改变 VideoRenderer 的行为。
extension VideoRenderer: WallpaperRenderer {
    var displayView: NSView { contentView }
}

/// 仅做接口适配，不改变 DesktopWindowRuntime 的行为。
extension DesktopWindowRuntime: DesktopContentHost {}
