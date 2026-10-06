import AppKit
import CoreImage
import ImageIO
import SwiftUI

/// Kinetic 1.0 Module 11 — Unified Square Poster Grid（规格第 5–7 节）。
///
/// 「本地」与 Steam 在线商店的壁纸预览统一为 1:1 连续圆角正方形：
/// - 圆角随尺寸按比例变化（连续曲率），既不像 App 图标那样圆，也不像网页卡片那样硬。
/// - 非正方形 Poster：前景保持原比例、完整居中；背景用同一张 Poster 等比放大铺满正方形，
///   高斯模糊并降低细节与对比，因此横图上下、竖图左右对称延展。
/// - 动态 Poster（GIF / APNG / 动态 WebP 等）默认播放；只有可见的卡片播放，
///   离开可视范围、窗口不可见、低电量模式或「减弱动态效果」时停在当前帧。背景与当前帧同步（低分辨率）。
enum PosterGeometry {
    static let aspectRatio: CGFloat = 1
    /// 圆角占边长的比例：180 pt 卡片约 13.5 pt，250 pt 约 18.8 pt。
    static let cornerRadiusFraction: CGFloat = 0.075

    static func cornerRadius(forSide side: CGFloat) -> CGFloat {
        max(0, side) * cornerRadiusFraction
    }

    /// 接近正方形（相差 2% 以内）时直接铺满，不做模糊延展。
    static func isEffectivelySquare(_ size: CGSize) -> Bool {
        guard size.width > 0, size.height > 0 else { return true }
        return abs(size.width / size.height - 1) <= 0.02
    }

    /// 前景在正方形中保持原比例、完整显示、居中后的区域。
    static func foregroundRect(imageSize: CGSize, in square: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return square }
        let scale = min(square.width / imageSize.width, square.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: square.midX - size.width / 2, y: square.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
}

/// 圆角随尺寸变化的 Poster 外形；描边、光晕与裁切都用它，保证与 Poster 完全重合。
struct PosterShape: InsettableShape {
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let square = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let radius = max(0, PosterGeometry.cornerRadius(forSide: min(rect.width, rect.height)) - insetAmount)
        return RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: square)
    }

    func inset(by amount: CGFloat) -> PosterShape {
        var shape = self
        shape.insetAmount += amount
        return shape
    }
}

// MARK: - Artwork

/// 一张 Poster 的已解码内容：首帧、背景（模糊、低对比）与是否为动态图。只从磁盘读取一次。
final class PosterArtwork {
    let url: URL
    let firstFrame: CGImage
    let pixelSize: CGSize
    let backdrop: CGImage?
    let frameCount: Int

    var isAnimated: Bool { frameCount > 1 }
    var needsBackdrop: Bool { !PosterGeometry.isEffectivelySquare(pixelSize) }

    init?(url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let first = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        self.url = url
        firstFrame = first
        pixelSize = CGSize(width: first.width, height: first.height)
        frameCount = CGImageSourceGetCount(source)
        backdrop = PosterGeometry.isEffectivelySquare(pixelSize) ? nil : PosterBackdrop.make(from: first)
    }
}

/// 背景：缩小后高斯模糊，降低饱和度与对比，只用来把非正方形 Poster 延展成正方形。
enum PosterBackdrop {
    /// 背景的最长边（像素）。动态 Poster 每帧都要重新生成，保持很小。
    static let maximumSide = 72
    private static let context = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])

    static func make(from image: CGImage) -> CGImage? {
        guard let small = downsample(image) else { return nil }
        let input = CIImage(cgImage: small)
        let sigma = Double(max(small.width, small.height)) * 0.06
        let blurred = input.clampedToExtent()
            .applyingGaussianBlur(sigma: sigma)
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0.9,
                kCIInputContrastKey: 0.82,
                kCIInputBrightnessKey: -0.02
            ])
            .cropped(to: input.extent)
        return context.createCGImage(blurred, from: input.extent)
    }

    private static func downsample(_ image: CGImage) -> CGImage? {
        let longest = max(image.width, image.height)
        let scale = min(1, CGFloat(maximumSide) / CGFloat(max(1, longest)))
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

/// Poster 只解码一次；悬停、选中等外观变化不会重复读取文件。
@MainActor
final class PosterArtworkCache {
    static let shared = PosterArtworkCache()
    private let cache = NSCache<NSURL, PosterArtwork>()

    func artwork(for url: URL) -> PosterArtwork? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        guard let artwork = PosterArtwork(url: url) else { return nil }
        cache.setObject(artwork, forKey: url as NSURL)
        return artwork
    }

    func removeAll() { cache.removeAllObjects() }
}

