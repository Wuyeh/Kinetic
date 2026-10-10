import Foundation

/// R4 UI-MS6 / MS9：Steam 多选后的批量动作（下载、加入壁纸列表、标记喜爱）。
///
/// - 复用 Module 9 的单项获取（`SteamAcquisitionService.acquire`）：不另造下载引擎，下载 = 加入本地资料库，绝不应用、
///   不打开显示器选择、不改变 controlledDisplayID。
/// - 已在本地的项目跳过下载、不重复建记录、不播放「刚下载完成」动画；在线项目先下载、校验、入库，成功后才加入列表 / 喜爱，
///   所以列表里永远没有悬空的在线引用，也不会伪造本地喜爱。
/// - 每个任务独立完成；完成动画由 `SteamDownloadPresentation` 按实际完成顺序排队，一次只播一张（Module 15）。
/// - 重复执行是幂等的：同一编号只处理一次，已喜爱 / 已在列表视为成功。
@MainActor
final class SteamBatchTransaction {
    enum Action: Equatable {
        case download
        case addToList(id: UUID, name: String)
        case favorite
    }

    enum Outcome: Equatable {
        /// 这次下载并加入了本地资料库。
        case downloaded(Wallpaper.ID)
        /// 已在本地：跳过下载。
        case alreadyLocal(Wallpaper.ID)
        case failed(String)
    }

    struct Summary: Equatable {
        let action: Action
        let downloaded: Int
        let alreadyLocal: Int
        let failed: Int
        /// 加入列表 / 喜爱失败（例如写入失败）的数量，计入失败。
        var postActionFailed = 0

        var succeeded: Int { downloaded + alreadyLocal - postActionFailed }
        var totalFailed: Int { failed + postActionFailed }

        /// 文案中的数字都是真实结果；有失败时不显示全成功的勾。勾号只是文字（黑 / 白），不用绿色。
        var message: String {
            func text(_ key: String, _ args: CVarArg...) -> String { String(format: NSLocalizedString(key, comment: ""), arguments: args) }
            switch action {
            case .download:
                if totalFailed == 0 {
                    var message = downloaded > 0 ? text("steam.batch.download.done", downloaded) : ""
                    if alreadyLocal > 0 {
                        let skipped = text("steam.batch.download.skipped", alreadyLocal)
                        message = message.isEmpty ? skipped : message + "，" + skipped
                    }
                    return message
                }
                return text("steam.batch.download.partial", downloaded, totalFailed)
            case .addToList(_, let name):
                return totalFailed == 0 ? text("steam.batch.list.done", succeeded, name)
                    : text("steam.batch.list.partial", succeeded, name, totalFailed)
            case .favorite:
                return totalFailed == 0 ? text("steam.batch.favorite.done", succeeded)
                    : text("steam.batch.favorite.partial", succeeded, totalFailed)
            }
        }
    }

    private let steam: SteamAcquisitionService
    private let library: WallpaperLibrary
    private let organization: LocalOrganizationStore?
    private let presentation: SteamDownloadPresentation?
    private let posterURL: (SteamStoreItem) -> URL?
    private let reduceMotion: Bool
    /// 等待已有下载任务结束时的轮询间隔。
    var pollInterval: TimeInterval = 0.2

    init(steam: SteamAcquisitionService, library: WallpaperLibrary, organization: LocalOrganizationStore?,
         presentation: SteamDownloadPresentation?, posterURL: @escaping (SteamStoreItem) -> URL? = { _ in nil },
         reduceMotion: Bool = false) {
        self.steam = steam
        self.library = library
        self.organization = organization
        self.presentation = presentation
        self.posterURL = posterURL
        self.reduceMotion = reduceMotion
    }

