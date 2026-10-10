import AppKit
import SwiftUI

/// 设置窗口的 Steam 页面（1.0 Module 9）：SteamCMD 安装与 Steam 账号登录。
/// 密码与 Steam 令牌代码只在输入框与 SteamCMD 之间传递，提交后立即清空，不保存。
@MainActor
struct SteamSettingsView: View {
    @ObservedObject var steam: SteamAcquisitionService
    /// 1.0 Module 14：在线商店（Steam Web API Key）。
    @ObservedObject var store: SteamStoreService
    /// 1.0 Module 28：Wallpaper Engine 引擎素材。
    var engineAssets: EngineAssetsStore? = nil
    /// 用户决定（2026-10-06）：年龄分级隐藏开关，默认关闭。
    var settings: SettingsStore? = nil

    @State private var usernameField = ""
    @State private var passwordField = ""
    @State private var guardCodeField = ""
    @State private var apiKeyField = ""
    @State private var apiKeyError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                steamCMDSection
                Divider()
                accountSection
                Divider()
                apiKeySection
                if let settings {
                    Divider()
                    SteamContentRatingSettingsSection(settings: settings)
                }
                if let engineAssets {
                    Divider()
                    EngineAssetsSettingsSection(assets: engineAssets, steam: steam)
                }
                Divider()
                WorkshopDependenciesSettingsSection(steam: steam)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(28)
        }
        .onAppear { if usernameField.isEmpty { usernameField = steam.username ?? "" } }
    }

    // MARK: - SteamCMD

    @ViewBuilder
    private var steamCMDSection: some View {
        Text("settings.steam.steamcmd")
            .font(.headline)
        HStack(spacing: 10) {
            switch steam.installState {
            case .installed:
                Label("settings.steam.steamcmd.installed", systemImage: "checkmark")
            case .notInstalled:
                Text("settings.steam.steamcmd.notInstalled")
            case .installing:
                ProgressView().controlSize(.small)
                Text("settings.steam.steamcmd.installing")
            case .failed(let reason):
                Text(reason).foregroundStyle(.red)
            }
            Spacer(minLength: 0)
            if steam.installState != .installing {
                Button(LocalizedStringKey(steam.installState == .installed ? "settings.steam.steamcmd.update"
                                                                             : "settings.steam.steamcmd.install")) {
                    Task { await steam.install() }
                }
            }
        }
        Text("settings.steam.steamcmd.detail")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 账号

    @ViewBuilder
    private var accountSection: some View {
        Text("settings.steam.account")
            .font(.headline)
        switch steam.signInState {
        case .signedIn:
            HStack {
                Text(String(format: NSLocalizedString("settings.steam.signedIn", comment: ""), steam.username ?? ""))
                Spacer(minLength: 0)
                Button("settings.steam.signOut") { steam.signOut() }
            }
        case .needsGuardCode(let kind):
            Text(LocalizedStringKey(kind == .email ? "settings.steam.guard.email" : "settings.steam.guard.twoFactor"))
            HStack {
                TextField("settings.steam.guard.code", text: $guardCodeField)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)
                    .onSubmit(submitGuardCode)
                Button("settings.steam.guard.submit", action: submitGuardCode)
                    .disabled(guardCodeField.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("settings.steam.cancel") { steam.cancelSignIn() }
            }
        case .waitingForMobileConfirmation:
            Text("settings.steam.guard.mobile")
            Button("settings.steam.cancel") { steam.cancelSignIn() }
        case .signingIn:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("settings.steam.signingIn")
            }
        case .signedOut, .failed:
            signInForm
        }
        Text("settings.steam.account.detail")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var signInForm: some View {
        if case .failed(let failure) = steam.signInState {
            Text(SteamLoginFailure.describe(failure))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Text("settings.steam.username")
                TextField("", text: $usernameField)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
            }
            GridRow {
                Text("settings.steam.password")
                SecureField("", text: $passwordField)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                    .onSubmit(signIn)
            }
        }
        Button("settings.steam.signIn", action: signIn)
            .disabled(usernameField.trimmingCharacters(in: .whitespaces).isEmpty || passwordField.isEmpty)
    }

    // MARK: - Steam Web API Key

    @ViewBuilder
    private var apiKeySection: some View {
        Text("settings.steam.apiKey")
            .font(.headline)
        if store.hasAPIKey {
            HStack {
                Label("settings.steam.apiKey.saved", systemImage: "checkmark")
                Spacer(minLength: 0)
                Button("settings.steam.apiKey.remove") { store.removeAPIKey() }
            }
        } else {
            HStack {
                SecureField("settings.steam.apiKey.placeholder", text: $apiKeyField)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 300)
                    .onSubmit(saveAPIKey)
                Button("settings.steam.apiKey.save", action: saveAPIKey)
                    .disabled(apiKeyField.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let apiKeyError {
                Text(apiKeyError).foregroundStyle(.red)
            }
        }
        HStack(alignment: .firstTextBaseline) {
            Text("settings.steam.apiKey.detail")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("steam.store.getKey") { NSWorkspace.shared.open(SteamStoreBrowserView.apiKeyPage) }
        }
    }

    private func saveAPIKey() {
        let key = apiKeyField
        do {
            try store.saveAPIKey(key)
            apiKeyField = ""
            apiKeyError = nil
        } catch {
            apiKeyError = error.localizedDescription
        }
    }

    private func signIn() {
        let username = usernameField
        let password = passwordField
        passwordField = ""
        guard !username.trimmingCharacters(in: .whitespaces).isEmpty, !password.isEmpty else { return }
        Task { await steam.signIn(username: username, password: password) }
    }

    private func submitGuardCode() {
        let code = guardCodeField
        guardCodeField = ""
        steam.submitGuardCode(code)
    }
}

