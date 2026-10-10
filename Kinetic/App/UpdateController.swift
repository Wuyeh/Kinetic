import Combine
import Foundation
import Sparkle
import SwiftUI

/// Module 54：这份构建从哪里取更新。
///
/// 更新地址来自构建设置 `KINETIC_UPDATE_FEED_URL`（写进 Info.plist 的 `KineticUpdateFeedURL`），没有地址的构建不检查更新；
/// `SUPublicEDKey` 是校验更新包签名的 EdDSA 公钥。两者都有才启用 Sparkle。
struct UpdateConfiguration: Equatable, Sendable {
    static let feedURLKey = "KineticUpdateFeedURL"
    static let publicKeyKey = "SUPublicEDKey"

    let feedURL: URL?
    let publicKey: String?

    var isConfigured: Bool { feedURL != nil && publicKey != nil }

    init(feedURL: URL?, publicKey: String?) {
        self.feedURL = feedURL
        self.publicKey = publicKey
    }

    init(info: [String: Any]) {
        feedURL = Self.feedURL(info[Self.feedURLKey] as? String)
        publicKey = Self.publicKey(info[Self.publicKeyKey] as? String)
    }

    static var bundled: UpdateConfiguration { UpdateConfiguration(info: Bundle.main.infoDictionary ?? [:]) }

    /// https（发布）或 http / file（本机验收用的更新源）；其他写法、未展开的构建变量都当作没有配置。
    static func feedURL(_ raw: String?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty, !raw.contains("$("),
              let url = URL(string: raw), let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "https", "http": return url.host?.isEmpty == false ? url : nil
        case "file": return url.path.isEmpty ? nil : url
        default: return nil
        }
    }

    /// Ed25519 公钥：base64 解出来正好 32 字节。
    static func publicKey(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let data = Data(base64Encoded: raw), data.count == 32 else { return nil }
        return raw
    }
}

/// Module 54：Sparkle 2 的检查 / 下载 / 安装 / 重启。
///
/// 安装走 Sparkle 自带的安装服务（沙盒下由 `SUEnableInstallerLauncherService` 与两个 mach-lookup 例外放行），
/// 更新包必须带与 `SUPublicEDKey` 匹配的 EdDSA 签名，并与当前 App 同一签名身份。自动检查每天一次，只提示，
/// 下载安装都由用户在 Sparkle 的窗口里确认。
@MainActor
final class UpdateController: NSObject, ObservableObject {
    let configuration: UpdateConfiguration
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var lastCheckDate: Date?
    /// 最近一次检查失败的原因（找不到新版本不算失败）。
    @Published private(set) var lastError: String?

    private let settings: SettingsStore
    private var controller: SPUStandardUpdaterController?
    private var subscriptions = Set<AnyCancellable>()

    init(configuration: UpdateConfiguration = .bundled, settings: SettingsStore) {
        self.configuration = configuration
        self.settings = settings
        super.init()
    }

    var isConfigured: Bool { configuration.isConfigured }
    var isRunning: Bool { controller != nil }

    /// 没有更新地址或公钥时不创建 Sparkle，设置里说明原因。
    func start() {
        guard controller == nil, configuration.isConfigured else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        let updater = controller.updater
        updater.automaticallyChecksForUpdates = settings.state.automaticUpdateChecksEnabled
        updater.automaticallyDownloadsUpdates = false
        do {
            try updater.start()
        } catch {
            lastError = error.localizedDescription
            self.controller = nil
            return
        }
        updater.publisher(for: \.canCheckForUpdates).receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }.store(in: &subscriptions)
        updater.publisher(for: \.lastUpdateCheckDate).receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.lastCheckDate = $0 }.store(in: &subscriptions)
        settings.$state.map(\.automaticUpdateChecksEnabled).removeDuplicates().dropFirst()
            .sink { [weak updater] in updater?.automaticallyChecksForUpdates = $0 }.store(in: &subscriptions)
    }

    func checkForUpdates() {
        guard let controller, canCheckForUpdates else { return }
        lastError = nil
        controller.checkForUpdates(nil)
    }
}

extension UpdateController: SPUUpdaterDelegate {
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        MainActor.assumeIsolated { configuration.feedURL?.absoluteString }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        let message = Self.failureMessage(error)
        MainActor.assumeIsolated { lastError = message }
    }

    /// 「已是最新版本」「用户取消」不算失败。
    nonisolated static func failureMessage(_ error: Error?) -> String? {
        guard let error = error as NSError? else { return nil }
        // SUNoUpdateError = 1001, SUInstallationCanceledError = 4007（SUErrors.h）。
        if error.domain == SUSparkleErrorDomain, [1001, 4007].contains(error.code) {
            return nil
        }
        return error.localizedDescription
    }
}

/// 设置 › 关于 里的更新部分。
struct UpdateSettingsSection: View {
    @ObservedObject var updates: UpdateController
    @ObservedObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("更新").font(.headline)
            if updates.isRunning {
                Toggle("自动检查更新", isOn: Binding(get: { settings.state.automaticUpdateChecksEnabled },
                                                set: { settings.set(\.automaticUpdateChecksEnabled, to: $0) }))
                Text("每天检查一次，有新版本时提示；下载和安装都要你确认，装好后 Kinetic 自动重新打开。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button("检查更新…") { updates.checkForUpdates() }
                        .kineticGlassButton()
                        .disabled(!updates.canCheckForUpdates)
                    Text(Self.lastCheckText(updates.lastCheckDate)).foregroundStyle(.secondary)
                }
                if let error = updates.lastError {
                    Text("上次检查没有完成：\(error)").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(updates.lastError.map { "检查更新不可用：\($0)" }
                     ?? "这个版本没有配置更新地址，不检查更新。发布的版本会带上更新地址和签名公钥。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static func lastCheckText(_ date: Date?) -> String {
        guard let date else { return "还没有检查过" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh-Hans")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "上次检查：\(formatter.string(from: date))"
    }
}
