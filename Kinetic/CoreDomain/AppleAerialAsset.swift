import Foundation

/// An already-downloaded Apple asset, independent of Library membership and playback.
struct AppleAerialAsset: Identifiable, Equatable, Sendable {
    let id: String
    let url: URL
    let name: String
    let category: String?
    let sizeInBytes: Int64

    init(id: UUID, url: URL, name: String, category: String?, sizeInBytes: Int64) {
        self.id = id.uuidString; self.url = url; self.name = name
        self.category = category; self.sizeInBytes = sizeInBytes
    }

    func matches(_ wallpaper: Wallpaper) -> Bool {
        wallpaper.acquisitionOrigin == .appleAerial && wallpaper.type == .video
            && wallpaper.resourceURL.deletingPathExtension().lastPathComponent.uppercased() == id
    }
    func matchesSearch(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || [name, category ?? "", id].contains {
            $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
    var previewWallpaper: Wallpaper {
        Wallpaper(id: UUID(uuidString: id)!, name: name, type: .video,
                  acquisitionOrigin: .appleAerial, resourceURL: url)
    }
}
