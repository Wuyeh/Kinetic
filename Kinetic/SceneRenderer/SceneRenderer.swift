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
    convenience init(wallpaper: Wallpaper) {
        self.init(wallpaper: wallpaper, engineAssets: SceneRenderer.engineAssetsProvider?(),
                  dependencyFolders: SceneRenderer.dependencyFolders(for: wallpaper))
    }
    private let hasEngineAssets: Bool
    init(wallpaper: Wallpaper, engineAssets: URL?, dependencyFolders: [String: URL] = [:]) {
        self.wallpaper = wallpaper
        hasEngineAssets = engineAssets != nil
        scene = KineticSceneRuntime(root: wallpaper.resourceURL, engineAssets: engineAssets,
                                    dependencyFolder: dependencyFolders.isEmpty ? nil : { dependencyFolders[$0] })
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
    func play() { scene.play() }
    func pause() { scene.pause() }
    func resume() { scene.resume() }
    func setMuted(_ muted: Bool) { scene.setMuted(muted) }
    func dispose() { scene.dispose(); onFailure = nil }
}
