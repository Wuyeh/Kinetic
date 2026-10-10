import Combine
import Foundation

/// A separate sidecar; no Library schema changes or automatic file creation.
@MainActor
final class WeatherStore: ObservableObject {
    private struct Document: Codable {
        var version = 1
        var configuration = WeatherConfiguration()
        var cache: [WeatherSnapshot] = []
        var lastSystemPlace: WeatherPlace?
    }
    @Published private(set) var configuration = WeatherConfiguration()
    @Published private(set) var loadError: String?
    private var document = Document()
    let fileURL: URL
    static let maximumBytes = 256 * 1_024
    static let maximumSnapshots = 16
    private let now: () -> Date

    init(storage: LibraryStorageLocation, now: @escaping () -> Date = Date.init) {
        self.now = now; fileURL = storage.rootURL.appendingPathComponent("weather.json")
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  (values.fileSize ?? Int.max) <= Self.maximumBytes else { throw WeatherError.settingsUnreadable }
            let decoded = try JSONDecoder().decode(Document.self, from: Data(contentsOf: fileURL))
            _ = try validated(decoded)
            document = decoded; configuration = decoded.configuration
        } catch { loadError = WeatherError.settingsUnreadable.localizedDescription }
    }
    func saveConfiguration(_ configuration: WeatherConfiguration) throws {
        var next = document; next.configuration = try configuration.validated(); try save(next)
    }
    func saveSnapshot(_ snapshot: WeatherSnapshot, system: Bool) throws {
        _ = try snapshot.validated(now: now())
        var next = document
        next.cache.removeAll { $0.place.matches(snapshot.place) }; next.cache.insert(snapshot, at: 0)
        next.cache = Array(next.cache.prefix(Self.maximumSnapshots))
        if system { next.lastSystemPlace = snapshot.place }
        try save(next)
    }
    var lastSystemPlace: WeatherPlace? { document.lastSystemPlace }
    func cached(for place: WeatherPlace) -> WeatherSnapshot? {
        document.cache.first { $0.place.matches(place) && (try? $0.validated(now: now())) != nil }?.cached(at: now())
    }
    private func validated(_ value: Document) throws -> Document {
        guard value.version == 1, value.cache.count <= Self.maximumSnapshots else { throw WeatherError.settingsUnreadable }
        _ = try value.configuration.validated()
        if let place = value.lastSystemPlace { _ = try place.validated() }
        for snapshot in value.cache { _ = try snapshot.validated(now: now()) }
        guard Set(value.cache.map { $0.place.id + ":" + String($0.place.latitude) + ":" + String($0.place.longitude) }).count == value.cache.count else {
            throw WeatherError.settingsUnreadable
        }
        return value
    }
    private func save(_ value: Document) throws {
        guard loadError == nil else { throw WeatherError.settingsUnreadable }
        if let values = try? fileURL.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true { throw WeatherError.settingsUnreadable }
        let next = try validated(value), encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(next)
        guard data.count <= Self.maximumBytes else { throw WeatherError.settingsUnreadable }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        document = next; configuration = next.configuration
    }
}
