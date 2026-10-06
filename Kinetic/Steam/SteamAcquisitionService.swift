import Combine
import Foundation

enum SteamAcquisitionError: LocalizedError, Equatable {
    case steamCMDUnavailable(String)
    /// 没有登录，或 SteamCMD 缓存的登录已失效，需要在设置中重新登录。
    case signInRequired
    /// Steam 拒绝下载：这个账号没有 Wallpaper Engine。
    case noLicense
    case network
    case downloadFailed(String)
    case invalidPackage(String)
    case importFailed(String)
    /// 已在本地资料库（规格 10：双击不重复下载）。
    case alreadyInLibrary(Wallpaper.ID)
    case alreadyInProgress

    var errorDescription: String? {
        switch self {
        case .steamCMDUnavailable(let reason): return reason
        case .signInRequired: return NSLocalizedString("steam.error.signInRequired", comment: "")
        case .noLicense: return NSLocalizedString("steam.error.noLicense", comment: "")
        case .network: return NSLocalizedString("steam.error.network", comment: "")
        case .downloadFailed(let reason):
            return String(format: NSLocalizedString("steam.error.download", comment: ""), reason)
        case .invalidPackage(let reason), .importFailed(let reason): return reason
        case .alreadyInLibrary: return NSLocalizedString("steam.store.inLibrary", comment: "")
        case .alreadyInProgress: return NSLocalizedString("steam.error.inProgress", comment: "")
        }
    }
}

/// Kinetic 1.0 Module 9 — Steam Acquisition Core（规格 37：SteamCMD / Login / Guard / Download / Verify / Import Local）。
///
/// - SteamCMD 由 Kinetic 从 Valve 官方地址下载到自己的数据目录（用户决定）。
/// - 登录：只保存用户名。密码与 Steam 令牌代码只通过标准输入交给 SteamCMD，不保存、不写日志；
///   之后由 SteamCMD 自己缓存的登录凭据完成下载（`@NoPromptForPassword`）。
/// - 下载：同一时间只运行一个 SteamCMD；其余任务排队。
/// - 下载完成后校验 `project.json` 与内容，复制进本地资料库（`SteamWorkshopImporter`），再删除 SteamCMD 的下载副本。
/// - 规格 11：下载 = 添加到本地资料库，绝不应用、不改变任何显示器。
@MainActor
final class SteamAcquisitionService: ObservableObject {
    enum InstallState: Equatable {
        case notInstalled
        case installing
        case installed
        case failed(String)
    }

    enum SignInState: Equatable {
        case signedOut
        case signingIn
        case needsGuardCode(SteamGuardKind)
        case waitingForMobileConfirmation
        case signedIn
        case failed(SteamLoginFailure)
    }

    enum TaskPhase: Equatable {
        case queued
        case downloading(progress: Double?)
        case verifying
        case importing
        case finished(Wallpaper.ID)
        case failed(String)

        var isActive: Bool {
            switch self {
            case .queued, .downloading, .verifying, .importing: return true
            case .finished, .failed: return false
            }
        }
    }

    static let usernameKey = "Kinetic.Steam.Username"

    @Published private(set) var installState: InstallState
    @Published private(set) var signInState: SignInState
    /// 最近一次成功登录的 Steam 用户名（登录失效后仍保留，方便重新登录）。
    @Published private(set) var username: String?
    /// 按创意工坊编号记录的下载任务状态（Module 14 / 15 的卡片据此显示进度）。
    @Published private(set) var tasks: [String: TaskPhase] = [:]
    /// Module 28：最近一次没能下载的 Scene 依赖项（创意工坊编号 → 原因）。壁纸照常入库，播放时报告缺少的依赖项。
    @Published private(set) var dependencyFailures: [String: String] = [:]
    /// Module 28.4：设置 › Steam「下载缺少的依赖项」的进度。
    @Published private(set) var dependencyDownload: DependencyDownloadPhase = .idle

    enum DependencyDownloadPhase: Equatable {
        case idle
        /// 已处理 `completed` 个（成功或失败），共 `total` 个。
        case downloading(completed: Int, total: Int)
    }

    /// 资料库中 Scene 壁纸缺少的创意工坊依赖项。
    struct MissingDependencies: Equatable {
        /// 去重后的编号（按资料库顺序）。
        var ids: [String] = []
        /// 因此无法播放的 Scene 壁纸数量。
        var wallpaperCount = 0
        var isEmpty: Bool { ids.isEmpty }
    }

