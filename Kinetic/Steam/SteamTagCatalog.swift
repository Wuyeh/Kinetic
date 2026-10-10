import Foundation

/// R4 第 45 节：Wallpaper Engine 创意工坊的标签分组与中文名称。
///
/// 英文是创意工坊的真实标签（与参考截图逐字一致，也是 QueryFiles `requiredtags` / 返回 `tags` 使用的值）；
/// 中文只用于显示，不能反过来猜标签。筛选器（第 44–49 节）与详情窗口（第 51 节）共用这一份目录。
enum SteamTagGroup: String, CaseIterable, Identifiable, Sendable {
    case type
    case miscellaneous
    case ageRating
    case genre
    case resolution
    case category
    case assetType
    case assetGenre
    case scriptType

    var id: String { rawValue }

    /// 中文组名（本地化键 steam.tags.group.<rawValue>）。
    var titleKey: String { "steam.tags.group.\(rawValue)" }
    var title: String { NSLocalizedString(titleKey, comment: "Steam tag group") }

    /// 第 46 节：首次打开筛选器时默认展开的组。
    var isExpandedByDefault: Bool { self == .miscellaneous || self == .genre }

    /// 参考截图中的候选，顺序与截图一致（Type 组按 Kinetic 现有顺序：Scene、Web、视频，再加 Application）。
    var tags: [SteamTag] {
        switch self {
        case .type:
            return [.init("Scene", "场景"), .init("Web", "网页"), .init("Video", "视频"), .init("Application", "应用")]
        case .miscellaneous:
            return [.init("Approved", "已审核"), .init("Audio responsive", "音频响应"), .init("3D", "3D"),
                    .init("Customizable", "可自定义"), .init("Puppet Warp", "人偶变形"), .init("HDR", "HDR"),
                    .init("Media Integration", "媒体集成"), .init("User Shortcut", "用户快捷方式"),
                    .init("Video Texture", "视频纹理"), .init("Asset Pack", "资源包")]
        case .ageRating:
            return [.init("Everyone", "全年龄"), .init("Questionable", "可能不适宜"), .init("Mature", "成人")]
        case .genre:
            return [.init("Abstract", "抽象"), .init("Animal", "动物"), .init("Anime", "动漫"), .init("Cartoon", "卡通"),
                    .init("CGI", "CGI"), .init("Cyberpunk", "赛博朋克"), .init("Fantasy", "奇幻"), .init("Game", "游戏"),
                    .init("Girls", "女性角色"), .init("Guys", "男性角色"), .init("Landscape", "风景"),
                    .init("Medieval", "中世纪"), .init("Memes", "梗图"), .init("MMD", "MMD"), .init("Music", "音乐"),
                    .init("Nature", "自然"), .init("Pixel art", "像素艺术"), .init("Relaxing", "舒缓"),
                    .init("Retro", "复古"), .init("Sci-Fi", "科幻"), .init("Sports", "体育"),
                    .init("Technology", "科技"), .init("Television", "电视"), .init("Vehicle", "交通工具"),
                    .init("Unspecified", "未指定")]
        case .resolution:
            return [.init("3840 x 2160", "3840 × 2160"),
                    .init("Ultrawide Standard Definition", "超宽屏 · 标清"),
                    .init("Ultrawide 2560 x 1080", "超宽屏 · 2560 × 1080"),
                    .init("Ultrawide 3440 x 1440", "超宽屏 · 3440 × 1440"),
                    .init("Dual Standard Definition", "双屏 · 标清"),
                    .init("Dual 3840 x 1080", "双屏 · 3840 × 1080"),
                    .init("Dual 5120 x 1440", "双屏 · 5120 × 1440"),
                    .init("Dual 7680 x 2160", "双屏 · 7680 × 2160"),
                    .init("Triple Standard Definition", "三屏 · 标清"),
                    .init("Triple 4096 x 768", "三屏 · 4096 × 768"),
                    .init("Triple 5760 x 1080", "三屏 · 5760 × 1080"),
                    .init("Triple 7680 x 1440", "三屏 · 7680 × 1440"),
                    .init("Triple 11520 x 2160", "三屏 · 11520 × 2160"),
                    .init("Portrait Standard Definition", "竖屏 · 标清"),
                    .init("Portrait 720 x 1280", "竖屏 · 720 × 1280"),
                    .init("Portrait 1080 x 1920", "竖屏 · 1080 × 1920"),
                    .init("Portrait 1440 x 2560", "竖屏 · 1440 × 2560"),
                    .init("Portrait 2160 x 3840", "竖屏 · 2160 × 3840"),
                    .init("Other resolution", "其他分辨率"),
                    .init("Dynamic resolution", "动态分辨率")]
        case .category:
            return [.init("Wallpaper", "壁纸"), .init("Preset", "预设"), .init("Asset", "素材")]
        case .assetType:
            return [.init("Particle", "粒子"), .init("Image", "图片"), .init("Sound", "声音"), .init("Model", "模型"),
                    .init("Text", "文本"), .init("Sprite", "精灵"), .init("Fullscreen", "全屏"),
                    .init("Composite", "复合素材"), .init("Script", "脚本"), .init("Effect", "效果"),
                    .init("Scripted Layer", "脚本图层")]
        case .assetGenre:
            return [.init("Audio Visualizer", "音频可视化"), .init("Background", "背景"), .init("Character", "角色"),
                    .init("Clock", "时钟"), .init("Fire", "火焰"), .init("Interactive", "交互"), .init("Magic", "魔法"),
                    .init("Post Processing", "后期处理"), .init("Smoke", "烟雾"), .init("Space", "太空")]
        case .scriptType:
            return [.init("Boolean", "布尔值"), .init("Number", "数字"), .init("Vec2", "二维向量"),
                    .init("Vec3", "三维向量"), .init("Vec4", "四维向量"), .init("String", "字符串"),
                    .init("No Animation", "无动画"), .init("Oversized", "超大尺寸")]
        }
    }
}

