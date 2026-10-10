import AppKit
import WebKit

enum WebRendererError: LocalizedError {
    case invalidLifecycle
    case unsupportedWallpaper
    case missingEntry
    case networkPolicyUnavailable
    case preparationTimedOut
    case contentProcessTerminated

    var errorDescription: String? {
        switch self {
        case .invalidLifecycle: return "网页壁纸的运行状态无效。"
        case .unsupportedWallpaper: return "只能播放已导入的本地网页壁纸。"
        case .missingEntry: return "网页壁纸缺少可读取的 index.html。"
        case .networkPolicyUnavailable: return "无法启用网页壁纸的网络安全规则。"
        case .preparationTimedOut: return "网页壁纸加载超时。"
        case .contentProcessTerminated: return "网页壁纸进程已停止。"
        }
    }
}

/// 只承载画面。准备失败或网页进程终止时保留海报/最近一次快照，避免桌面黑屏。
@MainActor
final class WebContentView: NSView {
    private let posterLayer = CALayer()
    private let viewport = NSView()
    private var options = WebPlaybackOptions()
    private(set) var hasPoster = false
    private(set) var webView: WKWebView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.masksToBounds = true
        posterLayer.contentsGravity = .resizeAspectFill
        layer?.addSublayer(posterLayer)
        viewport.wantsLayer = true
        addSubview(viewport)
    }

    required init?(coder: NSCoder) { nil }

    /// The wallpaper remains click-through. Optional pointer movement is delivered without capturing clicks.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        posterLayer.frame = bounds
        viewport.frame = bounds
        webView?.frame = bounds
        applyGeometry()
    }

    func setPoster(_ image: NSImage) {
        guard let image = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        posterLayer.contents = image
        hasPoster = true
    }

    func attach(_ web: WKWebView) {
        web.frame = bounds
        web.autoresizingMask = [.width, .height]
        web.isHidden = true
        web.wantsLayer = true
        viewport.addSubview(web)
        webView = web
        applyGeometry()
    }

    func showWeb() { webView?.isHidden = false; posterLayer.isHidden = true }
    func showFallback() { webView?.isHidden = true; posterLayer.isHidden = false }

    func detach() {
        webView?.removeFromSuperview()
        webView = nil
    }

    func setLayoutOptions(_ options: WebPlaybackOptions) { self.options = options; applyGeometry() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); applyGeometry() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); applyGeometry() }
    private func applyGeometry() {
        let backing = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        webView?.pageZoom = options.physicalPixelLayout ? 1 / max(1, backing) : 1
        var transform = CATransform3DMakeTranslation(options.panX * bounds.width, -options.panY * bounds.height, 0)
        transform = CATransform3DRotate(transform, options.rotationDegrees * .pi / 180, 0, 0, 1)
        transform = CATransform3DScale(transform, options.scale, options.scale, 1)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        viewport.layer?.sublayerTransform = transform
        CATransaction.commit()
    }
}

/// Module 4：一个实例对应一张本地网页壁纸，与 VideoRenderer 共用 WallpaperRenderer 契约。
/// 只管理 WKWebView 的生命周期，不决定 Runtime 状态、桌面窗口或 Crossfade。
@MainActor
final class WebRenderer: NSObject, WallpaperRenderer, WKNavigationDelegate, WKUIDelegate {
    let wallpaper: Wallpaper
    let allowsNetwork: Bool
    private(set) var options: WebPlaybackOptions
    static var optionsProvider: (@MainActor (Wallpaper.ID) -> WebPlaybackOptions)?
    /// Module 49: a global pause for every web wallpaper's mouse interaction; the per-wallpaper option is unchanged.
    static var isMouseInteractionPaused = false
    /// Module 51 自适应帧率：网页脚本动画（requestAnimationFrame）的上限；nil 不限制。
    private(set) static var adaptiveFrameRateLimit: Int?
    private static let liveRenderers = NSHashTable<WebRenderer>.weakObjects()
    static func applyAdaptiveFrameRateLimit(_ framesPerSecond: Int?) {
        guard adaptiveFrameRateLimit != framesPerSecond else { return }
        adaptiveFrameRateLimit = framesPerSecond
        for renderer in liveRenderers.allObjects { renderer.applyFrameRateLimit() }
    }
    let contentView = WebContentView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
    var displayView: NSView { contentView }
    var onFailure: (@MainActor (Error) -> Void)?

