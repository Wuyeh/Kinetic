import Combine
import Foundation

enum EngineAssetsError: LocalizedError, Equatable {
    /// 选择的文件夹里没有 Wallpaper Engine 的 `assets`（至少包含 shaders 与 materials）。
    case notWallpaperEngineFolder
    case bookmarkFailed(String)
    case removeFailed(String)

    var errorDescription: String? {
        switch self {
        case .notWallpaperEngineFolder: return NSLocalizedString("engineAssets.error.notFolder", comment: "")
        case .bookmarkFailed(let reason): return String(format: NSLocalizedString("engineAssets.error.bookmark", comment: ""), reason)
        case .removeFailed(let reason): return String(format: NSLocalizedString("engineAssets.error.remove", comment: ""), reason)
        }
    }
}

/// 只读安全范围书签的创建与解析。正式环境使用安全范围书签，测试注入普通书签。
struct EngineAssetsBookmarks {
    var make: (URL) throws -> Data
    var resolve: (Data) throws -> (url: URL, isStale: Bool)

    static let securityScoped = EngineAssetsBookmarks(
        make: { url in
            try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                 includingResourceValuesForKeys: nil, relativeTo: nil)
        },
        resolve: { data in
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            return (url, stale)
        })
}

/// Kinetic 1.0 Module 28 — Wallpaper Engine 引擎素材（用户决定：支持链接已有文件夹，或用自己的 Steam 账号下载）。
///
/// 很多 Scene 壁纸引用 Wallpaper Engine 自带的着色器、材质、模型与粒子（安装目录中的 `assets/`）。Kinetic 不附带、
/// 不分发这些素材，只读取用户自己的副本，素材始终留在这台 Mac 上：
/// - 链接：用户选择 Wallpaper Engine 的安装文件夹（或其中的 `assets`），Kinetic 保存只读的安全范围书签；
/// - 下载：用用户登录的 SteamCMD 下载 Wallpaper Engine（应用 431960，Windows 版本，需要账号拥有它），
///   完成后只保留 `assets/`，位于 `~/Library/Application Support/Kinetic Steam/EngineAssets/wallpaper_engine`。
/// Scene 先在壁纸自己的文件中查找，找不到时才读取这里（`KineticSceneRuntime` 的 engineAssets 根）。
@MainActor
final class EngineAssetsStore: ObservableObject {
    enum Source: String, Equatable { case linked, downloaded }

    enum Status: Equatable {
        case notConfigured
        /// `name`：链接的文件夹名；下载的素材为 nil。
        case ready(Source, name: String?)
        /// 已设置但现在读不到（文件夹被移动、删除，或书签失效）。
        case unavailable(Source, reason: String)
    }