/// 一个创意工坊标签：真实标签值 + 中文显示名。
struct SteamTag: Hashable, Identifiable, Sendable {
    let value: String
    let label: String
    var id: String { value }

    init(_ value: String, _ label: String) {
        self.value = value
        self.label = label
    }
}

enum SteamTagCatalog {
    /// 参考截图中的全部候选（不含「全部 / 未选择」），共 94 个。
    static var allTags: [SteamTag] { SteamTagGroup.allCases.flatMap(\.tags) }

    private static let index: [String: (SteamTagGroup, SteamTag)] = {
        var map: [String: (SteamTagGroup, SteamTag)] = [:]
        for group in SteamTagGroup.allCases {
            for tag in group.tags { map[tag.value.lowercased()] = (group, tag) }
        }
        return map
    }()

    /// 标签属于哪一组。目录外但明显是分辨率的标签（例如「1920 x 1080」）归入分辨率组，按原文显示。
    static func group(of tag: String) -> SteamTagGroup? {
        if let known = index[tag.lowercased()] { return known.0 }
        return looksLikeResolution(tag) ? .resolution : nil
    }

    /// 中文显示名；目录外的标签保留原文（分辨率把 x 显示为 ×）。
    static func label(for tag: String) -> String {
        if let known = index[tag.lowercased()] { return known.1.label }
        return looksLikeResolution(tag) ? tag.replacingOccurrences(of: " x ", with: " × ") : tag
    }

    /// 按组整理一个项目的标签（详情窗口：同组多个标签并列显示，不受筛选器单选限制）。
    static func grouped(_ tags: [String]) -> [SteamTagGroup: [String]] {
        var result: [SteamTagGroup: [String]] = [:]
        for tag in tags {
            guard let group = group(of: tag) else { continue }
            let label = label(for: tag)
            if result[group]?.contains(label) != true { result[group, default: []].append(label) }
        }
        return result
    }

    private static func looksLikeResolution(_ tag: String) -> Bool {
        let lower = tag.lowercased()
        let digits = lower.split(whereSeparator: { !$0.isNumber })
        return (lower.contains(" x ") && digits.count >= 2) || lower.hasSuffix("standard definition")
    }
}

/// R4 第 47 节：Steam 页面的筛选状态（只用于 Steam 在线创意工坊页）。
///
/// - 类型组沿用原「全部类型 / 具体类型可多选」的规则（新增「应用」）；四类都选中时归为全部类型。
/// - 其余 8 组每组单选：选另一项替换本组条件，「全部」只清除本组；不同组共同生效（AND）。
/// - 展开 / 收起由视图单独保存，与这里的条件无关。
struct SteamFilterState: Equatable, Sendable {
    private(set) var types: Set<String> = []
    private(set) var tags: [SteamTagGroup: String] = [:]

    var isDefault: Bool { types.isEmpty && tags.isEmpty }
    var showsAllTypes: Bool { types.isEmpty }

    func isSelected(_ tag: String, in group: SteamTagGroup) -> Bool {
        group == .type ? types.contains(tag) : tags[group] == tag
    }

    func hasSelection(in group: SteamTagGroup) -> Bool {
        group == .type ? !types.isEmpty : tags[group] != nil
    }

    mutating func showAllTypes() { types = [] }

    mutating func toggleType(_ tag: String) {
        if !types.insert(tag).inserted { types.remove(tag) }
        if types.count == SteamTagGroup.type.tags.count { types = [] }
    }

    /// 单选组：选中另一项替换本组条件；再次点按已选项保持不变（与原行点击一致）。
    mutating func select(_ tag: String, in group: SteamTagGroup) {
        guard group != .type else { return toggleType(tag) }
        tags[group] = tag
    }

    /// 「全部 / 未选择」：只清除本组。
    mutating func clear(_ group: SteamTagGroup) {
        if group == .type { types = [] } else { tags[group] = nil }
    }

    /// 选中的类型标签（按目录顺序）。
    var typeTags: [String] { SteamTagGroup.type.tags.map(\.value).filter(types.contains) }

    /// 其余组的条件（按组顺序），全部是创意工坊的真实标签。
    var groupTags: [String] { SteamTagGroup.allCases.compactMap { $0 == .type ? nil : tags[$0] } }

    /// 是否明确在找非壁纸资源（预设 / 素材）。
    var selectsNonWallpaperCategory: Bool {
        guard let category = tags[.category] else { return false }
        return category != "Wallpaper"
    }

    /// 收起时显示的单行摘要（弱强调）；没有条件时为 nil。
    func summary(for group: SteamTagGroup) -> String? {
        switch group {
        case .type:
            let labels = SteamTagGroup.type.tags.filter { types.contains($0.value) }.map(\.label)
            return labels.isEmpty ? nil : labels.joined(separator: "、")
        default:
            return tags[group].map(SteamTagCatalog.label(for:))
        }
    }
}
