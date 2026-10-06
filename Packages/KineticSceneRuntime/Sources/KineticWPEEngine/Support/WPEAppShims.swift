import Foundation
import os

// Kinetic adaptation: small stand-ins for upstream app-level services the scene engine references.
// None of them reaches outside the engine: no settings store, no log file, no media or audio capture.

/// Upstream stores shader caches under the app's configuration folder.
struct ConfigurationDirectory {
    let root: URL
    init(fileManager: FileManager = .default) {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        root = caches.appendingPathComponent("KineticSceneEngine", isDirectory: true)
    }
}

/// Kinetic resolves (and keeps open) the engine-assets folder in the app; the renderer never opens a scope itself.
enum WPEEngineAssetsLibrary {
    static func isContainerInternal(_ url: URL) -> Bool { true }
}

enum WallpaperEngineImportService {
    static func originKind(forSourceFolder folderURL: URL) -> HTMLOriginKind {
        let canonical = folderURL.standardizedFileURL.resolvingSymlinksInPath().path
        let components = canonical.split(separator: "/", omittingEmptySubsequences: true)
        guard let id = components.last, UInt64(id) != nil, components.count >= 5 else { return .userLocal }
        let tail = Array(components.suffix(5))
        guard tail[0] == "steamapps", tail[1] == "workshop", tail[2] == "content", tail[3] == "431960" else { return .userLocal }
        return .workshopImport
    }
}

/// Wallpaper Engine language code handed to SceneScript (`engine.userProperties` / general settings).
enum AppLanguagePreference {
    case simplifiedChinese
    static func current(in _: UserDefaults) -> AppLanguagePreference { .simplifiedChinese }
    func wallpaperEngineLanguageCode() -> String { "zh-chs" }
}

enum LogFileSink {
    static func levelTag(_ level: Logger.Level) -> String {
        switch level {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .notice: return "NOTICE"
        case .warning: return "WARNING"
        case .error: return "ERROR"
        case .fault: return "FAULT"
        }
    }
}

/// System audio capture belongs to Kinetic Module 45 and is never started by the engine.
/// A host may feed `broker` and mark the spectrum active (default silent).
enum SystemAudioCaptureManager {
    static let broker = AudioSpectrumBroker()
    private static let captureActive = OSAllocatedUnfairLock(initialState: false)
    static var isCapturing: Bool { captureActive.withLock { $0 } }
    static func setHostSpectrumActive(_ active: Bool) { captureActive.withLock { $0 = active } }
}

struct PreparedScenePropertyPatch: Sendable {
    let patch: WPEScenePropertyPatch
    let rendererGeneration: UInt64
}

// MARK: - Now Playing (Kinetic Music modules come later; the engine receives no track data yet)

enum MonitorNowPlayingPhase: String, Codable, Sendable {
    case playing
    case paused
    case awaitingFirstEvent
    case noPlayer
}

struct MonitorNowPlayingState: Codable, Sendable, Equatable {
    var phase: MonitorNowPlayingPhase
    var title: String
    var artist: String?
    var album: String?
    var duration: Double?
    var position: Double?
    var positionSampledAt: Double?
    var trackID: String?
    var playerBundleID: String?
    var artwork: Data?
}

struct MonitorSystemSnapshot: Codable, Sendable, Equatable {}
struct MonitorAgentSessionState: Codable, Sendable, Equatable {}
struct MonitorSourceHealth: Codable, Sendable, Equatable {}

protocol MonitorSnapshotSink: Actor {
    func updateSystem(_ snapshot: MonitorSystemSnapshot) async
    func updateAgents(sourceID: String, sessions: [MonitorAgentSessionState]) async
    func updateHealth(_ health: MonitorSourceHealth) async
    func updateNowPlaying(_ state: MonitorNowPlayingState?) async
}

/// No-op now-playing source: never publishes a track.
final class NowPlayingSource: Sendable {
    init(audioReactive: Bool, audioDemand: @escaping @Sendable (Bool) -> Void) {}
    func start(sink: any MonitorSnapshotSink) async {}
    func stop() async {}
}