    let installation: SteamCMDInstallation
    private let library: WallpaperLibrary
    private let makeProcess: SteamCMDProcessFactory
    private let installer: SteamCMDInstaller
    private let defaults: UserDefaults
    private let isInUse: @MainActor (Wallpaper.ID) -> Bool
    /// 下载进度的轮询间隔。
    var progressInterval: TimeInterval = 0.5

    private var signInProcess: SteamCMDProcess?
    /// Module 28：正在下载 Wallpaper Engine 引擎素材的 SteamCMD（用于取消）。
    private var engineAssetsProcess: SteamCMDProcess?
    private var isRunningSteamCMD = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(installation: SteamCMDInstallation,
         library: WallpaperLibrary,
         defaults: UserDefaults = .standard,
         isInUse: @escaping @MainActor (Wallpaper.ID) -> Bool = { _ in false },
         makeProcess: @escaping SteamCMDProcessFactory = { XPCSteamCMDProcess(installation: $0, arguments: $1) },
         installer: @escaping SteamCMDInstaller = { try await SteamHelperClient.shared.install(into: $0.rootURL) }) {
        self.installation = installation
        self.library = library
        self.defaults = defaults
        self.isInUse = isInUse
        self.makeProcess = makeProcess
        self.installer = installer
        installState = installation.isInstalled ? .installed : .notInstalled
        let saved = defaults.string(forKey: Self.usernameKey)
        username = saved
        signInState = saved == nil ? .signedOut : .signedIn
    }

    var isSignedIn: Bool { signInState == .signedIn }

    // MARK: - SteamCMD

    /// 下载并解压 Valve 官方的 SteamCMD（由 Steam 小助手完成），然后让它完成第一次自我更新。
    @discardableResult
    func install() async -> Bool {
        if installState == .installing { return false }
        installState = .installing
        do {
            if !installation.isInstalled {
                try await installer(installation)
            }
            await acquireSteamCMD()
            defer { releaseSteamCMD() }
            var lastLine = ""
            let status = try await run(["+quit"], onLine: { lastLine = $0 }) { _, _ in false }
            // SteamCMD 自我更新后可能以 7 退出，属于正常情况。
            guard status == 0 || status == 7 else {
                var reason = String(format: NSLocalizedString("steam.exitCode", comment: ""), status)
                if !lastLine.isEmpty { reason += " " + lastLine }
                throw SteamCMDInstallError.launchFailed(reason)
            }
            installState = .installed
            return true
        } catch {
            installState = .failed(error.localizedDescription)
            return false
        }
    }

    // MARK: - 登录

    /// 用用户名与密码登录。密码只写给 SteamCMD 的输入提示一次，随后丢弃。
    func signIn(username rawUsername: String, password: String) async {
        let username = rawUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, !password.isEmpty, signInProcess == nil else { return }
        signInState = .signingIn
        if !installation.isInstalled || installState != .installed {
            guard await install() else {
                signInState = .failed(.other(NSLocalizedString("steam.install.required", comment: "")))
                return
            }
        }
        await acquireSteamCMD()
        defer { releaseSteamCMD() }

        let secret = SecretBox(password)
        var succeeded = false
        do {
            let status = try await run(["+@ShutdownOnFailedCommand", "1", "+login", username, "+quit"]) { [weak self] event, process in
                guard let self else { return true }
                self.signInProcess = process
                switch event {
                case .passwordPrompt:
                    // 第二次要求密码说明密码错误。
                    guard let password = secret.take() else {
                        self.signInState = .failed(.invalidPassword)
                        return true
                    }
                    process.writeLine(password)
                case .guardCodePrompt(let kind):
                    self.signInProcess = process
                    self.signInState = .needsGuardCode(kind)
                case .mobileConfirmationRequested:
                    self.signInProcess = process
                    self.signInState = .waitingForMobileConfirmation
                case .loginSucceeded:
                    succeeded = true
                    self.signInState = .signedIn
                    self.username = username
                    self.defaults.set(username, forKey: Self.usernameKey)
                case .loginFailed(.passwordRequired) where !secret.wasTaken:
                    // 交互登录时 SteamCMD 先报告“没有缓存的登录凭据”（Cached credentials not found），
                    // 随后才提示输入密码；这不是失败。
                    break
                case .loginFailed(let failure):
                    self.signInState = .failed(failure)
                    return true
                case .downloadSucceeded, .downloadFailed, .appUpdateProgress, .appInstalled, .appInstallFailed:
                    break
                }
                return false
            }
            if !succeeded, signInState == .signingIn || signInState.isWaitingForUser {
                signInState = .failed(.other(String(format: NSLocalizedString("steam.exitCode", comment: ""), status)))
            }
        } catch {
            signInState = .failed(.other(error.localizedDescription))
        }
        secret.clear()
        signInProcess = nil
    }

