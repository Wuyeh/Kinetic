import Foundation
import CoreGraphics

enum MusicSource: String, CaseIterable, Codable, Sendable {
    case appleMusic, spotify
    var title: String { self == .appleMusic ? "Apple Music" : "Spotify" }
    var bundleID: String { self == .appleMusic ? "com.apple.Music" : "com.spotify.client" }
    // Player dictionaries use different suites and property codes, despite shared property names.
    var commandSuite: String { self == .appleMusic ? "hook" : "spfy" }
    var trackIDProperty: String { self == .appleMusic ? "pPIS" : "ID  " }
    var artworkURLProperty: String { "aUrl" }
}

enum MusicAvailability: String, Sendable {
    case live, notRunning, permissionRequired, denied, noTrack, timedOut, unavailable, inactive
    var message: String { NSLocalizedString("music.status." + rawValue, comment: "") }
}
struct MusicTrack: Equatable, Sendable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let duration: Double
    var artwork: Data?
    var artworkURL: URL?
    func validated() throws -> Self {
        guard !id.isEmpty, id.utf8.count <= 2048, !title.isEmpty, title.utf8.count <= 2048,
              artist.utf8.count <= 2048, album.utf8.count <= 2048,
              duration.isFinite, (0...86_400).contains(duration), (artwork?.count ?? 0) <= 4 * 1024 * 1024 else {
            throw MusicReadError.invalidResponse
        }
        return self
    }
}
struct MusicSnapshot: Equatable, Sendable {
    var availability: MusicAvailability = .inactive
    var track: MusicTrack?
    var isPlaying = false
    var position = 0.0
    var sampledAt = Date()
    func elapsed(at date: Date) -> Double {
        guard let track, position.isFinite else { return 0 }
        // Do not keep advancing indefinitely after the source has stopped replying.
        let advance = availability == .live && isPlaying ? min(12, max(0, date.timeIntervalSince(sampledAt))) : 0
        return min(track.duration, max(0, position + advance))
    }
}
enum MusicReadError: Error, Equatable { case invalidResponse, denied, timedOut, unavailable }
enum MusicControl: Sendable, Equatable { case playPause, previous, next }
enum MusicLayout: String, CaseIterable, Sendable { case poster, vinyl, aurora }
enum LyricsMode: String, CaseIterable, Sendable { case off, plain, synced }

/// Both music and optional lyrics belong to a display overlay, never to the wallpaper.
struct MusicOverlayOptions: Equatable, Sendable {
    var source = MusicSource.appleMusic
    var layout = MusicLayout.poster
    var scale = 1.0
    var opacity = 1.0
    var position = WidgetPosition(x: 0.1, y: 0.85)
    var lyrics = LyricsMode.off
    var lyricsScale = 1.0
    var lyricsPosition = WidgetPosition(x: 0.5, y: 0.92)
    static let keys: Set<String> = ["source", "layout", "scale", "opacity", "x", "y", "lyrics", "lyricsScale", "lyricsX", "lyricsY"]
    init() {}
    init(configuration: OverlayConfiguration) throws {
        _ = try configuration.validated()
        guard configuration.kind == .music, Set(configuration.parameters.keys).isSubset(of: Self.keys) else { throw OverlayError.invalidConfiguration }
        func text(_ key: String, _ fallback: String) throws -> String {
            guard let v = configuration.parameters[key] else { return fallback }
            guard case .text(let s) = v else { throw OverlayError.invalidConfiguration }; return s
        }
        func number(_ key: String, _ fallback: Double) throws -> Double {
            guard let v = configuration.parameters[key] else { return fallback }
            guard case .number(let n) = v else { throw OverlayError.invalidConfiguration }; return n
        }
        guard let source = MusicSource(rawValue: try text("source", source.rawValue)),
              let layout = MusicLayout(rawValue: try text("layout", layout.rawValue)),
              let lyrics = LyricsMode(rawValue: try text("lyrics", lyrics.rawValue)) else { throw OverlayError.invalidConfiguration }
        self.source = source; self.layout = layout; self.lyrics = lyrics
        scale = try number("scale", scale); opacity = try number("opacity", opacity)
        position = .init(x: try number("x", position.x), y: try number("y", position.y))
        lyricsScale = try number("lyricsScale", lyricsScale)
        lyricsPosition = .init(x: try number("lyricsX", lyricsPosition.x), y: try number("lyricsY", lyricsPosition.y))
        self = try validated()
    }
    func validated() throws -> Self {
        guard scale.isFinite, (0.6...2).contains(scale), lyricsScale.isFinite, (0.6...2).contains(lyricsScale),
              opacity.isFinite, (0.2...1).contains(opacity),
              [position.x, position.y, lyricsPosition.x, lyricsPosition.y].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw OverlayError.invalidConfiguration }
        return self
    }
    func applying(to configuration: OverlayConfiguration) throws -> OverlayConfiguration {
        _ = try validated(); guard configuration.kind == .music else { throw OverlayError.invalidConfiguration }
        var c = configuration
        c.parameters = ["source": .text(source.rawValue), "layout": .text(layout.rawValue), "scale": .number(scale), "opacity": .number(opacity),
                        "x": .number(position.x), "y": .number(position.y), "lyrics": .text(lyrics.rawValue),
                        "lyricsScale": .number(lyricsScale), "lyricsX": .number(lyricsPosition.x), "lyricsY": .number(lyricsPosition.y)]
        return try c.validated()
    }
    func frame(in canvas: CGSize, isLyrics: Bool = false) -> CGRect? {
        guard canvas.width.isFinite, canvas.height.isFinite, canvas.width > 0, canvas.height > 0 else { return nil }
        let base = isLyrics ? CGSize(width: 500, height: 160) : layout == .vinyl ? CGSize(width: 340, height: 160) : CGSize(width: 340, height: 130)
        let margin = min(12, canvas.width / 4, canvas.height / 4)
        let room = CGSize(width: canvas.width - 2 * margin, height: canvas.height - 2 * margin)
        let s = min(isLyrics ? lyricsScale : scale, room.width / base.width, room.height / base.height)
        let size = CGSize(width: base.width * s, height: base.height * s), p = isLyrics ? lyricsPosition : position
        return CGRect(x: margin + max(0, room.width - size.width) * p.x,
                      y: margin + max(0, room.height - size.height) * p.y, width: size.width, height: size.height)
    }
    func moved(by delta: CGSize, in canvas: CGSize, isLyrics: Bool) -> Self {
        guard delta.width.isFinite, delta.height.isFinite, let frame = frame(in: canvas, isLyrics: isLyrics) else { return self }
        var next = self, p = isLyrics ? lyricsPosition : position
        p.x = min(1, max(0, p.x + delta.width / max(1, canvas.width - 24 - frame.width)))
        p.y = min(1, max(0, p.y + delta.height / max(1, canvas.height - 24 - frame.height)))
        if isLyrics { next.lyricsPosition = p } else { next.position = p }; return next
    }
}
