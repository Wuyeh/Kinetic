import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 桌面壁纸窗口使用此标识，不能用于普通主窗口或设置窗口。
    static let desktopWallpaperWindowIdentifier = NSUserInterfaceItemIdentifier(
        "Kinetic.DesktopWallpaper"
    )

    private var desktopWindowRuntime: DesktopWindowRuntime?
    /// 全局唯一的 Runtime Manager；启动时不应用任何壁纸。
    private(set) var runtimeManager: WallpaperRuntimeManager?
    /// Runtime 通过它在同一桌面窗口内完成 Crossfade。
    private var crossfadeHost: CrossfadeDesktopHost?
    /// 全局唯一的资料库（metadata 持久化）；启动时只读取，不添加或改动任何记录。
    private(set) var library: WallpaperLibrary?
    /// 本地导入服务（复制到 Library Storage）。
    private(set) var importService: LocalImportService?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 在 Runtime 初始化之前，关闭当前进程中可能恢复的旧桌面窗口。
        // 已退出进程的窗口由 macOS 回收；此处不操作其他进程或系统桌面。
        for window in NSApp.windows
        where window.identifier == Self.desktopWallpaperWindowIdentifier {
            window.close()
        }

        desktopWindowRuntime = DesktopWindowRuntime(identifier: Self.desktopWallpaperWindowIdentifier)
        if let desktopWindowRuntime {
            let host = CrossfadeDesktopHost(desktop: desktopWindowRuntime)
            crossfadeHost = host
            runtimeManager = WallpaperRuntimeManager(desktop: host)
        }
        if let storage = libraryStorage() {
            let library = WallpaperLibrary(storage: storage)
            self.library = library
            importService = LocalImportService(library: library)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        WallpaperPreviewCoordinator.shared.stopAll()
        // 退出时恢复用户原本的 macOS 壁纸，并释放所有 Renderer。
        runtimeManager?.shutdown()
        desktopWindowRuntime?.stop()
    }

    /// 资料库目录。
    private func libraryStorage() -> LibraryStorageLocation? {
        return try? LibraryStorageLocation.standard()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
