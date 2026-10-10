import AppKit
import WebKit
import XCTest
@testable import Kinetic

private enum WebRendererTestError: Error {
    case animationTimedOut
}

@MainActor
final class WebRendererTests: XCTestCase {
    private func fixture() throws -> (Wallpaper, URL) {
        let folder = TestWorkspaceDirectory.make(".build/WebRenderer/Fixtures")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><style>body{background:#345678}</style></head>
        <body><canvas id="canvas"></canvas><script>
        window.kineticCounter = 0;
        window.kineticTimer = 0;
        setInterval(() => { window.kineticTimer++; }, 20);
        window.kineticAudio = new Audio();
        function tick() { window.kineticCounter++; requestAnimationFrame(tick); }
        requestAnimationFrame(tick);
        window.kineticScriptLoaded = true;
        </script></body></html>
        """
        try html.write(to: folder.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        return (Wallpaper(name: "网页测试", type: .web, source: .local, resourceURL: folder), folder)
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () async -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !(await condition()) {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                XCTFail("Timed out waiting for WebKit")
                // An assertion deadline is a test failure, not cancellation of the
                // XCTest task. Cancellation can obscure the original failure during teardown.
                throw WebRendererTestError.animationTimedOut
            }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    private func javascript(_ source: String, in renderer: WebRenderer) async throws -> Any? {
        let web = try XCTUnwrap(renderer.contentView.webView)
        return try await web.evaluateJavaScript(source)
    }

    private func host(_ renderer: WebRenderer) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 90, y: 90, width: 640, height: 360),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        renderer.contentView.frame = window.contentView?.bounds ?? .zero
        window.contentView?.addSubview(renderer.contentView)
        window.orderFrontRegardless()
        return window
    }

    func testLocalHTMLJavaScriptWebGLPauseResumeMuteAndStop() async throws {
        let (model, folder) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let renderer = WebRenderer(wallpaper: model)
        defer { renderer.dispose() }
        try await renderer.prepare()
        let window = host(renderer)
        defer { window.close() }
        XCTAssertTrue(renderer.contentView.hasPoster, "Web renderer must retain a first-frame fallback")
        let controlAvailable = try await javascript("typeof window.__kineticWeb?.setPaused === 'function'", in: renderer) as? Bool
        XCTAssertEqual(controlAvailable, true)
        let scriptLoaded = try await javascript("window.kineticScriptLoaded === true", in: renderer) as? Bool
        XCTAssertEqual(scriptLoaded, true)
        let webGL = try await javascript("!!document.querySelector('#canvas').getContext('webgl')", in: renderer) as? Bool
        XCTAssertEqual(webGL, true)
        XCTAssertTrue(renderer.isMuted)
        let initiallyMuted = try await javascript("window.kineticAudio.muted", in: renderer) as? Bool
        XCTAssertEqual(initiallyMuted, true)
        renderer.play()
        try await waitUntil(5) {
            ((try? await self.javascript("window.kineticCounter", in: renderer)) as? Int ?? 0) > 3
        }
        let timerBeforePause = try await javascript("window.kineticTimer", in: renderer) as? Int
        XCTAssertGreaterThan(timerBeforePause ?? 0, 0)
        renderer.pause()
        try await Task.sleep(nanoseconds: 200_000_000)
        let pausedValue = try await javascript("window.kineticCounter", in: renderer) as? Int
        let pausedCount = try XCTUnwrap(pausedValue)
        try await Task.sleep(nanoseconds: 250_000_000)
        let stillPaused = try await javascript("window.kineticCounter", in: renderer) as? Int
        XCTAssertEqual(stillPaused, pausedCount)
        let pausedTimer = try await javascript("window.kineticTimer", in: renderer) as? Int
        try await Task.sleep(nanoseconds: 100_000_000)
        let stillPausedTimer = try await javascript("window.kineticTimer", in: renderer) as? Int
        XCTAssertEqual(stillPausedTimer, pausedTimer)
        renderer.setMuted(false)
        XCTAssertFalse(renderer.isMuted)
        try await waitUntil(2) {
            ((try? await self.javascript("window.kineticAudio.muted", in: renderer)) as? Bool) == false
        }
        renderer.resume()
        try await waitUntil(5) {
            ((try? await self.javascript("window.kineticCounter", in: renderer)) as? Int ?? 0) > pausedCount + 3
        }
        renderer.dispose()
        XCTAssertNil(renderer.contentView.webView)
    }

    func testEmbeddedVideoContinuesAfterPause() async throws {
        let (model, folder) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try XCTUnwrap(Bundle.main.url(forResource: "loop", withExtension: "mp4", subdirectory: "Fixtures"))
        try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent("loop.mp4"))
        let renderer = WebRenderer(wallpaper: model)
        defer { renderer.dispose() }
        try await renderer.prepare()
        let window = host(renderer)
        defer { window.close() }
        renderer.play()
        _ = try await javascript("""
        const video = document.createElement('video');
        video.id = 'kinetic-test-video'; video.src = 'loop.mp4';
        video.muted = true; video.loop = true;
        document.body.appendChild(video); video.play().catch(() => {}); true;
        """, in: renderer)
        try await waitUntil(8) {
            ((try? await self.javascript("document.querySelector('#kinetic-test-video').currentTime", in: renderer)) as? Double ?? 0) > 0.2
        }
        renderer.pause()
        try await Task.sleep(nanoseconds: 200_000_000)
        let paused = (try await javascript("document.querySelector('#kinetic-test-video').currentTime", in: renderer)) as? Double ?? 0
        try await Task.sleep(nanoseconds: 300_000_000)
        let held = (try await javascript("document.querySelector('#kinetic-test-video').currentTime", in: renderer)) as? Double ?? 0
        XCTAssertEqual(held, paused, accuracy: 0.06)
        renderer.resume()
        try await waitUntil(8) {
            ((try? await self.javascript("document.querySelector('#kinetic-test-video').currentTime", in: renderer)) as? Double ?? 0) > held + 0.12
        }
    }

    func testNetworkAndPermissionPolicyRejectsInsecureOrExternalActions() async throws {
        let (model, folder) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let renderer = WebRenderer(wallpaper: model)
        defer { renderer.dispose() }
        do { try await renderer.prepare() }
        catch { XCTFail("prepare: \(error)"); throw error }
        let window = host(renderer)
        defer { window.close() }
        let blockedSocket: Bool?
        do { blockedSocket = try await javascript("try { new WebSocket('ws://example.com'); false } catch (_) { true }", in: renderer) as? Bool }
        catch { XCTFail("socket: \(error)"); throw error }
        XCTAssertEqual(blockedSocket, true)
        _ = try await javascript("window.__blockedFetch = false; fetch('http://example.com').catch(() => { window.__blockedFetch = true; }); true", in: renderer)
        try await Task.sleep(nanoseconds: 50_000_000)
        let blockedFetch = try await javascript("window.__blockedFetch", in: renderer) as? Bool
        XCTAssertEqual(blockedFetch, true)
        let blockedXHR = try await javascript("try { new XMLHttpRequest().open('GET', 'http://example.com'); false } catch (_) { true }", in: renderer) as? Bool
        XCTAssertEqual(blockedXHR, true)
        let secureSocketAllowed = try await javascript("try { const ws = new WebSocket('wss://example.invalid'); ws.close(); true } catch (_) { false }", in: renderer) as? Bool
        XCTAssertEqual(secureSocketAllowed, true)
        let bypassesBlocked = try await javascript("['Worker','SharedWorker','RTCPeerConnection','webkitRTCPeerConnection'].every(key => typeof window[key] === 'undefined')", in: renderer) as? Bool
        XCTAssertEqual(bypassesBlocked, true)
        XCTAssertFalse(WebWallpaperPolicy.allowsNavigation(to: URL(string: "file:///etc/passwd"), isMainFrame: false, root: folder))
        XCTAssertFalse(WebWallpaperPolicy.allowsNavigation(to: URL(string: "https://example.com"), isMainFrame: true, root: folder))
        let web = try XCTUnwrap(renderer.contentView.webView)
        XCTAssertFalse(web.configuration.websiteDataStore.isPersistent)
        XCTAssertFalse(web.configuration.preferences.javaScriptCanOpenWindowsAutomatically)
        for selector in [
            "webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:",
            "webView:runOpenPanelWithParameters:initiatedByFrame:completionHandler:",
            "webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:"
        ] { XCTAssertTrue(renderer.responds(to: NSSelectorFromString(selector)), selector) }
    }

    func testOfflineNetworkPolicyBlocksHTTPSAndWSSWhileKeepingLocalPage() async throws {
        let (model, folder) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let renderer = WebRenderer(wallpaper: model, allowsNetwork: false)
        defer { renderer.dispose() }
        try await renderer.prepare()
        let window = host(renderer)
        defer { window.close() }
        let scriptLoaded = try await javascript("window.kineticScriptLoaded", in: renderer) as? Bool
        XCTAssertEqual(scriptLoaded, true)
        let blockedSocket = try await javascript("try { new WebSocket('wss://example.invalid'); false } catch (_) { true }", in: renderer) as? Bool
        XCTAssertEqual(blockedSocket, true)
        _ = try await javascript("window.__blockedSecureFetch = false; fetch('https://example.invalid').catch(() => { window.__blockedSecureFetch = true; }); true", in: renderer)
        try await Task.sleep(nanoseconds: 50_000_000)
        let blockedFetch = try await javascript("window.__blockedSecureFetch", in: renderer) as? Bool
        XCTAssertEqual(blockedFetch, true)
    }

    /// 手工联网验收时才运行；常规回归不依赖第三方服务的可用性。
    func testLiveHTTPSFetchXHRAndWSSWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["KINETIC_WEB_LIVE_NETWORK"] == "1" else {
            throw XCTSkip("仅在 Module 4 联网验收时运行")
        }
        let (model, folder) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let renderer = WebRenderer(wallpaper: model)
        defer { renderer.dispose() }
        try await renderer.prepare()
        let window = host(renderer)
        defer { window.close() }
        renderer.play()
        _ = try await javascript("""
        window.__kineticNetworkProbe = { fetch: null, xhr: null, socket: null };
        fetch('https://httpbin.dev/get', { mode: 'no-cors' })
          .then(() => { window.__kineticNetworkProbe.fetch = true; })
          .catch(() => { window.__kineticNetworkProbe.fetch = false; });
        const xhr = new XMLHttpRequest();
        xhr.onload = () => { window.__kineticNetworkProbe.xhr = xhr.status === 200; };
        xhr.onerror = () => { window.__kineticNetworkProbe.xhr = false; };
        xhr.open('GET', 'https://httpbin.dev/get'); xhr.send();
        const ws = new WebSocket('wss://ws.postman-echo.com/raw');
        ws.onopen = () => { window.__kineticNetworkProbe.socket = true; ws.close(); };
        ws.onerror = () => { window.__kineticNetworkProbe.socket = false; };
        true;
        """, in: renderer)
        try await waitUntil(15) {
            (try? await self.javascript("Object.values(window.__kineticNetworkProbe).every(value => value !== null)", in: renderer)) as? Bool == true
        }
        let result = try await javascript("JSON.stringify(window.__kineticNetworkProbe)", in: renderer) as? String
        XCTAssertEqual(result, #"{"fetch":true,"xhr":true,"socket":true}"#)
    }

    func testMissingPageFailsWithoutChangingExistingDesktopAndFactoryRoutesWeb() async throws {
        XCTAssertTrue(WallpaperRuntimeManager.isRendererAvailable(for: .web))
        XCTAssertTrue(WallpaperRuntimeManager.isRendererAvailable(for: .scene), "Module 28 已注册独立 Scene Renderer")
        let model = Wallpaper(name: "缺失网页", type: .web, source: .local,
                              resourceURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let renderer = try XCTUnwrap(WallpaperRuntimeManager.standardRenderer(for: model) as? WebRenderer)
        defer { renderer.dispose() }
        do {
            try await renderer.prepare()
            XCTFail("Missing page should fail")
        } catch WebRendererError.missingEntry { }
    }
}
