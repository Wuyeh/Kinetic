import Combine
import Foundation

/// Versioned settings sidecar; does not modify library.json or imported HTML/CSS.
@MainActor
final class WebPlaybackStore: ObservableObject {
    private struct Document: Codable {
        var version = 1
        var wallpapers: [String: WebPlaybackOptions] = [:]
    }
    @Published private(set) var options: [String: WebPlaybackOptions] = [:]
    @Published private(set) var loadError: String?
    let fileURL: URL
    static let maximumBytes = 4 * 1_024 * 1_024

    init(storage: LibraryStorageLocation) {
        fileURL = storage.rootURL.appendingPathComponent("web-settings.json")
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let info = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true,
                  let size = info.fileSize, size <= Self.maximumBytes else { throw WebOptionsError.unreadable }
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            guard data.count <= Self.maximumBytes else { throw WebOptionsError.unreadable }
            let document = try JSONDecoder().decode(Document.self, from: data)
            guard document.version == 1, document.wallpapers.count <= 10_000 else { throw WebOptionsError.unreadable }
            for value in document.wallpapers.values { _ = try value.validated() }
            options = document.wallpapers
        } catch { loadError = WebOptionsError.unreadable.localizedDescription }
    }
    func configuration(for id: Wallpaper.ID) -> WebPlaybackOptions { options[id.uuidString] ?? .init() }

    func save(_ value: WebPlaybackOptions, for wallpaper: Wallpaper, runtime: WallpaperRuntimeManager?) throws {
        guard wallpaper.type == .web, wallpaper.resourceURL.isFileURL else { throw WebOptionsError.unsupportedWallpaper }
        guard loadError == nil else { throw WebOptionsError.unreadable }
        let value = try value.validated()
        var next = options; next[wallpaper.id.uuidString] = value
        guard next.count <= 10_000 else { throw WebOptionsError.unreadable }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Document(wallpapers: next))
        guard data.count <= Self.maximumBytes else { throw WebOptionsError.unreadable }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        options = next
        for display in runtime?.displayIDs ?? [] {
            guard let runtime, runtime.activeWallpaper(on: display)?.id == wallpaper.id,
                  let state = runtime.state(of: display),
                  [.playing, .manualPaused, .smartPaused].contains(state.playbackState) else { continue }
            let updated = runtime.configureActive(wallpaper, on: display) { renderer, onError in
                guard let web = renderer as? WebRenderer, !value.requiresReload(comparedTo: web.options) else { return false }
                web.scheduleOptionsUpdate(value, onError: onError); return true
            }
            if !updated { runtime.reloadActive(wallpaper, on: display) }
        }
    }
    /// Explicit refresh uses only saved settings and the existing Ready/promotion path.
    func refresh(_ wallpaper: Wallpaper, runtime: WallpaperRuntimeManager) {
        guard wallpaper.type == .web else { return }
        for display in runtime.displayIDs where runtime.activeWallpaper(on: display)?.id == wallpaper.id {
            runtime.reloadActive(wallpaper, on: display)
        }
    }
}
