import Foundation

enum SteamCMDInstallError: LocalizedError, Equatable {
    case downloadFailed(String)
    case launchFailed(String)
    /// Steam 小助手（XPC 服务）无法启动或连接中断。
    case helperUnavailable(String)
    /// SteamCMD 是 Intel 程序，在 Apple 芯片上需要 Rosetta 2。
    case rosettaRequired

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let reason):
            return String(format: NSLocalizedString("steam.install.error.download", comment: ""), reason)
        case .launchFailed(let reason):
            return String(format: NSLocalizedString("steam.install.error.launch", comment: ""), reason)
        case .helperUnavailable(let reason):
            return String(format: NSLocalizedString("steam.install.error.helper", comment: ""), reason)
        case .rosettaRequired: return NSLocalizedString("steam.install.error.rosetta", comment: "")
        }
    }
}

/// 安装 SteamCMD（下载 Valve 官方安装包并解压）。正式环境由 Steam 小助手完成（`SteamHelperClient`），测试注入替身。
typealias SteamCMDInstaller = @MainActor (SteamCMDInstallation) async throws -> Void

/// Kinetic 自己管理的 SteamCMD（用户决定：Kinetic 从 Valve 官方地址自动下载）。
///
/// 位于 `~/Library/Application Support/Kinetic Steam/SteamCMD`（`SteamHelperConstants.steamCMDRootURL()`），
/// 只由 Kinetic、Steam 小助手与它启动的 SteamCMD 写入：
/// - `steamcmd.sh` 与 SteamCMD 自己的文件；
/// - `Downloads/`：`force_install_dir`，创意工坊内容下载到 `Downloads/steamapps/workshop/content/431960/<编号>`，
///   校验并复制进资料库后删除。
@MainActor
final class SteamCMDInstallation {
    let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    /// 正式使用的位置（与 Steam 小助手约定的共享目录）。
    static func standard() -> SteamCMDInstallation {
        SteamCMDInstallation(rootURL: SteamHelperConstants.steamCMDRootURL())
    }

    var scriptURL: URL { rootURL.appendingPathComponent("steamcmd.sh", isDirectory: false) }
    var downloadsURL: URL { rootURL.appendingPathComponent("Downloads", isDirectory: true) }
    /// SteamCMD 运行时的 HOME，避免它写入用户电脑上 Steam 客户端的目录。
    var homeURL: URL { rootURL.appendingPathComponent("home", isDirectory: true) }

    /// SteamCMD 完成下载后的内容目录。
    func contentURL(for workshopID: String) -> URL {
        downloadsURL.appendingPathComponent("steamapps/workshop/content/\(SteamWorkshop.wallpaperEngineAppID)/\(workshopID)",
                                            isDirectory: true)
    }
    /// SteamCMD 下载过程中的暂存目录（用于估计下载进度）。
    func partialDownloadURL(for workshopID: String) -> URL {
        downloadsURL.appendingPathComponent("steamapps/workshop/downloads/\(SteamWorkshop.wallpaperEngineAppID)/\(workshopID)",
                                            isDirectory: true)
    }

    /// 安装脚本存在即视为已安装；第一次运行时 SteamCMD 会自己更新其余文件。
    var isInstalled: Bool { FileManager.default.isReadableFile(atPath: scriptURL.path) }

    /// 路径是否在 Kinetic 的 SteamCMD 目录之内。SteamCMD 报告的下载路径必须在这里，才会被复制进资料库、
    /// 才会在入库后删除。
    func isManagedDownload(_ url: URL) -> Bool {
        WallpaperDeletionService.isInside(url, folder: rootURL)
    }

    /// 删除 SteamCMD 缓存的登录凭据（退出登录）。只删除 Kinetic 自己的 SteamCMD 目录中的文件，
    /// 不触碰用户电脑上的 Steam 客户端。
    func removeCachedCredentials() {
        let fileManager = FileManager.default
        let configFolders = [rootURL.appendingPathComponent("config", isDirectory: true),
                             homeURL.appendingPathComponent("Library/Application Support/Steam/config", isDirectory: true)]
        for folder in configFolders {
            try? fileManager.removeItem(at: folder.appendingPathComponent("config.vdf"))
            try? fileManager.removeItem(at: folder.appendingPathComponent("loginusers.vdf"))
        }
        for folder in [rootURL] + configFolders.map({ $0.deletingLastPathComponent() }) {
            let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in names where name.hasPrefix("ssfn") {
                try? fileManager.removeItem(at: folder.appendingPathComponent(name))
            }
        }
    }
}
