import Foundation

struct DisplayAssignmentDocument: Codable, Equatable {
    var assignments: [String: WallpaperRestorationRecord] = [:]
    var hasMigratedLegacy = false
}

/// 独立于 library.json，按资料库与稳定显示器 ID 保存；断开不删除 assignment。
@MainActor
final class DisplayAssignmentStore {
    static let storageKey = "Kinetic.DisplayAssignments.v1"
    private let defaults: UserDefaults
    private let libraryKey: String

    init(defaults: UserDefaults = .standard, library: LibraryStorageLocation) {
        self.defaults = defaults
        libraryKey = library.rootURL.path
    }

    func load() -> DisplayAssignmentDocument {
        guard let data = defaults.dictionary(forKey: Self.storageKey)?[libraryKey] as? Data,
              let result = try? JSONDecoder().decode(DisplayAssignmentDocument.self, from: data) else {
            return DisplayAssignmentDocument()
        }
        return result
    }

    func save(_ document: DisplayAssignmentDocument) {
        guard let data = try? JSONEncoder().encode(document) else { return }
        var entries = defaults.dictionary(forKey: Self.storageKey) ?? [:]
        entries[libraryKey] = data
        defaults.set(entries, forKey: Self.storageKey)
    }
}
