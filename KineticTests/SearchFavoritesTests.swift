import Foundation
import XCTest
@testable import Kinetic

/// 搜索与喜爱：空状态选择，以及搜索 / 喜爱全程不发出网络请求。
final class SearchFavoritesTests: XCTestCase {
    /// 记录进程内经由 URL Loading System 发出的任何请求。
    private final class RecordingProtocol: URLProtocol {
        static let lock = NSLock()
        nonisolated(unsafe) static var requests: [URL] = []

        override class func canInit(with request: URLRequest) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if let url = request.url { requests.append(url) }
            return false
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {}
        override func stopLoading() {}
    }

    func testEmptyStateMatchesTheSection() {
        typealias S = LibraryEmptyState
        XCTAssertEqual(S.resolve(isSearch: false, isFavorites: true, query: "", libraryIsEmpty: false), .favorites)
        XCTAssertEqual(S.resolve(isSearch: false, isFavorites: true, query: "", libraryIsEmpty: true), .favorites)
        XCTAssertEqual(S.resolve(isSearch: false, isFavorites: false, query: "", libraryIsEmpty: true), .library)
        XCTAssertEqual(S.resolve(isSearch: true, isFavorites: false, query: "雨夜", libraryIsEmpty: false), .search)
        XCTAssertEqual(S.resolve(isSearch: true, isFavorites: false, query: "雨夜", libraryIsEmpty: true), .search)
        XCTAssertEqual(S.resolve(isSearch: true, isFavorites: false, query: "  ", libraryIsEmpty: true), .library,
                       "Searching an empty library without a keyword shows the library empty state")

        XCTAssertEqual(NSLocalizedString(S.search.titleKey, comment: ""), "没有找到匹配的壁纸")
        XCTAssertEqual(NSLocalizedString(S.favorites.titleKey, comment: ""), "还没有喜爱的壁纸")
        // 1.0 Module 22：独立详情面板已按 R2 移除，提示指向卡片的辅助点按菜单。
        XCTAssertEqual(NSLocalizedString(S.favorites.hintKey, comment: ""), "辅助点按本地资料库中的壁纸，选择“添加到喜爱”。")
        XCTAssertTrue(S.library.offersImport)
        XCTAssertFalse(S.search.offersImport)
        XCTAssertFalse(S.favorites.offersImport)

        // 1.0 Module 7：Steam 页面是在线商店，不显示本地资料库的内容。
        XCTAssertEqual(S.resolve(isSearch: false, isFavorites: false, query: "", libraryIsEmpty: false,
                                 isSteamStore: true), .steamStore)
        XCTAssertFalse(S.steamStore.offersImport)
        XCTAssertEqual(ShellSection.steam.filter, nil)
        XCTAssertEqual(ShellSection.local.filter, .local)
        // 1.0 Module 10：侧栏只有 搜索 / 喜爱 / 本地 / Steam，没有「全部」；「本地」用共用的小房子图标。
        XCTAssertEqual(ShellSection.allCases, [.search, .favorites, .local, .steam])
        XCTAssertEqual(ShellSection.local.symbol, LocalLibraryIcon.symbolName)
        XCTAssertEqual(ShellSection.local.title, "本地")
        XCTAssertEqual(ShellSection.steam.sidebarTitle, "Steam")
        XCTAssertNil(ShellSection.steam.symbol, "No look-alike symbol stands in for the Steam logo")
        XCTAssertEqual(ShellSection.favorites.filter, .favorites)
    }

    @MainActor
    func testSearchAndFavoritesNeverTouchTheNetwork() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KineticSearch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = WallpaperLibrary(storage: LibraryStorageLocation(rootURL: root))
        let web = Wallpaper(name: "https://example.com 网页", type: .web, source: .steam,
                            resourceURL: URL(string: "https://example.com/index.html")!,
                            thumbnailURL: URL(string: "https://example.com/preview.png"),
                            steamMetadata: SteamMetadata(workshopID: "1", author: "作者"))
        let video = Wallpaper(name: "雨夜", type: .video, source: .local,
                              resourceURL: root.appendingPathComponent("rain.mp4"))
        try library.add(web)
        try library.add(video)

        URLProtocol.registerClass(RecordingProtocol.self)
        defer { URLProtocol.unregisterClass(RecordingProtocol.self) }
        RecordingProtocol.lock.lock(); RecordingProtocol.requests = []; RecordingProtocol.lock.unlock()

        for query in ["", "雨", "example", "作者", "Steam", "网页 steam", "不存在"] {
            _ = library.search(query)
            _ = library.search(query, in: .favorites)
        }
        try library.setFavorite(true, for: web.id)
        XCTAssertEqual(library.wallpapers(in: .favorites).map(\.id), [web.id])
        XCTAssertEqual(library.search("example", in: .favorites).map(\.id), [web.id])
        try library.setFavorite(false, for: web.id)
        XCTAssertTrue(library.wallpapers(in: .favorites).isEmpty)

