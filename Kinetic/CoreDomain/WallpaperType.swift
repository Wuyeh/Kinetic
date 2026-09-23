enum WallpaperType: String, Codable, CaseIterable, Sendable {
    case video
    case web
    case scene

    var supportState: WallpaperSupportState {
        switch self {
        case .video, .web:
            return .supported
        case .scene:
            return .unsupported
        }
    }
}

enum WallpaperSupportState: String, Codable, Sendable {
    case supported
    case unsupported
}
