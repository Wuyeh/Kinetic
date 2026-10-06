import Combine
import Foundation
import XCTest
@testable import Kinetic

/// 1.0 Module 9：创意工坊项目的校验（project.json）、入本地资料库、下载流程（假的 SteamCMD）。
final class SteamWorkshopImportTests: XCTestCase {
    private var temporaryRoots: [URL] = []
    private var suites: [String] = []

    override func tearDown() {
        for root in temporaryRoots { try? FileManager.default.removeItem(at: root) }
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        super.tearDown()
    }

    private func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KineticWorkshop-\(UUID().uuidString)",
                                                                                  isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        temporaryRoots.append(root)
        return root
    }

    private func fixture(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
    }

    /// 写一个 Wallpaper Engine 项目文件夹。
    @discardableResult
    private func makeProject(at folder: URL, project: [String: Any], files: [String: Data] = [:]) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: project).write(to: folder.appendingPathComponent("project.json"))
        for (path, data) in files {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        return folder
    }

    private let html = Data("<html><body>kinetic</body></html>".utf8)
    private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])

    // MARK: - 校验

    func testPackageVerificationFollowsProjectJSON() async throws {
        let root = makeRoot()
        let video = try Data(contentsOf: fixture("loop", "mp4"))

        let videoPackage = try await SteamWorkshopPackage.verify(folder: makeProject(
            at: root.appendingPathComponent("video"),
            project: ["title": "海浪", "type": "Video", "file": "waves.mp4", "preview": "preview.jpg"],
            files: ["waves.mp4": video, "preview.jpg": jpeg]))
        XCTAssertEqual(videoPackage.type, .video)
        XCTAssertEqual(videoPackage.title, "海浪")
        XCTAssertEqual(videoPackage.entryPath, "waves.mp4")
        XCTAssertEqual(videoPackage.resourcePath, "waves.mp4")
        XCTAssertEqual(videoPackage.previewPath, "preview.jpg")
        XCTAssertGreaterThan(videoPackage.sizeInBytes, Int64(video.count))

        let web = try await SteamWorkshopPackage.verify(folder: makeProject(
            at: root.appendingPathComponent("web"), project: ["title": "网页", "type": "web", "file": "index.html"],
            files: ["index.html": html]))
        XCTAssertEqual(web.type, .web)
        XCTAssertEqual(web.resourcePath, "", "The web root is the project folder")
        XCTAssertNil(web.previewPath)

        let nested = try await SteamWorkshopPackage.verify(folder: makeProject(
            at: root.appendingPathComponent("nested"), project: ["type": "web", "file": "dist/index.html"],
            files: ["dist/index.html": html]))
        XCTAssertEqual(nested.resourcePath, "dist")
        XCTAssertNil(nested.title)

        let scene = try await SteamWorkshopPackage.verify(folder: makeProject(
            at: root.appendingPathComponent("scene"), project: ["type": "scene", "file": "scene.json"],
            files: ["scene.json": Data("{\"objects\":[]}".utf8)]))
        XCTAssertEqual(scene.type, .scene)
        XCTAssertEqual(scene.resourcePath, "")

        let untyped = try await SteamWorkshopPackage.verify(folder: makeProject(
            at: root.appendingPathComponent("untyped"), project: ["file": "clip.mp4"], files: ["clip.mp4": video]))
        XCTAssertEqual(untyped.type, .video, "Old projects without a type are recognised by their file")

        func expect(_ expected: SteamWorkshopPackageError, project: [String: Any], files: [String: Data] = [:],
                    line: UInt = #line) async throws {
            let folder = try makeProject(at: root.appendingPathComponent(UUID().uuidString), project: project, files: files)
            do {
                _ = try await SteamWorkshopPackage.verify(folder: folder)
                XCTFail("Expected \(expected)", line: line)
            } catch {
                XCTAssertEqual(error as? SteamWorkshopPackageError, expected, line: line)
            }
        }
        try await expect(.unsupportedType("application"), project: ["type": "application", "file": "app.exe"],
                         files: ["app.exe": html])
        try await expect(.missingEntry, project: ["type": "web", "file": "index.html"])
        try await expect(.missingEntry, project: ["type": "web", "file": "../outside/index.html"])
        try await expect(.missingEntry, project: ["type": "video", "file": "/etc/hosts"])
        try await expect(.webEntryNotIndex, project: ["type": "web", "file": "main.html"], files: ["main.html": html])
        try await expect(.unplayableVideo, project: ["type": "video", "file": "broken.mp4"], files: ["broken.mp4": html])

        let noProject = root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: noProject, withIntermediateDirectories: true)
        do { _ = try await SteamWorkshopPackage.verify(folder: noProject); XCTFail() } catch {
            XCTAssertEqual(error as? SteamWorkshopPackageError, .missingProject)
        }

        let linked = try makeProject(at: root.appendingPathComponent("linked"), project: ["type": "web", "file": "index.html"],
                                     files: ["index.html": html])
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("secret"),
                                                   withDestinationURL: URL(fileURLWithPath: "/etc"))
        do { _ = try await SteamWorkshopPackage.verify(folder: linked); XCTFail() } catch {
            XCTAssertEqual(error as? SteamWorkshopPackageError, .containsSymbolicLinks)
        }
    }

    // MARK: - 入库

    func testSceneVerificationPreservesFailureReasonInsteadOfReportingEveryErrorAsMissingEntry() async throws {
        let root = makeRoot()
        let missing = try makeProject(at: root.appendingPathComponent("missing-scene"),
                                      project: ["type": "scene", "file": "scene.json"])
        do {
            _ = try await SteamWorkshopPackage.verify(folder: missing)
            XCTFail("A missing scene entry must be rejected")
        } catch {
            XCTAssertEqual(error as? SteamWorkshopPackageError, .missingEntry)
        }
        let malformed = try makeProject(at: root.appendingPathComponent("malformed-scene"),
                                        project: ["type": "scene", "file": "scene.json"],
                                        files: ["scene.json": Data(#"{"objects":true}"#.utf8)])
        do {
            _ = try await SteamWorkshopPackage.verify(folder: malformed)
            XCTFail("Invalid scene JSON must be rejected")
        } catch SteamWorkshopPackageError.invalidScene(let reason) {
            XCTAssertTrue(reason.contains("scene objects"))
        }
    }

    @MainActor
    func testModernPackedSceneDownloadImportsOneLocalRecordWithoutApplying() async throws {
        let root = makeRoot()
        let scene = Data(#"{"objects":[]}"#.utf8)
        func u32(_ value: UInt32) -> Data {
            var value = value.littleEndian
            return withUnsafeBytes(of: &value) { Data($0) }
        }
        let magic = Data("PKGV0024".utf8)
        let name = Data("scene.json".utf8)
        let archive = u32(UInt32(magic.count)) + magic + u32(1)
            + u32(UInt32(name.count)) + name + u32(0) + u32(UInt32(scene.count)) + scene
        let source = try makeProject(at: root.appendingPathComponent("download/2204"),
                                     project: ["type": "Scene", "file": "scene.json", "title": "现代场景"],
                                     files: ["scene.pkg": archive])
        let library = WallpaperLibrary(storage: LibraryStorageLocation(rootURL: root.appendingPathComponent("Library")))
        let package = try await SteamWorkshopPackage.verify(folder: source)
        let record = try await SteamWorkshopImporter(library: library).importPackage(
            package, item: SteamWorkshopItemInfo(workshopID: "2204"), isInUse: { _ in false })
        XCTAssertEqual(record.type, .scene)
        XCTAssertEqual(record.acquisitionOrigin, .steamWorkshop)
        XCTAssertEqual(library.wallpaper(workshopID: "2204")?.id, record.id)
        XCTAssertEqual(library.wallpapers.count, 1)
        XCTAssertEqual(try Data(contentsOf: record.resourceURL.appendingPathComponent("scene.pkg")), archive)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "Import copies the download")
    }

    @MainActor
    func testImportCreatesOneLocalRecordAndUpdatesKeepItsIdentity() async throws {
        let root = makeRoot()
        let library = WallpaperLibrary(storage: LibraryStorageLocation(rootURL: root.appendingPathComponent("Library")))
        let source = try makeProject(at: root.appendingPathComponent("download/2201"),
                                     project: ["title": "项目标题", "type": "web", "file": "index.html",
                                               "preview": "preview.gif"],
                                     files: ["index.html": html, "preview.gif": jpeg])
        let package = try await SteamWorkshopPackage.verify(folder: source)
        let updated = Date(timeIntervalSince1970: 1_700_000_000)
        let item = SteamWorkshopItemInfo(workshopID: "2201", title: "极光之夜", authorName: "北境工作室",
                                         fileSize: 1234, timeUpdated: updated)
        let importer = SteamWorkshopImporter(library: library)

        let first = try await importer.importPackage(package, item: item, isInUse: { _ in false })
        XCTAssertEqual(first.name, "极光之夜", "The store title wins over project.json")
        XCTAssertEqual(first.type, .web)
        XCTAssertEqual(first.acquisitionOrigin, .steamWorkshop)
        XCTAssertEqual(first.steamMetadata, SteamMetadata(workshopID: "2201", author: "北境工作室", sizeInBytes: 1234,
                                                          remoteUpdatedAt: updated))
        let recordFolder = library.storage.wallpapersDirectoryURL.appendingPathComponent(first.id.uuidString)
        XCTAssertTrue(WallpaperDeletionService.isInside(first.resourceURL, folder: recordFolder),
                      "Steam content lives in the folder the deletion flow manages")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.resourceURL.appendingPathComponent("index.html").path))
        XCTAssertEqual(first.thumbnailURL?.lastPathComponent, "preview.gif")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "The download is copied, not moved")
        XCTAssertEqual(library.wallpapers(in: .local).map(\.id), [first.id])
        let firstVersion = first.resourceURL.deletingLastPathComponent()
        try library.setFavorite(true, for: first.id)

        // 更新：同一条记录、保留喜爱与加入时间，旧版本在没有使用时立即删除。
        let newer = SteamWorkshopItemInfo(workshopID: "2201", title: "极光之夜 2", timeUpdated: updated.addingTimeInterval(60))
        let second = try await importer.importPackage(package, item: newer, isInUse: { _ in false })
        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(second.name, "极光之夜 2")
        XCTAssertTrue(second.isFavorite)
        XCTAssertEqual(second.importedAt, library.wallpaper(id: first.id)?.importedAt)
        XCTAssertEqual(second.steamMetadata?.author, "北境工作室", "The known author is kept")
        XCTAssertEqual(library.wallpapers.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstVersion.path))

        // 正在使用时不强制热切：旧版本保留，直到下次启动清理。
        let secondVersion = second.resourceURL.deletingLastPathComponent()
        let third = try await importer.importPackage(package, item: newer, isInUse: { $0 == first.id })
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondVersion.path))
        XCTAssertNotEqual(third.resourceURL, second.resourceURL)
        SteamWorkshopImporter.removeStaleVersions(in: library)
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondVersion.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: third.resourceURL.path))

        // 重新打开资料库：记录与元数据都保留（格式 2）。
        let reopened = WallpaperLibrary(storage: library.storage)
        XCTAssertEqual(reopened.wallpaper(workshopID: "2201")?.steamMetadata?.remoteUpdatedAt,
                       updated.addingTimeInterval(60))
    }

    @MainActor
    func testVideoWithoutAnAuthorPosterGetsARepresentativeFrame() async throws {
        let root = makeRoot()
        let library = WallpaperLibrary(storage: LibraryStorageLocation(rootURL: root.appendingPathComponent("Library")))
        let source = try makeProject(at: root.appendingPathComponent("download/77"),
                                     project: ["title": "Loop", "type": "video", "file": "loop.mp4"],
                                     files: ["loop.mp4": try Data(contentsOf: fixture("loop", "mp4"))])
        let package = try await SteamWorkshopPackage.verify(folder: source)
        let record = try await SteamWorkshopImporter(library: library)
            .importPackage(package, item: SteamWorkshopItemInfo(workshopID: "77"), isInUse: { _ in false })
        XCTAssertEqual(record.name, "Loop", "project.json title is used when the store gives none")
        XCTAssertEqual(record.resourceURL.lastPathComponent, "loop.mp4")
        XCTAssertEqual(record.thumbnailURL?.lastPathComponent, LocalImportService.thumbnailFileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(record.thumbnailURL).path))
    }

    // MARK: - 完整流程（假的 SteamCMD）

    @MainActor
    private func makeService(_ fake: FakeSteamCMD, signedIn: Bool = true) -> (SteamAcquisitionService, WallpaperLibrary) {
        let root = makeRoot()
        let installation = SteamCMDInstallation(rootURL: root.appendingPathComponent("SteamCMD", isDirectory: true))
        try? FileManager.default.createDirectory(at: installation.rootURL, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: installation.scriptURL.path, contents: Data("#!/bin/bash\n".utf8))
        let suite = "KineticWorkshopTests-\(UUID().uuidString)"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        if signedIn { defaults.set("wu", forKey: SteamAcquisitionService.usernameKey) }
        let library = WallpaperLibrary(storage: LibraryStorageLocation(rootURL: root.appendingPathComponent("Library")))
        let service = SteamAcquisitionService(installation: installation, library: library, defaults: defaults,
                                              makeProcess: fake.factory)
        service.progressInterval = 0.02
        return (service, library)
    }

    @MainActor
    func testDownloadAddsTheItemToTheLocalLibraryOnly() async throws {
        let fake = FakeSteamCMD()
        var service: SteamAcquisitionService!
        fake.configure = { [unowned self] process in
            process.script = { process in
                let folder = service.installation.contentURL(for: "2201")
                _ = try? self.makeProject(at: folder, project: ["title": "极光", "type": "web", "file": "index.html"],
                                      files: ["index.html": self.html])
                process.emit("Logging in user 'wu' to Steam Public...OK\nWaiting for user info...OK\n")
                process.emit("Downloading item 2201 ...\nSuccess. Downloaded item 2201 to \"\(folder.path)\" (33 bytes)\n")
                process.finish(0)
            }
        }
        let made = makeService(fake)
        service = made.0
        let library = made.1
        let item = SteamWorkshopItemInfo(workshopID: "2201", title: "极光之夜", authorName: "北境", fileSize: 33)

        let result = await service.acquire(item)
        let wallpaper = try result.get()
        XCTAssertEqual(library.wallpaper(workshopID: "2201")?.id, wallpaper.id)
        XCTAssertEqual(wallpaper.acquisitionOrigin, .steamWorkshop)
        XCTAssertEqual(service.tasks["2201"], .finished(wallpaper.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.installation.contentURL(for: "2201").path),
                       "SteamCMD's copy is removed after it is in the library")
        let process = try XCTUnwrap(fake.processes.last)
        XCTAssertEqual(process.arguments, ["+@ShutdownOnFailedCommand", "1", "+@NoPromptForPassword", "1",
                                           "+force_install_dir", service.installation.downloadsURL.path,
                                           "+login", "wu",
                                           "+workshop_download_item", "431960", "2201", "validate", "+quit"])
        XCTAssertTrue(process.written.isEmpty, "Downloads never type a password")

        // 已在资料库：不重复下载。
        let again = await service.acquire(item)
        XCTAssertEqual(again.failureValue, .alreadyInLibrary(wallpaper.id))
        XCTAssertEqual(fake.processes.count, 1)
    }

    @MainActor
    func testDownloadFailuresAreExplained() async throws {
        let fake = FakeSteamCMD()
        let (service, library) = makeService(fake)

        fake.configure = { process in
            process.script = { $0.emit("Waiting for user info...OK\nERROR! Download item 9 failed (Access Denied).\n"); $0.finish(0) }
        }
        let denied = await service.acquire(SteamWorkshopItemInfo(workshopID: "9"))
        XCTAssertEqual(denied.failureValue, .noLicense)
        XCTAssertEqual(service.tasks["9"], .failed(SteamAcquisitionError.noLicense.localizedDescription))

        fake.configure = { process in
            process.script = { $0.emit("Success. Downloaded item 10 to \"/Users/someone/Documents/10\" (1 bytes)\n"); $0.finish(0) }
        }
        let outside = await service.acquire(SteamWorkshopItemInfo(workshopID: "10"))
        XCTAssertEqual(outside.failureValue,
                       .downloadFailed(NSLocalizedString("steam.error.unexpectedPath", comment: "")),
                       "Paths outside Kinetic's SteamCMD folder are never imported")

        fake.configure = { process in process.script = { $0.emit("Cached credentials not found.\n"); $0.finish(5) } }
        let expired = await service.acquire(SteamWorkshopItemInfo(workshopID: "11"))
        XCTAssertEqual(expired.failureValue, .signInRequired)
        XCTAssertEqual(service.signInState, .failed(.passwordRequired), "The settings page asks to sign in again")

        let before = fake.processes.count
        let notSignedIn = await service.acquire(SteamWorkshopItemInfo(workshopID: "12"))
        XCTAssertEqual(notSignedIn.failureValue, .signInRequired)
        XCTAssertEqual(fake.processes.count, before, "Nothing runs without a signed-in account")

        fake.configure = { process in process.script = { $0.finish(1) } }
        let (fresh, _) = makeService(fake)
        let crashed = await fresh.acquire(SteamWorkshopItemInfo(workshopID: "13"))
        XCTAssertEqual(crashed.failureValue,
                       .downloadFailed(String(format: NSLocalizedString("steam.exitCode", comment: ""), 1)))
        XCTAssertTrue(library.wallpapers.isEmpty)
    }

    @MainActor
    func testOnlyOneSteamCMDRunsAtATime() async throws {
        let fake = FakeSteamCMD()
        var service: SteamAcquisitionService!
        var running = 0
        var maximum = 0
        fake.configure = { [unowned self] process in
            process.script = { process in
                running += 1
                maximum = max(maximum, running)
                let id = process.arguments[process.arguments.firstIndex(of: "431960")! + 1]
                let folder = service.installation.contentURL(for: id)
                _ = try? self.makeProject(at: folder, project: ["type": "web", "file": "index.html"],
                                      files: ["index.html": self.html])
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    process.emit("Success. Downloaded item \(id) to \"\(folder.path)\" (1 bytes)\n")
                    running -= 1
                    process.finish(0)
                }
            }
        }
        service = makeService(fake).0
        let steam: SteamAcquisitionService = service
        async let first = steam.acquire(SteamWorkshopItemInfo(workshopID: "1"))
        async let second = steam.acquire(SteamWorkshopItemInfo(workshopID: "2"))
        let results = await [first, second]
        XCTAssertTrue(results.allSatisfy { (try? $0.get()) != nil })
        XCTAssertEqual(maximum, 1)
        XCTAssertEqual(fake.processes.count, 2)
    }

    // MARK: - Module 28：Scene 的创意工坊依赖项

    private let sceneJSON = Data(#"{"camera":{"center":"0 0 0"},"general":{"orthogonalprojection":{"width":64,"height":64}},"objects":[]}"#.utf8)

    /// 假的 SteamCMD：按参数里的编号写出项目；`failing` 中的编号报告下载失败。
    @MainActor
    private func configureSceneDownloads(_ fake: FakeSteamCMD, service: @escaping () -> SteamAcquisitionService,
                                         failing: Set<String> = []) {
        fake.configure = { [unowned self] process in
            process.script = { process in
                let id = process.arguments[process.arguments.firstIndex(of: "431960")! + 1]
                if failing.contains(id) {
                    process.emit("ERROR! Download item \(id) failed (Timeout).\n"); process.finish(0); return
                }
                let folder = service().installation.contentURL(for: id)
                if id == "4401" {
                    _ = try? self.makeProject(at: folder, project: ["title": "依赖场景", "type": "scene", "file": "scene.json",
                                                                    "dependencies": ["4402", 4403] as [Any]],
                                              files: ["scene.json": self.sceneJSON])
                } else {
                    _ = try? self.makeProject(at: folder, project: ["title": "素材包 \(id)", "type": "scene"],
                                              files: ["materials/shared.json": Data("{}".utf8)])
                }
                process.emit("Success. Downloaded item \(id) to \"\(folder.path)\" (1 bytes)\n")
                process.finish(0)
            }
        }
    }

    @MainActor
    func testSceneDependenciesAreDownloadedWithTheWallpaper() async throws {
        let fake = FakeSteamCMD()
        var service: SteamAcquisitionService!
        configureSceneDownloads(fake, service: { service })
        let made = makeService(fake)
        service = made.0
        let library = made.1
        let wallpaper = try await service.acquire(SteamWorkshopItemInfo(workshopID: "4401")).get()
        XCTAssertEqual(wallpaper.type, .scene)
        XCTAssertEqual(fake.processes.map { $0.arguments[$0.arguments.firstIndex(of: "431960")! + 1] }, ["4401", "4402", "4403"])
        let store = WorkshopDependencyStore(storage: library.storage)
        for id in ["4402", "4403"] {
            let folder = try XCTUnwrap(store.folder(for: id, library: library), id)
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("materials/shared.json").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: service.installation.contentURL(for: id).path),
                           "SteamCMD's copy of the dependency is removed")
        }
        XCTAssertNil(library.wallpaper(workshopID: "4402"), "Dependencies are not library wallpapers")
        XCTAssertEqual(store.missingDependencies(of: wallpaper, library: library), [])
        XCTAssertTrue(service.dependencyFailures.isEmpty)

        // The renderer receives exactly the local dependency folders.
        SceneRenderer.dependencyProvider = { store.folder(for: $0, library: library) }
        defer { SceneRenderer.dependencyProvider = nil }
        XCTAssertEqual(Set(SceneRenderer.dependencyFolders(for: wallpaper).keys), ["4402", "4403"])

        // Updating the wallpaper does not download dependencies that are already here.
        _ = try await service.acquire(SteamWorkshopItemInfo(workshopID: "4401"), allowUpdate: true).get()
        XCTAssertEqual(fake.processes.count, 4)
    }

    @MainActor
    func testFailedDependencyKeepsTheWallpaperAndIsReported() async throws {
        let fake = FakeSteamCMD()
        var service: SteamAcquisitionService!
        configureSceneDownloads(fake, service: { service }, failing: ["4402"])
        let made = makeService(fake)
        service = made.0
        let library = made.1
        let wallpaper = try await service.acquire(SteamWorkshopItemInfo(workshopID: "4401")).get()
        XCTAssertEqual(library.wallpaper(workshopID: "4401")?.id, wallpaper.id)
        XCTAssertNotNil(service.dependencyFailures["4402"])
        let store = WorkshopDependencyStore(storage: library.storage)
        XCTAssertEqual(store.missingDependencies(of: wallpaper, library: library), ["4402"])
        XCTAssertNotNil(store.folder(for: "4403", library: library))
    }

    @MainActor
    func testLocallyImportedSceneFetchesMissingDependenciesOnlyWhenSignedIn() async throws {
        let fake = FakeSteamCMD()
        var service: SteamAcquisitionService!
        configureSceneDownloads(fake, service: { service })
        let made = makeService(fake)
        service = made.0
        let library = made.1
        let source = try makeProject(at: makeRoot().appendingPathComponent("local-scene"),
                                     project: ["title": "本地依赖场景", "type": "scene", "file": "scene.json", "dependencies": ["4402"]],
                                     files: ["scene.json": sceneJSON])
        let importer = LocalImportService(library: library)
        var imported: [Wallpaper.ID] = []
        importer.onImported = { imported.append($0.id) }
        let wallpaper = try await importer.importItem(at: source).result.get()
        XCTAssertEqual(imported, [wallpaper.id])
        await service.fetchMissingDependencies(of: wallpaper)
        XCTAssertEqual(fake.processes.count, 1)
        XCTAssertNotNil(WorkshopDependencyStore(storage: library.storage).folder(for: "4402", library: library))
        await service.fetchMissingDependencies(of: wallpaper)
        XCTAssertEqual(fake.processes.count, 1, "Nothing left to download")

        let signedOut = FakeSteamCMD()
        let (offline, offlineLibrary) = makeService(signedOut, signedIn: false)
        let other = try await LocalImportService(library: offlineLibrary).importItem(at: source).result.get()
        await offline.fetchMissingDependencies(of: other)
        XCTAssertTrue(signedOut.processes.isEmpty, "Signed out: no SteamCMD run, no sign-in prompt")
    }

    /// 28.4：设置 › Steam「下载缺少的依赖项」——统计资料库中所有 Scene 缺少的依赖项（去重），已登录时一次补下；
    /// 失败的留在列表里并报告原因，再次下载时只下载仍缺少的。未登录时不运行 SteamCMD。
    @MainActor
    func testSettingsDownloadsEveryMissingLibraryDependencyOnce() async throws {
        let fake = FakeSteamCMD()
        var service: SteamAcquisitionService!
        configureSceneDownloads(fake, service: { service }, failing: ["4405"])
        let made = makeService(fake)
        service = made.0
        let library = made.1
        let importer = LocalImportService(library: library)
        for (name, dependencies) in [("scene-a", ["4402", "4403"]), ("scene-b", ["4403", "4405"])] {
            let source = try makeProject(at: makeRoot().appendingPathComponent(name),
                                         project: ["title": name, "type": "scene", "file": "scene.json", "dependencies": dependencies],
                                         files: ["scene.json": sceneJSON])
            _ = try await importer.importItem(at: source).result.get()
        }
        let before = service.missingLibraryDependencies()
        XCTAssertEqual(Set(before.ids), ["4402", "4403", "4405"])
        XCTAssertEqual(before.ids.count, 3, "Shared dependencies are counted once")
        XCTAssertEqual(before.wallpaperCount, 2)

        var phases: [SteamAcquisitionService.DependencyDownloadPhase] = []
        let observation = service.$dependencyDownload.sink { phases.append($0) }
        defer { observation.cancel() }
        let allSucceeded = await service.downloadMissingLibraryDependencies()
        XCTAssertFalse(allSucceeded)
        let downloaded = fake.processes.map { $0.arguments[$0.arguments.firstIndex(of: "431960")! + 1] }
        XCTAssertEqual(downloaded.count, 3); XCTAssertEqual(Set(downloaded), ["4402", "4403", "4405"])
        XCTAssertEqual(phases.first, .idle); XCTAssertEqual(phases.last, .idle)
        XCTAssertTrue(phases.contains(.downloading(completed: 0, total: 3)))
        XCTAssertTrue(phases.contains(.downloading(completed: 3, total: 3)))
        let after = service.missingLibraryDependencies()
        XCTAssertEqual(after.ids, ["4405"]); XCTAssertEqual(after.wallpaperCount, 1)
        XCTAssertNotNil(service.dependencyFailures["4405"])
        XCTAssertNil(library.wallpaper(workshopID: "4402"), "Dependencies never become library wallpapers")

        configureSceneDownloads(fake, service: { service })
        let retried = await service.downloadMissingLibraryDependencies()
        XCTAssertTrue(retried)
        XCTAssertEqual(fake.processes.count, 4, "Only the dependency still missing is downloaded again")
        XCTAssertTrue(service.missingLibraryDependencies().isEmpty)
        XCTAssertNil(service.dependencyFailures["4405"])

        let signedOut = FakeSteamCMD()
        let (offline, offlineLibrary) = makeService(signedOut, signedIn: false)
        let source = try makeProject(at: makeRoot().appendingPathComponent("offline-scene"),
                                     project: ["title": "offline", "type": "scene", "file": "scene.json", "dependencies": ["4402"]],
                                     files: ["scene.json": sceneJSON])
        _ = try await LocalImportService(library: offlineLibrary).importItem(at: source).result.get()
        XCTAssertEqual(offline.missingLibraryDependencies().ids, ["4402"])
        let offlineResult = await offline.downloadMissingLibraryDependencies()
        XCTAssertFalse(offlineResult)
        XCTAssertTrue(signedOut.processes.isEmpty, "Signed out: no SteamCMD run, no sign-in prompt")
        XCTAssertEqual(offline.dependencyDownload, .idle)
    }

    @MainActor
    func testUnreferencedDependenciesAreRemovedAtLaunch() async throws {
        let fake = FakeSteamCMD()
        var service: SteamAcquisitionService!
        configureSceneDownloads(fake, service: { service })
        let made = makeService(fake)
        service = made.0
        let library = made.1
        _ = try await service.acquire(SteamWorkshopItemInfo(workshopID: "4401")).get()
        let store = WorkshopDependencyStore(storage: library.storage)
        let orphan = try makeProject(at: store.rootURL.appendingPathComponent("9999"), project: ["type": "scene"])
        let staging = store.rootURL.appendingPathComponent(LocalImportFiles.stagingPrefix + "x")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let unsafe = try makeProject(at: store.rootURL.appendingPathComponent("notes"), project: ["type": "scene"])
        store.removeUnreferenced(library: library)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unsafe.path), "Only Workshop-ID folders are managed")
        XCTAssertNotNil(store.folder(for: "4402", library: library))
        XCTAssertNil(store.folder(for: "../4402", library: library), "Only numeric IDs resolve")
    }
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
