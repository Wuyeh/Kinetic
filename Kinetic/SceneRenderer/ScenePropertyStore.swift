import Combine
import Foundation
import KineticSceneRuntime

struct LocalScenePreset: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    let values: [String: ScenePropertyValue]
}

struct ScenePropertyConfiguration: Codable, Equatable {
    var values: [String: ScenePropertyValue] = [:]
    var presets: [LocalScenePreset] = []
}

enum ScenePropertyStoreError: LocalizedError {
    case unreadable, incompatiblePreset, invalidName, missingPreset, limitExceeded
    var errorDescription: String? {
        switch self {
        case .unreadable: return "场景设置文件无法读取，已保留原文件。"
        case .incompatiblePreset: return "此预设不属于当前场景，或预设版本不受支持。"
        case .invalidName: return "请使用 1–80 个字符的预设名称。"
        case .missingPreset: return "此预设已不存在。"
        case .limitExceeded: return "场景设置或预设超过大小限制。"
        }
    }
}

private struct ScenePropertyDocument: Codable {
    var version = 1
    var wallpapers: [String: ScenePropertyConfiguration] = [:]
}

/// Separate from library.json format 2. Commit to disk before publishing or changing any display.
@MainActor
final class ScenePropertyStore: ObservableObject {
    @Published private(set) var configurations: [String: ScenePropertyConfiguration] = [:]
    @Published private(set) var loadError: String?
    let fileURL: URL
    static let maximumDocumentBytes = 4 * 1_024 * 1_024
    static let maximumPresetBytes = 256 * 1_024

    init(storage: LibraryStorageLocation) {
        fileURL = storage.rootURL.appendingPathComponent("scene-properties.json")
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let document = try JSONDecoder().decode(ScenePropertyDocument.self,
                from: Self.read(fileURL, maximumBytes: Self.maximumDocumentBytes))
            guard document.version == 1, document.wallpapers.count <= 10_000,
                  document.wallpapers.values.allSatisfy({ $0.presets.count <= 100 }) else {
                throw ScenePropertyStoreError.unreadable
            }
            configurations = document.wallpapers
        } catch { loadError = ScenePropertyStoreError.unreadable.localizedDescription }
    }

    func configuration(for id: Wallpaper.ID) -> ScenePropertyConfiguration {
        configurations[id.uuidString] ?? .init()
    }

    func save(values: [String: ScenePropertyValue], for wallpaper: Wallpaper,
              schema: ScenePropertySchema, runtime: WallpaperRuntimeManager?) throws {
        var configuration = configuration(for: wallpaper.id)
        configuration.values = try schema.validated(values)
        try commit(configuration, for: wallpaper.id)
        // Only explicitly enabled sessions showing THIS wallpaper are refreshed. The existing session
        // keeps its old frame until Ready, retains manual/smart pause, and handles failed replacements.
        for display in runtime?.displayIDs ?? [] {
            guard let runtime, runtime.activeWallpaper(on: display)?.id == wallpaper.id,
                  let state = runtime.state(of: display),
                  [.playing, .manualPaused, .smartPaused].contains(state.playbackState) else { continue }
            runtime.reloadActive(wallpaper, on: display)
        }
    }

    @discardableResult
    func createPreset(name: String, values: [String: ScenePropertyValue], for wallpaper: Wallpaper,
                      schema: ScenePropertySchema) throws -> UUID {
        var configuration = configuration(for: wallpaper.id)
        guard configuration.presets.count < 100 else { throw ScenePropertyStoreError.limitExceeded }
        let preset = LocalScenePreset(id: UUID(), name: try Self.validName(name), values: try schema.validated(values))
        configuration.presets.append(preset)
        try commit(configuration, for: wallpaper.id)
        return preset.id
    }

    func renamePreset(_ id: UUID, name: String, for wallpaper: Wallpaper) throws {
        var configuration = configuration(for: wallpaper.id)
        guard let index = configuration.presets.firstIndex(where: { $0.id == id }) else { throw ScenePropertyStoreError.missingPreset }
        configuration.presets[index].name = try Self.validName(name)
        try commit(configuration, for: wallpaper.id)
    }

    func deletePreset(_ id: UUID, for wallpaper: Wallpaper) throws {
        var configuration = configuration(for: wallpaper.id)
        guard configuration.presets.contains(where: { $0.id == id }) else { throw ScenePropertyStoreError.missingPreset }
        configuration.presets.removeAll { $0.id == id }
        try commit(configuration, for: wallpaper.id)
    }

    struct PresetDocument: Codable {
        var version = 1
        let wallpaperKey: String
        let name: String
        let values: [String: ScenePropertyValue]
    }

    static func identity(of wallpaper: Wallpaper) -> String {
        wallpaper.steamMetadata.map { "workshop:" + $0.workshopID } ?? "local:" + wallpaper.id.uuidString
    }

    static func exportPreset(name: String, values: [String: ScenePropertyValue], for wallpaper: Wallpaper,
                             schema: ScenePropertySchema) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(PresetDocument(wallpaperKey: identity(of: wallpaper),
            name: validName(name), values: schema.validated(values)))
        guard data.count <= maximumPresetBytes else { throw ScenePropertyStoreError.limitExceeded }
        return data
    }

    @discardableResult
    func importPreset(data: Data, for wallpaper: Wallpaper, schema: ScenePropertySchema) throws -> UUID {
        guard data.count <= Self.maximumPresetBytes else { throw ScenePropertyStoreError.limitExceeded }
        let name: String, values: [String: ScenePropertyValue]
        if let document = try? JSONDecoder().decode(PresetDocument.self, from: data) {
            guard document.version == 1, document.wallpaperKey == Self.identity(of: wallpaper) else {
                throw ScenePropertyStoreError.incompatiblePreset
            }
            name = document.name; values = document.values
        } else {
            // Community preset project.json: values only, never its entry, scripts or dependencies.
            struct CommunityPreset: Decodable {
                let type: String
                let dependency: String
                let title: String
                let preset: [String: ScenePropertyValue]
            }
            let document = try JSONDecoder().decode(CommunityPreset.self, from: data)
            guard document.type.lowercased() == "scene", document.dependency == wallpaper.steamMetadata?.workshopID else {
                throw ScenePropertyStoreError.incompatiblePreset
            }
            name = document.title
            let decorativeKeys = Set(schema.properties.filter { ["text", "group"].contains($0.kind) }.map(\.key))
            values = document.preset.filter { !decorativeKeys.contains($0.key) }
        }
        return try createPreset(name: name, values: values, for: wallpaper, schema: schema)
    }

    static func read(_ url: URL, maximumBytes: Int) throws -> Data {
        let info = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true,
              let size = info.fileSize, size <= maximumBytes else { throw ScenePropertyStoreError.limitExceeded }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= maximumBytes else { throw ScenePropertyStoreError.limitExceeded }
        return data
    }

    private static func validName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80 else { throw ScenePropertyStoreError.invalidName }
        return trimmed
    }

    private func commit(_ configuration: ScenePropertyConfiguration, for id: Wallpaper.ID) throws {
        guard loadError == nil else { throw ScenePropertyStoreError.unreadable }
        var next = configurations; next[id.uuidString] = configuration
        guard next.count <= 10_000 else { throw ScenePropertyStoreError.limitExceeded }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(ScenePropertyDocument(wallpapers: next))
        guard data.count <= Self.maximumDocumentBytes else { throw ScenePropertyStoreError.limitExceeded }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        configurations = next
    }
}
