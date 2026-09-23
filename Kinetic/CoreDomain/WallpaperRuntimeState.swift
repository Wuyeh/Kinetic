import Foundation

/// Runtime 的数据快照；不包含状态转换与资源管理逻辑。
/// 不包含资料库的 UI 选中状态。
struct WallpaperRuntimeState: Equatable, Sendable {
    var playbackState: PlaybackState = .noWallpaper

    /// 当前实际显示的壁纸；准备新内容时可以继续保留旧内容。
    var activeWallpaperID: Wallpaper.ID?
    var preparingWallpaperID: Wallpaper.ID?

    /// 停止后重新启用所需的壁纸标识，与当前是否显示分开记录。
    var lastActiveWallpaperID: Wallpaper.ID?
}
