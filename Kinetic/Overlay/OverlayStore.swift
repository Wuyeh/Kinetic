import Combine
import Foundation

@MainActor
final class OverlayStore: ObservableObject {
    private struct Document: Codable { var version = 1; var configurations: [OverlayConfiguration] }
    @Published private(set) var configurations: [OverlayConfiguration] = []
    @Published private(set) var loadError: String?
    let fileURL: URL
    static let maximumBytes = 1_024 * 1_024
    static let maximumConfigurations = 64
    static let maximumPerDisplay = 8

    init(storage: LibraryStorageLocation) {
        fileURL = storage.rootURL.appendingPathComponent("overlays.json")
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let info = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true,
                  (info.fileSize ?? Int.max) <= Self.maximumBytes else { throw OverlayError.settingsUnreadable }
            let data = try Data(contentsOf: fileURL)
            guard data.count <= Self.maximumBytes else { throw OverlayError.settingsUnreadable }
            let document = try JSONDecoder().decode(Document.self, from: data)
            guard document.version == 1 else { throw OverlayError.settingsUnreadable }
            configurations = try Self.validate(document.configurations)
        } catch { loadError = OverlayError.settingsUnreadable.localizedDescription }
    }

    func upsert(_ configuration: OverlayConfiguration) throws {
        var next = configurations
        if let index = next.firstIndex(where: { $0.id == configuration.id }) { next[index] = configuration }
        else { next.append(configuration) }
        try save(next)
    }
    func remove(_ id: UUID) throws { try save(configurations.filter { $0.id != id }) }
    /// Module 48: a scheme replaces one display's overlays in one atomic write; other displays are untouched.
    func replaceConfigurations(on display: DisplayID, with list: [OverlayConfiguration]) throws {
        guard list.allSatisfy({ $0.displayID == display }) else { throw OverlayError.invalidConfiguration }
        try save(configurations.filter { $0.displayID != display } + list)
    }
    func setEnabled(_ enabled: Bool, for id: UUID) throws {
        guard var configuration = configurations.first(where: { $0.id == id }) else { return }
        configuration.isEnabled = enabled; try upsert(configuration)
    }
    func setManuallyPaused(_ paused: Bool, for id: UUID) throws {
        guard var configuration = configurations.first(where: { $0.id == id }) else { return }
        configuration.isManuallyPaused = paused; try upsert(configuration)
    }

    private static func validate(_ list: [OverlayConfiguration]) throws -> [OverlayConfiguration] {
        guard list.count <= maximumConfigurations, Set(list.map(\.id)).count == list.count,
              Dictionary(grouping: list, by: \.displayID).values.allSatisfy({ $0.count <= maximumPerDisplay }) else {
            throw OverlayError.invalidConfiguration
        }
        return try list.map { try $0.validated() }
    }
    private func save(_ list: [OverlayConfiguration]) throws {
        guard loadError == nil else { throw OverlayError.settingsUnreadable }
        // Recheck before writing, including a symlink substituted since initialization.
        if let info = try? fileURL.resourceValues(forKeys: [.isSymbolicLinkKey]), info.isSymbolicLink == true {
            throw OverlayError.settingsUnreadable
        }
        let next = try Self.validate(list)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Document(configurations: next))
        guard data.count <= Self.maximumBytes else { throw OverlayError.invalidConfiguration }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        configurations = next
    }
}
