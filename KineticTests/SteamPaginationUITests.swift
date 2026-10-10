import AppKit
import SwiftUI
import XCTest
@testable import Kinetic

/// 用户修订（2026-10-07）：Workshop 使用服务器数字分页，滚动不触发请求。
/// 在真实 NSWindow / SwiftUI ScrollView 中验证跳页 / 重试 / 边界，不读钥匙串或联网。
@MainActor
final class SteamPaginationUITests: XCTestCase {
    private var roots: [URL] = []
    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.forEach { $0.contentView = nil; $0.close() }
        windows.removeAll()
        for root in roots { try? FileManager.default.removeItem(at: root) }
        super.tearDown()
    }

    /// 按真正的 page / numperpage 返回内容；非首屏可明确失败一次。
    private final class PagedSteam {
        var requestedPages: [Int] = []
        var pageCount = 5
        var failNext = false
        var cursorWasSent = false
        func fetch(_ url: URL) async throws -> (Data, Int) {
            guard url.path.contains("QueryFiles") else {
                if url.path.contains("GetPlayerSummaries") { return (Data(#"{"response":{"players":[]}}"#.utf8), 200) }
                return (Data(), 404)
            }
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let page = Int(items.first { $0.name == "page" }?.value ?? "1") ?? 1
            let count = Int(items.first { $0.name == "numperpage" }?.value ?? "30") ?? 30
            cursorWasSent = cursorWasSent || items.contains { $0.name == "cursor" }
            requestedPages.append(page)
            if failNext, page != 1 { failNext = false; throw URLError(.timedOut) }
            let details: [[String: Any]] = (0..<(page <= pageCount ? count : 0)).map { offset in
                let id = String(1000 + (page - 1) * count + offset)
                return ["publishedfileid": id, "result": 1, "title": "Item \(id)", "creator": "76561190000000001",
                        "time_created": 1_700_000_000 - (page - 1) * count - offset, "tags": [["tag": "Video"]]]
            }
            let body: [String: Any] = ["response": ["total": pageCount * count, "publishedfiledetails": details,
                "next_cursor": page < pageCount ? "legacy-next" : "*"]]
            return (try JSONSerialization.data(withJSONObject: body), 200)
        }
    }

    private func spin(seconds: TimeInterval = 5, until predicate: () -> Bool = { false }, every action: (() -> Void)? = nil) {
        let deadline = Date().addingTimeInterval(seconds)
        var lastAction = Date.distantPast
        while Date() < deadline, !predicate() {
            if let action, Date().timeIntervalSince(lastAction) > 0.15 { action(); lastAction = Date() }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    private func host(_ steam: PagedSteam) throws -> (SteamStoreService, NSScrollView) {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let root = base.appendingPathComponent(".build/DisplayWorkspaceRevision/PaginationFixtures/" + UUID().uuidString)
        roots.append(root)
        let store = SteamStoreService(keyStore: MemorySteamAPIKeyStore("0123456789ABCDEF0123456789ABCDEF"),
                                      cacheDirectory: root,
                                      posters: SteamPosterCache(directory: nil, fetch: { try await steam.fetch($0) }),
                                      fetch: { try await steam.fetch($0) })
        let library = WallpaperLibrary(storage: .init(rootURL: root.appendingPathComponent("Library")))
        let acquisition = SteamAcquisitionService(installation: SteamCMDInstallation(rootURL: root.appendingPathComponent("SteamCMD")),
                                                  library: library)
        let downloads = SteamDownloadPresentation()
        let size = CGSize(width: 860, height: 560)
        let view = GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SteamStoreBrowserView(store: store, steam: acquisition, library: library, downloads: downloads,
                                          options: ContentViewOptions(), sortMode: .constant(.recentlyPublished), availableWidth: 800,
                                          viewportHeight: proxy.size.height, showMessage: { _ in },
                                          selection: .constant(StableCardSelection()))
                }
                .padding(.horizontal, 30)
            }
        }
        .frame(width: size.width, height: size.height)
        .coordinateSpace(name: DownloadAnimationMetrics.coordinateSpace)
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -4000, y: -4000), size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.orderFrontRegardless()
        windows.append(window)
        spin(until: { store.phase == .loaded })
        XCTAssertEqual(store.phase, .loaded)
        let scrollView = try XCTUnwrap(Self.firstScrollView(in: window.contentView!))
        return (store, scrollView)
    }

    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews { if let found = firstScrollView(in: child) { return found } }
        return nil
    }

    private func scrollToBottom(_ scrollView: NSScrollView) {
        guard let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let maxOffset = max(0, document.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: document.isFlipped ? maxOffset : 0))
        scrollView.reflectScrolledClipView(clip)
    }

    func testScrollingNeverLoadsAndNumberedNavigationReplacesEachPage() throws {
        let steam = PagedSteam()
        let (store, scrollView) = try host(steam)
        spin(seconds: 0.4, every: { self.scrollToBottom(scrollView) })
        XCTAssertEqual(steam.requestedPages, [1], "Scrolling to the bottom must not download another page")
        XCTAssertEqual(store.items.count, 30); XCTAssertFalse(steam.cursorWasSent)
        for page in 2...4 {
            store.goToPage(page)
            spin(until: { store.phase == .loaded && store.query.numberedPage == page })
            spin(seconds: 0.1)
            XCTAssertEqual(store.items.count, 30, "Navigation replaces, never appends")
            XCTAssertEqual(store.items.first?.workshopID, String(1000 + (page - 1) * 30))
            XCTAssertEqual(store.items.first?.serverRankIndex, (page - 1) * 30)
            XCTAssertEqual(scrollView.contentView.bounds.minY, 0, accuracy: 1, "A new page starts at its top")
            spin(seconds: 0.15, every: { self.scrollToBottom(scrollView) })
        }
        XCTAssertEqual(Set(store.items.map(\.workshopID)).count, store.items.count)
        XCTAssertEqual(steam.requestedPages, [1, 2, 3, 4], "Only explicit navigation requests pages")
    }

    func testFailedNumberedPageWaitsForExplicitRetryOfTheSamePage() throws {
        let steam = PagedSteam(); steam.failNext = true
        let (store, scrollView) = try host(steam)
        store.goToPage(2)
        spin(until: { if case .failed = store.phase { return true }; return false })
        guard case .failed = store.phase else { return XCTFail("Expected an explicit retryable failure") }
        XCTAssertEqual(store.query.numberedPage, 2)
        spin(seconds: 0.3, every: { self.scrollToBottom(scrollView) })
        XCTAssertEqual(steam.requestedPages, [1, 2], "A failure never retries by scrolling")
        store.reload()
        spin(until: { store.phase == .loaded })
        XCTAssertEqual(steam.requestedPages, [1, 2, 2]); XCTAssertEqual(store.items.count, 30)
        XCTAssertEqual(store.items.first?.workshopID, "1030"); XCTAssertFalse(store.canLoadMore)
    }

    func testPage500IsTheLastNumberedPageAndScrollingCannotRequest501() throws {
        let steam = PagedSteam(); steam.pageCount = 500
        let (store, scrollView) = try host(steam)
        store.goToPage(500); spin(until: { store.phase == .loaded })
        XCTAssertEqual(store.items.count, 30); XCTAssertEqual(store.items.first?.workshopID, "15970")
        XCTAssertEqual(store.query.numberedPage, 500); XCTAssertFalse(store.canLoadMore)
        spin(seconds: 0.3, every: { self.scrollToBottom(scrollView) })
        store.goToPage(501); store.loadMore(); spin(seconds: 0.2)
        XCTAssertEqual(steam.requestedPages, [1, 500], "Neither scrolling nor an out-of-range page triggers request 501")
        store.setResultsPerPage(65); spin(until: { store.phase == .loaded })
        XCTAssertEqual(store.query.numberedPage, 1); XCTAssertEqual(store.items.count, 65)
    }
}
