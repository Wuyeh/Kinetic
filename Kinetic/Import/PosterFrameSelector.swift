import AVFoundation
import CoreGraphics

/// Kinetic 1.0 Module 8：为没有 Poster 的本地视频选一帧代表性画面（规格 8：避免黑色首帧）。
///
/// 依次检查片长的约 10%（不超过 1 秒，与旧规则相同）、25%、50%、75% 处的画面，
/// 取第一张不是近乎全黑的画面；都很暗时取其中最亮、最有层次的一张。只读取视频，不修改任何文件。
enum PosterFrameSelector {
    struct FrameStatistics: Equatable {
        /// 平均亮度 0…1。
        let meanLuminance: Double
        /// 亮度标准差 0…0.5，衡量画面层次。
        let luminanceDeviation: Double
    }

    /// 平均亮度低于这个值视为黑场（片头 / 转场）。
    static let darkThreshold = 0.08

    static func candidateTimes(forDuration seconds: Double) -> [Double] {
        guard seconds.isFinite, seconds > 0 else { return [0] }
        return [min(1.0, seconds * 0.1), seconds * 0.25, seconds * 0.5, seconds * 0.75]
    }

    static func isRepresentative(_ statistics: FrameStatistics) -> Bool {
        statistics.meanLuminance >= darkThreshold
    }

    static func score(_ statistics: FrameStatistics) -> Double {
        statistics.meanLuminance + statistics.luminanceDeviation
    }

    /// 缩小到 16×16 灰度后统计亮度。
    static func statistics(of image: CGImage) -> FrameStatistics? {
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        let values = pixels.map { Double($0) / 255 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return FrameStatistics(meanLuminance: mean, luminanceDeviation: variance.squareRoot())
    }

    /// 返回代表性画面；视频无法读取时返回 nil。
    static func representativeFrame(of video: URL, maximumSize: CGSize = CGSize(width: 960, height: 960)) async -> CGImage? {
        let asset = AVURLAsset(url: video)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maximumSize
        let tolerance = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let duration = (try? await asset.load(.duration)).flatMap { $0.isNumeric ? $0.seconds : nil } ?? 0
        var best: (image: CGImage, score: Double)?
        for seconds in candidateTimes(forDuration: duration) {
            guard let frame = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)),
                  let statistics = statistics(of: frame.image) else { continue }
            let image = frame.image
            if isRepresentative(statistics) { return image }
            if best == nil || score(statistics) > best!.score { best = (image, score(statistics)) }
        }
        return best?.image
    }
}