// MARK: - Poster View

/// 壁纸的正方形 Poster（网格卡片、详情面板与欢迎页共用）。尺寸只由给定宽度决定，与 Poster 内容无关。
/// 1.0 Module 14：Steam 在线商店的卡片也用它（本地已缓存的作者 Poster）。
@MainActor
struct PosterView: View {
    let posterURL: URL?
    let placeholderType: WallpaperType

    init(wallpaper: Wallpaper) {
        self.init(posterURL: wallpaper.thumbnailURL, placeholderType: wallpaper.type)
    }

    init(posterURL: URL?, placeholderType: WallpaperType) {
        self.posterURL = posterURL
        self.placeholderType = placeholderType
    }

    var body: some View {
        Color.clear
            .aspectRatio(PosterGeometry.aspectRatio, contentMode: .fit)
            .overlay { PosterArtworkView(posterURL: posterURL, placeholderType: placeholderType) }
            .clipShape(PosterShape())
    }
}

/// Poster 内容：由图层绘制（`PosterLayerView`）——前景等比完整、背景等比铺满，静态与动态同一条路径；
/// 动态图逐帧更新图层，不引起 SwiftUI 重绘。没有 Poster 时显示占位图形。
@MainActor
struct PosterArtworkView: View {
    let posterURL: URL?
    let placeholderType: WallpaperType

    init(wallpaper: Wallpaper) {
        self.init(posterURL: wallpaper.thumbnailURL, placeholderType: wallpaper.type)
    }

    init(posterURL: URL?, placeholderType: WallpaperType) {
        self.posterURL = posterURL
        self.placeholderType = placeholderType
    }

