enum PlaybackState: String, Codable, CaseIterable, Sendable {
    case noWallpaper
    case preparing
    case playing
    case manualPaused
    case smartPaused
    case stopped
    case failed
}
