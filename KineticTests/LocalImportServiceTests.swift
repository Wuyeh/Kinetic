import AppKit
import CryptoKit
import XCTest
@testable import Kinetic

/// 本地导入。临时目录模拟用户的“下载”文件夹与 Kinetic 的 Library Storage，不接触正式资料库。
final class LocalImportServiceTests: XCTestCase {
    private var workspace: URL!
    private var downloads: URL!
    private var storage: LibraryStorageLocation!

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("KineticImportTests-\(UUID().uuidString)", isDirectory: true)
        downloads = workspace.appendingPathComponent("Downloads", isDirectory: true)
        storage = LibraryStorageLocation(rootURL: workspace.appendingPathComponent("Library", isDirectory: true))
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workspace)
    }

    private func fixture(_ name: String, _ ext: String? = nil) throws -> URL {
        try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
    }

    /// 把测试素材复制到“下载”文件夹，作为用户的原始文件。
    private func download(_ source: URL, as name: String) throws -> URL {
        let target = downloads.appendingPathComponent(name)
        try FileManager.default.copyItem(at: source, to: target)
        return target
    }

    private func digest(_ url: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory))
        let files: [URL] = isDirectory.boolValue
            ? (FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            : [url]
        for file in files where !file.hasDirectoryPath {
            let hash = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
            result[file.path.replacingOccurrences(of: url.path, with: "")] = hash
        }
        return result
    }

    private func entries(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    @MainActor
    func testVideoIsCopiedIntoLibraryStorageAndOriginalStaysUntouched() async throws {
        let original = try download(try fixture("loop", "mp4"), as: "海浪.mp4")
        let before = try digest(original)
        let modified = try original.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let library = WallpaperLibrary(storage: storage)
        let importer = LocalImportService(library: library)

        let outcome = await importer.importItem(at: original)
        let wallpaper = try XCTUnwrap(outcome.wallpaper, "\(outcome.result)")
        XCTAssertTrue(outcome.sourceUnchanged)
        XCTAssertEqual(wallpaper.name, "海浪")
        XCTAssertEqual(wallpaper.type, .video)
        XCTAssertEqual(wallpaper.source, .local)
        XCTAssertEqual(library.wallpapers, [wallpaper])

        // 内容位于 Library Storage/Wallpapers/<标识>/，字节与原文件一致，但不是同一个路径。
        let expectedFolder = storage.wallpapersDirectoryURL.appendingPathComponent(wallpaper.id.uuidString)
        XCTAssertEqual(wallpaper.resourceURL.deletingLastPathComponent().standardizedFileURL.path,
                       expectedFolder.standardizedFileURL.path)
        XCTAssertNotEqual(wallpaper.resourceURL.standardizedFileURL.path, original.standardizedFileURL.path)
        XCTAssertEqual(try Data(contentsOf: wallpaper.resourceURL), try Data(contentsOf: original))

        // 原文件原封不动。
        XCTAssertEqual(try digest(original), before)
        XCTAssertEqual(try original.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified)
        XCTAssertEqual(entries(in: downloads), ["海浪.mp4"])

        // 预览图为 JPEG；没有残留暂存目录。
        let thumbnail = try XCTUnwrap(wallpaper.thumbnailURL)
        XCTAssertEqual(try Data(contentsOf: thumbnail).prefix(2), Data([0xFF, 0xD8]))
        XCTAssertEqual(entries(in: storage.wallpapersDirectoryURL), [wallpaper.id.uuidString])

        // 用户之后删除原文件，Kinetic 中的壁纸不受影响。
        try FileManager.default.removeItem(at: original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: wallpaper.resourceURL.path))
        let renderer = VideoRenderer(wallpaper: wallpaper)
        defer { renderer.dispose() }
        try await renderer.prepare()
        XCTAssertTrue(renderer.isPrepared)
        XCTAssertEqual(WallpaperLibrary(storage: storage).wallpapers, [wallpaper], "Survives relaunch")
    }

    @MainActor
    func testUppercaseMOVExtensionIsAccepted() async throws {
        let original = try download(try fixture("loop", "mov"), as: "Clip.MOV")
        let importer = LocalImportService(library: WallpaperLibrary(storage: storage))
        let outcome = await importer.importItem(at: original)
        let wallpaper = try XCTUnwrap(outcome.wallpaper)
        XCTAssertEqual(wallpaper.type, .video)
        XCTAssertEqual(wallpaper.name, "Clip")
        XCTAssertEqual(wallpaper.resourceURL.lastPathComponent, "Clip.MOV")
    }

    @MainActor
    func testWebFolderIsCopiedWholeAndMarkedNotPlayableYet() async throws {
        let original = try download(try fixture("web-sample"), as: "海边网页")
        let before = try digest(original)
        let library = WallpaperLibrary(storage: storage)
        let importer = LocalImportService(library: library)

        let outcome = await importer.importItem(at: original)
        let wallpaper = try XCTUnwrap(outcome.wallpaper, "\(outcome.result)")
        XCTAssertTrue(outcome.sourceUnchanged)
        XCTAssertEqual(wallpaper.type, .web)
        XCTAssertEqual(wallpaper.name, "海边网页")
        XCTAssertEqual(wallpaper.resourceURL.lastPathComponent, "海边网页")
        XCTAssertEqual(try digest(wallpaper.resourceURL), before, "Whole folder copied byte for byte")
        XCTAssertEqual(wallpaper.thumbnailURL?.lastPathComponent, "preview.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(wallpaper.thumbnailURL).path))
        XCTAssertEqual(try digest(original), before)

        // 网页壁纸进入资料库，但暂不能播放。
        XCTAssertFalse(WallpaperRuntimeManager.isRendererAvailable(for: wallpaper.type))
        XCTAssertThrowsError(try WallpaperRuntimeManager.standardRenderer(for: wallpaper))
    }

    @MainActor
    func testInvalidItemsAreRejectedWithoutCopyingOrChangingTheLibrary() async throws {
        let text = downloads.appendingPathComponent("说明.txt")
        try Data("hello".utf8).write(to: text)
        let corrupt = try download(try fixture("corrupt", "mp4"), as: "坏视频.mp4")
        let noEntry = downloads.appendingPathComponent("普通文件夹", isDirectory: true)
        try FileManager.default.createDirectory(at: noEntry, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: noEntry.appendingPathComponent("readme.md"))
        let linked = try download(try fixture("web-sample"), as: "带链接的网页")
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("secret"),
                                                   withDestinationURL: workspace)
        let missing = downloads.appendingPathComponent("不存在.mp4")
        let renamedVideo = try download(try fixture("loop", "mp4"), as: "伪装.txt")

        let library = WallpaperLibrary(storage: storage)
        let importer = LocalImportService(library: library)
        let outcomes = await importer.importItems(at: [text, corrupt, noEntry, linked, missing, renamedVideo])
        let errors = outcomes.map { outcome -> LocalImportError? in
            if case .failure(let error) = outcome.result { return error }
            return nil
        }
        XCTAssertEqual(errors, [.unsupportedItem, .unplayableVideo, .missingWebEntry,
                                .containsSymbolicLinks, .unreadable, .unsupportedItem])
        XCTAssertTrue(library.wallpapers.isEmpty)
        XCTAssertTrue(entries(in: storage.wallpapersDirectoryURL).isEmpty, "Nothing copied, no staging left")
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.libraryFileURL.path))
        XCTAssertTrue(outcomes[0].sourceUnchanged && outcomes[1].sourceUnchanged)
    }

    @MainActor
    func testBatchContinuesAfterFailuresAndKeepsNewestFirst() async throws {
        let first = try download(try fixture("loop", "mp4"), as: "第一段.mp4")
        let bad = try download(try fixture("corrupt", "mp4"), as: "坏.mp4")
        let second = try download(try fixture("loop-warm", "mp4"), as: "第二段.mp4")
        let library = WallpaperLibrary(storage: storage)
        let outcomes = await LocalImportService(library: library).importItems(at: [first, bad, second])
        XCTAssertEqual(outcomes.map { $0.wallpaper != nil }, [true, false, true])
        XCTAssertEqual(outcomes.map(\.sourceURL), [first, bad, second])
        XCTAssertEqual(library.wallpapers.map(\.name), ["第二段", "第一段"])
        XCTAssertEqual(entries(in: storage.wallpapersDirectoryURL).count, 2)
    }

    @MainActor
    func testImportingTheSameFileTwiceCreatesTwoIndependentCopies() async throws {
        let original = try download(try fixture("loop", "mp4"), as: "重复.mp4")
        let library = WallpaperLibrary(storage: storage)
        let importer = LocalImportService(library: library)
        let first = await importer.importItem(at: original)
        let second = await importer.importItem(at: original)
        let a = try XCTUnwrap(first.wallpaper)
        let b = try XCTUnwrap(second.wallpaper)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertNotEqual(a.resourceURL, b.resourceURL)
        XCTAssertEqual(library.wallpapers.count, 2)
    }

    @MainActor
    func testLibraryWriteFailureRollsBackCopiedContent() async throws {
        // 资料库目录只读（Wallpapers 子目录仍可写）：内容能复制，但 library.json 无法写入。
        try FileManager.default.createDirectory(at: storage.wallpapersDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: storage.rootURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: storage.rootURL.path) }
        let original = try download(try fixture("loop", "mp4"), as: "回滚.mp4")
        let library = WallpaperLibrary(storage: storage)
        let outcome = await LocalImportService(library: library).importItem(at: original)
        guard case .failure(.libraryFailed) = outcome.result else { return XCTFail("\(outcome.result)") }
        XCTAssertTrue(entries(in: storage.wallpapersDirectoryURL).isEmpty, "Copied content removed again")
        XCTAssertTrue(library.wallpapers.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }

    @MainActor
    func testStartupRemovesOnlyInterruptedStagingFolders() throws {
        let directory = storage.wallpapersDirectoryURL
        let staging = directory.appendingPathComponent("\(LocalImportFiles.stagingPrefix)\(UUID().uuidString)")
        let imported = directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: imported, withIntermediateDirectories: true)
        _ = LocalImportService(library: WallpaperLibrary(storage: storage))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.path), "Imported content is never swept")
    }

    @MainActor
    func testImportedVideoPlaysThroughRuntimeAfterOriginalIsDeleted() async throws {
        let original = try download(try fixture("loop-warm", "mp4"), as: "暖色.mp4")
        let library = WallpaperLibrary(storage: storage)
        let outcome = await LocalImportService(library: library).importItem(at: original)
        let wallpaper = try XCTUnwrap(outcome.wallpaper)
        try FileManager.default.removeItem(at: original)

        let desktop = DesktopWindowRuntime(identifier: NSUserInterfaceItemIdentifier("Kinetic.Import.UnitTest"))
        let manager = WallpaperRuntimeManager(desktop: CrossfadeDesktopHost(desktop: desktop))
        defer { manager.shutdown() }
        manager.apply(wallpaper)
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while manager.state.playbackState != .playing, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(manager.state.playbackState, .playing)
        XCTAssertEqual(manager.activeWallpaper, wallpaper)
        XCTAssertNil(manager.lastFailure)
    }

    @MainActor
    func testRendererAvailabilityMatchesTheStandardFactory() {
        for type in WallpaperType.allCases {
            let wallpaper = Wallpaper(name: "t", type: type, source: .local, resourceURL: URL(fileURLWithPath: "/t"))
            let created = (try? WallpaperRuntimeManager.standardRenderer(for: wallpaper)) != nil
            XCTAssertEqual(WallpaperRuntimeManager.isRendererAvailable(for: type), created, "\(type)")
        }
    }

    @MainActor
    func testOpenPanelOnlyOffersVideosAndFolders() {
        let panel = LocalImportPanel.makePanel()
        XCTAssertTrue(panel.canChooseFiles)
        XCTAssertTrue(panel.canChooseDirectories)
        XCTAssertTrue(panel.allowsMultipleSelection)
        XCTAssertFalse(panel.canCreateDirectories)
        XCTAssertEqual(Set(panel.allowedContentTypes), [.mpeg4Movie, .quickTimeMovie, .folder])
        XCTAssertEqual(panel.prompt, "导入")
    }
}
