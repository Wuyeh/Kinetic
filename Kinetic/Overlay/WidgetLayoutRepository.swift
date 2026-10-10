import Foundation

/// Immutable payloads: only OverlayStore's atomic pointer commit makes a draft live.
@MainActor
final class WidgetLayoutRepository {
    let directory: URL
    private var cache: [UUID: WidgetBoardLayout] = [:]
    private var order: [UUID] = []
    static let maximumRevisions = 128
    static let maximumCachedLayouts = 8
    var cachedLayoutCount: Int { cache.count }

    init(storage: LibraryStorageLocation) { directory = storage.rootURL.appendingPathComponent("WidgetBoardLayouts", isDirectory: true) }
    private func checkDirectory() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            let value = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard value.isSymbolicLink != true, value.isDirectory == true else { throw WidgetBoardError.unreadableLayout }
        }
    }
    func url(for id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
    func load(_ id: UUID) throws -> WidgetBoardLayout {
        try checkDirectory()
        // Recheck file identity/limits even when cached, so deleted/replaced payloads are not masked.
        let file = url(for: id)
        let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true, (info.fileSize ?? Int.max) <= WidgetBoardLayout.maximumBytes else {
            throw WidgetBoardError.unreadableLayout
        }
        let value = try WidgetBoardLayout.decode(Data(contentsOf: file))
        remember(value, id: id); return value
    }
    func write(_ layout: WidgetBoardLayout, keeping references: Set<UUID>) throws -> UUID {
        let data = try layout.encoded(); try checkDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        prune(keeping: references)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard files.count < Self.maximumRevisions else { throw WidgetBoardError.storageFull }
        let id = UUID(), file = url(for: id)
        guard !FileManager.default.fileExists(atPath: file.path) else { throw WidgetBoardError.unreadableLayout }
        try data.write(to: file, options: .atomic); remember(layout, id: id); return id
    }
    func discard(_ id: UUID) {
        guard (try? checkDirectory()) != nil else { return }
        try? FileManager.default.removeItem(at: url(for: id)); forget(id)
    }
    func prune(keeping references: Set<UUID>) {
        guard (try? checkDirectory()) != nil,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]),
              files.count <= 4_096 else { return }
        for file in files {
            guard file.pathExtension == "json", let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  !references.contains(id), (try? load(id)) != nil else { continue }
            discard(id) // Only valid, unreferenced v1 payloads owned by this folder; preserve unknown/corrupt files.
        }
    }
    static func references(in configurations: [OverlayConfiguration]) -> Set<UUID> {
        // A future/unsupported reference still owns its payload. Never prune it just
        // because this version cannot activate that board.
        Set(configurations.compactMap { configuration in
            guard configuration.kind == .widgets,
                  case .text(let id) = configuration.parameters["widgetLayout"] else { return nil }
            return UUID(uuidString: id)
        })
    }
    private func remember(_ value: WidgetBoardLayout, id: UUID) {
        cache[id] = value; order.removeAll { $0 == id }; order.append(id)
        while order.count > Self.maximumCachedLayouts { cache[order.removeFirst()] = nil }
    }
    private func forget(_ id: UUID) { cache[id] = nil; order.removeAll { $0 == id } }
    func clearCache() { cache = [:]; order = [] }
}
