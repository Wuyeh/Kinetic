import Foundation

/// Module 48: a saved wallpaper content selection — one wallpaper with the parameters chosen for it
/// (video / web options, scene values, display fit and custom frame).
struct WallpaperBookmark: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var configuration: StagedDisplayWallpaperConfiguration
    var createdAt = Date()

    var wallpaperID: Wallpaper.ID? { configuration.wallpaperID }
}

/// Module 48: one display's part of a scheme.
struct SchemeDisplay: Codable, Equatable, Sendable {
    /// The wallpaper shown (or last shown, when stopped), with this display's parameters for it.
    var configuration: StagedDisplayWallpaperConfiguration?
    var isStopped = false
    var isManuallyPaused = false
    var isAudioEnabled = false
    /// The display's overlays; widget boards carry their layout, because layout files are pruned when unreferenced.
    var overlays: [OverlayConfiguration] = []
    var widgetLayouts: [String: WidgetBoardLayout] = [:]
    var playlist: DisplayPlaylistConfiguration?
    var schedule: DisplaySchedule?
}

/// Module 48: a complete saved setup, applied only after confirmation.
struct WallpaperScheme: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var createdAt = Date()
    /// Keyed by stable display ID.
    var displays: [String: SchemeDisplay] = [:]
    /// The global wallpaper sound default (menu bar / Settings).
    var isAudioEnabled = false
}
