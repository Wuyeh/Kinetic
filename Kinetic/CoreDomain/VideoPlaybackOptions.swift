import Foundation

/// 显示器 › 显示方式 › 自定义：显示器上显示壁纸的哪一部分（视频与场景共用，按显示器、按壁纸保存）。
/// zoom 1 = 壁纸刚好铺满显示器，最大 `maximumZoom`；中心点用壁纸自身的 0…1 坐标（左上角为原点）。
/// 显示的部分始终落在壁纸以内，显示器永远是铺满的。
struct CustomDisplayFrame: Codable, Equatable, Sendable {
    /// 与 KineticSceneRuntime.SceneDisplayCrop.maximumZoom 相同。
    static let maximumZoom: Double = 5
    var zoom: Double = 1
    var centerX: Double = 0.5
    var centerY: Double = 0.5

    var isValid: Bool {
        zoom.isFinite && (1...Self.maximumZoom).contains(zoom)
            && centerX.isFinite && (0...1).contains(centerX) && centerY.isFinite && (0...1).contains(centerY)
    }
}

/// Module 30: saved per video; neutral defaults preserve Module 3 playback.
struct VideoPlaybackOptions: Codable, Equatable, Sendable {
    enum DisplayFit: String, Codable, CaseIterable { case fill, fit, stretch, custom }
    enum FrameRate: Int, Codable, CaseIterable { case source = 0, fps24 = 24, fps30 = 30, fps60 = 60 }
    enum DynamicRange: String, Codable, CaseIterable { case automatic, sdr }
    enum Effect: String, Codable, CaseIterable { case none, grayscale, sepia }

    var displayFit: DisplayFit = .fill
    /// 显示方式为「自定义」时显示的部分；nil 为居中、刚好铺满。只在显示器页设置。
    var customFrame: CustomDisplayFrame?
    var speed: Double = 1
    var volume: Double = 1
    var frameRate: FrameRate = .source
    var dynamicRange: DynamicRange = .automatic
    var brightness: Double = 0
    var contrast: Double = 1
    var saturation: Double = 1
    var effect: Effect = .none
    /// Kinetic preparation budget, not a cap on AVFoundation's private decoder memory.
    var preloadBudgetMiB: Int = 256

    var preloadBudgetBytes: Int { preloadBudgetMiB * 1_024 * 1_024 }
    var needsComposition: Bool {
        frameRate != .source || dynamicRange != .automatic || brightness != 0 || contrast != 1
            || saturation != 1 || effect != .none
    }
    func validated() throws -> Self {
        guard speed.isFinite, (0.25...2).contains(speed), volume.isFinite, (0...1).contains(volume),
              brightness.isFinite, (-0.5...0.5).contains(brightness), contrast.isFinite, (0.5...1.5).contains(contrast),
              saturation.isFinite, (0...2).contains(saturation), [64, 128, 256, 512].contains(preloadBudgetMiB),
              customFrame?.isValid ?? true else {
            throw VideoOptionsError.invalidValues
        }
        return self
    }
}

enum VideoOptionsError: LocalizedError {
    case invalidValues, unreadable, unsupportedWallpaper, preparationBudget, composition
    var errorDescription: String? {
        switch self {
        case .invalidValues: return "视频设置包含无效数值。"
        case .unreadable: return "视频设置文件无法读取，已保留原文件。"
        case .unsupportedWallpaper: return "这些设置仅适用于视频壁纸。"
        case .preparationBudget: return "视频准备资源超过预加载预算，请提高预算后重试。原壁纸已保留。"
        case .composition: return "无法建立视频处理管线。原壁纸已保留。"
        }
    }
}
