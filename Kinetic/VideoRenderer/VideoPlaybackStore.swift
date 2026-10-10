import Combine
import Foundation

/// Separate versioned sidecar. Source videos and library.json format 2 never change.
@MainActor
final class VideoPlaybackStore: ObservableObject {
    private struct Document: Codable {
        var version = 1
        var wallpapers: [String: VideoPlaybackOptions] = [:]
    }
    @Published private(set) var options: [String: VideoPlaybackOptions] = [:]
    @Published private(set) var loadError: String?
    let fileURL: URL
    static let maximumBytes = 4 * 1_024 * 1_024

    init(storage: LibraryStorageLocation) {
        fileURL = storage.rootURL.appendingPathComponent("video-settings.json")
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let info = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true,
                  let size = info.fileSize, size <= Self.maximumBytes else { throw VideoOptionsError.unreadable }
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            guard data.count <= Self.maximumBytes else { throw VideoOptionsError.unreadable }
            let document = try JSONDecoder().decode(Document.self, from: data)
            guard document.version == 1, document.wallpapers.count <= 10_000 else { throw VideoOptionsError.unreadable }
            for value in document.wallpapers.values { _ = try value.validated() }
            options = document.wallpapers
        } catch { loadError = VideoOptionsError.unreadable.localizedDescription }
    }
    func configuration(for id: Wallpaper.ID) -> VideoPlaybackOptions { options[id.uuidString] ?? .init() }

    func save(_ value: VideoPlaybackOptions, for wallpaper: Wallpaper, runtime: WallpaperRuntimeManager?) throws {
        guard wallpaper.type == .video else { throw VideoOptionsError.unsupportedWallpaper }
        guard loadError == nil else { throw VideoOptionsError.unreadable }
        var next = options; next[wallpaper.id.uuidString] = try value.validated()
        guard next.count <= 10_000 else { throw VideoOptionsError.unreadable }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Document(wallpapers: next))
        guard data.count <= Self.maximumBytes else { throw VideoOptionsError.unreadable }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        options = next
        for display in runtime?.displayIDs ?? [] {
            guard let runtime, runtime.activeWallpaper(on: display)?.id == wallpaper.id,
                  let state = runtime.state(of: display),
                  [.playing, .manualPaused, .smartPaused].contains(state.playbackState) else { continue }
            let updated = runtime.configureActive(wallpaper, on: display) { renderer, onError in
                guard let video = renderer as? VideoRenderer else { return false }
                video.scheduleOptionsUpdate(value, onError: onError); return true
            }
            if !updated { runtime.reloadActive(wallpaper, on: display) }
        }
    }
}
