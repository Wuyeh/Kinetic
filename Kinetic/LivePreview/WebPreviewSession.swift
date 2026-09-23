import AppKit
import WebKit

/// 网页壁纸的安全边界。预览只使用这里的配置，不另建更宽松的版本；
/// 桌面 Web Renderer 接入时应复用同一套规则。
enum WebWallpaperPolicy {
    /// 允许：本地 HTML/CSS/JS/Canvas/WebGL、HTTPS 资源、Fetch/XHR、WebSocket。
    /// 固定禁止：摄像头、麦克风、定位、任意文件读取、原生命令、启动其他 App、下载、弹出新窗口。
    @MainActor
    static func makeConfiguration(userScripts: [WKUserScript]) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = sharedDataStore
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isElementFullscreenEnabled = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        // 有声媒体必须由用户手势启动；预览区域不接收任何点击，因此网页无法自行发声。
        configuration.mediaTypesRequiringUserActionForPlayback = .audio
        configuration.allowsAirPlayForMediaPlayback = false
        configuration.upgradeKnownHostsToHTTPS = true
        // 不注册任何 script message handler：网页没有通往原生代码的桥。
        for script in userScripts {
            configuration.userContentController.addUserScript(script)
        }
        return configuration
    }

    /// 不持久化 Cookie / 本地存储。
    @MainActor
    static let sharedDataStore = WKWebsiteDataStore.nonPersistent()

    /// 网页可以加载哪些地址。主框架只能停留在壁纸自己的文件夹里；
    /// 子框架额外允许 HTTPS 与内存内容。其余协议（http、自定义 App 协议、mailto 等）一律拒绝。
    static func allowsNavigation(to url: URL?, isMainFrame: Bool, root: URL) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased() else { return false }
        switch scheme {
        case "file":
            return isInside(url, root: root)
        case "https":
            return !isMainFrame
        case "about", "data", "blob":
            return !isMainFrame
        default:
            return false
        }
    }

    static func isInside(_ url: URL, root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }
}

/// 网页壁纸的卡片内预览：独立、短生命周期的 WKWebView。强制静音，JS 动画约限制在 30 FPS。
@MainActor
final class WebPreviewSession: NSObject, LivePreviewSession, WKNavigationDelegate, WKUIDelegate {
    let wallpaperID: Wallpaper.ID
    let rootURL: URL
    let entryURL: URL
    private let content = LivePreviewContentView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
    private(set) var webView: WKWebView?
    private var revealTask: Task<Void, Never>?
    private var isInvalidated = false

    private(set) var state: PreviewContentState = .preparing {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    var onStateChange: ((PreviewContentState) -> Void)?
    var contentView: NSView { content }

    /// 网页壁纸文件夹中的入口页面；没有入口时不能预览。
    static func entryURL(for wallpaper: Wallpaper) -> URL? {
        guard wallpaper.type == .web, wallpaper.resourceURL.isFileURL else { return nil }
        let folder = wallpaper.resourceURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let name = LocalImportService.webEntryName(in: folder) else { return nil }
        let entry = folder.appendingPathComponent(name)
        return FileManager.default.isReadableFile(atPath: entry.path) ? entry : nil
    }

    init?(wallpaper: Wallpaper) {
        guard let entry = Self.entryURL(for: wallpaper) else { return nil }
        wallpaperID = wallpaper.id
        rootURL = wallpaper.resourceURL
        entryURL = entry
        super.init()
    }

    func start() {
        guard !isInvalidated, webView == nil else { return }
        let configuration = WebWallpaperPolicy.makeConfiguration(userScripts: [
            WKUserScript(source: Self.muteScript, injectionTime: .atDocumentStart, forMainFrameOnly: false),
            WKUserScript(source: Self.frameRateScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        ])
        let web = WKWebView(frame: content.bounds, configuration: configuration)
        web.autoresizingMask = [.width, .height]
        web.allowsBackForwardNavigationGestures = false
        web.allowsMagnification = false
        web.allowsLinkPreview = false
        web.navigationDelegate = self
        web.uiDelegate = self
        web.setAccessibilityElement(false)
        content.addSubview(web)
        webView = web
        #if DEBUG
        LivePreviewDiagnostics.shared.sessionStarted()
        LivePreviewDiagnostics.shared.track(webView: web)
        #endif
        web.loadFileURL(entryURL, allowingReadAccessTo: rootURL)
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        onStateChange = nil
        revealTask?.cancel()
        revealTask = nil
        if let web = webView {
            webView = nil
            web.stopLoading()
            web.pauseAllMediaPlayback(completionHandler: nil)
            web.setAllMediaPlaybackSuspended(true, completionHandler: nil)
            web.navigationDelegate = nil
            web.uiDelegate = nil
            web.configuration.userContentController.removeAllUserScripts()
            web.removeFromSuperview()
            #if DEBUG
            LivePreviewDiagnostics.shared.sessionEnded()
            #endif
        }
        content.removeFromSuperview()
    }

    private func markPlaying() {
        guard !isInvalidated, state == .preparing else { return }
        state = .playing
    }

    private func fail() {
        guard !isInvalidated, state != .failed else { return }
        state = .failed
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        let allowed = !navigationAction.shouldPerformDownload
            && WebWallpaperPolicy.allowsNavigation(to: navigationAction.request.url, isMainFrame: isMainFrame, root: rootURL)
        // 预览不接收点击；网页脚本发起的外链跳转直接取消，不打开浏览器。
        return allowed ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        navigationResponse.canShowMIMEType ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView, state == .preparing else { return }
        // 等页面真正画出两帧再淡入；若动画帧被系统节流，最多再等 300 ms。
        webView.callAsyncJavaScript(
            "await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r))); return true;",
            arguments: [:], in: nil, in: .defaultClient
        ) { [weak self] _ in
            self?.markPlaying()
        }
        revealTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.markPlaying()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if webView === self.webView { fail() }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if webView === self.webView { fail() }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if webView === self.webView { fail() }
    }

    // MARK: WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil
    }

    /// 摄像头 / 麦克风：永远拒绝，不弹出系统授权。
    func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
                 initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        .deny
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {}

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        false
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        nil
    }