    private enum Lifecycle { case idle, preparing, ready, failed, disposed }
    private var lifecycle = Lifecycle.idle
    private var webView: WKWebView?
    private var preparationWindow: NSWindow?
    private var rootURL: URL?
    private var initialNavigation: WKNavigation?
    private var preparation: CheckedContinuation<Void, Error>?
    private var watchdog: Task<Void, Never>?
    private var isPlaying = false
    private(set) var isMuted = true
    var isPrepared: Bool { lifecycle == .ready }
    var isMouseInteractionActive: Bool { mouseTimer != nil }
    private var mouseTimer: Timer?
    private var mouseRequestPending = false
    private var lastMousePoint: CGPoint?
    private var optionsTask: Task<Void, Never>?
    private var optionsGeneration = 0

    init(wallpaper: Wallpaper, allowsNetwork: Bool = true, options: WebPlaybackOptions? = nil) {
        self.wallpaper = wallpaper
        self.allowsNetwork = allowsNetwork
        self.options = options ?? Self.optionsProvider?(wallpaper.id) ?? .init()
    }

    func prepare() async throws {
        guard lifecycle == .idle else { throw WebRendererError.invalidLifecycle }
        lifecycle = .preparing
        do { options = try options.validated() }
        catch { lifecycle = .failed; throw error }
        contentView.setLayoutOptions(options)
        guard wallpaper.type == .web, wallpaper.resourceURL.isFileURL else {
            lifecycle = .failed
            throw WebRendererError.unsupportedWallpaper
        }
        guard let entry = WebPreviewSession.entryURL(for: wallpaper) else {
            lifecycle = .failed
            throw WebRendererError.missingEntry
        }
        let root = wallpaper.resourceURL.resolvingSymlinksInPath()
        guard WebWallpaperPolicy.isInside(entry, root: root) else {
            lifecycle = .failed
            throw WebRendererError.missingEntry
        }
        rootURL = root
        if let posterURL = wallpaper.thumbnailURL, WebWallpaperPolicy.isInside(posterURL, root: root),
           let poster = NSImage(contentsOf: posterURL) {
            contentView.setPoster(poster)
        }

        let configuration = WebWallpaperPolicy.makeConfiguration(userScripts: [
            WKUserScript(source: Self.networkScript(allowsNetwork: allowsNetwork), injectionTime: .atDocumentStart, forMainFrameOnly: false),
            WKUserScript(source: Self.controlScript, injectionTime: .atDocumentStart, forMainFrameOnly: false),
            WKUserScript(source: WebAdvancedPolicy.cssScript(options.customCSS), injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        ], allowsAutomaticAudioPlayback: true)
        do {
            try await WebWallpaperPolicy.installNetworkRules(on: configuration, allowsNetwork: allowsNetwork)
            try await WebAdvancedPolicy.install(on: configuration, options: options)
            try Task.checkCancellation()
            guard lifecycle == .preparing else { throw CancellationError() }
            let web = WKWebView(frame: contentView.bounds, configuration: configuration)
            web.allowsBackForwardNavigationGestures = false
            web.allowsMagnification = false
            web.allowsLinkPreview = false
            web.navigationDelegate = self
            web.uiDelegate = self
            web.setAccessibilityElement(false)
            // WebKit 在完全离屏且没有窗口的 View 中可能回收页面进程；短命的屏外窗口
            // 让首帧在旧壁纸仍可见时真正准备好。展示后随内容迁移立即关闭。
            let holdingWindow = NSWindow(contentRect: NSRect(x: -8000, y: -8000, width: 640, height: 360),
                                         styleMask: .borderless, backing: .buffered, defer: false)
            holdingWindow.isReleasedWhenClosed = false
            holdingWindow.collectionBehavior = [.transient, .ignoresCycle]
            holdingWindow.contentView?.addSubview(contentView)
            holdingWindow.orderFrontRegardless()
            preparationWindow = holdingWindow
            contentView.attach(web)
            contentView.showWeb()
            webView = web
            watchdog = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard !Task.isCancelled else { return }
                self?.fail(WebRendererError.preparationTimedOut)
            }
            try await withCheckedThrowingContinuation { continuation in
                preparation = continuation
                initialNavigation = web.loadFileURL(entry, allowingReadAccessTo: root)
                if initialNavigation == nil { fail(WebRendererError.missingEntry) }
            }
        } catch {
            if lifecycle != .disposed { lifecycle = .failed }
            throw error
        }
    }

