import Foundation

/// Kinetic 1.0：本地资料库中的一条壁纸记录（规格 3 的 WallpaperRecord）。
/// 只要已经保存到本机并加入资料库，就属于「本地」；`acquisitionOrigin` 只记录来源历史，不决定显示在哪一页。
/// 不读取文件，也不持有 UI 或渲染器。
struct Wallpaper: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    let type: WallpaperType
    /// 来源历史：本地导入、Steam 创意工坊、Apple 航拍、内置演示……不能通过路径推断。
    let acquisitionOrigin: AcquisitionOrigin

    /// Kinetic 管理的本机资源（复制进 Library Storage 的内容，或 Steam 已下载的内容）。
    var resourceURL: URL
    /// 海报（Poster）。
    var thumbnailURL: URL?
    var isFavorite: Bool
    /// 加入「喜爱」的时间（Content Header：喜爱页面的「添加时间」）；取消喜爱时清空。
    /// 这个字段出现之前加入的喜爱没有时间。
    var favoritedAt: Date?
    var steamMetadata: SteamMetadata?
    /// 加入资料库的时间；1.0 之前加入的记录没有这个时间。
    var importedAt: Date?
    /// 内容最近一次更新的时间（导入，或以后的 Steam 更新）；收藏等偏好变化不算。
    var updatedAt: Date?
    /// 每张壁纸自己的播放设置（由 Advanced Video / Advanced Web 等模块填写）。
    var settings: PerWallpaperSettings

    /// 支持状态只描述类型能力，不代表资源已加载或通过校验。
    var supportState: WallpaperSupportState { type.supportState }

    /// v0.1 的来源分类，只供尚未迁移到 1.0 的界面显示「本地 / Steam」文字使用；
    /// 资料库分页不再使用它（规格 3：不要再用 source 决定 Sidebar）。
    var source: WallpaperSource { acquisitionOrigin == .steamWorkshop ? .steam : .local }

    init(
        id: UUID = UUID(),
        name: String,
        type: WallpaperType,
        acquisitionOrigin: AcquisitionOrigin,
        resourceURL: URL,
        thumbnailURL: URL? = nil,
        isFavorite: Bool = false,
        favoritedAt: Date? = nil,
        steamMetadata: SteamMetadata? = nil,
        importedAt: Date? = nil,
        updatedAt: Date? = nil,
        settings: PerWallpaperSettings = PerWallpaperSettings()
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.acquisitionOrigin = acquisitionOrigin
        self.resourceURL = resourceURL
        self.thumbnailURL = thumbnailURL
        self.isFavorite = isFavorite
        self.favoritedAt = favoritedAt
        self.steamMetadata = steamMetadata
        self.importedAt = importedAt
        self.updatedAt = updatedAt
        self.settings = settings
    }

    /// v0.1 兼容入口：旧的来源分类直接对应来源历史（本地 → 本地导入，Steam → Steam 创意工坊）。
    /// 新代码使用 `acquisitionOrigin`。
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
        self.init(id: id, name: name, type: type, acquisitionOrigin: AcquisitionOrigin(legacySource: source),
                  resourceURL: resourceURL, thumbnailURL: thumbnailURL, isFavorite: isFavorite,
                  steamMetadata: steamMetadata)
    }

    // MARK: - Codable（兼容 v0.1 记录）

    private enum CodingKeys: String, CodingKey {
        case id, name, type, acquisitionOrigin, resourceURL, thumbnailURL, isFavorite, favoritedAt, steamMetadata
        case importedAt, updatedAt, settings
        /// v0.1 的旧字段，只读取、不再写入。
        case source
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decode(WallpaperType.self, forKey: .type)
        if let origin = try container.decodeIfPresent(AcquisitionOrigin.self, forKey: .acquisitionOrigin) {
            acquisitionOrigin = origin
        } else {
            // v0.1 记录：只有 local / steam 两种来源，按记录本身的字段迁移，不看路径。
            acquisitionOrigin = AcquisitionOrigin(legacySource: try container.decode(WallpaperSource.self, forKey: .source))
        }
        resourceURL = try container.decode(URL.self, forKey: .resourceURL)
        thumbnailURL = try container.decodeIfPresent(URL.self, forKey: .thumbnailURL)
        isFavorite = try container.decode(Bool.self, forKey: .isFavorite)
        favoritedAt = try container.decodeIfPresent(Date.self, forKey: .favoritedAt)
        steamMetadata = try container.decodeIfPresent(SteamMetadata.self, forKey: .steamMetadata)
        importedAt = try container.decodeIfPresent(Date.self, forKey: .importedAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        settings = try container.decodeIfPresent(PerWallpaperSettings.self, forKey: .settings) ?? PerWallpaperSettings()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(type, forKey: .type)
        try container.encode(acquisitionOrigin, forKey: .acquisitionOrigin)
        try container.encode(resourceURL, forKey: .resourceURL)
        try container.encodeIfPresent(thumbnailURL, forKey: .thumbnailURL)
        try container.encode(isFavorite, forKey: .isFavorite)
        try container.encodeIfPresent(favoritedAt, forKey: .favoritedAt)
        try container.encodeIfPresent(steamMetadata, forKey: .steamMetadata)
        try container.encodeIfPresent(importedAt, forKey: .importedAt)
        try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
        try container.encode(settings, forKey: .settings)
    }
}

/// Kinetic 1.0（规格 3）：壁纸是从哪里得到的。只记录来源历史，不决定资料库归属。
enum AcquisitionOrigin: String, Codable, CaseIterable, Sendable {
    /// 从 Finder / 文件选择导入到本机。
    case localImport
    /// 从 Steam 创意工坊下载到本机。
    case steamWorkshop
    /// Mac 已下载的 Apple 航拍（Module 32）。
    case appleAerial
    /// Kinetic 随 App 提供的演示壁纸（Welcome）。
    case bundledDemo
    /// 以后从其他线上来源下载并保存到本机的内容。
    case futureRemoteSource

    init(legacySource: WallpaperSource) {
        self = legacySource == .steam ? .steamWorkshop : .localImport
    }
}

/// 每张壁纸自己的播放设置。1.0 的 Advanced Video / Advanced Web 模块在这里增加字段（都要可选，保证旧记录可读）。
struct PerWallpaperSettings: Codable, Equatable, Sendable {
    init() {}
}

/// 本机资源是否还在（例如用户在 Finder 中删除了资料库目录里的文件）。由资料库在读取与修改时检查，不写入记录。
enum WallpaperAvailability: String, Sendable {
    case available
    case missing
}

struct SteamMetadata: Codable, Equatable, Sendable {
    let workshopID: String
    var author: String?
    var sizeInBytes: Int64?
    /// 1.0 Module 9：下载时创意工坊项目的最后更新时间。在线商店据此判断「有更新」。可选字段，资料库格式仍为 2。
    var remoteUpdatedAt: Date?

    init(workshopID: String, author: String? = nil, sizeInBytes: Int64? = nil, remoteUpdatedAt: Date? = nil) {
        self.workshopID = workshopID
        self.author = author
        self.sizeInBytes = sizeInBytes
        self.remoteUpdatedAt = remoteUpdatedAt
    }
}