    /// 回答 Steam 令牌代码提示。
    func submitGuardCode(_ code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let process = signInProcess, case .needsGuardCode = signInState else { return }
        signInState = .signingIn
        process.writeLine(trimmed)
    }

    /// 取消正在进行的登录（例如不想输入令牌代码）。保留用户名，方便再次登录。
    func cancelSignIn() {
        signInProcess?.terminate()
        signInProcess = nil
        signInState = .signedOut
    }

    /// 退出登录：忘记用户名，并删除 Kinetic 的 SteamCMD 缓存的登录凭据。
    func signOut() {
        signInProcess?.terminate()
        signInProcess = nil
        installation.removeCachedCredentials()
        defaults.removeObject(forKey: Self.usernameKey)
        username = nil
        signInState = .signedOut
    }

    // MARK: - 获取（下载 → 校验 → 入库）

    /// 把一个创意工坊项目加入本地资料库。已在资料库时不重复下载（`allowUpdate` 为 true 时更新现有记录）。
    /// 绝不应用、不改变任何显示器。
    func acquire(_ item: SteamWorkshopItemInfo, allowUpdate: Bool = false) async -> Result<Wallpaper, SteamAcquisitionError> {
        let id = item.workshopID
        if let existing = library.wallpaper(workshopID: id), !allowUpdate { return .failure(.alreadyInLibrary(existing.id)) }
        if tasks[id]?.isActive == true { return .failure(.alreadyInProgress) }
        tasks[id] = .queued
        let result = await performAcquire(item)
        switch result {
        case .success(let wallpaper): tasks[id] = .finished(wallpaper.id)
        case .failure(let error): tasks[id] = .failed(error.localizedDescription)
        }
        return result
    }

    private func performAcquire(_ item: SteamWorkshopItemInfo) async -> Result<Wallpaper, SteamAcquisitionError> {
        if !installation.isInstalled || installState != .installed {
            guard await install() else {
                if case .failed(let reason) = installState { return .failure(.steamCMDUnavailable(reason)) }
                return .failure(.steamCMDUnavailable(NSLocalizedString("steam.install.required", comment: "")))
            }
        }
        guard let username, isSignedIn else { return .failure(.signInRequired) }

        await acquireSteamCMD()
        let downloaded: URL
        do {
            tasks[item.workshopID] = .downloading(progress: nil)
            downloaded = try await download(item, username: username)
        } catch let error as SteamAcquisitionError {
            releaseSteamCMD()
            return .failure(error)
        } catch {
            releaseSteamCMD()
            return .failure(.downloadFailed(error.localizedDescription))
        }
        releaseSteamCMD()
        defer {
            if installation.isManagedDownload(downloaded) { try? FileManager.default.removeItem(at: downloaded) }
        }

        tasks[item.workshopID] = .verifying
        let package: SteamWorkshopPackage
        do {
            package = try await SteamWorkshopPackage.verify(folder: downloaded)
        } catch {
            return .failure(.invalidPackage(error.localizedDescription))
        }

        tasks[item.workshopID] = .importing
        let wallpaper: Wallpaper
        do {
            wallpaper = try await SteamWorkshopImporter(library: library)
                .importPackage(package, item: item, isInUse: isInUse)
        } catch {
            return .failure(.importFailed(error.localizedDescription))
        }
        await acquireDependencies(of: wallpaper, username: username)
        return .success(wallpaper)
    }

    /// Module 28：本地导入的 Scene 列出创意工坊依赖项时，若 SteamCMD 已安装且已登录，在后台下载缺少的那些。
    /// 不安装 SteamCMD、不要求登录、不改动资料库记录。
    func fetchMissingDependencies(of wallpaper: Wallpaper) async {
        guard wallpaper.type == .scene, installation.isInstalled, installState == .installed,
              let username, isSignedIn else { return }
        await acquireDependencies(of: wallpaper, username: username)
    }