    func play() {
        guard lifecycle == .ready else { return }
        isPlaying = true
        preparationWindow?.close()
        preparationWindow = nil
        contentView.showWeb()
        updateMouseTimer()
        webView?.setAllMediaPlaybackSuspended(false) { [weak self, weak webView] in
            guard let self, let webView, self.webView === webView,
                  self.lifecycle == .ready, self.isPlaying else { return }
            self.setPausedInPage(false)
        }
    }

    func pause() {
        guard lifecycle == .ready else { return }
        isPlaying = false
        stopMouseTimer()
        setPausedInPage(true)
        webView?.setAllMediaPlaybackSuspended(true, completionHandler: nil)
    }

    func resume() { play() }

    /// CSS and geometry stay in the same document; script / tracker policy changes require a prepared replacement.
    func updateOptions(_ value: WebPlaybackOptions) async throws {
        let value = try value.validated()
        guard lifecycle == .ready, let webView else { throw WebRendererError.invalidLifecycle }
        guard !value.requiresReload(comparedTo: options) else { throw WebOptionsError.requiresReload }
        optionsGeneration += 1; let generation = optionsGeneration
        if value.customCSS != options.customCSS {
            _ = try await webView.evaluateJavaScript(WebAdvancedPolicy.cssScript(value.customCSS))
        }
        // Native WebKit evaluation cannot be cancelled once sent. If it has already applied
        // valid CSS, commit matching geometry/options; a later generation still takes precedence.
        guard lifecycle == .ready, self.webView === webView, generation == optionsGeneration else { throw CancellationError() }
        options = value
        contentView.setLayoutOptions(value)
        updateMouseTimer()
    }
    func scheduleOptionsUpdate(_ value: WebPlaybackOptions, onError: @escaping @MainActor (Error) -> Void) {
        optionsTask?.cancel()
        optionsTask = Task { @MainActor [weak self] in
            do { try await self?.updateOptions(value) }
            catch { if !Task.isCancelled { onError(error) } }
        }
    }
    deinit { watchdog?.cancel(); optionsTask?.cancel(); mouseTimer?.invalidate() }

