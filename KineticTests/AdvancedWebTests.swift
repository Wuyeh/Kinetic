import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import Kinetic

@MainActor private final class AdvancedWebHost: DesktopContentHost {
    var content: NSView?
    func present(_ contentView: NSView) -> Bool { content = contentView; return true }
    func stop() { content = nil }
}

@MainActor
final class AdvancedWebTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() { for root in roots { try? FileManager.default.removeItem(at: root) }; super.tearDown() }
    private func root() throws -> URL {
        let root = TestWorkspaceDirectory.make(".build/Module31/Fixtures")
        roots.append(root); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
    }
    private func fixture() throws -> Wallpaper {
        let root = try root()
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><style>
        html,body{margin:0;width:100%;height:100%;background:rgb(40,80,120)}
        #mark{position:absolute;left:40%;top:40%;width:20%;height:20%;background:#fff}
        </style></head><body><div id="mark"></div><script>
        window.initialized=1; window.frames=0; window.pointerMoves=0; window.lastPointer=null;
        document.addEventListener('pointermove',e=>{window.pointerMoves++; window.lastPointer=[e.clientX,e.clientY]});
        function tick(){window.frames++;requestAnimationFrame(tick)} requestAnimationFrame(tick);
        </script></body></html>
        """
        try html.write(to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        return Wallpaper(name: "高级网页原创验证", type: .web, source: .local, resourceURL: root)
    }
    private func wait(_ condition: () -> Bool, timeout: Double = 12) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { XCTFail("Timed out"); throw CancellationError() }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    private func js(_ source: String, _ renderer: WebRenderer) async throws -> Any? {
        try await XCTUnwrap(renderer.contentView.webView).evaluateJavaScript(source)
    }
    private func host(_ view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: .init(x: 90, y: 90, width: 640, height: 360),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView?.addSubview(view)
        view.frame = window.contentView?.bounds ?? .zero; view.autoresizingMask = [.width, .height]
        window.orderFrontRegardless(); return window
    }

    func testDefaultsAndBoundedFiniteValues() throws {
        let value = WebPlaybackOptions()
        XCTAssertTrue(value.javaScriptEnabled); XCTAssertFalse(value.mouseInteractionEnabled)
        XCTAssertFalse(value.trackerBlockingEnabled); XCTAssertFalse(value.physicalPixelLayout)
        XCTAssertEqual(value.scale, 1); XCTAssertEqual(value.customCSS, "")
        XCTAssertEqual(try value.validated(), value)
        var bad = value; bad.scale = .nan; XCTAssertThrowsError(try bad.validated())
        bad = value; bad.rotationDegrees = .infinity; XCTAssertThrowsError(try bad.validated())
        bad = value; bad.panY = 1.01; XCTAssertThrowsError(try bad.validated())
        bad = value; bad.customCSS = String(repeating: "中", count: 22_000); XCTAssertThrowsError(try bad.validated())
        bad = value; bad.customCSS = "a\0b"; XCTAssertThrowsError(try bad.validated())
        var reload = value; reload.javaScriptEnabled = false; XCTAssertTrue(reload.requiresReload(comparedTo: value))
        reload = value; reload.trackerBlockingEnabled = true; XCTAssertTrue(reload.requiresReload(comparedTo: value))
        reload = value; reload.scale = 2; reload.customCSS = "body{color:red}"; XCTAssertFalse(reload.requiresReload(comparedTo: value))
    }

    func testSettingsRoundTripPerWallpaperWithoutChangingSourceOrLibrary() throws {
        let wallpaper = try fixture(), other = try fixture(), storeRoot = try root()
        let entry = wallpaper.resourceURL.appendingPathComponent("index.html"), original = try Data(contentsOf: entry)
        let store = WebPlaybackStore(storage: .init(rootURL: storeRoot))
        var value = WebPlaybackOptions(); value.scale = 1.7; value.panX = -0.2; value.customCSS = "body{background:#456}"
        try store.save(value, for: wallpaper, runtime: nil)
        let restored = WebPlaybackStore(storage: .init(rootURL: storeRoot))
        XCTAssertEqual(restored.configuration(for: wallpaper.id), value)
        XCTAssertEqual(restored.configuration(for: other.id), .init())
        try restored.save(.init(), for: wallpaper, runtime: nil)
        XCTAssertEqual(WebPlaybackStore(storage: .init(rootURL: storeRoot)).configuration(for: wallpaper.id), .init())
        XCTAssertEqual(try Data(contentsOf: entry), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeRoot.appendingPathComponent("library.json").path))
    }

    func testCorruptFutureSymlinkAndWriteFailurePreserveExistingData() throws {
        let wallpaper = try fixture()
        for contents in [Data("invalid".utf8), Data("{\"version\":2,\"wallpapers\":{}}".utf8)] {
            let root = try root(), url = root.appendingPathComponent("web-settings.json")
            try contents.write(to: url)
            let store = WebPlaybackStore(storage: .init(rootURL: root))
            XCTAssertNotNil(store.loadError)
            XCTAssertThrowsError(try store.save(.init(), for: wallpaper, runtime: nil))
            XCTAssertEqual(try Data(contentsOf: url), contents)
        }
        let symlinkRoot = try root(), target = symlinkRoot.appendingPathComponent("target"), url = symlinkRoot.appendingPathComponent("web-settings.json")
        try Data("keep".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        XCTAssertNotNil(WebPlaybackStore(storage: .init(rootURL: symlinkRoot)).loadError)
        XCTAssertEqual(try Data(contentsOf: target), Data("keep".utf8))
        let failedRoot = try root(), store = WebPlaybackStore(storage: .init(rootURL: failedRoot))
        try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: false)
        var value = WebPlaybackOptions(); value.scale = 2
        XCTAssertThrowsError(try store.save(value, for: wallpaper, runtime: nil)); XCTAssertTrue(store.options.isEmpty)
    }

    func testJavaScriptToggleIsNativeAndCSSStillWorksWithoutContentScripts() async throws {
        let wallpaper = try fixture()
        var options = WebPlaybackOptions(); options.javaScriptEnabled = false; options.customCSS = "body{background:rgb(220,30,40)}"
        let renderer = WebRenderer(wallpaper: wallpaper, allowsNetwork: false, options: options)
        defer { renderer.dispose() }; try await renderer.prepare()
        let web = try XCTUnwrap(renderer.contentView.webView)
        XCTAssertFalse(web.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        let loaded = try await js("typeof window.initialized", renderer) as? String
        XCTAssertEqual(loaded, "undefined", "Actual inline content JavaScript did not execute")
        let color = try await js("getComputedStyle(document.body).backgroundColor", renderer) as? String
        XCTAssertEqual(color, "rgb(220, 30, 40)", "App-injected CSS remains available")
        XCTAssertTrue(renderer.contentView.hasPoster); XCTAssertTrue(renderer.isMuted)
        XCTAssertTrue(web.configuration.userContentController.userScripts.allSatisfy { !$0.source.contains("messageHandlers") })
        let blocked = try await js("typeof Worker === 'undefined' && typeof RTCPeerConnection === 'undefined'", renderer) as? Bool
        XCTAssertEqual(blocked, true)
    }

    func testCSSGeometryAndResetKeepDocumentAndPausedFrame() async throws {
        let renderer = WebRenderer(wallpaper: try fixture(), allowsNetwork: false)
        defer { renderer.dispose() }; try await renderer.prepare()
        let window = host(renderer.displayView); defer { window.close() }; renderer.play()
        let poster = try XCTUnwrap(renderer.contentView.layer?.sublayers?.first { $0.contents != nil })
        XCTAssertTrue(poster.isHidden, "Scale/Pan/Rotation cannot reveal a duplicate old poster behind the live page")
        try await Task.sleep(nanoseconds: 200_000_000)
        renderer.pause(); try await Task.sleep(nanoseconds: 100_000_000)
        let web = try XCTUnwrap(renderer.contentView.webView), frames = try await js("window.frames", renderer) as? Int
        var value = WebPlaybackOptions(); value.scale = 1.5; value.panX = 0.1; value.rotationDegrees = 25
        value.physicalPixelLayout = true; value.mouseInteractionEnabled = true
        value.customCSS = "body{background:rgb(70,180,100)}"
        try await renderer.updateOptions(value)
        XCTAssertTrue(renderer.contentView.webView === web)
        let sameFrames = try await js("window.frames", renderer) as? Int
        XCTAssertEqual(sameFrames, frames); XCTAssertFalse(renderer.isMouseInteractionActive)
        let color = try await js("getComputedStyle(document.body).backgroundColor", renderer) as? String
        XCTAssertEqual(color, "rgb(70, 180, 100)")
        let innerWidth = try await js("window.innerWidth", renderer) as? Double
        XCTAssertEqual(innerWidth ?? 0, web.bounds.width * window.backingScaleFactor, accuracy: 2)
        XCTAssertEqual(web.pageZoom, 1 / window.backingScaleFactor, accuracy: 0.001)
        try await renderer.updateOptions(.init())
        XCTAssertTrue(renderer.contentView.webView === web); XCTAssertEqual(web.pageZoom, 1)
        let resetColor = try await js("getComputedStyle(document.body).backgroundColor", renderer) as? String
        XCTAssertEqual(resetColor, "rgb(40, 80, 120)")
        let initCount = try await js("window.initialized", renderer) as? Int; XCTAssertEqual(initCount, 1)
        renderer.resume()
        // WebKit can throttle a native test window under full-suite load. Verify progress with
        // a bounded wait rather than assuming its first animation frame arrives within 150 ms.
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        var resumedFrames = try await js("window.frames", renderer) as? Int
        while (resumedFrames ?? 0) <= (frames ?? 0), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
            resumedFrames = try await js("window.frames", renderer) as? Int
        }
        XCTAssertGreaterThan(resumedFrames ?? 0, frames ?? 0)
        print("MODULE31 physical layout: native=\(web.bounds.width), backing=\(window.backingScaleFactor), physical CSS=\(innerWidth ?? 0)")
    }

    func testMouseCoordinateMappingAndTimerPauseStop() async throws {
        var options = WebPlaybackOptions(); options.mouseInteractionEnabled = true
        let mapped = try XCTUnwrap(WebAdvancedPolicy.mousePoint(.init(x: 100, y: 50), size: .init(width: 640, height: 360),
                                                              options: options, pageZoom: 0.5))
        XCTAssertEqual(mapped, CGPoint(x: 200, y: 620))
        options.panX = 0.25; options.rotationDegrees = 90
        let center = try XCTUnwrap(WebAdvancedPolicy.mousePoint(.init(x: 480, y: 180), size: .init(width: 640, height: 360),
                                                              options: options, pageZoom: 1))
        XCTAssertEqual(center.x, 320, accuracy: 0.01); XCTAssertEqual(center.y, 180, accuracy: 0.01)
        options.panX = 0; options.rotationDegrees = 0
        let renderer = WebRenderer(wallpaper: try fixture(), allowsNetwork: false, options: options)
        defer { renderer.dispose() }; try await renderer.prepare()
        let window = host(renderer.displayView); defer { window.close() }; renderer.play()
        XCTAssertTrue(renderer.isMouseInteractionActive)
        XCTAssertNil(renderer.contentView.hitTest(.init(x: 100, y: 100)))
        _ = try await js(WebAdvancedPolicy.mouseScript(.init(x: 123, y: 45)), renderer)
        let point = try await js("window.lastPointer", renderer) as? [Int]
        XCTAssertEqual(point, [123, 45])
        renderer.pause(); XCTAssertFalse(renderer.isMouseInteractionActive)
        renderer.resume(); XCTAssertTrue(renderer.isMouseInteractionActive)
        renderer.dispose(); XCTAssertFalse(renderer.isMouseInteractionActive); XCTAssertNil(renderer.contentView.webView)
    }

    func testTrackerRulesCompileAndOnlyMatchTheNamedDomains() async throws {
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(WebAdvancedPolicy.trackerRulesJSON.utf8)) as? [[String: Any]])
        let expressions = try rules.map { rule -> NSRegularExpression in
            let trigger = try XCTUnwrap(rule["trigger"] as? [String: String]); return try NSRegularExpression(pattern: XCTUnwrap(trigger["url-filter"]))
        }
        func matches(_ url: String) -> Bool { expressions.contains { $0.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil } }
        XCTAssertTrue(matches("https://www.google-analytics.com/collect"))
        XCTAssertTrue(matches("https://doubleclick.net:443/ad"))
        XCTAssertFalse(matches("https://google-analytics.com.example.org/path"))
        XCTAssertFalse(matches("https://images.example.org/google-analytics.com/photo"))
        let configuration = WebWallpaperPolicy.makeConfiguration(userScripts: [])
        var value = WebPlaybackOptions(); value.trackerBlockingEnabled = true
        try await WebWallpaperPolicy.installNetworkRules(on: configuration, allowsNetwork: false)
        try await WebAdvancedPolicy.install(on: configuration, options: value)
        let list: WKContentRuleList? = try await withCheckedThrowingContinuation { continuation in
            WKContentRuleListStore.default().lookUpContentRuleList(forIdentifier: "Kinetic.Web.Trackers.v1") { list, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: list) }
            }
        }
        XCTAssertNotNil(list); XCTAssertTrue(configuration.defaultWebpagePreferences.allowsContentJavaScript)
        XCTAssertEqual(configuration.websiteDataStore.isPersistent, false)
    }

    func testDraftIsolatedBurstSamePageAndOwnerCloseRelease() async throws {
        let wallpaper = try fixture(), storageRoot = try root(), owner = UUID()
        let store = WebPlaybackStore(storage: .init(rootURL: storageRoot))
        let preview = WebPlaybackPreview(debounceNanoseconds: 5_000_000)
        defer { preview.stop() }; let window = host(preview.surface)
        preview.update(wallpaper, options: .init(), allowsNetwork: false, ownerID: owner)
        try await wait { preview.renderer != nil && !preview.isPreparing }
        let initial = try XCTUnwrap(preview.renderer), web = initial.contentView.webView
        var value = WebPlaybackOptions()
        for i in 0..<20 { value.scale = 1 + Double(i) / 20; value.customCSS = "body{background:rgb(50,\(80+i),160)}"; preview.update(wallpaper, options: value, allowsNetwork: false, ownerID: owner) }
        try await wait { !preview.isPreparing && preview.renderer?.options == value }
        XCTAssertTrue(preview.renderer === initial); XCTAssertTrue(initial.contentView.webView === web)
        XCTAssertTrue(initial.isMuted); XCTAssertTrue(store.options.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        var invalid = value; invalid.scale = .nan
        preview.update(wallpaper, options: invalid, allowsNetwork: false, ownerID: owner)
        try await wait { preview.error != nil }; XCTAssertTrue(preview.renderer === initial)
        preview.stop(ownerID: UUID()); XCTAssertTrue(preview.renderer === initial, "Old owner cannot close another preview")
        window.close(); try await wait { preview.renderer == nil }
        XCTAssertNil(initial.contentView.webView)
    }

    func testDraftScriptChangeRefreshAndCancellationPrepareReplacement() async throws {
        let wallpaper = try fixture(), preview = WebPlaybackPreview(debounceNanoseconds: 0)
        defer { preview.stop() }; let window = host(preview.surface); defer { window.close() }
        preview.update(wallpaper, options: .init(), allowsNetwork: false)
        try await wait { preview.renderer != nil && !preview.isPreparing }
        let original = try XCTUnwrap(preview.renderer)
        var value = WebPlaybackOptions(); value.javaScriptEnabled = false
        preview.update(wallpaper, options: value, allowsNetwork: false)
        try await wait { !preview.isPreparing && preview.renderer?.options == value }
        XCTAssertFalse(preview.renderer === original); XCTAssertNil(original.contentView.webView)
        let replaced = try XCTUnwrap(preview.renderer)
        preview.update(wallpaper, options: value, allowsNetwork: false, forceReload: true)
        try await wait { !preview.isPreparing && preview.renderer !== replaced }
        XCTAssertNil(replaced.contentView.webView)
        preview.update(wallpaper, options: .init(), allowsNetwork: false)
        preview.stop(); try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertNil(preview.renderer); XCTAssertTrue(preview.surface.subviews.isEmpty)
    }

    func testSaveUpdatesOnlyMatchingDisplayAndRefreshPreservesManualPause() async throws {
        let a = try fixture(), b = try fixture(), store = WebPlaybackStore(storage: .init(rootURL: try root()))
        var created: [WebRenderer] = []
        let runtime = WallpaperRuntimeManager { wallpaper in
            let renderer = WebRenderer(wallpaper: wallpaper, allowsNetwork: false, options: store.configuration(for: wallpaper.id))
            created.append(renderer); return renderer
        }
        defer { runtime.shutdown() }
        let da = DisplayID("web-a"), db = DisplayID("web-b"), ha = AdvancedWebHost(), hb = AdvancedWebHost()
        runtime.addDisplay(da, host: ha); runtime.addDisplay(db, host: hb)
        runtime.apply(a, to: da); runtime.apply(b, to: db)
        try await wait { runtime.state(of: da)?.playbackState == .playing && runtime.state(of: db)?.playbackState == .playing }
        runtime.pause(.display(da)); runtime.setAudioEnabled(true, on: da)
        let oldA = try XCTUnwrap(created.first { $0.wallpaper.id == a.id }), oldB = try XCTUnwrap(created.first { $0.wallpaper.id == b.id })
        let webA = oldA.contentView.webView
        var value = WebPlaybackOptions(); value.scale = 1.3; value.customCSS = "body{color:#123}"
        try store.save(value, for: a, runtime: runtime); try await wait { oldA.options == value }
        XCTAssertEqual(created.count, 2); XCTAssertTrue(oldA.contentView.webView === webA)
        XCTAssertEqual(oldB.options, .init()); XCTAssertEqual(runtime.state(of: da)?.playbackState, .manualPaused)
        XCTAssertFalse(oldA.isMuted); XCTAssertTrue(oldB.isMuted)
        value.javaScriptEnabled = false
        try store.save(value, for: a, runtime: runtime)
        try await wait { created.count == 3 && runtime.state(of: da)?.preparingWallpaperID == nil }
        let replacement = try XCTUnwrap(created.last)
        XCTAssertEqual(replacement.options, value); XCTAssertFalse(replacement.isMuted)
        XCTAssertEqual(runtime.state(of: da)?.playbackState, .manualPaused)
        XCTAssertTrue(hb.content === oldB.displayView); XCTAssertNil(oldA.contentView.webView)
        store.refresh(a, runtime: runtime)
        try await wait { created.count == 4 && runtime.state(of: da)?.preparingWallpaperID == nil }
        XCTAssertEqual(runtime.state(of: da)?.playbackState, .manualPaused)
        runtime.stop(.display(da)); let count = created.count
        store.refresh(a, runtime: runtime); XCTAssertEqual(created.count, count, "Refresh cannot revive stopped wallpaper")
    }

    func testMalformedCSSCannotEscapeIntoScriptAndInvalidUpdateKeepsReadyContent() async throws {
        let renderer = WebRenderer(wallpaper: try fixture(), allowsNetwork: false)
        defer { renderer.dispose() }; try await renderer.prepare()
        let web = renderer.contentView.webView
        var options = WebPlaybackOptions(); options.customCSS = "body{color:red}/*'\");window.escaped=true;//</style>"
        try await renderer.updateOptions(options)
        let escaped = try await js("window.escaped === true", renderer) as? Bool
        let css = try await js("document.getElementById('__kinetic_custom_css_v1').textContent", renderer) as? String
        XCTAssertEqual(escaped, false); XCTAssertEqual(css, options.customCSS)
        var invalid = options; invalid.scale = 0
        do { try await renderer.updateOptions(invalid); XCTFail("Invalid options accepted") } catch {}
        XCTAssertEqual(renderer.options, options); XCTAssertTrue(renderer.contentView.webView === web)
        XCTAssertTrue(renderer.isPrepared); XCTAssertTrue(renderer.contentView.hasPoster)
    }

    func testFailedRefreshAndRapidSaveThenStopCannotReplaceTheOldWallpaperOrReviveIt() async throws {
        let wallpaper = try fixture(), store = WebPlaybackStore(storage: .init(rootURL: try root()))
        var created: [WebRenderer] = []
        let runtime = WallpaperRuntimeManager { wallpaper in
            let renderer = WebRenderer(wallpaper: wallpaper, allowsNetwork: false, options: store.configuration(for: wallpaper.id))
            created.append(renderer); return renderer
        }
        defer { runtime.shutdown() }
        let id = DisplayID("failed-refresh"), desktop = AdvancedWebHost()
        runtime.addDisplay(id, host: desktop); runtime.apply(wallpaper, to: id)
        try await wait { runtime.state(of: id)?.playbackState == .playing }
        let original = try XCTUnwrap(created.first), web = original.contentView.webView
        try FileManager.default.removeItem(at: wallpaper.resourceURL.appendingPathComponent("index.html"))
        store.refresh(wallpaper, runtime: runtime)
        try await wait { runtime.lastFailure != nil && runtime.state(of: id)?.preparingWallpaperID == nil }
        XCTAssertTrue(desktop.content === original.displayView); XCTAssertTrue(original.contentView.webView === web)
        XCTAssertEqual(runtime.state(of: id)?.playbackState, .playing)
        var value = WebPlaybackOptions()
        for i in 0..<15 { value.customCSS = "body{color:rgb(\(i),100,100)}"; try store.save(value, for: wallpaper, runtime: runtime) }
        runtime.stop(.display(id)); try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(runtime.state(of: id)?.playbackState, .stopped); XCTAssertNil(desktop.content)
        XCTAssertNil(original.contentView.webView); XCTAssertFalse(original.isMouseInteractionActive)
    }

    func testSettingsEditorLightDarkLayoutAndCloseDisposesPreview() async throws {
        let originalAppearance = NSApp.appearance
        defer { NSApp.appearance = originalAppearance }
        let wallpaper = try fixture(), root = try root(), store = WebPlaybackStore(storage: .init(rootURL: root))
        let snapshots = TestWorkspaceDirectory.make(".build/Module31/Snapshots").deletingLastPathComponent()
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        let runtime = WallpaperRuntimeManager()
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            // Formal settings use the App-level appearance override, including native glass buttons.
            NSApp.appearance = NSAppearance(named: appearance)
            let preview = WebPlaybackPreview(debounceNanoseconds: 0)
            let window = NSWindow(contentRect: .init(x: -5000, y: -5000, width: 580, height: 1270),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: appearance)
            let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 14) {
                WebPlaybackPreviewView(preview: preview).frame(width: 420)
                WebPlaybackSettingsEditor(wallpaper: wallpaper, store: store, runtime: runtime,
                                          allowsNetwork: false, preview: preview, ownerID: UUID())
            }.padding(24).environment(\.locale, Locale(identifier: "zh-Hans"))
                .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
                .frame(width: 580, height: 1270, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor)))
            window.contentView = host; window.orderFrontRegardless()
            try await wait { preview.renderer != nil && !preview.isPreparing }
            try await Task.sleep(nanoseconds: 100_000_000); host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            // Resolve dynamic AppKit colors in the same appearance while rasterizing.
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                host.cacheDisplay(in: host.bounds, to: bitmap)
            }
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let url = snapshots.appendingPathComponent("advanced-web-\(appearance.rawValue).png")
            try data.write(to: url); print("MODULE31 snapshot: \(url.path)")
            window.close(); try await wait { preview.renderer == nil }
            XCTAssertGreaterThan(data.count, 20_000); XCTAssertTrue(store.options.isEmpty)
            XCTAssertTrue(runtime.displayIDs.isEmpty)
        }
    }
}