    /// Module 28：Scene 在 `project.json` 中列出的创意工坊依赖项（素材包）用同一个账号一起下载（与 Wallpaper Engine
    /// 订阅时相同），放进 `WorkshopDependencyStore`。依赖项下载失败不影响壁纸入库；播放时会明确报告缺少哪一个。
    private func acquireDependencies(of wallpaper: Wallpaper, username: String) async {
        let missing = WorkshopDependencyStore(storage: library.storage).missingDependencies(of: wallpaper, library: library)
        await downloadDependencies(missing, username: username)
    }

    /// Module 28.4：资料库中所有 Scene 壁纸缺少的依赖项（只读本地 `project.json`，不联网）。
    func missingLibraryDependencies() -> MissingDependencies {
        let store = WorkshopDependencyStore(storage: library.storage)
        var result = MissingDependencies()
        var seen = Set<String>()
        for wallpaper in library.wallpapers where wallpaper.type == .scene {
            let missing = store.missingDependencies(of: wallpaper, library: library)
            guard !missing.isEmpty else { continue }
            result.wallpaperCount += 1
            for id in missing where seen.insert(id).inserted { result.ids.append(id) }
        }
        return result
    }

    /// Module 28.4：设置 › Steam「下载缺少的依赖项」。未登录时导入、或当时下载失败的 Scene 依赖项在这里补下。
    /// 需要已安装 SteamCMD 并已登录；不会弹出登录、不改动资料库记录。返回是否全部下载成功。
    @discardableResult
    func downloadMissingLibraryDependencies() async -> Bool {
        guard dependencyDownload == .idle, installation.isInstalled, installState == .installed,
              let username, isSignedIn else { return false }
        let missing = missingLibraryDependencies().ids
        guard !missing.isEmpty else { return true }
        return await downloadDependencies(missing, username: username, reportsProgress: true)
    }

    @discardableResult
    private func downloadDependencies(_ ids: [String], username: String, reportsProgress: Bool = false) async -> Bool {
        guard !ids.isEmpty else { return true }
        if reportsProgress { dependencyDownload = .downloading(completed: 0, total: ids.count) }
        await acquireSteamCMD()
        defer {
            releaseSteamCMD()
            if reportsProgress { dependencyDownload = .idle }
        }
        let store = WorkshopDependencyStore(storage: library.storage)
        var succeeded = true
        for (index, id) in ids.enumerated() {
            do {
                let downloaded = try await download(SteamWorkshopItemInfo(workshopID: id), username: username)
                defer { if installation.isManagedDownload(downloaded) { try? FileManager.default.removeItem(at: downloaded) } }
                try await store.install(downloaded, workshopID: id)
                dependencyFailures[id] = nil
            } catch {
                dependencyFailures[id] = error.localizedDescription
                succeeded = false
            }
            if reportsProgress { dependencyDownload = .downloading(completed: index + 1, total: ids.count) }
        }
        return succeeded
    }

    private func download(_ item: SteamWorkshopItemInfo, username: String) async throws -> URL {
        let id = item.workshopID
        var result: Result<URL, SteamAcquisitionError>?
        let progress = startProgressPolling(item)
        defer { progress.cancel() }
        let arguments = ["+@ShutdownOnFailedCommand", "1", "+@NoPromptForPassword", "1",
                         "+force_install_dir", installation.downloadsURL.path,
                         "+login", username,
                         "+workshop_download_item", SteamWorkshop.wallpaperEngineAppID, id, "validate",
                         "+quit"]
        let status = try await run(arguments) { [weak self] event, _ in
            guard let self else { return true }
            switch event {
            case .passwordPrompt, .guardCodePrompt, .mobileConfirmationRequested:
                result = .failure(.signInRequired)
            case .loginFailed(let failure):
                switch failure {
                case .passwordRequired, .invalidPassword, .invalidGuardCode:
                    result = .failure(.signInRequired)
                case .noConnection:
                    result = .failure(.network)
                case .rateLimited, .other:
                    result = .failure(.downloadFailed(SteamLoginFailure.describe(failure)))
                }
            case .downloadSucceeded(let workshopID, let path, _) where workshopID == id:
                let url = URL(fileURLWithPath: path, isDirectory: true)
                result = self.installation.isManagedDownload(url)
                    ? .success(url) : .failure(.downloadFailed(NSLocalizedString("steam.error.unexpectedPath", comment: "")))
            case .downloadFailed(let workshopID, let reason) where workshopID == id:
                result = .failure(reason.lowercased().contains("access denied") ? .noLicense : .downloadFailed(reason))
            case .loginSucceeded, .downloadSucceeded, .downloadFailed, .appUpdateProgress, .appInstalled, .appInstallFailed:
                return false
            }
            if case .failure(.signInRequired) = result { self.signInState = .failed(.passwordRequired) }
            return result != nil
        }
        switch result {
        case .success(let url): return url
        case .failure(let error): throw error
        case nil:
            throw SteamAcquisitionError.downloadFailed(String(format: NSLocalizedString("steam.exitCode", comment: ""), status))
        }
    }

