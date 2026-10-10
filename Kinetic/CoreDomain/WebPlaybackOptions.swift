import Foundation

/// Module 31: renderer-independent values. Default settings preserve Module 4 behavior.
struct WebPlaybackOptions: Codable, Equatable, Sendable {
    var javaScriptEnabled = true
    var mouseInteractionEnabled = false
    var trackerBlockingEnabled = false
    var customCSS = ""
    var scale = 1.0
    /// Fraction of viewport width / height; positive Y moves downward.
    var panX = 0.0
    var panY = 0.0
    var rotationDegrees = 0.0
    var physicalPixelLayout = false
    static let maximumCSSBytes = 64 * 1_024

    func validated() throws -> Self {
        guard scale.isFinite, (0.25...3).contains(scale),
              panX.isFinite, (-1...1).contains(panX), panY.isFinite, (-1...1).contains(panY),
              rotationDegrees.isFinite, (-180...180).contains(rotationDegrees),
              customCSS.utf8.count <= Self.maximumCSSBytes, !customCSS.contains("\0") else {
            throw WebOptionsError.invalidValue
        }
        return self
    }
    func requiresReload(comparedTo previous: Self) -> Bool {
        javaScriptEnabled != previous.javaScriptEnabled || trackerBlockingEnabled != previous.trackerBlockingEnabled
    }
}

enum WebOptionsError: LocalizedError {
    case invalidValue, unreadable, unsupportedWallpaper, requiresReload
    var errorDescription: String? {
        switch self {
        case .invalidValue: return "网页参数无效，或自定义 CSS 超过 64 KiB。"
        case .unreadable: return "网页设置无法读取，原文件已保留。"
        case .unsupportedWallpaper: return "此设置只适用于本地网页壁纸。"
        case .requiresReload: return "脚本与跟踪拦截规则需要重新加载网页。"
        }
    }
}
