import Foundation

/// 描述内容及其本地资源位置；不读取文件，也不持有 UI 或渲染器。
struct Wallpaper: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    let type: WallpaperType
    let source: WallpaperSource

    /// 本地导入的副本，或 Steam 已管理的资源。
    var resourceURL: URL
    var thumbnailURL: URL?
    var isFavorite: Bool
    var steamMetadata: SteamMetadata?

    /// 支持状态只描述 v0.1 的类型能力，不代表资源已加载或通过校验。
    var supportState: WallpaperSupportState { type.supportState }

    init(
        id: UUID = UUID(),
        name: String,
        type: WallpaperType,
        source: WallpaperSource,
        resourceURL: URL,
        thumbnailURL: URL? = nil,
        isFavorite: Bool = false,
        steamMetadata: SteamMetadata? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.source = source
        self.resourceURL = resourceURL
        self.thumbnailURL = thumbnailURL
        self.isFavorite = isFavorite
        self.steamMetadata = steamMetadata
    }
}

struct SteamMetadata: Codable, Equatable, Sendable {
    let workshopID: String
    var author: String?
    var sizeInBytes: Int64?

    init(workshopID: String, author: String? = nil, sizeInBytes: Int64? = nil) {
        self.workshopID = workshopID
        self.author = author
        self.sizeInBytes = sizeInBytes
    }
}
