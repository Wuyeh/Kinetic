import XCTest
@testable import Kinetic

/// 资料库持久化。每个测试使用独立临时目录，不接触正式资料库。
final class WallpaperLibraryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KineticLibraryTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var storage: LibraryStorageLocation { LibraryStorageLocation(rootURL: root) }

    private func wallpaper(_ name: String, _ type: WallpaperType = .video, _ source: WallpaperSource = .local,
                           author: String? = nil, favorite: Bool = false) -> Wallpaper {
        Wallpaper(name: name, type: type, source: source,
                  resourceURL: URL(fileURLWithPath: "/kinetic-library-fixtures/\(name)"),
                  thumbnailURL: URL(fileURLWithPath: "/kinetic-library-fixtures/\(name).jpg"),
                  isFavorite: favorite,
                  steamMetadata: source == .steam ? SteamMetadata(workshopID: "42", author: author, sizeInBytes: 2048) : nil)
    }

    @MainActor
    func testMissingFileStartsEmptyAndNothingIsWrittenUntilAChange() {
        let library = WallpaperLibrary(storage: storage)
        XCTAssertTrue(library.wallpapers.isEmpty)
        XCTAssertNil(library.loadIssue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.libraryFileURL.path))
    }

    @MainActor
    func testLibrarySurvivesRelaunchWithIdentityOrderAndMetadata() throws {
        let a = wallpaper("雨夜", .web, .steam, author: "作者甲", favorite: true)
        let b = wallpaper("海浪")
        do {
            let library = WallpaperLibrary(storage: storage)
            try library.add(a)
            try library.add(b)
            XCTAssertEqual(library.wallpapers.map(\.id), [b.id, a.id], "Newest first")
        }
        // 模拟关闭后重新打开 App。
        let reopened = WallpaperLibrary(storage: storage)
        XCTAssertEqual(reopened.wallpapers, [b, a])
        XCTAssertEqual(reopened.wallpaper(id: a.id)?.steamMetadata?.author, "作者甲")
        XCTAssertEqual(reopened.wallpaper(id: a.id)?.isFavorite, true)
        XCTAssertNil(reopened.loadIssue)

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: storage.libraryFileURL)) as? [String: Any]
        XCTAssertEqual(json?["formatVersion"] as? Int, 1)
    }

    @MainActor
    func testFavoritePersistsAndFiltersFollowSource() throws {
        let library = WallpaperLibrary(storage: storage)
        let local = wallpaper("本地一"), steam = wallpaper("工坊一", .scene, .steam)
        try library.add(local)
        try library.add(steam)
        try library.setFavorite(true, for: local.id)
        try library.setFavorite(true, for: local.id)

        let reopened = WallpaperLibrary(storage: storage)
        XCTAssertEqual(reopened.wallpapers(in: .favorites).map(\.id), [local.id])
        XCTAssertEqual(reopened.wallpapers(in: .local).map(\.id), [local.id])
        XCTAssertEqual(reopened.wallpapers(in: .steam).map(\.id), [steam.id])
        XCTAssertEqual(reopened.wallpapers(in: .all).count, 2)

        try reopened.setFavorite(false, for: local.id)
        XCTAssertTrue(WallpaperLibrary(storage: storage).wallpapers(in: .favorites).isEmpty)
    }

    @MainActor
    func testUpdateKeepsPositionAndRemoveOnlyDropsTheRecord() throws {
        let resource = root.appendingPathComponent("content.mp4")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("video".utf8).write(to: resource)
        let library = WallpaperLibrary(storage: storage)
        var first = Wallpaper(name: "旧名称", type: .video, source: .local, resourceURL: resource)
        let second = wallpaper("第二张")
        try library.add(first)
        try library.add(second)

        first.name = "新名称"
        try library.update(first)
        XCTAssertEqual(library.wallpapers.map(\.name), ["第二张", "新名称"])

        let removed = try library.remove(id: first.id)
        XCTAssertEqual(removed.id, first.id)
        XCTAssertEqual(library.wallpapers.map(\.id), [second.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: resource.path), "Library never deletes content files")
        XCTAssertEqual(WallpaperLibrary(storage: storage).wallpapers.map(\.id), [second.id])
    }

    @MainActor
    func testInvalidChangesThrowAndLeaveLibraryUnchanged() throws {
        let library = WallpaperLibrary(storage: storage)
        let a = wallpaper("一")
        try library.add(a)
        XCTAssertThrowsError(try library.add(a)) { XCTAssertEqual($0 as? WallpaperLibraryError, .duplicateIdentifier) }
        XCTAssertThrowsError(try library.update(wallpaper("不存在"))) { XCTAssertEqual($0 as? WallpaperLibraryError, .notFound) }
        XCTAssertThrowsError(try library.remove(id: UUID())) { XCTAssertEqual($0 as? WallpaperLibraryError, .notFound) }
        XCTAssertThrowsError(try library.setFavorite(true, for: UUID()))
        XCTAssertEqual(library.wallpapers, [a])
    }

    @MainActor
    func testSaveFailureKeepsMemoryAndDiskUnchanged() throws {
        // 根路径被一个普通文件占用，目录无法创建。
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("occupied".utf8).write(to: root)
        let library = WallpaperLibrary(storage: storage)
        XCTAssertThrowsError(try library.add(wallpaper("写入失败"))) { error in
            guard case .saveFailed = error as? WallpaperLibraryError else { return XCTFail("Unexpected \(error)") }
        }
        XCTAssertTrue(library.wallpapers.isEmpty)
        XCTAssertEqual(try Data(contentsOf: root), Data("occupied".utf8))
    }

    @MainActor
    func testSearchIsLocalAndMatchesNameTypeSourceAndAuthor() throws {
        let library = WallpaperLibrary(storage: storage)
        let rain = wallpaper("雨夜 Rain", .web, .steam, author: "Aurora 工作室")
        let ocean = wallpaper("Ocean Waves")
        let scene = wallpaper("星空", .scene, .steam, author: "另一位作者")
        try library.add(rain)
        try library.add(ocean)
        try library.add(scene)
        func names(_ query: String, _ filter: LibraryFilter = .all) -> Set<String> {
            Set(library.search(query, in: filter).map(\.name))
        }
        XCTAssertEqual(names("rain"), ["雨夜 Rain"])
        XCTAssertEqual(names("RAIN"), ["雨夜 Rain"])
        XCTAssertEqual(names("ｒａｉｎ"), ["雨夜 Rain"], "Full-width input matches")
        XCTAssertEqual(names("雨夜"), ["雨夜 Rain"])
        XCTAssertEqual(names("视频"), ["Ocean Waves"])
        XCTAssertEqual(names("网页"), ["雨夜 Rain"])
        XCTAssertEqual(names("场景"), ["星空"])
        XCTAssertEqual(names("本地"), ["Ocean Waves"])
        XCTAssertEqual(names("Steam"), ["雨夜 Rain", "星空"])
        XCTAssertEqual(names("创意工坊 aurora"), ["雨夜 Rain"], "All terms must match")
        XCTAssertEqual(names("另一位"), ["星空"])
        XCTAssertEqual(names(""), ["雨夜 Rain", "Ocean Waves", "星空"])
        XCTAssertEqual(names("   "), ["雨夜 Rain", "Ocean Waves", "星空"])
        XCTAssertEqual(names("不存在"), [])
        XCTAssertEqual(names("steam", .local), [])
        try library.setFavorite(true, for: scene.id)
        XCTAssertEqual(names("", .favorites), ["星空"])
    }

    @MainActor
    func testUnreadableFileIsBackedUpAndNeverOverwritten() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let garbage = Data("{ not json".utf8)
        try garbage.write(to: storage.libraryFileURL)

        let library = WallpaperLibrary(storage: storage)
        XCTAssertTrue(library.wallpapers.isEmpty)
        let backup = try XCTUnwrap(library.loadIssue?.backupURL)
        XCTAssertEqual(try Data(contentsOf: backup), garbage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.libraryFileURL.path))

        try library.add(wallpaper("新记录"))
        XCTAssertEqual(try Data(contentsOf: backup), garbage, "Backup stays untouched")
        XCTAssertEqual(WallpaperLibrary(storage: storage).wallpapers.map(\.name), ["新记录"])
    }

    @MainActor
    func testNewerFormatVersionIsPreservedInsteadOfDowngraded() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let future = Data(#"{"formatVersion": 99, "wallpapers": []}"#.utf8)
        try future.write(to: storage.libraryFileURL)
        let library = WallpaperLibrary(storage: storage)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(library.loadIssue?.backupURL)), future)
    }

    @MainActor
    func testDuplicateIdentifiersInFileKeepTheFirstRecord() throws {
        let a = wallpaper("第一条")
        var copy = a
        copy.name = "重复标识"
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let records = try [a, copy].map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }
        let document: [String: Any] = ["formatVersion": 1, "wallpapers": records]
        try JSONSerialization.data(withJSONObject: document).write(to: storage.libraryFileURL)
        XCTAssertEqual(WallpaperLibrary(storage: storage).wallpapers.map(\.name), ["第一条"])
    }

    func testStandardLocationIsKineticApplicationSupport() throws {
        let location = try LibraryStorageLocation.standard()
        XCTAssertEqual(location.rootURL.lastPathComponent, "Kinetic")
        XCTAssertEqual(location.rootURL.deletingLastPathComponent().lastPathComponent, "Application Support")
        XCTAssertEqual(location.libraryFileURL.lastPathComponent, "library.json")
        XCTAssertEqual(location.wallpapersDirectoryURL.lastPathComponent, "Wallpapers")
    }
}
