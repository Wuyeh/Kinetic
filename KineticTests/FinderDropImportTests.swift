import AppKit
import AVFoundation
import UniformTypeIdentifiers
import XCTest
@testable import Kinetic

/// Kinetic 1.0 Module 8：Local Import（File Picker + Finder 拖入）。
/// 临时目录模拟 Finder 中用户的文件与 Kinetic 的 Library Storage，不接触正式资料库。
final class FinderDropImportTests: XCTestCase {
    private var workspace: URL!
    private var finder: URL!
    private var storage: LibraryStorageLocation!

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("KineticDropTests-\(UUID().uuidString)", isDirectory: true)
        finder = workspace.appendingPathComponent("Desktop", isDirectory: true)
        storage = LibraryStorageLocation(rootURL: workspace.appendingPathComponent("Library", isDirectory: true))
        try FileManager.default.createDirectory(at: finder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workspace)
    }

    private func fixture(_ name: String, _ ext: String? = nil) throws -> URL {
        try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
    }

    /// 放到“桌面”上，作为用户要从 Finder 拖入的原始文件。
    private func place(_ source: URL, as name: String) throws -> URL {
        let target = finder.appendingPathComponent(name)
        try FileManager.default.copyItem(at: source, to: target)
        return target
    }

    private struct Timeout: Error {}

    @MainActor
    private func waitUntil(timeout: TimeInterval = 8, _ predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !predicate() {
            if ProcessInfo.processInfo.systemUptime > deadline {
                XCTFail("Condition not met within \(timeout) s")
                throw Timeout()
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - 格式

    func testSupportedVideoFormatsAreMP4MOVAndM4V() throws {
        XCTAssertEqual(VideoFormats.fileExtensions, ["mp4", "mov", "m4v"])
        let m4v = try XCTUnwrap(UTType(filenameExtension: "m4v"))
        XCTAssertTrue(VideoFormats.contentTypes.contains(m4v))
        XCTAssertTrue(VideoFormats.contentTypes.contains(.mpeg4Movie))
        XCTAssertTrue(VideoFormats.contentTypes.contains(.quickTimeMovie))
        XCTAssertTrue(VideoFormats.hasVideoExtension(URL(fileURLWithPath: "/x/A.M4V")))
        XCTAssertFalse(VideoFormats.hasVideoExtension(URL(fileURLWithPath: "/x/a.webm")))
    }

    /// M4V：导入后由真实 VideoRenderer 准备、播放、循环（规格 8：M4V 需经 Video Runtime 验证）。
    @MainActor
    func testM4VIsImportedAndPlaysThroughVideoRenderer() async throws {
        let original = try place(try fixture("loop", "m4v"), as: "片段.m4v")
        let library = WallpaperLibrary(storage: storage)
        let outcome = await LocalImportService(library: library).importItem(at: original)
        let wallpaper = try XCTUnwrap(outcome.wallpaper, "\(outcome.result)")
        XCTAssertEqual(wallpaper.type, .video)
        XCTAssertEqual(wallpaper.acquisitionOrigin, .localImport)
        XCTAssertEqual(wallpaper.resourceURL.pathExtension, "m4v")
        XCTAssertTrue(wallpaper.resourceURL.path.hasPrefix(storage.wallpapersDirectoryURL.path))
        XCTAssertNotNil(wallpaper.thumbnailURL)
        XCTAssertTrue(outcome.sourceUnchanged)
        XCTAssertTrue(LivePreviewEligibility.canLivePreview(wallpaper))

        let renderer = VideoRenderer(wallpaper: wallpaper)
        let desktop = DesktopWindowRuntime(identifier: NSUserInterfaceItemIdentifier("Kinetic.Drop.M4V"))
        defer { desktop.stop(); renderer.dispose() }
        try await renderer.prepare()
        XCTAssertTrue(desktop.present(renderer.contentView))
        renderer.play()
        try await waitUntil { renderer.currentTime.seconds > 0.5 }
        try await waitUntil(timeout: 10) { renderer.completedLoopCount >= 1 }
        XCTAssertNil(renderer.failure)
        XCTAssertTrue(renderer.isMuted)
    }

    @MainActor
    func testOtherVideoFormatsAreRejectedBeforeCopying() async throws {
        let video = try fixture("loop", "mp4")
        let items = try ["片段.webm", "片段.avi", "片段.mkv"].map { try place(video, as: $0) }
        let library = WallpaperLibrary(storage: storage)
        let outcomes = await LocalImportService(library: library).importItems(at: items)
        for outcome in outcomes {
            guard case .failure(let error) = outcome.result else { return XCTFail("\(outcome.sourceURL) imported") }
            XCTAssertEqual(error, .unsupportedItem)
            XCTAssertTrue(error.localizedDescription.hasPrefix("不支持此文件格式"))
        }
        XCTAssertTrue(library.wallpapers.isEmpty)
        XCTAssertEqual(FinderDropEvaluation.evaluate(items), .unsupported)
    }

    // MARK: - Poster

    func testPosterCandidatesStartNearTheBeginningAndSpreadAcrossTheClip() {
        XCTAssertEqual(PosterFrameSelector.candidateTimes(forDuration: 2.4).map { ($0 * 100).rounded() / 100 },
                       [0.24, 0.6, 1.2, 1.8])
        XCTAssertEqual(PosterFrameSelector.candidateTimes(forDuration: 30), [1, 7.5, 15, 22.5])
        XCTAssertEqual(PosterFrameSelector.candidateTimes(forDuration: .nan), [0])
    }

    /// 规格 8：本地视频没有 Poster 时避免黑色首帧。测试片前 1.6 秒是黑场，旧规则（1 秒 / 10% 处）会取到黑色画面。
    @MainActor
    func testPosterSkipsABlackIntro() async throws {
        let video = try fixture("dark-intro", "mp4")
        let asset = AVURLAsset(url: video)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let early = try await generator.image(at: CMTime(seconds: 0.3, preferredTimescale: 600)).image
        let earlyStats = try XCTUnwrap(PosterFrameSelector.statistics(of: early))
        XCTAssertLessThan(earlyStats.meanLuminance, PosterFrameSelector.darkThreshold, "The fixture starts black")

        let original = try place(video, as: "黑场片头.mp4")
        let library = WallpaperLibrary(storage: storage)
        let imported = await LocalImportService(library: library).importItem(at: original)
        let wallpaper = try XCTUnwrap(imported.wallpaper)
        let thumbnail = try XCTUnwrap(wallpaper.thumbnailURL)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(thumbnail as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let stats = try XCTUnwrap(PosterFrameSelector.statistics(of: image))
        XCTAssertGreaterThanOrEqual(stats.meanLuminance, PosterFrameSelector.darkThreshold, "Poster must not be the black intro")
        XCTAssertGreaterThan(stats.luminanceDeviation, 0.05, "Poster shows the actual picture")
    }

    @MainActor
    func testExistingClipsStillGetTheirEarlyFrame() async throws {
        // 普通视频的第一个候选画面就合格：仍取片长 10%（不超过 1 秒）处，与之前相同。
        let video = try fixture("loop", "mp4")
        let selected = await PosterFrameSelector.representativeFrame(of: video)
        let frame = try XCTUnwrap(selected)
        let stats = try XCTUnwrap(PosterFrameSelector.statistics(of: frame))
        XCTAssertTrue(PosterFrameSelector.isRepresentative(stats))
    }

    // MARK: - Finder 拖入

    @MainActor
    func testDropFeedbackDistinguishesImportableItemsFromUnsupportedOnes() throws {
        let mp4 = try place(try fixture("loop", "mp4"), as: "a.mp4")
        let mov = try place(try fixture("loop", "mov"), as: "B.MOV")
        let m4v = try place(try fixture("loop", "m4v"), as: "c.m4v")
        let web = try place(try fixture("web-sample"), as: "网页壁纸")
        let plainFolder = finder.appendingPathComponent("普通文件夹", isDirectory: true)
        try FileManager.default.createDirectory(at: plainFolder, withIntermediateDirectories: true)
        let text = finder.appendingPathComponent("说明.txt")
        try Data("hello".utf8).write(to: text)

        XCTAssertEqual(FinderDropEvaluation.evaluate([mp4]), .importable(count: 1))
        XCTAssertEqual(FinderDropEvaluation.evaluate([mp4, mov, m4v, web]), .importable(count: 4))
        XCTAssertEqual(FinderDropEvaluation.evaluate([text, mov, plainFolder]), .importable(count: 1))
        XCTAssertEqual(FinderDropEvaluation.evaluate([text, plainFolder]), .unsupported)
        XCTAssertEqual(FinderDropEvaluation.evaluate([URL(string: "https://example.com/a.mp4")!]), .unsupported)
        XCTAssertEqual(FinderDropEvaluation.evaluate([]), .unsupported)

        XCTAssertEqual(FinderDropEvaluation.importable(count: 1).dropOperation, .copy)
        XCTAssertEqual(FinderDropEvaluation.unsupported.dropOperation, .forbidden)
        XCTAssertEqual(NSLocalizedString(FinderDropEvaluation.importable(count: 2).titleKey, comment: ""), "添加到本地资料库")
        XCTAssertEqual(NSLocalizedString(FinderDropEvaluation.unsupported.titleKey, comment: ""), "不支持此文件格式")
    }

    /// Finder 拖入的项目以文件地址提供；忽略非文件内容，顺序与拖入顺序一致。
    func testFileURLsAreReadFromDraggedItems() async throws {
        let first = try place(try fixture("loop", "mp4"), as: "一.mp4")
        let second = try place(try fixture("loop-warm", "mp4"), as: "二.mp4")
        let providers = [NSItemProvider(object: first as NSURL),
                         NSItemProvider(object: "纯文本" as NSString),
                         NSItemProvider(object: URL(string: "https://example.com/x.mp4")! as NSURL),
                         NSItemProvider(object: second as NSURL)]
        let urls = await FinderDropDelegate.loadFileURLs(from: providers)
        XCTAssertEqual(urls.map(\.standardizedFileURL), [first.standardizedFileURL, second.standardizedFileURL])
    }

    /// 批量拖入：可以导入的进入「本地」，其余逐个报告；原文件不变；
    /// 导入期间正在播放的桌面壁纸、状态与声音设置都不受影响（不自动应用）。
    @MainActor
    func testDroppedItemsOnlyJoinTheLocalLibraryAndNeverChangeTheDesktop() async throws {
        let playing = try place(try fixture("loop", "mp4"), as: "正在播放.mp4")
        let library = WallpaperLibrary(storage: storage)
        let importer = LocalImportService(library: library)
        let first = await importer.importItem(at: playing)
        let current = try XCTUnwrap(first.wallpaper)

        let desktop = DesktopWindowRuntime(identifier: NSUserInterfaceItemIdentifier("Kinetic.Drop.Runtime"))
        let manager = WallpaperRuntimeManager(desktop: CrossfadeDesktopHost(desktop: desktop))
        defer { manager.shutdown() }
        manager.apply(current)
        try await waitUntil { manager.state.playbackState == .playing }
        let audioBefore = manager.isAudioEnabled

        let dropped = [try place(try fixture("loop-warm", "mp4"), as: "暖色.mp4"),
                       try place(try fixture("loop", "m4v"), as: "蓝色.m4v"),
                       finder.appendingPathComponent("说明.txt")]
        try Data("x".utf8).write(to: dropped[2])
        let outcomes = await importer.importItems(at: dropped)
        let summary = LocalImportSummary(outcomes: outcomes)

        XCTAssertEqual(summary.addedIDs.count, 2)
        XCTAssertEqual(summary.message, "已添加 2 个壁纸到本地资料库，1 个未能添加：\(LocalImportError.unsupportedItem.localizedDescription)")
        XCTAssertEqual(library.wallpapers(in: .local).map(\.name), ["蓝色", "暖色", "正在播放"])
        XCTAssertTrue(outcomes.allSatisfy(\.sourceUnchanged))
        XCTAssertEqual(manager.activeWallpaper, current, "Import never applies")
        XCTAssertEqual(manager.state.playbackState, .playing)
        XCTAssertEqual(manager.isAudioEnabled, audioBefore)
        XCTAssertNil(manager.lastFailure)
    }

    func testImportSummaryMessages() {
        func outcome(_ ok: Bool, _ error: LocalImportError = .unsupportedItem) -> LocalImportOutcome {
            let wallpaper = Wallpaper(name: "w", type: .video, acquisitionOrigin: .localImport,
                                      resourceURL: URL(fileURLWithPath: "/w.mp4"))
            return LocalImportOutcome(sourceURL: URL(fileURLWithPath: "/src"),
                                      result: ok ? .success(wallpaper) : .failure(error), sourceUnchanged: true)
        }
        let unsupported = LocalImportError.unsupportedItem.localizedDescription
        let video = LocalImportError.unplayableVideo.localizedDescription
        XCTAssertNil(LocalImportSummary(outcomes: []).message)
        XCTAssertEqual(LocalImportSummary(outcomes: [outcome(true)]).message, "已添加到本地资料库 ✓")
        XCTAssertEqual(LocalImportSummary(outcomes: [outcome(true), outcome(true), outcome(true)]).message,
                       "已添加 3 个壁纸到本地资料库 ✓")
        XCTAssertEqual(LocalImportSummary(outcomes: [outcome(false, .unplayableVideo)]).message, video)
        XCTAssertEqual(LocalImportSummary(outcomes: [outcome(false), outcome(false, .unplayableVideo)]).message,
                       "2 个项目未能添加：\(unsupported)")
        XCTAssertEqual(LocalImportSummary(outcomes: [outcome(false, .protectedVideo)]).message,
                       "这个视频受版权保护，不能作为壁纸。")
    }
}