        RecordingProtocol.lock.lock(); let requests = RecordingProtocol.requests; RecordingProtocol.lock.unlock()
        XCTAssertTrue(requests.isEmpty, "Unexpected network requests: \(requests)")
    }

    // MARK: - 1.0 Module 22 — Search & Favorite：只针对本地资料库

    @MainActor
    private func makeLibrary() -> (WallpaperLibrary, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KineticModule22-\(UUID().uuidString)")
        return (WallpaperLibrary(storage: LibraryStorageLocation(rootURL: root)), root)
    }

    @MainActor
    func testSearchCoversEveryLocalRecordWhateverItsOriginAndNothingElse() throws {
        let (library, root) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let imported = Wallpaper(name: "海浪", type: .video, acquisitionOrigin: .localImport,
                                 resourceURL: root.appendingPathComponent("waves.mp4"))
        let downloaded = Wallpaper(name: "极光之夜", type: .web, acquisitionOrigin: .steamWorkshop,
                                   resourceURL: root.appendingPathComponent("aurora/index.html"),
                                   steamMetadata: SteamMetadata(workshopID: "2201", author: "北境工作室"))
        let demo = Wallpaper(name: "晨雾", type: .video, acquisitionOrigin: .bundledDemo,
                             resourceURL: root.appendingPathComponent("mist.mp4"))
        for wallpaper in [imported, downloaded, demo] { try library.add(wallpaper) }
        let libraryIDs = Set(library.wallpapers.map(\.id))

        // 没有关键词时就是整个本地资料库。
        XCTAssertEqual(Set(library.search("").map(\.id)), libraryIDs)
        XCTAssertEqual(Set(library.search("   ").map(\.id)), libraryIDs)
        // 已下载的 Steam 项目属于本地资料库，可以按名称、作者或来源找到。
        XCTAssertEqual(library.search("极光").map(\.id), [downloaded.id])
        XCTAssertEqual(library.search("北境").map(\.id), [downloaded.id])
        XCTAssertEqual(library.search("海浪 视频").map(\.id), [imported.id], "Every term must match")
        XCTAssertTrue(library.search("不存在的关键词").isEmpty)
        // 任何关键词的结果都只来自本地记录，也不改变资料库。
        for query in ["", "极光", "Steam", "网页", "视频", "晨"] {
            XCTAssertTrue(Set(library.search(query).map(\.id)).isSubset(of: libraryIDs), query)
        }
        XCTAssertEqual(Set(library.wallpapers.map(\.id)), libraryIDs)
        XCTAssertTrue(library.wallpapers(in: .favorites).isEmpty, "Searching never favourites anything")
    }

    @MainActor
    func testOnlyItemsInTheLocalLibraryCanBeFavourited() throws {
        let (library, root) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let local = Wallpaper(name: "海浪", type: .video, acquisitionOrigin: .localImport,
                              resourceURL: root.appendingPathComponent("waves.mp4"))
        let downloaded = Wallpaper(name: "极光之夜", type: .web, acquisitionOrigin: .steamWorkshop,
                                   resourceURL: root.appendingPathComponent("aurora/index.html"),
                                   steamMetadata: SteamMetadata(workshopID: "2201"))
        try library.add(local)
        try library.add(downloaded)

        // 不在本地资料库里的项目（例如以后 Steam 在线商店中尚未下载的项目）不能加入喜爱。
        XCTAssertThrowsError(try library.setFavorite(true, for: UUID())) { error in
            XCTAssertEqual(error as? WallpaperLibraryError, .notFound)
        }
        XCTAssertTrue(library.wallpapers(in: .favorites).isEmpty)

        try library.setFavorite(true, for: downloaded.id)
        try library.setFavorite(true, for: local.id)
        XCTAssertEqual(Set(library.wallpapers(in: .favorites).map(\.id)), [downloaded.id, local.id])
        // 重复设置不改变加入喜爱的时间。
        let firstDate = library.wallpaper(id: local.id)?.favoritedAt
        try library.setFavorite(true, for: local.id)
        XCTAssertEqual(library.wallpaper(id: local.id)?.favoritedAt, firstDate)

        // 从资料库删除后，它也不再出现在喜爱中。
        _ = try library.remove(id: downloaded.id)
        XCTAssertEqual(library.wallpapers(in: .favorites).map(\.id), [local.id])
        XCTAssertEqual(WallpaperLibrary(storage: LibraryStorageLocation(rootURL: root))
            .wallpapers(in: .favorites).map(\.id), [local.id], "Favourites persist with the library")
    }

    @MainActor
    func testRemovingAFavouriteOnTheFavouritesPageDropsItFromTheSelection() throws {
        let (library, root) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = Wallpaper(name: "海浪", type: .video, acquisitionOrigin: .localImport,
                              resourceURL: root.appendingPathComponent("waves.mp4"), isFavorite: true)
        let second = Wallpaper(name: "晨雾", type: .video, acquisitionOrigin: .localImport,
                               resourceURL: root.appendingPathComponent("mist.mp4"), isFavorite: true)
        try library.add(first)
        try library.add(second)

        func favouritesPage() -> [Wallpaper.ID] {
            ContentQuery.apply(ContentViewOptions(), to: library.wallpapers(in: .favorites),
                               dateAdded: \.favoritedAt).map(\.id)
        }
        var selection = StableCardSelection<Wallpaper.ID>()
        selection.replace(with: Set(favouritesPage()))
        XCTAssertEqual(selection.count, 2)

        // 批量菜单「从喜爱中移除」其中一个：页面上看不到它了，选择随可见项目收缩，菜单数量正确。
        try library.setFavorite(false, for: first.id)
        selection.retain(Set(favouritesPage()))
        XCTAssertEqual(selection.count, 1)
        XCTAssertEqual(selection.singleID, second.id)
        XCTAssertNotNil(library.wallpaper(id: first.id), "Unfavouriting never deletes the wallpaper")
        XCTAssertNil(library.wallpaper(id: first.id)?.favoritedAt)
    }
}
