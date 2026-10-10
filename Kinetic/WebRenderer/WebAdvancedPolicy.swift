import AppKit
import WebKit

/// Small, explicit tracker list, not a claim to block all tracking. Does not loosen network policy.
enum WebAdvancedPolicy {
    static let trackerDomains = ["google-analytics.com", "googletagmanager.com", "doubleclick.net", "hotjar.com", "hotjar.io"]
    static var trackerRulesJSON: String {
        let rules = trackerDomains.map { domain in
            ["trigger": ["url-filter": "^https?://([^/]+\\.)?" + domain.replacingOccurrences(of: ".", with: "\\.") + "[/:]"],
             "action": ["type": "block"]]
        }
        return String(data: try! JSONSerialization.data(withJSONObject: rules), encoding: .utf8)!
    }
    @MainActor private static let trackerRules = Task<WKContentRuleList, Error> {
        guard let list = try await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "Kinetic.Web.Trackers.v1", encodedContentRuleList: trackerRulesJSON) else {
            throw WebRendererError.networkPolicyUnavailable
        }
        return list
    }
    @MainActor static func install(on configuration: WKWebViewConfiguration, options: WebPlaybackOptions) async throws {
        configuration.defaultWebpagePreferences.allowsContentJavaScript = options.javaScriptEnabled
        if options.trackerBlockingEnabled { configuration.userContentController.add(try await trackerRules.value) }
    }
    static func cssScript(_ css: String) -> String {
        // JSON encoding prevents CSS text from escaping into executable JavaScript.
        let encoded = String(data: try! JSONSerialization.data(withJSONObject: [css]), encoding: .utf8)!
        return """
        (() => {
          const css = \(encoded)[0];
          let style = document.getElementById('__kinetic_custom_css_v1');
          if (!css) { style?.remove(); return; }
          if (!style) { style = document.createElement('style'); style.id = '__kinetic_custom_css_v1'; (document.head || document.documentElement).appendChild(style); }
          style.textContent = css;
        })();
        """
    }

    /// Inverse of the presentation transform; AppKit bottom-left -> CSS top-left.
    static func mousePoint(_ point: CGPoint, size: CGSize, options: WebPlaybackOptions, pageZoom: CGFloat) -> CGPoint? {
        guard size.width > 0, size.height > 0, pageZoom > 0 else { return nil }
        let x = point.x - size.width / 2 - options.panX * size.width
        let y = point.y - size.height / 2 + options.panY * size.height
        let angle = -options.rotationDegrees * .pi / 180
        let localX = (x * cos(angle) - y * sin(angle)) / options.scale + size.width / 2
        let localY = (x * sin(angle) + y * cos(angle)) / options.scale + size.height / 2
        guard localX >= 0, localX < size.width, localY >= 0, localY < size.height else { return nil }
        return CGPoint(x: localX / pageZoom, y: (size.height - localY) / pageZoom)
    }
    static func mouseScript(_ point: CGPoint) -> String {
        """
        (() => {
          const init = {clientX:\(point.x),clientY:\(point.y),bubbles:true,pointerId:1,pointerType:'mouse',isPrimary:true};
          const target = document.elementFromPoint(init.clientX, init.clientY) || document;
          target.dispatchEvent(new PointerEvent('pointermove', init));
          target.dispatchEvent(new MouseEvent('mousemove', init));
        })();
        """
    }
}
