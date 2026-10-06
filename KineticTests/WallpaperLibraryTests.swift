import XCTest
@testable import Kinetic

/// Module 7：资料库持久化（1.0：只维护本地资料库，来源记录在 acquisitionOrigin）。每个测试使用独立临时目录，不接触正式资料库。
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
                  steamMetadata: source == .steam ? SteamMetadata(workshopID: "ws-\(name)", author: author, sizeInBytes: 2048) : nil)
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
        XCTAssertEqual(json?["formatVersion"] as? Int, 2)
    }

    /// 1.0：已保存到本机的壁纸全部属于「本地」，来源不决定分页；只有「本地」与「喜爱」两种查询。
    @MainActor
    func testFavoritePersistsAndEverySavedWallpaperIsLocal() throws {
        let library = WallpaperLibrary(storage: storage)
        let local = wallpaper("本地一"), steam = wallpaper("工坊一", .scene, .steam)
        try library.add(local)
        try library.add(steam)
        try library.setFavorite(true, for: local.id)
        try library.setFavorite(true, for: local.id)

        let reopened = WallpaperLibrary(storage: storage)
        XCTAssertEqual(LibraryFilter.allCases, [.local, .favorites], "No All / Steam library queries")
        XCTAssertEqual(reopened.wallpapers(in: .favorites).map(\.id), [local.id])
        XCTAssertEqual(reopened.wallpapers(in: .local).map(\.id), [steam.id, local.id],
                       "A downloaded Steam wallpaper is in Local too")
        XCTAssertEqual(reopened.wallpaper(id: steam.id)?.acquisitionOrigin, .steamWorkshop)
        XCTAssertEqual(reopened.wallpaper(id: local.id)?.acquisitionOrigin, .localImport)

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
    func testSearchIsLocalAndMatchesNameTypeOriginAndAuthor() throws {
        let library = WallpaperLibrary(storage: storage)
        let rain = wallpaper("雨夜 Rain", .web, .steam, author: "Aurora 工作室")
        let ocean = wallpaper("Ocean Waves")
        let scene = wallpaper("星空", .scene, .steam, author: "另一位作者")
        try library.add(rain)
        try library.add(ocean)
        try library.add(scene)
        func names(_ query: String, _ filter: LibraryFilter = .local) -> Set<String> {
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
        XCTAssertEqual(names("steam", .local), ["雨夜 Rain", "星空"], "Local search covers every saved wallpaper")
        XCTAssertEqual(names("本地导入"), ["Ocean Waves"])
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

    // MARK: - 1.0 Module 7

    /// v0.1 的资料库（formatVersion 1，记录带 source）读取后迁移到 1.0：记录、顺序、喜爱全部保留，
    /// 来源按记录本身的字段转换；旧文件原样备份，新文件不再写 source。
    @MainActor
    func testV01LibraryIsMigratedKeepingEveryRecordAndBackingUpTheOriginal() throws {
        let localID = UUID(), steamID = UUID()
        let v1 = """
        {"formatVersion": 1, "wallpapers": [
          {"id": "\(steamID.uuidString)", "name": "雨夜", "type": "web", "source": "steam",
           "resourceURL": "file:///kinetic-v01/rain/index.html", "isFavorite": true,
           "steamMetadata": {"workshopID": "2718", "author": "作者甲"}},
          {"id": "\(localID.uuidString)", "name": "海浪", "type": "video", "source": "local",
           "resourceURL": "file:///kinetic-v01/waves.mp4", "thumbnailURL": "file:///kinetic-v01/waves.jpg",
           "isFavorite": false}
        ]}
        """
        let original = Data(v1.utf8)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try original.write(to: storage.libraryFileURL)

        let library = WallpaperLibrary(storage: storage)
        XCTAssertNil(library.loadIssue)
        XCTAssertEqual(library.wallpapers.map(\.id), [steamID, localID], "Order is kept")
        XCTAssertEqual(library.wallpapers.map(\.acquisitionOrigin), [.steamWorkshop, .localImport])
        XCTAssertEqual(library.wallpapers.map(\.isFavorite), [true, false])
        XCTAssertEqual(library.wallpaper(id: steamID)?.steamMetadata?.author, "作者甲")
        XCTAssertEqual(library.wallpaper(id: localID)?.thumbnailURL?.lastPathComponent, "waves.jpg")
        XCTAssertNil(library.wallpaper(id: localID)?.importedAt, "Unknown for v0.1 records; never invented")
        XCTAssertEqual(library.wallpapers(in: .local).count, 2)

        let backup = try XCTUnwrap(library.migrationBackupURL)
        XCTAssertEqual(try Data(contentsOf: backup), original, "The v0.1 file is backed up byte for byte")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: storage.libraryFileURL)) as? [String: Any])
        XCTAssertEqual(json["formatVersion"] as? Int, 2)
        let records = try XCTUnwrap(json["wallpapers"] as? [[String: Any]])
        XCTAssertEqual(records.compactMap { $0["acquisitionOrigin"] as? String }, ["steamWorkshop", "localImport"])
        XCTAssertTrue(records.allSatisfy { $0["source"] == nil }, "The old source field is no longer written")

        // 再次打开：已经是 1.0 格式，不再迁移，备份保持不变。
        let reopened = WallpaperLibrary(storage: storage)
        XCTAssertEqual(reopened.wallpapers, library.wallpapers)
        XCTAssertNil(reopened.migrationBackupURL)
        XCTAssertEqual(try Data(contentsOf: backup), original)

        // 之后又出现一个不同的旧格式文件（例如回到旧版）：另存新备份，不覆盖第一次的备份。
        let second = Data(v1.replacingOccurrences(of: "海浪", with: "海浪（旧版改名）").utf8)
        try second.write(to: storage.libraryFileURL)
        let again = WallpaperLibrary(storage: storage)
        XCTAssertEqual(again.wallpaper(id: localID)?.name, "海浪（旧版改名）")
        let secondBackup = try XCTUnwrap(again.migrationBackupURL)
        XCTAssertNotEqual(secondBackup, backup)
        XCTAssertEqual(try Data(contentsOf: secondBackup), second)
        XCTAssertEqual(try Data(contentsOf: backup), original, "The first backup is never overwritten")
    }

    @MainActor
    func testEveryOriginRoundTripsAndIsSearchableByItsName() throws {
        let library = WallpaperLibrary(storage: storage)
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        for origin in AcquisitionOrigin.allCases {
            try library.add(Wallpaper(name: origin.rawValue, type: .video, acquisitionOrigin: origin,
                                      resourceURL: URL(fileURLWithPath: "/kinetic-origins/\(origin.rawValue)"),
                                      importedAt: date, updatedAt: date))
        }
        let reopened = WallpaperLibrary(storage: storage)
        XCTAssertEqual(reopened.wallpapers, library.wallpapers)
        XCTAssertEqual(Set(reopened.wallpapers(in: .local).map(\.acquisitionOrigin)), Set(AcquisitionOrigin.allCases))
        XCTAssertEqual(reopened.wallpapers.first?.importedAt, date)
        XCTAssertEqual(reopened.search("Kinetic 演示").map(\.acquisitionOrigin), [.bundledDemo])
        XCTAssertEqual(reopened.search("Apple 航拍").map(\.acquisitionOrigin), [.appleAerial])
    }

    /// 规格 3、24：同一个 Steam 创意工坊项目只有一条本地记录；更新时保留原标识、喜爱、加入时间与设置。
    @MainActor
    func testTheSameWorkshopItemNeverGetsASecondRecord() throws {
        let library = WallpaperLibrary(storage: storage)
        let imported = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let first = Wallpaper(name: "雨夜", type: .web, acquisitionOrigin: .steamWorkshop,
                              resourceURL: URL(fileURLWithPath: "/kinetic-steam/2718/v1"),
                              steamMetadata: SteamMetadata(workshopID: "2718", author: "作者甲"),
                              importedAt: imported, updatedAt: imported)
        try library.add(first)
        try library.setFavorite(true, for: first.id)
        XCTAssertEqual(library.wallpaper(workshopID: "2718")?.id, first.id)

        let duplicate = Wallpaper(name: "雨夜（重复）", type: .web, acquisitionOrigin: .steamWorkshop,
                                  resourceURL: URL(fileURLWithPath: "/kinetic-steam/2718/dup"),
                                  steamMetadata: SteamMetadata(workshopID: "2718"))
        XCTAssertThrowsError(try library.add(duplicate)) {
            XCTAssertEqual($0 as? WallpaperLibraryError, .duplicateWorkshopItem(first.id))
        }

        let later = Date(timeIntervalSinceReferenceDate: 750_000_000)
        let update = Wallpaper(name: "雨夜 2.0", type: .web, acquisitionOrigin: .steamWorkshop,
                               resourceURL: URL(fileURLWithPath: "/kinetic-steam/2718/v2"),
                               steamMetadata: SteamMetadata(workshopID: "2718", author: "作者甲", sizeInBytes: 4096),
                               importedAt: later, updatedAt: later)
        XCTAssertEqual(try library.addOrUpdateWorkshopItem(update), first.id, "Updates keep the local identity")
        XCTAssertEqual(library.wallpapers.count, 1)
        let stored = try XCTUnwrap(library.wallpaper(id: first.id))
        XCTAssertEqual(stored.name, "雨夜 2.0")
        XCTAssertEqual(stored.resourceURL.lastPathComponent, "v2")
        XCTAssertEqual(stored.steamMetadata?.sizeInBytes, 4096)
        XCTAssertTrue(stored.isFavorite, "Favorite survives an update")
        XCTAssertEqual(stored.importedAt, imported)
        XCTAssertEqual(stored.updatedAt, later)

        let other = Wallpaper(name: "星空", type: .scene, acquisitionOrigin: .steamWorkshop,
                              resourceURL: URL(fileURLWithPath: "/kinetic-steam/3141"),
                              steamMetadata: SteamMetadata(workshopID: "3141"))
        XCTAssertEqual(try library.addOrUpdateWorkshopItem(other), other.id)
        XCTAssertEqual(library.wallpapers.count, 2)
        let notSteam = Wallpaper(name: "本地", type: .video, acquisitionOrigin: .localImport,
                                 resourceURL: URL(fileURLWithPath: "/kinetic-local/a.mp4"))
        XCTAssertThrowsError(try library.addOrUpdateWorkshopItem(notSteam)) {
            XCTAssertEqual($0 as? WallpaperLibraryError, .notWorkshopItem)
        }
        XCTAssertEqual(WallpaperLibrary(storage: storage).wallpapers.count, 2)
    }

    @MainActor
    func testAvailabilityFollowsTheLocalResource() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let resource = root.appendingPathComponent("present.mp4")
        try Data("video".utf8).write(to: resource)
        let library = WallpaperLibrary(storage: storage)
        let present = Wallpaper(name: "在", type: .video, acquisitionOrigin: .localImport, resourceURL: resource)
        let absent = wallpaper("不在")
        try library.add(present)
        try library.add(absent)
        XCTAssertEqual(library.availability(of: present.id), .available)
        XCTAssertEqual(library.availability(of: absent.id), .missing)
        XCTAssertEqual(library.availability(of: UUID()), .missing)

        try FileManager.default.removeItem(at: resource)
        XCTAssertEqual(library.availability(of: present.id), .available, "Cached until refreshed")
        library.refreshAvailability()
        XCTAssertEqual(library.availability(of: present.id), .missing)
        XCTAssertEqual(library.wallpapers.count, 2, "A missing file never removes the record")
        XCTAssertEqual(WallpaperLibrary(storage: storage).availability(of: present.id), .missing)
    }

    func testStandardLocationIsKineticApplicationSupport() throws {
        let location = try LibraryStorageLocation.standard()
        XCTAssertEqual(location.rootURL.lastPathComponent, "Kinetic")
        XCTAssertEqual(location.rootURL.deletingLastPathComponent().lastPathComponent, "Application Support")
        XCTAssertEqual(location.libraryFileURL.lastPathComponent, "library.json")
        XCTAssertEqual(location.wallpapersDirectoryURL.lastPathComponent, "Wallpapers")
    }
}
