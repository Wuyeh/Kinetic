import AppKit
import KineticSceneRuntime

/// Module 28：没有设置引擎素材时缺少资源，提示用户去 设置 › Steam 链接或下载（大多数 Scene 依赖引擎自带的模型与着色器）；
/// 缺少创意工坊依赖项时提示去 设置 › Steam 下载（28.4）。
enum SceneRendererError: LocalizedError, Equatable {
    case engineAssetsRequired(String)
    case workshopDependencyMissing(String)

    var errorDescription: String? {
        switch self {
        case .engineAssetsRequired(let path):
            return String(format: NSLocalizedString("scene.error.engineAssetsRequired", comment: "Scene needs engine assets"), path)
        case .workshopDependencyMissing(let id):
            return String(format: NSLocalizedString("scene.error.dependencyMissing", comment: "Scene needs a Workshop dependency"), id)
        }
    }
}

/// Thin renderer adapter. The independent package owns graphics; the existing
/// per-display session owns activation, crossfade, pause intent, and retirement.
@MainActor
final class SceneRenderer: WallpaperRenderer {
    let wallpaper: Wallpaper
    let scene: KineticSceneRuntime
    var displayView: NSView { scene.displayView }
    var onFailure: (@MainActor (Error) -> Void)?
    /// Module 28：用户链接或下载的 Wallpaper Engine `assets` 文件夹（设置 › Steam）。App 启动时设置；测试中为 nil。
    static var engineAssetsProvider: (@MainActor () -> URL?)?
    /// Module 28：按创意工坊编号找到本机的 Scene 依赖项文件夹（WorkshopDependencyStore）。App 启动时设置；测试中为 nil。
    static var dependencyProvider: (@MainActor (String) -> URL?)?
    /// Module 29: immutable, validated values for this library identity; no storage in the runtime.
    static var propertyValuesProvider: (@MainActor (Wallpaper.ID) -> [String: ScenePropertyValue])?
    /// 28.4：设置 › 播放 › 场景壁纸显示方式。新建的渲染器读取它；设置改变时 `applyDisplayFit` 更新正在显示的场景。
    static var displayFit: SceneDisplayFit = .automatic
    private static let liveRenderers = NSHashTable<SceneRenderer>.weakObjects()

    /// 设置改变时更新所有正在显示的场景（各显示器各自按自己的比例判断）。
    static func applyDisplayFit(_ fit: SceneDisplayFit) {
        displayFit = fit
        for renderer in liveRenderers.allObjects { renderer.scene.displayFit = fit }
    }
    /// Module 51：自适应帧率。桌面上的场景（与显示方式同一组）减半到 15 帧；之后创建的场景也跟随。
    private(set) static var isAdaptiveFrameRateThrottled = false
    static func applyAdaptiveFrameRateThrottle(_ active: Bool) {
        guard isAdaptiveFrameRateThrottled != active else { return }
        isAdaptiveFrameRateThrottled = active
        for renderer in liveRenderers.allObjects {
            let scene = renderer.scene
            Task { await scene.setAdaptiveFrameRateThrottle(active) }
        }
    }
    /// App 层只认识设置值；场景运行时的类型留在这个适配层里。
    static func applyDisplayFitSetting(_ setting: SceneDisplayFitSetting) { applyDisplayFit(SceneDisplayFit(setting)) }
    convenience init(wallpaper: Wallpaper) {
        self.init(wallpaper: wallpaper, engineAssets: SceneRenderer.engineAssetsProvider?(),
                  dependencyFolders: SceneRenderer.dependencyFolders(for: wallpaper),
                  propertyValues: SceneRenderer.propertyValuesProvider?(wallpaper.id) ?? [:])
    }
    private let hasEngineAssets: Bool
    init(wallpaper: Wallpaper, engineAssets: URL?, dependencyFolders: [String: URL] = [:],
         propertyValues: [String: ScenePropertyValue] = [:], participatesInGlobalDisplayFit: Bool = true) {
        self.wallpaper = wallpaper
        hasEngineAssets = engineAssets != nil
        scene = KineticSceneRuntime(root: wallpaper.resourceURL, engineAssets: engineAssets,
                                    dependencyFolder: dependencyFolders.isEmpty ? nil : { dependencyFolders[$0] },
                                    propertyValues: propertyValues)
        scene.displayFit = Self.displayFit
        if participatesInGlobalDisplayFit {
            Self.liveRenderers.add(self)
            if Self.isAdaptiveFrameRateThrottled { let scene = scene; Task { await scene.setAdaptiveFrameRateThrottle(true) } }
        }
        scene.onFailure = { [weak self] error in self?.onFailure?(error) }
    }
    /// 这个 Scene 列出的依赖项中本机已有的文件夹（缺少的不放进来，由场景引擎报告）。
    static func dependencyFolders(for wallpaper: Wallpaper) -> [String: URL] {
        guard wallpaper.type == .scene, let provider = dependencyProvider else { return [:] }
        var folders: [String: URL] = [:]
        for id in KineticSceneRuntime.workshopDependencies(of: wallpaper.resourceURL) where folders[id] == nil {
            if let folder = provider(id) { folders[id] = folder }
        }
        return folders
    }
    func prepare() async throws {
        guard wallpaper.type == .scene else { throw SceneRuntimeError.unsupported("wallpaper type") }
        do {
            try await scene.prepare()
        } catch SceneRuntimeError.missingAsset(let path) {
            if let id = KineticSceneRuntime.missingDependencyID(inDetail: path) {
                throw SceneRendererError.workshopDependencyMissing(id)
            }
            if !hasEngineAssets { throw SceneRendererError.engineAssetsRequired(path) }
            throw SceneRuntimeError.missingAsset(path)
        }
    }
    /// 显示器页的显示方式；「自定义」时显示 `frame` 选定的部分。
    func applyDisplay(_ setting: SceneDisplayFitSetting, frame: CustomDisplayFrame?) {
        scene.displayFit = SceneDisplayFit(setting)
        scene.displayCrop = SceneDisplayCrop(setting, frame: frame)
    }
    func play() { scene.play() }
    func pause() { scene.pause() }
    func resume() { scene.resume() }
    func setMuted(_ muted: Bool) { scene.setMuted(muted) }
    func dispose() { scene.dispose(); onFailure = nil }
}

extension SceneDisplayFit {
    init(_ setting: SceneDisplayFitSetting) {
        switch setting {
        case .automatic: self = .automatic
        // 「自定义」由 displayCrop 决定显示的部分；这里的值只在没有区域时使用。
        case .fill, .custom: self = .fill
        case .fit: self = .fit
        }
    }
}

extension SceneDisplayCrop {
    /// 显示方式为「自定义」时的区域；其他方式为 nil。没有保存过的区域为居中、刚好铺满。
    init?(_ setting: SceneDisplayFitSetting, frame: CustomDisplayFrame?) {
        guard setting == .custom else { return nil }
        self.init(frame ?? CustomDisplayFrame())
    }
    init(_ frame: CustomDisplayFrame) { self.init(zoom: frame.zoom, centerX: frame.centerX, centerY: frame.centerY) }
}

extension CustomDisplayFrame {
    /// 显示器上显示的那部分壁纸（0…1，左上角为原点），视频与场景用同一套计算。
    func region(content: CGSize, viewport: CGSize) -> CGRect {
        SceneDisplayCrop(self).region(canvas: content, viewport: viewport)
    }
}
