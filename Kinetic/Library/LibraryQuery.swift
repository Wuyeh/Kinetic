import Foundation

/// Kinetic 1.0 Module 7：资料库只维护「本地」——所有已经保存到本机的壁纸，不论来源（规格 2、3）。
/// 旧的「全部 / 本地 / Steam」三种查询已删除：来源（`acquisitionOrigin`）不再决定显示在哪一页，
/// Steam 页面是在线商店（Module 14），不是本地筛选。
enum LibraryFilter: String, CaseIterable, Sendable {
    /// 资料库中的全部记录。
    case local
    /// 资料库中且已喜爱的记录。
    case favorites

    func includes(_ wallpaper: Wallpaper) -> Bool {
        switch self {
        case .local: return true
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

extension AcquisitionOrigin {
    /// 来源的本地化名称，同时用于本地搜索匹配。
    var localizedName: String {
        NSLocalizedString("wallpaper.origin.\(rawValue)", comment: "Wallpaper acquisition origin")
    }
}

/// 只匹配本地已存储的 metadata，绝不联网。
enum LibrarySearch {
    /// 以空白分隔的每个关键词都必须命中名称、类型、来源或 Steam 作者之一；忽略大小写、变音符与全半角。
    static func matches(_ wallpaper: Wallpaper, query: String) -> Bool {
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !terms.isEmpty else { return true }
        var fields = [wallpaper.name, wallpaper.type.localizedName, wallpaper.acquisitionOrigin.localizedName]
        if let author = wallpaper.steamMetadata?.author { fields.append(author) }
        return terms.allSatisfy { term in
            fields.contains { $0.range(of: term, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil }
        }
    }
}