    enum DownloadPhase: Equatable {
        case idle
        case downloading(progress: Double?)
        /// 下载完成，正在删除 `assets/` 以外的文件。
        case pruning
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .downloading, .pruning: return true
            case .idle, .failed: return false
            }
        }
    }

    static let bookmarkKey = "Kinetic.EngineAssets.LinkedBookmark"
    static let sourceKey = "Kinetic.EngineAssets.Source"

    @Published private(set) var status: Status = .notConfigured
    @Published private(set) var downloadPhase: DownloadPhase = .idle
    /// Scene 读取的 `assets` 文件夹；没有可用素材时为 nil。
    @Published private(set) var assetsURL: URL?

    /// Kinetic 管理的下载位置（SteamCMD 的 `force_install_dir`）。
    let managedInstallURL: URL
    private let defaults: UserDefaults
    private let bookmarks: EngineAssetsBookmarks
    /// 链接的文件夹已开始的安全范围访问；取消链接或切换来源时结束。
    private var scopedFolder: URL?
    private var downloadTask: Task<Void, Never>?
    private weak var downloadingService: SteamAcquisitionService?

    init(defaults: UserDefaults = .standard,
         managedInstallURL: URL = EngineAssetsStore.standardManagedInstallURL(),
         bookmarks: EngineAssetsBookmarks = .securityScoped) {
        self.defaults = defaults
        self.managedInstallURL = managedInstallURL.standardizedFileURL
        self.bookmarks = bookmarks
        refresh()
    }

    nonisolated static func standardManagedInstallURL() -> URL {
        SteamHelperConstants.sharedRootURL()
            .appendingPathComponent("EngineAssets", isDirectory: true)
            .appendingPathComponent("wallpaper_engine", isDirectory: true)
    }

    var source: Source? { defaults.string(forKey: Self.sourceKey).flatMap(Source.init(rawValue:)) }
    var hasLink: Bool { defaults.data(forKey: Self.bookmarkKey) != nil }
    var hasDownload: Bool { Self.assetsFolder(in: managedInstallURL) != nil }

    /// 接受 Wallpaper Engine 的安装文件夹（包含 `assets`）或 `assets` 文件夹本身。
    nonisolated static func assetsFolder(in folder: URL) -> URL? {
        let manager = FileManager.default
        func isDirectory(_ url: URL) -> Bool {
            var directory: ObjCBool = false
            return manager.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
        }
        // Wallpaper Engine 的 assets 至少包含 shaders 与 materials。
        func isAssets(_ url: URL) -> Bool {
            isDirectory(url) && ["shaders", "materials"].allSatisfy { isDirectory(url.appendingPathComponent($0, isDirectory: true)) }
        }
        let nested = folder.appendingPathComponent("assets", isDirectory: true)
        if isAssets(nested) { return nested }
        if isAssets(folder) { return folder }
        return nil
    }

    /// 按保存的来源重新解析素材位置（启动时、链接 / 下载 / 删除之后）。
    func refresh() {
        endScopedAccess()
        switch source {
        case .linked?: resolveLinked()
        case .downloaded?: resolveDownloaded()
        case nil:
            assetsURL = nil
            status = .notConfigured
        }
    }

    private func resolveLinked() {
        guard let data = defaults.data(forKey: Self.bookmarkKey) else {
            assetsURL = nil
            status = .notConfigured
            return
        }
        let resolved: (url: URL, isStale: Bool)
        do { resolved = try bookmarks.resolve(data) } catch {
            assetsURL = nil
            status = .unavailable(.linked, reason: NSLocalizedString("engineAssets.unavailable.link", comment: ""))
            return
        }
        let folder = resolved.url
        let started = folder.startAccessingSecurityScopedResource()
        guard let assets = Self.assetsFolder(in: folder) else {
            if started { folder.stopAccessingSecurityScopedResource() }
            assetsURL = nil
            status = .unavailable(.linked, reason: NSLocalizedString("engineAssets.unavailable.link", comment: ""))
            return
        }
        if started { scopedFolder = folder }
        if resolved.isStale, let fresh = try? bookmarks.make(folder) { defaults.set(fresh, forKey: Self.bookmarkKey) }
        assetsURL = assets
        status = .ready(.linked, name: folder.lastPathComponent)
    }

    private func resolveDownloaded() {
        if let assets = Self.assetsFolder(in: managedInstallURL) {
            assetsURL = assets
            status = .ready(.downloaded, name: nil)
        } else {
            assetsURL = nil
            status = .unavailable(.downloaded, reason: NSLocalizedString("engineAssets.unavailable.download", comment: ""))
        }
    }

    private func endScopedAccess() {
        scopedFolder?.stopAccessingSecurityScopedResource()
        scopedFolder = nil
    }

    // MARK: - 链接

    /// 链接用户在打开面板中选择的文件夹（只读）。
    func link(folder: URL) throws {
        guard Self.assetsFolder(in: folder) != nil else { throw EngineAssetsError.notWallpaperEngineFolder }
        let data: Data
        do { data = try bookmarks.make(folder) } catch { throw EngineAssetsError.bookmarkFailed(error.localizedDescription) }
        defaults.set(data, forKey: Self.bookmarkKey)
        defaults.set(Source.linked.rawValue, forKey: Self.sourceKey)
        refresh()
    }

    /// 取消链接（不触碰用户的 Wallpaper Engine 文件夹）。有下载的素材时改用下载的素材。
    func unlink() {
        defaults.removeObject(forKey: Self.bookmarkKey)
        if source == .linked { setSource(hasDownload ? .downloaded : nil) }
        refresh()
    }

    // MARK: - 下载

    /// 用已登录的 SteamCMD 下载 Wallpaper Engine，只保留 `assets/`。下载不改变任何显示器或资料库。
    func startDownload(using steam: SteamAcquisitionService) {
        guard !downloadPhase.isBusy else { return }
        downloadPhase = .downloading(progress: nil)
        downloadingService = steam
        let install = managedInstallURL
        downloadTask = Task { [weak self] in
            let result = await steam.downloadEngineAssets(into: install) { [weak self] fraction in
                guard let self, case .downloading = self.downloadPhase else { return }
                self.downloadPhase = .downloading(progress: fraction)
            }
            guard let self, !Task.isCancelled else { return }
            self.downloadingService = nil
            switch result {
            case .success:
                self.downloadPhase = .pruning
                do {
                    try await Task.detached(priority: .utility) { try Self.prune(installFolder: install) }.value
                    self.setSource(.downloaded)
                    self.refresh()
                    self.downloadPhase = .idle
                } catch {
                    self.downloadPhase = .failed(error.localizedDescription)
                }
            case .failure(let error):
                self.downloadPhase = .failed(error.localizedDescription)
            }
            self.downloadTask = nil
        }
    }

    func cancelDownload() {
        guard downloadPhase.isBusy else { return }
        downloadTask?.cancel()
        downloadTask = nil
        downloadingService?.cancelEngineAssetsDownload()
        downloadingService = nil
        downloadPhase = .idle
    }

    /// 删除 Kinetic 下载的素材（只删除 Kinetic 自己的下载目录）。有链接时改用链接的文件夹。
    func removeDownload() throws {
        guard !downloadPhase.isBusy else { return }
        let folder = managedInstallURL.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: folder.path) {
            guard Self.isInsideSharedFolder(folder) else { throw EngineAssetsError.removeFailed(folder.lastPathComponent) }
            do { try FileManager.default.removeItem(at: folder) } catch {
                throw EngineAssetsError.removeFailed(error.localizedDescription)
            }
        }
        if source == .downloaded { setSource(hasLink ? .linked : nil) }
        downloadPhase = .idle
        refresh()
    }

    private func setSource(_ source: Source?) {
        if let source { defaults.set(source.rawValue, forKey: Self.sourceKey) } else { defaults.removeObject(forKey: Self.sourceKey) }
    }

    nonisolated private static func isInsideSharedFolder(_ url: URL) -> Bool {
        let root = SteamHelperConstants.sharedRootURL().standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// 删除安装目录中 `assets` 以外的所有内容（Wallpaper Engine 程序、SteamCMD 的清单与临时文件）。
    /// 不跟随符号链接；`assets` 必须存在且是真实目录。
    nonisolated static func prune(installFolder: URL) throws {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey]
        let installValues = try installFolder.resourceValues(forKeys: Set(keys))
        guard installValues.isSymbolicLink != true, installValues.isDirectory == true else {
            throw EngineAssetsError.removeFailed(installFolder.lastPathComponent)
        }
        let assets = installFolder.appendingPathComponent("assets", isDirectory: true)
        let assetValues = try? assets.resourceValues(forKeys: Set(keys))
        guard assetValues?.isSymbolicLink != true, assetValues?.isDirectory == true, assetsFolder(in: installFolder) != nil else {
            throw EngineAssetsError.notWallpaperEngineFolder
        }
        for item in try manager.contentsOfDirectory(at: installFolder, includingPropertiesForKeys: keys, options: [])
        where item.lastPathComponent != "assets" {
            try manager.removeItem(at: item)
        }
    }
}