    // MARK: - Module 28：Wallpaper Engine 引擎素材

    /// 用已登录的账号下载 Wallpaper Engine（应用 431960，Windows 版本）到 `installFolder`（Kinetic 管理的目录）。
    /// 需要账号拥有 Wallpaper Engine。只下载、不应用、不改动资料库；调用方随后只保留 `assets/`。
    func downloadEngineAssets(into installFolder: URL,
                              onProgress: @escaping @MainActor (Double?) -> Void) async -> Result<Void, SteamAcquisitionError> {
        if !installation.isInstalled || installState != .installed {
            guard await install() else {
                if case .failed(let reason) = installState { return .failure(.steamCMDUnavailable(reason)) }
                return .failure(.steamCMDUnavailable(NSLocalizedString("steam.install.required", comment: "")))
            }
        }
        guard let username, isSignedIn else { return .failure(.signInRequired) }
        do {
            try FileManager.default.createDirectory(at: installFolder, withIntermediateDirectories: true)
        } catch {
            return .failure(.downloadFailed(error.localizedDescription))
        }
        await acquireSteamCMD()
        defer { releaseSteamCMD(); engineAssetsProcess = nil }
        let appID = SteamWorkshop.wallpaperEngineAppID
        // Wallpaper Engine 只有 Windows 版本；引擎素材与平台无关。
        let arguments = ["+@ShutdownOnFailedCommand", "1", "+@NoPromptForPassword", "1",
                         "+@sSteamCmdForcePlatformType", "windows",
                         "+force_install_dir", installFolder.path,
                         "+login", username,
                         "+app_update", appID, "validate",
                         "+quit"]
        var result: Result<Void, SteamAcquisitionError>?
        do {
            let status = try await run(arguments) { [weak self] event, process in
                guard let self else { return true }
                self.engineAssetsProcess = process
                switch event {
                case .passwordPrompt, .guardCodePrompt, .mobileConfirmationRequested:
                    result = .failure(.signInRequired)
                case .loginFailed(let failure):
                    switch failure {
                    case .passwordRequired, .invalidPassword, .invalidGuardCode: result = .failure(.signInRequired)
                    case .noConnection: result = .failure(.network)
                    case .rateLimited, .other: result = .failure(.downloadFailed(SteamLoginFailure.describe(failure)))
                    }
                case .appUpdateProgress(let fraction):
                    onProgress(fraction)
                    return false
                case .appInstalled(let id) where id == appID:
                    // 让 SteamCMD 自己执行 +quit，写完安装记录。
                    result = .success(())
                    return false
                case .appInstallFailed(let id, let reason) where id == appID:
                    let lower = reason.lowercased()
                    result = .failure(lower.contains("no subscription") || lower.contains("invalid platform") ? .noLicense : .downloadFailed(reason))
                case .loginSucceeded, .downloadSucceeded, .downloadFailed, .appInstalled, .appInstallFailed:
                    return false
                }
                if case .failure(.signInRequired) = result { self.signInState = .failed(.passwordRequired) }
                return true
            }
            if let result { return result }
            return .failure(.downloadFailed(String(format: NSLocalizedString("steam.exitCode", comment: ""), status)))
        } catch {
            return .failure(.downloadFailed(error.localizedDescription))
        }
    }

    /// 取消引擎素材下载（结束 SteamCMD；已下载的部分留给下一次继续）。
    func cancelEngineAssetsDownload() {
        engineAssetsProcess?.terminate()
    }

