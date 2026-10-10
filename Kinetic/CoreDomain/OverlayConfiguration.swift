import Foundation

/// Independent of wallpaper identity, playback state and concrete effects.
enum OverlayKind: String, Codable, CaseIterable, Sendable {
    case particles, weather, widgets, music, clock
}

enum OverlayParameter: Codable, Equatable, Sendable {
    case number(Double), boolean(Bool), text(String)
}

struct OverlayConfiguration: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var kind: OverlayKind
    var displayID: DisplayID
    var isEnabled = false
    var isManuallyPaused = false
    var maximumFramesPerSecond = 30
    var parameters: [String: OverlayParameter] = [:]

    func validated() throws -> Self {
        guard !displayID.rawValue.isEmpty, displayID.rawValue.count <= 256,
              displayID != .main, !displayID.rawValue.hasPrefix("session-display-"),
              (1...60).contains(maximumFramesPerSecond), parameters.count <= 64 else {
            throw OverlayError.invalidConfiguration
        }
        for (key, value) in parameters {
            guard !key.isEmpty, key.count <= 128 else { throw OverlayError.invalidConfiguration }
            switch value {
            case .number(let number):
                guard number.isFinite, abs(number) <= 1_000_000 else { throw OverlayError.invalidConfiguration }
            case .text(let text):
                guard text.utf8.count <= 2_048 else { throw OverlayError.invalidConfiguration }
            case .boolean: break
            }
        }
        return self
    }
}

enum OverlayLifecycle: String, Equatable, Sendable {
    case disabled, unavailable, waitingForDisplay, preparing, running, paused, failed
}

struct OverlayState: Equatable, Identifiable, Sendable {
    let id: UUID
    let displayID: DisplayID
    let kind: OverlayKind
    var lifecycle: OverlayLifecycle
    var failure: String?
}

enum OverlayError: LocalizedError {
    case invalidConfiguration, settingsUnreadable, unavailable, targetUnavailable, preparationTimedOut, invalidWindowLevel
    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "叠加层配置无效。"
        case .settingsUnreadable: return "叠加层配置无法读取，原文件已保留。"
        case .unavailable: return "此叠加效果尚不可用。"
        case .targetUnavailable: return "所选显示器不可用，未改动其他显示器。"
        case .preparationTimedOut: return "叠加层准备超时，壁纸未受影响。"
        case .invalidWindowLevel: return "无法建立安全的桌面叠加层，壁纸未受影响。"
        }
    }
}
