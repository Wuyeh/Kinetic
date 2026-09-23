import Foundation

/// 资料库分类：喜爱 / 全部 / 本地 / Steam 创意工坊。
enum LibraryFilter: String, CaseIterable, Sendable {
    case all
    case local
    case steam
    case favorites

    func includes(_ wallpaper: Wallpaper) -> Bool {
        switch self {
        case .all: return true
        case .local: return wallpaper.source == .local
        case .steam: return wallpaper.source == .steam
        case .favorites: return wallpaper.isFavorite
        }
    }
}

extension WallpaperType {
    /// 本地化显示名称，同时用于本地搜索匹配。
    var localizedName: String {
        NSLocalizedString("wallpaper.type.\(rawValue)", comment: "Wallpaper type")
    }
}

extension WallpaperSource {
    var localizedName: String {
        NSLocalizedString("wallpaper.source.\(rawValue)", comment: "Wallpaper source")
    }
}

/// 只匹配本地已存储的 metadata，绝不联网。
enum LibrarySearch {
    /// 以空白分隔的每个关键词都必须命中名称、类型、来源或 Steam 作者之一；忽略大小写、变音符与全半角。
    static func matches(_ wallpaper: Wallpaper, query: String) -> Bool {
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !terms.isEmpty else { return true }
        var fields = [wallpaper.name, wallpaper.type.localizedName, wallpaper.source.localizedName]
        if let author = wallpaper.steamMetadata?.author { fields.append(author) }
        return terms.allSatisfy { term in
            fields.contains { $0.range(of: term, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil }
        }
    }
}