/// 1.0 Module 28：设置 › Steam › Wallpaper Engine 引擎素材。用户可以链接自己的 Wallpaper Engine 文件夹，
/// 或用已登录的 Steam 账号下载（只保留 `assets/`）。素材只保存在这台 Mac 上，Kinetic 不上传、不分发。
struct EngineAssetsSettingsSection: View {
    @ObservedObject var assets: EngineAssetsStore
    @ObservedObject var steam: SteamAcquisitionService
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("engineAssets.title").font(.headline)
            statusRow
            downloadRow
            if case .failed(let reason) = assets.downloadPhase {
                Text(reason).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if let errorText {
                Text(errorText).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            Text("engineAssets.detail")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusRow: some View {
        HStack(spacing: 10) {
            switch assets.status {
            case .notConfigured:
                Text("engineAssets.status.none")
            case .ready(.linked, let name):
                Label(String(format: NSLocalizedString("engineAssets.status.linked", comment: ""), name ?? ""), systemImage: "checkmark")
                    .lineLimit(1)
            case .ready(.downloaded, _):
                Label("engineAssets.status.downloaded", systemImage: "checkmark")
            case .unavailable(_, let reason):
                Text(reason).foregroundStyle(.red).lineLimit(2)
            }
            Spacer(minLength: 0)
            Button("engineAssets.link", action: chooseFolder)
            if assets.hasLink {
                Button("engineAssets.unlink") { errorText = nil; assets.unlink() }
            }
        }
    }

    private var downloadRow: some View {
        HStack(spacing: 10) {
            switch assets.downloadPhase {
            case .downloading(let progress):
                if let progress {
                    ProgressView(value: progress).frame(width: 160)
                    Text(progress.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
                } else {
                    ProgressView().controlSize(.small)
                    Text("engineAssets.downloading")
                }
                Button("settings.steam.cancel") { assets.cancelDownload() }
            case .pruning:
                ProgressView().controlSize(.small)
                Text("engineAssets.pruning")
            case .idle, .failed:
                Button(LocalizedStringKey(assets.hasDownload ? "engineAssets.update" : "engineAssets.download")) {
                    errorText = nil
                    assets.startDownload(using: steam)
                }
                .disabled(!steam.isSignedIn)
                if assets.hasDownload {
                    Button("engineAssets.removeDownload") {
                        do { try assets.removeDownload(); errorText = nil } catch { errorText = error.localizedDescription }
                    }
                }
                if !steam.isSignedIn {
                    Text("engineAssets.signInFirst").foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = NSLocalizedString("engineAssets.link.prompt", comment: "")
        panel.message = NSLocalizedString("engineAssets.link.message", comment: "")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try assets.link(folder: url); errorText = nil } catch { errorText = error.localizedDescription }
    }
}

/// 1.0 Module 28.4：设置 › Steam › 创意工坊依赖项。列出资料库中 Scene 壁纸缺少的依赖项（素材包），
/// 已登录时一次补下。只读本地 `project.json` 统计，不联网。
struct WorkshopDependenciesSettingsSection: View {
    @ObservedObject var steam: SteamAcquisitionService
    @State private var missing = SteamAcquisitionService.MissingDependencies()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("dependencies.title").font(.headline)
            HStack(spacing: 10) {
                switch steam.dependencyDownload {
                case .downloading(let completed, let total):
                    ProgressView(value: Double(completed), total: Double(max(total, 1))).frame(width: 160)
                    Text(String(format: NSLocalizedString("dependencies.downloading", comment: ""), min(completed + 1, total), total))
                        .monospacedDigit()
                case .idle:
                    if missing.isEmpty {
                        Label("dependencies.none", systemImage: "checkmark")
                    } else {
                        Text(String(format: NSLocalizedString("dependencies.missing", comment: ""), missing.wallpaperCount, missing.ids.count))
                    }
                }
                Spacer(minLength: 0)
                if steam.dependencyDownload == .idle, !missing.isEmpty {
                    Button("dependencies.download") {
                        Task { await steam.downloadMissingLibraryDependencies() }
                    }
                    .disabled(!steam.isSignedIn || steam.installState != .installed)
                }
            }
            if steam.dependencyDownload == .idle, !missing.isEmpty, !steam.isSignedIn {
                Text("engineAssets.signInFirst").foregroundStyle(.secondary)
            }
            ForEach(failures) { failure in
                Text(String(format: NSLocalizedString("dependencies.failed", comment: ""), failure.id, failure.reason))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("dependencies.detail")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear(perform: refresh)
        .onChange(of: steam.dependencyDownload) { _ in refresh() }
    }

    private struct Failure: Identifiable { let id: String; let reason: String }

    /// 仍然缺少、且最近一次下载失败的依赖项。
    private var failures: [Failure] {
        missing.ids.compactMap { id in steam.dependencyFailures[id].map { Failure(id: id, reason: $0) } }
    }

    private func refresh() { missing = steam.missingLibraryDependencies() }
}

/// 设置 › Steam：在线商店的年龄分级显示。默认全部像普通壁纸一样显示；开启后对应分级不再出现在 Steam 页面，
/// 在筛选器中明确选择该分级时仍显示。
struct SteamContentRatingSettingsSection: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Text("settings.steam.rating")
            .font(.headline)
        Toggle("settings.steam.rating.hideQuestionable", isOn: Binding(
            get: { settings.state.steamHideQuestionable },
            set: { settings.set(\.steamHideQuestionable, to: $0) }))
        Toggle("settings.steam.rating.hideMature", isOn: Binding(
            get: { settings.state.steamHideMature },
            set: { settings.set(\.steamHideMature, to: $0) }))
        Text("settings.steam.rating.detail")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
