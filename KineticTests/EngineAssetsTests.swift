import Combine
import Foundation
import XCTest
@testable import Kinetic

/// 1.0 Module 28 — Wallpaper Engine 引擎素材：链接用户的文件夹、用 Steam 下载并只保留 assets、恢复与失效、解析下载进度。
@MainActor
final class EngineAssetsTests: XCTestCase {
    private var root: URL!
    private var suites: [String] = []

    /// 测试用书签：只记录路径（正式环境使用只读安全范围书签）。
    private static let pathBookmarks = EngineAssetsBookmarks(
        make: { Data($0.path.utf8) },
        resolve: { (URL(fileURLWithPath: String(decoding: $0, as: UTF8.self), isDirectory: true), false) })

    override func setUp() async throws {
        root = TestWorkspaceDirectory.make(".build/Module28/EngineAssets")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func makeDefaults() -> UserDefaults {
        let name = "KineticEngineAssetsTests-\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    @discardableResult
    private func makeInstall(_ relative: String, withAssets: Bool = true) throws -> URL {
        let install = root.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: install, withIntermediateDirectories: true)
        if withAssets {
            for child in ["assets/shaders", "assets/materials"] {
                try FileManager.default.createDirectory(at: install.appendingPathComponent(child, isDirectory: true),
                                                        withIntermediateDirectories: true)
            }
        }
        return install
    }

    func testAssetsFolderAcceptsInstallFolderOrAssetsFolderOnly() throws {
        let install = try makeInstall("wallpaper_engine")
        let assets = install.appendingPathComponent("assets", isDirectory: true)
        XCTAssertEqual(EngineAssetsStore.assetsFolder(in: install)?.standardizedFileURL, assets.standardizedFileURL)
        XCTAssertEqual(EngineAssetsStore.assetsFolder(in: assets)?.standardizedFileURL, assets.standardizedFileURL)
        let other = try makeInstall("other", withAssets: false)
        XCTAssertNil(EngineAssetsStore.assetsFolder(in: other))
        try FileManager.default.createDirectory(at: other.appendingPathComponent("assets/shaders"), withIntermediateDirectories: true)
        XCTAssertNil(EngineAssetsStore.assetsFolder(in: other), "assets without materials is not a Wallpaper Engine folder")
    }

    func testLinkPersistsAcrossLaunchesAndMovedFolderIsReportedNotReplaced() throws {
        let defaults = makeDefaults()
        let managed = root.appendingPathComponent("managed/wallpaper_engine", isDirectory: true)
        let install = try makeInstall("wallpaper_engine")
        let store = EngineAssetsStore(defaults: defaults, managedInstallURL: managed, bookmarks: Self.pathBookmarks)
        XCTAssertEqual(store.status, .notConfigured)
        XCTAssertNil(store.assetsURL)

        XCTAssertThrowsError(try store.link(folder: try makeInstall("plain", withAssets: false))) {
            XCTAssertEqual($0 as? EngineAssetsError, .notWallpaperEngineFolder)
        }
        XCTAssertEqual(store.status, .notConfigured)

        try store.link(folder: install)
        XCTAssertEqual(store.status, .ready(.linked, name: "wallpaper_engine"))
        XCTAssertEqual(store.assetsURL?.standardizedFileURL, install.appendingPathComponent("assets").standardizedFileURL)

        let relaunched = EngineAssetsStore(defaults: defaults, managedInstallURL: managed, bookmarks: Self.pathBookmarks)
        XCTAssertEqual(relaunched.status, .ready(.linked, name: "wallpaper_engine"))

        let moved = root.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.moveItem(at: install, to: moved)
        relaunched.refresh()
        guard case .unavailable(.linked, _) = relaunched.status else { return XCTFail("\(relaunched.status)") }
        XCTAssertNil(relaunched.assetsURL)

        relaunched.unlink()
        XCTAssertEqual(relaunched.status, .notConfigured)
        XCTAssertFalse(relaunched.hasLink)
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.appendingPathComponent("assets/shaders").path),
                      "Unlinking never touches the user's folder")
    }

    func testPruneKeepsOnlyAssetsAndRefusesFoldersWithoutAssets() throws {
        let install = try makeInstall("managed/wallpaper_engine")
        try Data("x".utf8).write(to: install.appendingPathComponent("assets/shaders/genericimage2.frag"))
        try Data("exe".utf8).write(to: install.appendingPathComponent("wallpaper64.exe"))
        try FileManager.default.createDirectory(at: install.appendingPathComponent("steamapps/downloading"), withIntermediateDirectories: true)
        try EngineAssetsStore.prune(installFolder: install)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: install.path), ["assets"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: install.appendingPathComponent("assets/shaders/genericimage2.frag").path))

        let broken = try makeInstall("broken", withAssets: false)
        try Data("exe".utf8).write(to: broken.appendingPathComponent("wallpaper64.exe"))
        XCTAssertThrowsError(try EngineAssetsStore.prune(installFolder: broken))
        XCTAssertTrue(FileManager.default.fileExists(atPath: broken.appendingPathComponent("wallpaper64.exe").path))
    }

    func testDownloadRunsAppUpdateForWindowsThenKeepsOnlyAssets() async throws {
        let defaults = makeDefaults()
        defaults.set("wu", forKey: SteamAcquisitionService.usernameKey)
        let fake = FakeSteamCMD()
        let managed = root.appendingPathComponent("managed/wallpaper_engine", isDirectory: true)
        fake.configure = { process in
            process.script = { process in
                process.emit("Logging in user 'wu' to Steam Public...OK\nWaiting for user info...OK\n")
                process.emit(" Update state (0x61) downloading, progress: 50.00 (50 / 100)\n")
                for child in ["assets/shaders", "assets/materials", "bin"] {
                    try? FileManager.default.createDirectory(at: managed.appendingPathComponent(child), withIntermediateDirectories: true)
                }
                FileManager.default.createFile(atPath: managed.appendingPathComponent("wallpaper64.exe").path, contents: Data("exe".utf8))
                process.emit("Success! App '431960' fully installed.\n")
                process.finish(0)
            }
        }
        let steamRoot = root.appendingPathComponent("SteamCMD", isDirectory: true)
        try FileManager.default.createDirectory(at: steamRoot, withIntermediateDirectories: true)
        let installation = SteamCMDInstallation(rootURL: steamRoot)
        FileManager.default.createFile(atPath: installation.scriptURL.path, contents: Data("#!/bin/bash\n".utf8))
        let library = WallpaperLibrary(storage: LibraryStorageLocation(rootURL: root.appendingPathComponent("Library")))
        let steam = SteamAcquisitionService(installation: installation, library: library, defaults: defaults,
                                            makeProcess: fake.factory, installer: { _ in })
        XCTAssertTrue(steam.isSignedIn)

        let store = EngineAssetsStore(defaults: defaults, managedInstallURL: managed, bookmarks: Self.pathBookmarks)
        var sawProgress = false
        let observation = store.$downloadPhase.sink { if case .downloading(let value?) = $0, value == 0.5 { sawProgress = true } }
        defer { observation.cancel() }
        store.startDownload(using: steam)
        try await waitForSteam { store.status == .ready(.downloaded, name: nil) && store.downloadPhase == .idle }

        let arguments = try XCTUnwrap(fake.processes.first).arguments
        XCTAssertEqual(Array(arguments.suffix(4)), ["+app_update", "431960", "validate", "+quit"])
        XCTAssertTrue(arguments.contains("+@sSteamCmdForcePlatformType"))
        XCTAssertEqual(arguments[arguments.firstIndex(of: "+force_install_dir")! + 1], managed.path)
        XCTAssertTrue(sawProgress)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: managed.path), ["assets"])
        XCTAssertEqual(store.assetsURL?.lastPathComponent, "assets")
        XCTAssertTrue(library.wallpapers.isEmpty, "Downloading engine assets never adds library items")

        // 链接优先于下载；取消链接后回到下载的素材。
        try store.link(folder: try makeInstall("wallpaper_engine"))
        XCTAssertEqual(store.status, .ready(.linked, name: "wallpaper_engine"))
        store.unlink()
        XCTAssertEqual(store.status, .ready(.downloaded, name: nil))
    }

    func testDownloadWithoutLicenseFailsAndKeepsPreviousState() async throws {
        let defaults = makeDefaults()
        defaults.set("wu", forKey: SteamAcquisitionService.usernameKey)
        let fake = FakeSteamCMD()
        fake.configure = { process in
            process.script = { process in
                process.emit("Waiting for user info...OK\nERROR! Failed to install app '431960' (No subscription)\n")
                process.finish(0)
            }
        }
        let steamRoot = root.appendingPathComponent("SteamCMD", isDirectory: true)
        try FileManager.default.createDirectory(at: steamRoot, withIntermediateDirectories: true)
        let installation = SteamCMDInstallation(rootURL: steamRoot)
        FileManager.default.createFile(atPath: installation.scriptURL.path, contents: Data("#!/bin/bash\n".utf8))
        let library = WallpaperLibrary(storage: LibraryStorageLocation(rootURL: root.appendingPathComponent("Library")))
        let steam = SteamAcquisitionService(installation: installation, library: library, defaults: defaults,
                                            makeProcess: fake.factory, installer: { _ in })
        let store = EngineAssetsStore(defaults: defaults, managedInstallURL: root.appendingPathComponent("managed/wallpaper_engine"),
                                      bookmarks: Self.pathBookmarks)
        store.startDownload(using: steam)
        try await waitForSteam { if case .failed = store.downloadPhase { return true }; return false }
        XCTAssertEqual(store.downloadPhase, .failed(SteamAcquisitionError.noLicense.localizedDescription))
        XCTAssertEqual(store.status, .notConfigured)
    }

    func testAppUpdateOutputParsing() {
        var parser = SteamCMDOutputParser()
        XCTAssertEqual(parser.consume(" Update state (0x61) downloading, progress: 12.34 (25 / 100)\n"), [.appUpdateProgress(0.25)])
        XCTAssertEqual(parser.consume(" Update state (0x11) preallocating, progress: 40.00 (0 / 0)\n"), [.appUpdateProgress(0.4)])
        XCTAssertEqual(parser.consume(" Update state (0x3) reconfiguring, progress: 0.00 (0 / 0)\n"), [.appUpdateProgress(nil)])
        XCTAssertEqual(parser.consume("Success! App '431960' fully installed.\n"), [.appInstalled(appID: "431960")])
        XCTAssertEqual(parser.consume("ERROR! Failed to install app '431960' (No subscription)\n"),
                       [.appInstallFailed(appID: "431960", reason: "No subscription")])
        XCTAssertEqual(parser.consume("Error! App '431960' state is 0x202 after update job.\n"),
                       [.appInstallFailed(appID: "431960", reason: "Error! App '431960' state is 0x202 after update job.")])
    }
}
