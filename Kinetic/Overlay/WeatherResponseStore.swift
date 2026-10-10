import Combine
import Foundation

@MainActor
final class WeatherResponseStore: ObservableObject {
    private struct Document: Codable { var version = 1; var configurations: [WeatherResponseConfiguration] }
    @Published private(set) var configurations: [WeatherResponseConfiguration] = []
    @Published private(set) var loadError: String?
    let fileURL: URL
    static let maximumBytes = 128 * 1_024
    init(storage: LibraryStorageLocation) {
        fileURL = storage.rootURL.appendingPathComponent("weather-response.json")
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  (values.fileSize ?? Int.max) <= Self.maximumBytes else { throw WeatherError.settingsUnreadable }
            let decoded = try JSONDecoder().decode(Document.self, from: Data(contentsOf: fileURL))
            guard decoded.version == 1 else { throw WeatherError.settingsUnreadable }
            configurations = try Self.validated(decoded.configurations)
        } catch { loadError = WeatherError.settingsUnreadable.localizedDescription }
    }
    func upsert(_ value: WeatherResponseConfiguration) throws {
        var next = configurations
        if let index = next.firstIndex(where: { $0.overlayID == value.overlayID }) { next[index] = value }
        else { next.append(value) }
        try save(next)
    }
    private static func validated(_ values: [WeatherResponseConfiguration]) throws -> [WeatherResponseConfiguration] {
        guard values.count <= 64, Set(values.map(\.overlayID)).count == values.count,
              Dictionary(grouping: values, by: \.displayID).values.allSatisfy({ $0.count <= OverlayStore.maximumPerDisplay }) else {
            throw OverlayError.invalidConfiguration
        }
        return try values.map { try $0.validated() }
    }
    private func save(_ values: [WeatherResponseConfiguration]) throws {
        guard loadError == nil else { throw WeatherError.settingsUnreadable }
        if let values = try? fileURL.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true { throw WeatherError.settingsUnreadable }
        let next = try Self.validated(values), encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Document(configurations: next))
        guard data.count <= Self.maximumBytes else { throw WeatherError.settingsUnreadable }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic); configurations = next
    }
}