    private func updateMouseTimer() {
        stopMouseTimer()
        guard isPlaying, lifecycle == .ready, options.mouseInteractionEnabled, options.javaScriptEnabled else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sendMousePosition() }
        }
        mouseTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func stopMouseTimer() {
        mouseTimer?.invalidate(); mouseTimer = nil; lastMousePoint = nil
    }
    /// Observe cursor position only. Desktop remains click-through, without event taps or accessibility permission.
    private func sendMousePosition() {
        guard !Self.isMouseInteractionPaused, let window = contentView.window, let webView, !mouseRequestPending, isPlaying else { return }
        let point = contentView.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        guard contentView.bounds.contains(point), point != lastMousePoint else { return }
        guard let cssPoint = WebAdvancedPolicy.mousePoint(point, size: contentView.bounds.size,
                                                        options: options, pageZoom: webView.pageZoom) else { return }
        lastMousePoint = point; mouseRequestPending = true
        webView.evaluateJavaScript(WebAdvancedPolicy.mouseScript(cssPoint)) { [weak self] _, _ in
            self?.mouseRequestPending = false
        }
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        runScript("window.__kineticWeb?.setMuted(\(muted ? "true" : "false"));")
    }

    func dispose() {
        guard lifecycle != .disposed else { return }
        lifecycle = .disposed
        optionsGeneration += 1; optionsTask?.cancel(); optionsTask = nil
        stopMouseTimer()
        watchdog?.cancel()
        watchdog = nil
        preparation?.resume(throwing: CancellationError())
        preparation = nil
        onFailure = nil
        webView?.stopLoading()
        webView?.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.configuration.userContentController.removeAllUserScripts()
        contentView.detach()
        preparationWindow?.close()
        preparationWindow = nil
        webView = nil
        initialNavigation = nil
    }

    private func applyFrameRateLimit() {
        runScript("window.__kineticWeb?.setFrameRate(\(Self.adaptiveFrameRateLimit ?? 0));")
    }

    private func setPausedInPage(_ paused: Bool) {
        runScript("window.__kineticWeb?.setPaused(\(paused ? "true" : "false"));")
    }

    private func runScript(_ script: String) {
        webView?.evaluateJavaScript(script, completionHandler: nil)
    }

    private func finishPreparation() {
        guard lifecycle == .preparing else { return }
        watchdog?.cancel()
        watchdog = nil
        lifecycle = .ready
        runScript("window.__kineticWeb?.setPaused(true); window.__kineticWeb?.setMuted(true);")
        Self.liveRenderers.add(self)
        if Self.adaptiveFrameRateLimit != nil { applyFrameRateLimit() }
        contentView.showFallback()
        let continuation = preparation
        preparation = nil
        continuation?.resume()
    }

    private func fail(_ error: Error) {
        guard lifecycle == .preparing || lifecycle == .ready else { return }
        let wasPreparing = lifecycle == .preparing
        lifecycle = .failed
        stopMouseTimer()
        watchdog?.cancel()
        watchdog = nil
        webView?.stopLoading()
        webView?.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        contentView.showFallback()
        if wasPreparing {
            let continuation = preparation
            preparation = nil
            continuation?.resume(throwing: error)
        } else {
            onFailure?(error)
        }
    }

    // MARK: WebKit navigation and permissions

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard webView === self.webView, let rootURL else { return .cancel }
        let isMain = action.targetFrame?.isMainFrame ?? true
        let url = action.request.url
        if !action.shouldPerformDownload && WebWallpaperPolicy.allowsNavigation(to: url, isMainFrame: isMain, root: rootURL) {
            return .allow
        }
        // 只有用户主动点击的 HTTPS 链接可以离开壁纸，交给默认浏览器；脚本跳转不允许。
        if action.navigationType == .linkActivated, isMain, url?.scheme?.lowercased() == "https", let url {
            NSWorkspace.shared.open(url)
        }
        return .cancel
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        response.canShowMIMEType ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView, navigation === initialNavigation, lifecycle == .preparing else { return }
        // 加载完成后尝试留下静态快照；快照失败时沿用海报/系统底色，绝不暴露空黑层。
        webView.takeSnapshot(with: nil) { [weak self, weak webView] image, _ in
            guard let self, let webView, webView === self.webView, self.lifecycle == .preparing else { return }
            if let image { self.contentView.setPoster(image) }
            self.finishPreparation()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if webView === self.webView, navigation === initialNavigation { fail(error) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if webView === self.webView, navigation === initialNavigation { fail(error) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if webView === self.webView { fail(WebRendererError.contentProcessTerminated) }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

    func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
                 initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision { .deny }

    @available(macOS 27.0, *)
    func webView(_ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo) async -> [URL]? { nil }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {}

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool { false }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? { nil }

    /// 只允许 HTTPS/WSS。拦截 fetch、XHR 和 WebSocket；HTML/CSS 资源另由 WKContentRuleList 拦截。
    static func networkScript(allowsNetwork: Bool) -> String { """
    (() => {
      'use strict';
      const networkAllowed = \(allowsNetwork ? "true" : "false");
      const secureHTTP = input => { try {
        const raw = typeof input === 'string' ? input : input.url;
        const u = new URL(raw, document.baseURI);
        return ['file:', 'data:', 'blob:'].includes(u.protocol) || (networkAllowed && u.protocol === 'https:');
      } catch (_) { return false; } };
      const fetch0 = window.fetch;
      window.fetch = function(input, init) {
        return secureHTTP(input) ? fetch0.call(this, input, init) : Promise.reject(new TypeError('Blocked by Kinetic network policy'));
      };
      const open0 = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(method, url, ...rest) {
        if (!secureHTTP(url)) throw new DOMException('Blocked by Kinetic network policy', 'SecurityError');
        return open0.call(this, method, url, ...rest);
      };
      const WS = window.WebSocket;
      if (WS) {
        const SecureWS = function(url, protocols) {
          const target = new URL(url, document.baseURI);
          if (!networkAllowed || target.protocol !== 'wss:') throw new DOMException('Blocked by Kinetic network policy', 'SecurityError');
          return protocols === undefined ? new WS(url) : new WS(url, protocols);
        };
        SecureWS.prototype = WS.prototype;
        Object.setPrototypeOf(SecureWS, WS);
        window.WebSocket = SecureWS;
      }
      const beacon0 = navigator.sendBeacon?.bind(navigator);
      if (beacon0) navigator.sendBeacon = (url, data) => secureHTTP(url) && beacon0(url, data);
      if (navigator.geolocation) {
        const denied = error => error?.({ code: 1, message: 'Blocked by Kinetic permission policy' });
        navigator.geolocation.getCurrentPosition = (_, error) => denied(error);
        navigator.geolocation.watchPosition = (_, error) => { denied(error); return 0; };
        navigator.geolocation.clearWatch = () => {};
      }
      // Worker 中的请求不会经过当前页面的 fetch/XHR 包装；WebRTC 也可绕开 HTTPS/WSS 约束。
      // 基础 Web Renderer 暂不支持这两种执行/传输通道，避免出现未受控的网络出口。
      for (const key of ['Worker', 'SharedWorker', 'RTCPeerConnection', 'webkitRTCPeerConnection']) {
        try { Object.defineProperty(window, key, { value: undefined, writable: false, configurable: false }); }
        catch (_) { try { window[key] = undefined; } catch (_) {} }
      }
    })();
    """
    }

    /// 网页动画与媒体的统一开关。暂停只挂起回调、媒体和 CSS 动画，继续时保留页面状态。
    static let controlScript = """
    (() => {
      'use strict';
      let paused = false, muted = true, nextID = 1, frameInterval = 0, lastFrame = -Infinity;
      const raf = window.requestAnimationFrame.bind(window), cancelRAF = window.cancelAnimationFrame.bind(window);
      const pending = new Map();
      window.requestAnimationFrame = callback => {
        const id = nextID++;
        const entry = { callback, nativeID: null };
        pending.set(id, entry);
        if (!paused) schedule(id, entry);
        return id;
      };
      function schedule(id, entry) {
        entry.nativeID = raf(function tick(time) {
          if (!pending.has(id)) return;
          entry.nativeID = null;
          if (paused) return;
          // Kinetic adaptive frame rate: callbacks of one frame share its time; later frames wait for the interval.
          if (frameInterval > 0 && time !== lastFrame && time - lastFrame < frameInterval - 1) {
            entry.nativeID = raf(tick);
            return;
          }
          lastFrame = time;
          pending.delete(id);
          entry.callback(time);
        });
      }
      window.cancelAnimationFrame = id => {
        const entry = pending.get(id);
        if (entry && entry.nativeID !== null) cancelRAF(entry.nativeID);
        pending.delete(id);
      };
      const timeout0 = window.setTimeout.bind(window), clearTimeout0 = window.clearTimeout.bind(window);
      const interval0 = window.setInterval.bind(window), clearInterval0 = window.clearInterval.bind(window);
      let nextTimerID = 1;
      const timeouts = new Map(), intervals = new Map();
      window.setTimeout = (callback, delay, ...args) => {
        const id = nextTimerID++, entry = { callback, args, nativeID: null };
        timeouts.set(id, entry);
        entry.nativeID = timeout0(() => {
          entry.nativeID = null;
          if (!timeouts.has(id) || paused) return;
          timeouts.delete(id);
          if (typeof callback === 'function') callback(...args);
        }, delay);
        return id;
      };
      window.clearTimeout = id => {
        const timer = timeouts.get(id);
        if (timer && timer.nativeID !== null) clearTimeout0(timer.nativeID);
        timeouts.delete(id);
        const interval = intervals.get(id);
        if (interval !== undefined) clearInterval0(interval);
        intervals.delete(id);
      };
      window.setInterval = (callback, delay, ...args) => {
        const id = nextTimerID++;
        intervals.set(id, interval0(() => {
          if (!paused && typeof callback === 'function') callback(...args);
        }, delay));
        return id;
      };
      window.clearInterval = window.clearTimeout;
      const contexts = new Set();
      for (const key of ['AudioContext', 'webkitAudioContext']) {
        const Base = window[key];
        if (!Base) continue;
        const resume0 = Base.prototype.resume;
        Base.prototype.resume = function(...args) {
          return muted || paused ? Promise.resolve() : resume0.apply(this, args);
        };
        const Wrapped = function(...args) {
          const context = new Base(...args);
          contexts.add(context);
          if (muted) context.suspend();
          return context;
        };
        Wrapped.prototype = Base.prototype;
        Object.setPrototypeOf(Wrapped, Base);
        window[key] = Wrapped;
      }
      const media = new Set(), resumeMedia = new Set();
      const mediaPrototype = HTMLMediaElement.prototype;
      const nativeMuted = Object.getOwnPropertyDescriptor(mediaPrototype, 'muted');
      const pageMuted = new WeakMap();
      Object.defineProperty(mediaPrototype, 'muted', {
        configurable: false,
        get() { return nativeMuted.get.call(this); },
        set(value) {
          pageMuted.set(this, !!value);
          nativeMuted.set.call(this, muted || !!value);
        }
      });
      function track(element) {
        if (!(element instanceof HTMLMediaElement)) return;
        media.add(element);
        nativeMuted.set.call(element, muted || pageMuted.get(element) === true);
        if (paused) element.pause();
      }
      const play0 = HTMLMediaElement.prototype.play;
      HTMLMediaElement.prototype.play = function(...args) { track(this); return play0.apply(this, args); };
      const Audio0 = window.Audio;
      if (Audio0) {
        window.Audio = function(...args) { const element = new Audio0(...args); track(element); return element; };
        window.Audio.prototype = Audio0.prototype;
      }
      document.addEventListener('play', event => track(event.target), true);
      new MutationObserver(records => records.forEach(record => record.addedNodes.forEach(node => {
        track(node);
        node.querySelectorAll?.('audio,video').forEach(track);
      }))).observe(document, { childList: true, subtree: true });
      document.addEventListener('DOMContentLoaded', () => document.querySelectorAll('audio,video').forEach(track));
      window.__kineticWeb = {
        setPaused(value) {
          paused = !!value;
          if (paused) {
            for (const entry of pending.values()) if (entry.nativeID !== null) { cancelRAF(entry.nativeID); entry.nativeID = null; }
            document.getAnimations().forEach(animation => animation.pause());
            media.forEach(element => {
              if (!element.paused) resumeMedia.add(element);
              element.pause();
            });
          } else {
            for (const [id, entry] of pending) if (entry.nativeID === null) schedule(id, entry);
            for (const [id, entry] of timeouts) if (entry.nativeID === null) {
              entry.nativeID = timeout0(() => {
                timeouts.delete(id);
                if (typeof entry.callback === 'function') entry.callback(...entry.args);
              }, 0);
            }
            document.getAnimations().forEach(animation => animation.play());
            resumeMedia.forEach(element => {
              if (element.isConnected) element.play().catch(() => {});
            });
            resumeMedia.clear();
          }
          contexts.forEach(context => paused || muted ? context.suspend() : context.resume());
        },
        setFrameRate(value) {
          frameInterval = value > 0 ? 1000 / value : 0;
        },
        setMuted(value) {
          muted = !!value;
          document.querySelectorAll('audio,video').forEach(track);
          media.forEach(track);
          contexts.forEach(context => muted || paused ? context.suspend() : context.resume());
        }
      };
    })();
    """
}
