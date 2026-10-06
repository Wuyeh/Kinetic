import Foundation

/// Kinetic 1.0 Content Header 修订：内容页面（本地、Steam、喜爱、壁纸列表）的排序与显示选项。
/// 搜索页面不使用。各页面各有一份；排序与类型筛选是两个独立的状态。
enum ContentSortMode: String, CaseIterable, Codable, Sendable {
    /// 添加时间：本地 = 加入资料库，喜爱 = 加入喜爱，列表 = 加入该列表，Steam = 创意工坊发布时间。
    case dateAdded
    /// 卡片显示的名称。
    case name
    /// 壁纸类型（固定顺序：Scene、Web、视频）。只是排序，不改变显示哪些类型。
    case type

    var titleKey: String { "content.sort.\(rawValue)" }
}

/// 显示哪些类型。只有两种有效状态：全部类型，或 1–2 种具体类型；
/// 三种都选中会归一为「全部类型」，也不存在一种都不选的状态。
enum ContentTypeFilter: Equatable, Sendable {
    case all
    case only(Set<WallpaperType>)

    static let allTypes = Set(WallpaperType.allCases)

    /// 归一：空集合与包含全部类型的集合都等于「全部类型」。
    static func normalized(_ types: Set<WallpaperType>) -> ContentTypeFilter {
        let valid = types.intersection(allTypes)
        return valid.isEmpty || valid == allTypes ? .all : .only(valid)
    }

    func includes(_ type: WallpaperType) -> Bool {
        switch self {
        case .all: return true
        case .only(let types): return types.contains(type)
        }
    }
}

struct ContentViewOptions: Equatable, Sendable {
    var sortMode: ContentSortMode = .dateAdded
    private(set) var typeFilter: ContentTypeFilter = .all

    init(sortMode: ContentSortMode = .dateAdded, typeFilter: ContentTypeFilter = .all) {
        self.sortMode = sortMode
        switch typeFilter {
        case .all: self.typeFilter = .all
        case .only(let types): self.typeFilter = ContentTypeFilter.normalized(types)
        }
    }

    /// 弹出框中的显示顺序。
    static let displayedTypes: [WallpaperType] = [.scene, .web, .video]

    var showsAllTypes: Bool { typeFilter == .all }

    /// 具体类型旁是否显示勾号：「全部类型」时三项都不显示勾号。
    func isChecked(_ type: WallpaperType) -> Bool {
        if case .only(let types) = typeFilter { return types.contains(type) }
        return false
    }

    /// 点「全部类型」：总是回到全部类型。
    mutating func showAllTypes() {
        typeFilter = .all
    }

    /// 点某个具体类型：取消「全部类型」并多选；三种都选中归一为全部类型；
    /// 取消最后一个具体类型时回到全部类型，而不是变成空的筛选。
    mutating func toggle(_ type: WallpaperType) {
        switch typeFilter {
        case .all:
            typeFilter = .only([type])
        case .only(var types):
            if types.contains(type) { types.remove(type) } else { types.insert(type) }
            typeFilter = ContentTypeFilter.normalized(types)
        }
    }
}

/// 把排序与显示选项应用到一个页面的壁纸上。页面只提供数据与「添加时间」的含义。
enum ContentQuery {
    /// 类型排序的固定顺序。
    static let typeOrder: [WallpaperType] = [.scene, .web, .video]

    /// - Parameters:
    ///   - wallpapers: 页面的数据，按页面原有顺序（例如资料库中最新加入的在前）。
    ///   - dateAdded: 本页面「添加时间」的含义；没有时间的排在有时间的之后，保持原有顺序。
    ///   - isPinned: 只有「本地」页面传入：置顶组始终在前，排序只在置顶组与普通组内部进行。
    static func apply(_ options: ContentViewOptions, to wallpapers: [Wallpaper],
                      dateAdded: (Wallpaper) -> Date?,
                      isPinned: (Wallpaper.ID) -> Bool = { _ in false }) -> [Wallpaper] {
        let indexed = wallpapers.enumerated()
            .filter { options.typeFilter.includes($0.element.type) }
            .map { Entry(index: $0.offset, wallpaper: $0.element, date: dateAdded($0.element),
                         pinned: isPinned($0.element.id)) }
        return indexed.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            return precedes(a, b, by: options.sortMode)
        }.map(\.wallpaper)
    }

    private struct Entry {
        let index: Int
        let wallpaper: Wallpaper
        let date: Date?
        let pinned: Bool
    }

    /// 严格全序：最后总以原有顺序决定，所以每次刷新结果都一样。
    private static func precedes(_ a: Entry, _ b: Entry, by mode: ContentSortMode) -> Bool {
        switch mode {
        case .dateAdded:
            if let order = compareDates(a.date, b.date) { return order }
        case .name:
            if let order = compareNames(a.wallpaper.name, b.wallpaper.name) { return order }
        case .type:
            let ta = typeOrder.firstIndex(of: a.wallpaper.type) ?? typeOrder.count
            let tb = typeOrder.firstIndex(of: b.wallpaper.type) ?? typeOrder.count
            if ta != tb { return ta < tb }
            if let order = compareNames(a.wallpaper.name, b.wallpaper.name) { return order }
        }
        return a.index < b.index
    }

    /// 新的在前；没有时间的在后。相同返回 nil。
    private static func compareDates(_ a: Date?, _ b: Date?) -> Bool? {
        switch (a, b) {
        case let (a?, b?): return a == b ? nil : a > b
        case (.some, .none): return true
        case (.none, .some): return false
        case (.none, .none): return nil
        }
    }

    /// 面向用户阅读的本地化比较（数字按数值、忽略大小写）。相同返回 nil。
    private static func compareNames(_ a: String, _ b: String) -> Bool? {
        let result = a.localizedStandardCompare(b)
        return result == .orderedSame ? nil : result == .orderedAscending
    }
}

extension ContentQuery {
    /// 1.0 Module 14：Steam 在线商店的项目（不是本地记录）使用同一套排序与类型筛选规则。
    /// 类型未知的项目只在「全部类型」时显示。
    static func apply<Item>(_ options: ContentViewOptions, to items: [Item],
                            name: (Item) -> String, type: (Item) -> WallpaperType?,
                            dateAdded: (Item) -> Date?) -> [Item] {
        let entries = items.enumerated().compactMap { offset, item -> StoreEntry<Item>? in
            let itemType = type(item)
            if !options.showsAllTypes {
                guard let itemType, options.typeFilter.includes(itemType) else { return nil }
            }
            return StoreEntry(index: offset, item: item, name: name(item), type: itemType, date: dateAdded(item))
        }
        return entries.sorted { a, b in
            switch options.sortMode {
            case .dateAdded:
                if let order = compareDates(a.date, b.date) { return order }
            case .name:
                if let order = compareNames(a.name, b.name) { return order }
            case .type:
                let ta = a.type.flatMap { typeOrder.firstIndex(of: $0) } ?? typeOrder.count
                let tb = b.type.flatMap { typeOrder.firstIndex(of: $0) } ?? typeOrder.count
                if ta != tb { return ta < tb }
                if let order = compareNames(a.name, b.name) { return order }
            }
            return a.index < b.index
        }.map { $0.item }
    }

    private struct StoreEntry<Value> {
        let index: Int
        let item: Value
        let name: String
        let type: WallpaperType?
        let date: Date?
    }
}