    /// 按已下载的字节数估计进度（SteamCMD 不输出创意工坊下载的百分比）。不知道总大小时只显示正在下载。
    private func startProgressPolling(_ item: SteamWorkshopItemInfo) -> Task<Void, Never> {
        let folders = [installation.partialDownloadURL(for: item.workshopID), installation.contentURL(for: item.workshopID)]
        let interval = progressInterval
        return Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                guard let total = item.fileSize, total > 0 else { continue }
                let bytes = await Task.detached(priority: .utility) {
                    folders.reduce(Int64(0)) { $0 + (LocalImportFiles.fingerprint(of: $1)?.size ?? 0) }
                }.value
                if case .downloading = self.tasks[item.workshopID] {
                    self.tasks[item.workshopID] = .downloading(progress: min(0.99, Double(bytes) / Double(total)))
                }
            }
        }
    }

    // MARK: - 运行 SteamCMD

    /// 同一时间只运行一个 SteamCMD（它会锁定自己的目录）。
    private func acquireSteamCMD() async {
        if !isRunningSteamCMD { isRunningSteamCMD = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func releaseSteamCMD() {
        if waiters.isEmpty { isRunningSteamCMD = false } else { waiters.removeFirst().resume() }
    }

    /// 运行一次 SteamCMD，把解析出的事件交给 `onEvent`；`onEvent` 返回 true 时结束进程。返回退出码。
    private func run(_ arguments: [String],
                     onLine: (@MainActor (String) -> Void)? = nil,
                     onEvent: @escaping @MainActor (SteamCMDEvent, SteamCMDProcess) -> Bool) async throws -> Int32 {
        let process = makeProcess(installation, arguments)
        let state = RunState()
        return try await withCheckedThrowingContinuation { continuation in
            process.onOutput = { text in
                state.tail = String((state.tail + text).suffix(4000))
                // 最后一行非空输出，用于说明 SteamCMD 为什么没能运行。
                if let line = SteamCMDOutputParser.clean(state.tail).split(separator: "\n")
                    .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                    let text = line.trimmingCharacters(in: .whitespaces)
                    // 「路径: 原因」只显示原因，不在界面上显示完整路径。
                    let reason = text.components(separatedBy: ": ").last ?? text
                    onLine?(String(reason.suffix(200)))
                }
                for event in state.parser.consume(text) where onEvent(event, process) {
                    process.terminate()
                    break
                }
            }
            process.onExit = { status in
                for event in state.parser.finish() { _ = onEvent(event, process) }
                guard !state.finished else { return }
                state.finished = true
                if state.tail.contains("Bad CPU type") {
                    continuation.resume(throwing: SteamCMDInstallError.rosettaRequired)
                } else if status == SteamHelperClient.helperLostStatus {
                    let reason = SteamCMDOutputParser.clean(state.tail).split(separator: "\n").last.map(String.init) ?? ""
                    continuation.resume(throwing: SteamCMDInstallError.helperUnavailable(reason))
                } else {
                    continuation.resume(returning: status)
                }
            }
            do {
                try process.start()
            } catch {
                state.finished = true
                continuation.resume(throwing: SteamCMDInstallError.launchFailed(error.localizedDescription))
            }
        }
    }

    @MainActor
    private final class RunState {
        var parser = SteamCMDOutputParser()
        var tail = ""
        var finished = false
    }

    /// 只在一次登录中使用的密码；取出后立即清空。
    private final class SecretBox {
        private var value: String?
        /// 已经交给 SteamCMD 的输入提示。
        private(set) var wasTaken = false
        init(_ value: String) { self.value = value }
        func take() -> String? { defer { value = nil; wasTaken = true }; return value }
        func clear() { value = nil }
    }
}

extension SteamAcquisitionService.SignInState {
    /// 正在等用户输入令牌代码或在手机上确认。
    var isWaitingForUser: Bool {
        switch self {
        case .needsGuardCode, .waitingForMobileConfirmation: return true
        default: return false
        }
    }
}

extension SteamLoginFailure {
    static func describe(_ failure: SteamLoginFailure) -> String {
        switch failure {
        case .invalidPassword: return NSLocalizedString("steam.login.error.password", comment: "")
        case .invalidGuardCode: return NSLocalizedString("steam.login.error.guard", comment: "")
        case .rateLimited: return NSLocalizedString("steam.login.error.rateLimit", comment: "")
        case .passwordRequired: return NSLocalizedString("steam.login.error.expired", comment: "")
        case .noConnection: return NSLocalizedString("steam.error.network", comment: "")
        case .other(let reason): return String(format: NSLocalizedString("steam.login.error.other", comment: ""), reason)
        }
    }
}
