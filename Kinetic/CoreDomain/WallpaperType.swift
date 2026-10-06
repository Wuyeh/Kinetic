enum WallpaperType: String, Codable, CaseIterable, Sendable {
    case video
    case web
    case scene

    var supportState: WallpaperSupportState {
        switch self {
        case .video, .web, .scene:
            return .supported
        }
    }
}

enum WallpaperSupportState: String, Codable, Sendable {
    case supported
    case unsupported
}
