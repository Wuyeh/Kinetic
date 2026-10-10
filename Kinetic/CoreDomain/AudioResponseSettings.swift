import Foundation

struct AudioResponseSettings: Codable, Equatable, Sendable {
    var isEnabled = false
    var mediaSource = MusicSource.appleMusic
}
enum AudioResponseStatus: String {
    case off, permissionRequired, starting, listening, waitingForScene, suspended, failed
    var message: String { NSLocalizedString("audioResponse.status." + rawValue, comment: "") }
}