    func run(_ items: [SteamStoreItem], action: Action) async -> Summary {
        var seen = Set<String>()
        let unique = items.filter { seen.insert($0.workshopID).inserted }
        let outcomes = await withTaskGroup(of: (String, Outcome).self) { group in
            for item in unique {
                group.addTask { @MainActor in (item.workshopID, await self.acquire(item)) }
            }
            var results: [String: Outcome] = [:]
            for await (id, outcome) in group { results[id] = outcome }
            return results
        }
        var postFailures = 0
        // 下载结果全部确定后再统一完成列表 / 喜爱：失败项目不加入。
        let localIDs = unique.compactMap { item -> Wallpaper.ID? in
            switch outcomes[item.workshopID] {
            case .downloaded(let id)?, .alreadyLocal(let id)?: return id
            default: return nil
            }
        }
        switch action {
        case .download:
            break
        case .addToList(let listID, _):
            if !localIDs.isEmpty {
                do { try organization?.add(localIDs, to: listID) } catch { postFailures = localIDs.count }
            }
        case .favorite:
            for id in localIDs where library.wallpaper(id: id)?.isFavorite == false {
                do { try library.setFavorite(true, for: id) } catch { postFailures += 1 }
            }
        }
        let values = Array(outcomes.values)
        return Summary(action: action,
                       downloaded: values.filter { if case .downloaded = $0 { return true }; return false }.count,
                       alreadyLocal: values.filter { if case .alreadyLocal = $0 { return true }; return false }.count,
                       failed: values.filter { if case .failed = $0 { return true }; return false }.count,
                       postActionFailed: postFailures)
    }

    private func acquire(_ item: SteamStoreItem) async -> Outcome {
        let id = item.workshopID
        if let local = library.wallpaper(workshopID: id) { return .alreadyLocal(local.id) }
        if steam.tasks[id]?.isActive == true { return await waitForExistingTask(id) }
        let animates = presentation?.begin(item: item, posterURL: posterURL(item), reduceMotion: reduceMotion) ?? false
        let result = await steam.acquire(item.acquisitionInfo)
        switch result {
        case .success(let wallpaper):
            if animates { presentation?.finish(id, succeeded: true) }
            return .downloaded(wallpaper.id)
        case .failure(.alreadyInLibrary(let existing)):
            if animates { presentation?.finish(id, succeeded: false) }
            return .alreadyLocal(existing)
        case .failure(.alreadyInProgress):
            if animates { presentation?.finish(id, succeeded: false) }
            return await waitForExistingTask(id)
        case .failure(let error):
            if animates { presentation?.finish(id, succeeded: false) }
            return .failed(error.localizedDescription)
        }
    }

    /// 同一项目已经在下载（例如之前双击过）：不重复下载，等它结束后按结果处理。
    private func waitForExistingTask(_ id: String) async -> Outcome {
        while steam.tasks[id]?.isActive == true {
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            if Task.isCancelled { break }
        }
        if let local = library.wallpaper(workshopID: id) { return .downloaded(local.id) }
        if case .failed(let reason)? = steam.tasks[id] { return .failed(reason) }
        return .failed(NSLocalizedString("steam.batch.failed.unknown", comment: ""))
    }
}

/// R4 第 24、28 节：Steam 卡片菜单与双击的规则（纯数据，便于验证）。
///
/// 用户 2026-10-06 确认：以 2026-09-25 的规定为准——单张与多张辅助点按菜单统一，菜单不显示选中数量，
/// 动作作用于当前所选全部壁纸（R4 文档中带数量的写法来自旧版本，不采用）。
enum SteamCardMenuPlan {
    enum Entry: Equatable {
        /// 详情只看被点按的这一张，不改变选择。
        case details
        case separator
        /// 下载当前所选的全部在线项目。
        case download
        /// 所选项目都已在本地资料库：不可点按的说明行。
        case inLibrary
        case addToList
        case favorite
    }

    /// 只有下载 / 加入列表 / 喜爱三类动作（不应用、不访达、不删除、不置顶）；单选与多选相同，不显示数量。
    static func entries(allTargetsLocal: Bool) -> [Entry] {
        [.details, .separator, allTargetsLocal ? .inLibrary : .download, .addToList, .favorite]
    }

    static func title(_ entry: Entry) -> String {
        func localized(_ key: String) -> String { NSLocalizedString(key, comment: "") }
        switch entry {
        case .details: return localized("wallpaper.menu.details")
        case .separator: return ""
        case .download: return localized("steam.menu.download")
        case .inLibrary: return localized("steam.store.inLibrary")
        case .addToList: return localized("wallpaper.menu.addToList")
        case .favorite: return localized("steam.menu.favorite")
        }
    }

    /// 双击：当前多选中的一张 → 批量下载全部；未选中的卡片或单选 → 原有单张双击。
    static func doubleClickDownloadsSelection(selectionCount: Int, clickedIsSelected: Bool) -> Bool {
        selectionCount > 1 && clickedIsSelected
    }
}