    var body: some View {
        if let url = posterURL, let artwork = PosterArtworkCache.shared.artwork(for: url) {
            PosterLayerRepresentable(artwork: artwork)
        } else {
            ZStack {
                Color(nsColor: .controlBackgroundColor)
                Image(systemName: placeholderType == .video ? "play.rectangle" : "photo")
                    .font(.system(size: MainWindowDesignTokens.Spacing.large, weight: .ultraLight))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Animated Poster

/// 动态 Poster 是否应当播放（规格 7）。
enum AnimatedPosterPlaybackPolicy {
    static func shouldAnimate(isVisibleInScrollView: Bool, windowIsVisible: Bool,
                              lowPowerMode: Bool, reduceMotion: Bool) -> Bool {
        isVisibleInScrollView && windowIsVisible && !lowPowerMode && !reduceMotion
    }
}

private struct PosterLayerRepresentable: NSViewRepresentable {
    let artwork: PosterArtwork
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> PosterLayerView {
        let view = PosterLayerView()
        view.reduceMotion = reduceMotion
        view.artwork = artwork
        return view
    }

    func updateNSView(_ view: PosterLayerView, context: Context) {
        view.reduceMotion = reduceMotion
        if view.artwork !== artwork { view.artwork = artwork }
    }

    static func dismantleNSView(_ view: PosterLayerView, coordinator: ()) {
        view.stopAnimating()
    }
}

/// 显示一张 Poster：背景图层（模糊、等比铺满）与前景图层（等比完整居中）；接近正方形时前景直接铺满。
/// 动态 Poster 逐帧同时更新两层（背景为低分辨率模糊），只在可见时通过 ImageIO 的
/// `CGAnimateImageAtURLWithBlock` 播放；暂停后从停下的那一帧继续。
final class PosterLayerView: NSView {
    private let backdropLayer = CALayer()
    private let foregroundLayer = CALayer()
    private var animationToken = 0
    private var nextFrameIndex = 0
    private(set) var isAnimating = false
    private(set) var displayedFrameCount = 0
    private weak var observedClipView: NSClipView?

    var reduceMotion = false { didSet { if reduceMotion != oldValue { updatePlayback() } } }

    var artwork: PosterArtwork? {
        didSet {
            stopAnimating()
            nextFrameIndex = 0
            show(frame: artwork?.firstFrame)
            refreshObservers()
            updatePlayback()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = true
        for sublayer in [backdropLayer, foregroundLayer] {
            sublayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
            layer?.addSublayer(sublayer)
        }
        backdropLayer.contentsGravity = .resizeAspectFill
        foregroundLayer.contentsGravity = .resizeAspect
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // SwiftUI 的 clipShape 不裁切 NSView，圆角由图层自己完成。
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = PosterGeometry.cornerRadius(forSide: min(bounds.width, bounds.height))
        backdropLayer.frame = bounds
        foregroundLayer.frame = bounds
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshObservers()
        updatePlayback()
    }

    /// 只有动态 Poster 需要知道滚动、窗口与电源状态；静态 Poster 不注册任何通知，滚动时没有额外开销。
    private func refreshObservers() {
        let center = NotificationCenter.default
        center.removeObserver(self)
        observedClipView = nil
        guard let window, artwork?.isAnimated == true else { return }
        center.addObserver(self, selector: #selector(conditionsChanged),
                           name: .NSProcessInfoPowerStateDidChange, object: nil)
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification] {
            center.addObserver(self, selector: #selector(conditionsChanged), name: name, object: window)
        }
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            observedClipView = clip
            center.addObserver(self, selector: #selector(conditionsChanged),
                               name: NSView.boundsDidChangeNotification, object: clip)
        }
    }

    override func viewDidHide() { super.viewDidHide(); updatePlayback() }
    override func viewDidUnhide() { super.viewDidUnhide(); updatePlayback() }

    @objc private func conditionsChanged() {
        DispatchQueue.main.async { [weak self] in self?.updatePlayback() }
    }

    var isVisibleInScrollView: Bool {
        guard window != nil, !isHiddenOrHasHiddenAncestor else { return false }
        return !visibleRect.isEmpty
    }

    private var windowIsVisible: Bool {
        guard let window else { return false }
        return !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    func updatePlayback() {
        guard let artwork, artwork.isAnimated else { return stopAnimating() }
        let shouldAnimate = AnimatedPosterPlaybackPolicy.shouldAnimate(
            isVisibleInScrollView: isVisibleInScrollView,
            windowIsVisible: windowIsVisible,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            reduceMotion: reduceMotion
        )
        shouldAnimate ? startAnimating(artwork) : stopAnimating()
    }

    private func startAnimating(_ artwork: PosterArtwork) {
        guard !isAnimating else { return }
        isAnimating = true
        animationToken += 1
        let token = animationToken
        let options = [kCGImageAnimationStartIndex as String: nextFrameIndex] as CFDictionary
        let status = CGAnimateImageAtURLWithBlock(artwork.url as CFURL, options) { [weak self] index, image, stop in
            let deliver = {
                guard let self, self.isAnimating, self.animationToken == token else {
                    stop.pointee = true
                    return
                }
                self.nextFrameIndex = (index + 1) % max(1, artwork.frameCount)
                self.show(frame: image)
            }
            if Thread.isMainThread { deliver() } else { DispatchQueue.main.sync(execute: deliver) }
        }
        if status != noErr { isAnimating = false }
    }

    func stopAnimating() {
        guard isAnimating else { return }
        isAnimating = false
        animationToken += 1
    }

    private func show(frame image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        foregroundLayer.contents = image
        if let image, let artwork, artwork.needsBackdrop {
            // 静态 Poster 与首帧用预先生成的背景；动态 Poster 的其他帧实时生成低分辨率背景。
            backdropLayer.contents = image === artwork.firstFrame ? artwork.backdrop : PosterBackdrop.make(from: image)
            backdropLayer.isHidden = false
            foregroundLayer.contentsGravity = .resizeAspect
        } else {
            backdropLayer.isHidden = true
            foregroundLayer.contentsGravity = .resizeAspectFill
        }
        CATransaction.commit()
        if image != nil { displayedFrameCount += 1 }
    }

    /// 测试与诊断用：按当前图层内容绘制一张位图。
    func renderedImage(scale: CGFloat = 1) -> CGImage? {
        needsLayout = true
        layoutSubtreeIfNeeded()
        let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
        guard width > 0, height > 0, let layer,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        return context.makeImage()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