    // MARK: Injected scripts

    /// 在每个框架的最早时机强制静音：媒体元素始终 muted / volume 0，Web Audio 保持挂起，不朗读文字。
    static let muteScript = """
    (() => {
      'use strict';
      const P = HTMLMediaElement.prototype;
      const mutedSet = Object.getOwnPropertyDescriptor(P, 'muted').set;
      const volumeSet = Object.getOwnPropertyDescriptor(P, 'volume').set;
      const force = el => { try { mutedSet.call(el, true); volumeSet.call(el, 0); } catch (e) {} };
      Object.defineProperty(P, 'muted', { configurable: false, get() { return true; }, set() { force(this); } });
      Object.defineProperty(P, 'volume', { configurable: false, get() { return 0; }, set() { force(this); } });
      const play = P.play;
      P.play = function () { force(this); return play.apply(this, arguments); };
      document.addEventListener('play', e => { if (e.target instanceof HTMLMediaElement) force(e.target); }, true);
      new MutationObserver(records => {
        for (const record of records) for (const node of record.addedNodes) {
          if (node instanceof HTMLMediaElement) force(node);
          else if (node.querySelectorAll) node.querySelectorAll('audio,video').forEach(force);
        }
      }).observe(document, { childList: true, subtree: true });
      for (const name of ['AudioContext', 'webkitAudioContext']) {
        const Base = window[name];
        if (typeof Base !== 'function') continue;
        Base.prototype.resume = function () { return Promise.resolve(); };
        const Silent = function (...args) { const context = new Base(...args); try { context.suspend(); } catch (e) {} return context; };
        Silent.prototype = Base.prototype;
        Object.setPrototypeOf(Silent, Base);
        window[name] = Silent;
      }
      if (window.speechSynthesis) window.speechSynthesis.speak = function () {};
    })();
    """

    /// 小窗口预览不需要高帧率：requestAnimationFrame 回调约限制为 30 FPS。
    static let frameRateScript = """
    (() => {
      'use strict';
      const raf = window.requestAnimationFrame.bind(window);
      const caf = window.cancelAnimationFrame.bind(window);
      const pending = new Map();
      let nextID = 1, lastOn = -1e9, decidedAt = -1, decidedOn = true;
      const gate = t => {
        if (t !== decidedAt) { decidedAt = t; decidedOn = t - lastOn >= 29; if (decidedOn) lastOn = t; }
        return decidedOn;
      };
      window.requestAnimationFrame = callback => {
        const id = nextID++;
        const tick = t => {
          if (!pending.has(id)) return;
          if (!gate(t)) { pending.set(id, raf(tick)); return; }
          pending.delete(id);
          callback(t);
        };
        pending.set(id, raf(tick));
        return id;
      };
      window.cancelAnimationFrame = id => {
        const handle = pending.get(id);
        if (handle !== undefined) { caf(handle); pending.delete(id); }
      };
    })();
    """
}
