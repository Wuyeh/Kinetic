import CryptoKit
import Foundation

struct LyricLine: Codable, Equatable, Sendable { let time: Double; let text: String }
struct TrackLyrics: Codable, Equatable, Sendable {
    var plain: String
    var lines: [LyricLine]
    var instrumental: Bool
    func currentIndex(at seconds: Double) -> Int? {
        guard seconds.isFinite else { return nil }
        return lines.lastIndex { $0.time <= seconds }
    }
    static func parseLRC(_ source: String, duration: Double) -> [LyricLine] {
        // Non-zero offsets require a verified timing convention; prefer plain text to false synchronization.
        guard source.utf8.count <= 256 * 1024, duration.isFinite, duration > 0,
              !source.lowercased().contains("[offset:") else { return [] }
        let regex = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]"#)
        var result: [LyricLine] = []
        for line in source.components(separatedBy: .newlines).prefix(2000) {
            let ns = line as NSString, matches = regex.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard let end = matches.last?.range.upperBound else { continue }
            let text = ns.substring(from: end).trimmingCharacters(in: .whitespaces)
            guard text.utf8.count <= 4096 else { return [] }
            for match in matches {
                let minute = Double(ns.substring(with: match.range(at: 1))) ?? 0
                let second = Double(ns.substring(with: match.range(at: 2))) ?? 0
                guard second < 60 else { return [] }
                let fraction = match.range(at: 3).location == NSNotFound ? "" : ns.substring(with: match.range(at: 3))
                let time = minute * 60 + second + (Double("0." + fraction) ?? 0)
                guard time <= duration + 2 else { return [] }
                result.append(.init(time: time, text: text))
                guard result.count <= 2000 else { return [] }
            }
        }
        // Conflicting duplicate timestamps cannot be treated as reliable synchronization.
        result.sort { $0.time < $1.time }
        guard zip(result, result.dropFirst()).allSatisfy({ $0.time < $1.time }) else { return [] }
        return result
    }
}
enum LyricsError: Error { case unavailable, tooLarge, invalidResponse }
protocol LyricsFetching: Sendable { func fetch(_ track: MusicTrack) async throws -> TrackLyrics }

private final class LyricsRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
final class LRCLIBClient: LyricsFetching, @unchecked Sendable {
    static let responseLimit = 512 * 1024
    private let session: URLSession
    private let redirects = LyricsRedirectPolicy()
    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.timeoutIntervalForRequest = 12; configuration.timeoutIntervalForResource = 15
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        session = URLSession(configuration: configuration)
    }
    static func url(_ track: MusicTrack) throws -> URL {
        _ = try track.validated()
        guard !track.artist.isEmpty, (1...3600).contains(track.duration) else { throw LyricsError.unavailable }
        var c = URLComponents(); c.scheme = "https"; c.host = "lrclib.net"; c.path = "/api/get"
        c.queryItems = [URLQueryItem(name: "track_name", value: track.title), .init(name: "artist_name", value: track.artist),
                        .init(name: "album_name", value: track.album), .init(name: "duration", value: String(Int(track.duration.rounded())))]
        guard let url = c.url else { throw LyricsError.invalidResponse }; return url
    }
    func fetch(_ track: MusicTrack) async throws -> TrackLyrics {
        var request = URLRequest(url: try Self.url(track)); request.setValue("Kinetic/1.0 (macOS desktop lyrics)", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request, delegate: redirects)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.url?.scheme == "https", response.url?.host == "lrclib.net" else { throw LyricsError.unavailable }
        guard response.expectedContentLength <= Self.responseLimit else { throw LyricsError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation(); guard data.count < Self.responseLimit else { throw LyricsError.tooLarge }; data.append(byte)
        }
        return try Self.decode(data, matching: track)
    }
    static func decode(_ data: Data, matching track: MusicTrack) throws -> TrackLyrics {
        guard data.count <= responseLimit else { throw LyricsError.tooLarge }
        struct Response: Decodable { let trackName: String; let artistName: String; let albumName: String?; let duration: Double; let instrumental: Bool; let plainLyrics: String?; let syncedLyrics: String? }
        let value = try JSONDecoder().decode(Response.self, from: data)
        func normalized(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .init(identifier: "en_US_POSIX")) }
        guard normalized(value.trackName) == normalized(track.title), normalized(value.artistName) == normalized(track.artist),
              track.album.isEmpty || value.albumName.map(normalized) == normalized(track.album),
              value.duration.isFinite, abs(value.duration - track.duration) <= 2,
              (value.plainLyrics?.utf8.count ?? 0) <= 256 * 1024 else { throw LyricsError.invalidResponse }
        let lines = TrackLyrics.parseLRC(value.syncedLyrics ?? "", duration: track.duration)
        return .init(plain: value.plainLyrics ?? lines.map(\.text).joined(separator: "\n"), lines: lines, instrumental: value.instrumental)
    }
}

/// Bounded successful-result cache; malformed/future files are preserved rather than overwritten.
actor LyricsRepository {
    private struct Entry: Codable { let key: String; let date: Date; let lyrics: TrackLyrics }
    private struct Cache: Codable { var version = 1; var entries: [Entry] }
    private let client: any LyricsFetching
    private let file: URL?
    private var loaded = false, writable = true
    private var entries: [Entry] = []
    init(client: any LyricsFetching = LRCLIBClient(), file: URL? = nil) { self.client = client; self.file = file }
    static func key(_ track: MusicTrack) -> String {
        SHA256.hash(data: Data([track.title, track.artist, track.album, String(Int(track.duration.rounded()))].joined(separator: "\u{1f}").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
    func lyrics(for track: MusicTrack) async throws -> TrackLyrics {
        _ = try track.validated(); load()
        let key = Self.key(track)
        if let entry = entries.first(where: { $0.key == key && (0..<30 * 86400).contains(Date().timeIntervalSince($0.date)) }) { return entry.lyrics }
        let result = try await client.fetch(track); try Task.checkCancellation()
        entries.removeAll { $0.key == key }; entries.insert(.init(key: key, date: Date(), lyrics: result), at: 0)
        entries = Array(entries.prefix(32)); save(); return result
    }
    private func load() {
        guard !loaded else { return }; loaded = true
        guard let file, FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let meta = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
            guard meta.isSymbolicLink != true, (meta.fileSize ?? Int.max) <= 1024 * 1024 else { writable = false; return }
            let cache = try JSONDecoder().decode(Cache.self, from: Data(contentsOf: file))
            guard cache.version == 1, cache.entries.count <= 32, cache.entries.allSatisfy({
                $0.key.count == 64 && $0.lyrics.plain.utf8.count <= 256 * 1024 && $0.lyrics.lines.count <= 2000
                && $0.lyrics.lines.allSatisfy { $0.time.isFinite && (0...86_402).contains($0.time) && $0.text.utf8.count <= 4096 }
                && zip($0.lyrics.lines, $0.lyrics.lines.dropFirst()).allSatisfy { $0.time < $1.time }
            }) else { writable = false; return }
            entries = cache.entries
        } catch { writable = false }
    }
    private func save() {
        guard writable, let file else { return }
        do {
            var encoded = try JSONEncoder().encode(Cache(entries: entries))
            while encoded.count > 1024 * 1024 && !entries.isEmpty { entries.removeLast(); encoded = try JSONEncoder().encode(Cache(entries: entries)) }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return }
            try encoded.write(to: file, options: .atomic)
        } catch { /* A cache-write failure never removes valid lyrics from the current presentation. */ }
    }
}
