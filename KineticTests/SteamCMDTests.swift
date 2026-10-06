import Foundation
import XCTest
@testable import Kinetic

/// 假的 SteamCMD 进程：记录参数与写入标准输入的内容，由测试脚本输出文字、结束进程。
@MainActor
final class FakeSteamCMDProcess: SteamCMDProcess {
    var onOutput: (@MainActor (String) -> Void)?
    var onExit: (@MainActor (Int32) -> Void)?
    let arguments: [String]
    private(set) var written: [String] = []
    private(set) var started = false
    private(set) var terminated = false
    private var exited = false
    /// 进程启动后执行。
    var script: (@MainActor (FakeSteamCMDProcess) -> Void)?
    /// 每次写入标准输入后执行。
    var onWrite: (@MainActor (FakeSteamCMDProcess, String) -> Void)?

    init(arguments: [String]) { self.arguments = arguments }

    func start() throws {
        started = true
        let script = script
        DispatchQueue.main.async { script?(self) }
    }

    func writeLine(_ line: String) {
        written.append(line)
        onWrite?(self, line)
    }

    func terminate() {
        guard !terminated else { return }
        terminated = true
        DispatchQueue.main.async { self.finish(143) }
    }

    func emit(_ text: String) { onOutput?(text) }

    func finish(_ status: Int32) {
        guard !exited else { return }
        exited = true
        onExit?(status)
    }
}

@MainActor
final class FakeSteamCMD {
    var processes: [FakeSteamCMDProcess] = []
    /// 按启动顺序为每个进程配置脚本。
    var configure: (FakeSteamCMDProcess) -> Void = { $0.script = { $0.finish(0) } }

    var factory: SteamCMDProcessFactory {
        { [unowned self] _, arguments in
            let process = FakeSteamCMDProcess(arguments: arguments)
            self.processes.append(process)
            self.configure(process)
            return process
        }
    }
}

@MainActor
func waitForSteam(timeout: TimeInterval = 10, _ predicate: () -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while !predicate() {
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            XCTFail("Timed out")
            throw CancellationError()
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}

/// 1.0 Module 9 — Steam Acquisition Core：SteamCMD 输出解析、登录与 Steam 令牌、安装、退出登录。
final class SteamCMDTests: XCTestCase {
    private var temporaryRoots: [URL] = []
    private var suites: [String] = []

    override func tearDown() {
        for root in temporaryRoots { try? FileManager.default.removeItem(at: root) }
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        super.tearDown()
    }

    private func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KineticSteam-\(UUID().uuidString)",
                                                                                  isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        temporaryRoots.append(root)
        return root
    }

    private func makeDefaults() -> UserDefaults {
        let name = "KineticSteamTests-\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    @MainActor
    private func makeService(installed: Bool = true, fake: FakeSteamCMD,
                             defaults: UserDefaults? = nil,
                             installer: @escaping SteamCMDInstaller = { _ in throw URLError(.notConnectedToInternet) })
    -> (SteamAcquisitionService, WallpaperLibrary) {
        let root = makeRoot()
        let installation = SteamCMDInstallation(rootURL: root.appendingPathComponent("SteamCMD", isDirectory: true))
        if installed {
            try? FileManager.default.createDirectory(at: installation.rootURL, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: installation.scriptURL.path, contents: Data("#!/bin/bash\n".utf8))
        }
        let library = WallpaperLibrary(storage: LibraryStorageLocation(rootURL: root.appendingPathComponent("Library")))
        let service = SteamAcquisitionService(installation: installation, library: library,
                                              defaults: defaults ?? makeDefaults(),
                                              makeProcess: fake.factory, installer: installer)
        service.progressInterval = 0.02
        return (service, library)
    }

    // MARK: - 输出解析

    func testParserRecognisesSteamCMDOutputInArbitraryChunks() {
        var parser = SteamCMDOutputParser()
        var events: [SteamCMDEvent] = []
        let output = "Redirecting stderr to '/x/stderr.txt'\r\n\u{1B}[0mLogging in user 'wu' [U:1:1] to Steam Public...\npass"
            + "word: "
        for chunk in output.map(String.init) { events += parser.consume(chunk) }
        XCTAssertEqual(events, [.passwordPrompt], "Prompts without a newline are recognised once")

        events = parser.consume("\nThis computer has not been authenticated for your account using Steam Guard.\n"
                                + "Steam Guard code:")
        XCTAssertEqual(events, [.guardCodePrompt(.email)])
        XCTAssertEqual(parser.consume("Two-factor code:"), [.guardCodePrompt(.twoFactor)])
        XCTAssertEqual(parser.consume("Please confirm the login in the Steam Mobile app on your phone.\n"),
                       [.mobileConfirmationRequested])
        XCTAssertEqual(parser.consume("OK\nWaiting for user info...OK\n"), [.loginSucceeded])

        XCTAssertEqual(parser.consume("Logging in user 'wu' to Steam Public...FAILED (Invalid Password)\n"),
                       [.loginFailed(.invalidPassword)])
        XCTAssertEqual(parser.consume("FAILED (Rate Limit Exceeded)\n"), [.loginFailed(.rateLimited)])
        XCTAssertEqual(parser.consume("FAILED (Invalid Login Auth Code)\n"), [.loginFailed(.invalidGuardCode)])
        XCTAssertEqual(parser.consume("FAILED (Two-factor code mismatch)\n"), [.loginFailed(.invalidGuardCode)])
        XCTAssertEqual(parser.consume("Cached credentials not found.\n"), [.loginFailed(.passwordRequired)])
        XCTAssertEqual(parser.consume("Logging in user 'wu' to Steam Public...FAILED (No Connection)\n"),
                       [.loginFailed(.noConnection)])

        XCTAssertEqual(parser.consume("Downloading item 123 ...\nSuccess. Downloaded item 123 to \"/tmp/a b/123\" (4096 bytes)\n"),
                       [.downloadSucceeded(workshopID: "123", path: "/tmp/a b/123", bytes: 4096)])
        XCTAssertEqual(parser.consume("ERROR! Download item 456 failed (Access Denied).\n"),
                       [.downloadFailed(workshopID: "456", reason: "Access Denied")])
        // Module 28：app_update 的进度现在是事件（引擎素材下载），提示符等其余输出仍被忽略。
        XCTAssertEqual(parser.consume("Update state (0x61) downloading, progress: 12.34\nSteam>"), [.appUpdateProgress(12.34 / 100)])
        XCTAssertEqual(parser.finish(), [])
    }

    // MARK: - 登录

    @MainActor
    func testSignInAnswersPromptsAndNeverStoresThePassword() async throws {
        let fake = FakeSteamCMD()
        fake.configure = { process in
            process.script = { $0.emit("Logging in user 'wu' to Steam Public...\npassword: ") }
            process.onWrite = { process, _ in
                if process.written.count == 1 {
                    process.emit("\nPlease check your email for the message from Steam, and enter the Steam Guard\n"
                                 + " code from that message.\nSteam Guard code:")
                } else {
                    process.emit("OK\nWaiting for user info...OK\n")
                    process.finish(0)
                }
            }
        }
        let defaults = makeDefaults()
        let (service, _) = makeService(fake: fake, defaults: defaults)
        XCTAssertEqual(service.signInState, .signedOut)

        let signIn = Task { await service.signIn(username: " wu ", password: "hunter2") }
        try await waitForSteam { service.signInState == .needsGuardCode(.email) }
        service.submitGuardCode(" ABCDE ")
        await signIn.value

        XCTAssertEqual(service.signInState, .signedIn)
        XCTAssertEqual(service.username, "wu")
        XCTAssertEqual(defaults.string(forKey: SteamAcquisitionService.usernameKey), "wu")
        let process = try XCTUnwrap(fake.processes.last)
        XCTAssertEqual(process.written, ["hunter2", "ABCDE"], "Password and code go to SteamCMD's input")
        XCTAssertEqual(process.arguments, ["+@ShutdownOnFailedCommand", "1", "+login", "wu", "+quit"])
        XCTAssertFalse(process.arguments.contains("hunter2"), "The password is never a command-line argument")
        let stored = defaults.dictionaryRepresentation().values.map { "\($0)" }.joined()
        XCTAssertFalse(stored.contains("hunter2"), "The password is never saved")
        XCTAssertFalse(stored.contains("ABCDE"), "The Steam Guard code is never saved")

        // 重新创建服务：记住的是用户名，不是密码。
        let reopened = SteamAcquisitionService(installation: service.installation,
                                               library: WallpaperLibrary(storage: LibraryStorageLocation(rootURL: makeRoot())),
                                               defaults: defaults, makeProcess: fake.factory)
        XCTAssertEqual(reopened.signInState, .signedIn)
        XCTAssertEqual(reopened.username, "wu")
    }

    /// 真实 SteamCMD（没有缓存的登录凭据时）先输出 “Cached credentials not found.”，再提示输入密码；
    /// 之前 Kinetic 把这一行当成“登录已失效”并结束了登录。
    @MainActor
    func testFirstSignInContinuesPastMissingCachedCredentials() async throws {
        let fake = FakeSteamCMD()
        fake.configure = { process in
            process.script = {
                $0.emit("Loading Steam API...OK\nLogging in using username/password.\n")
                $0.emit("Logging in user 'wu' [U:1:0] to Steam Public...\nCached credentials not found.\npassword: ")
            }
            process.onWrite = { process, _ in
                process.emit("\nPlease confirm the login in the Steam Mobile app on your phone.\n")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    process.emit("OK\nWaiting for client config...OK\nWaiting for user info...OK\n")
                    process.finish(0)
                }
            }
        }
        let defaults = makeDefaults()
        let (service, _) = makeService(fake: fake, defaults: defaults)
        await service.signIn(username: "wu", password: "hunter2")
        XCTAssertEqual(service.signInState, .signedIn)
        XCTAssertEqual(try XCTUnwrap(fake.processes.last).written, ["hunter2"])

        // 密码已经交出后再报告需要密码，才是失败。
        let failing = FakeSteamCMD()
        failing.configure = { process in
            process.script = { $0.emit("Cached credentials not found.\npassword: ") }
            process.onWrite = { process, _ in process.emit("\nFAILED (Password required)\n"); process.finish(5) }
        }
        let (other, _) = makeService(fake: failing, defaults: makeDefaults())
        await other.signIn(username: "wu", password: "wrong")
        XCTAssertEqual(other.signInState, .failed(.passwordRequired))
    }

    /// SteamCMD 的输入提示没有换行：小助手在伪终端中运行它，提示立即送达、回显关闭。
    func testTerminalDeliversPromptsWithoutNewlineAndDoesNotEchoInput() throws {
        let queue = DispatchQueue(label: "terminal-test")
        let terminal: SteamCMDTerminalProcess
        do {
            // awk 用 stdio 缓冲输出，和 SteamCMD 一样：通过管道时这个没有换行的提示要等进程结束才出现。
            terminal = try SteamCMDTerminalProcess(executable: URL(fileURLWithPath: "/usr/bin/awk"),
                arguments: ["BEGIN { printf \"password: \" } { print \"got:\" $0; exit }"],
                directory: FileManager.default.temporaryDirectory, environment: [:], queue: queue)
        } catch {
            throw XCTSkip("Pseudo-terminals are not available to this test host: \(error)")
        }
        XCTAssertTrue(terminal.isEchoDisabled, "echo is switched off before SteamCMD starts")
        let output = NSMutableString()
        let prompted = expectation(description: "prompt arrives before any input")
        let exited = expectation(description: "exit")
        var promptSeen = false
        terminal.onOutput = { [unowned terminal] data in
            output.append(String(decoding: data, as: UTF8.self))
            if !promptSeen, output.contains("password:") {
                promptSeen = true
                prompted.fulfill()
                terminal.writeLine("hunter2")
            }
        }
        var status: Int32 = -1
        terminal.onExit = { status = $0; exited.fulfill() }
        do { try terminal.start() } catch { throw XCTSkip("Cannot launch awk here: \(error)") }
        wait(for: [prompted, exited], timeout: 10, enforceOrder: true)
        let text = output as String
        XCTAssertEqual(status, 0)
        XCTAssertTrue(text.contains("got:hunter2"), text)
        XCTAssertEqual(text.components(separatedBy: "hunter2").count - 1, 1, "The input is not echoed: \(text)")
    }

    @MainActor
    func testSignInFailuresAreReportedAndNothingIsRemembered() async throws {
        let fake = FakeSteamCMD()
        fake.configure = { process in
            process.script = { $0.emit("Logging in user 'wu' to Steam Public...\npassword: ") }
            process.onWrite = { process, _ in process.emit("FAILED (Invalid Password)\n") }
        }
        let defaults = makeDefaults()
        let (service, _) = makeService(fake: fake, defaults: defaults)
        await service.signIn(username: "wu", password: "wrong")
        XCTAssertEqual(service.signInState, .failed(.invalidPassword))
        XCTAssertNil(service.username)
        XCTAssertNil(defaults.string(forKey: SteamAcquisitionService.usernameKey))
        XCTAssertTrue(try XCTUnwrap(fake.processes.last).terminated)
        XCTAssertEqual(SteamLoginFailure.describe(.invalidPassword), "用户名或密码不正确。")

        // 手机确认可以取消。
        fake.configure = { process in
            process.script = { $0.emit("password: ") }
            process.onWrite = { process, _ in process.emit("Please confirm the login in the Steam Mobile app on your phone.\n") }
        }
        let signIn = Task { await service.signIn(username: "wu", password: "pw") }
        try await waitForSteam { service.signInState == .waitingForMobileConfirmation }
        service.cancelSignIn()
        await signIn.value
        XCTAssertEqual(service.signInState, .signedOut)
        XCTAssertNil(defaults.string(forKey: SteamAcquisitionService.usernameKey))
    }

    @MainActor
    func testSignOutForgetsTheAccountAndCachedCredentials() throws {
        let fake = FakeSteamCMD()
        let defaults = makeDefaults()
        defaults.set("wu", forKey: SteamAcquisitionService.usernameKey)
        let (service, _) = makeService(fake: fake, defaults: defaults)
        XCTAssertTrue(service.isSignedIn)
        let config = service.installation.rootURL.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: config.appendingPathComponent("config.vdf").path, contents: Data("x".utf8))
        FileManager.default.createFile(atPath: service.installation.rootURL.appendingPathComponent("ssfn123").path,
                                       contents: Data("x".utf8))
        let other = config.appendingPathComponent("other.vdf")
        FileManager.default.createFile(atPath: other.path, contents: Data("x".utf8))

        service.signOut()
        XCTAssertEqual(service.signInState, .signedOut)
        XCTAssertNil(service.username)
        XCTAssertNil(defaults.string(forKey: SteamAcquisitionService.usernameKey))
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.appendingPathComponent("config.vdf").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: service.installation.rootURL.appendingPathComponent("ssfn123").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path), "Only cached credentials are removed")
        XCTAssertTrue(service.installation.isInstalled, "SteamCMD itself stays installed")
    }

    // MARK: - 安装

    @MainActor
    func testInstallExtractsTheOfficialArchiveAndLetsSteamCMDUpdateItself() async throws {
        // 用一个假的安装包模拟 Valve 的 steamcmd_osx.tar.gz。
        let source = makeRoot()
        FileManager.default.createFile(atPath: source.appendingPathComponent("steamcmd.sh").path,
                                       contents: Data("#!/bin/bash\n".utf8))
        let archive = makeRoot().appendingPathComponent("steamcmd_osx.tar.gz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", archive.path, "-C", source.path, "steamcmd.sh"]
        try tar.run()
        tar.waitUntilExit()
        XCTAssertEqual(tar.terminationStatus, 0)

        var requested: [URL] = []
        let fake = FakeSteamCMD()
        fake.configure = { process in process.script = { $0.emit("Checking for available updates...\n"); $0.finish(7) } }
        // 正式环境由 Steam 小助手下载官方安装包并用同一个 SteamCMDArchive 解压；这里用本地安装包代替下载。
        let (service, _) = makeService(installed: false, fake: fake, installer: { installation in
            requested.append(SteamHelperConstants.officialDownloadURL)
            try SteamCMDArchive.extract(archive: archive, into: installation.rootURL)
        })
        XCTAssertEqual(service.installState, .notInstalled)
        let installed = await service.install()
        XCTAssertTrue(installed)
        XCTAssertEqual(service.installState, .installed)
        XCTAssertEqual(requested, [SteamHelperConstants.officialDownloadURL])
        XCTAssertEqual(SteamHelperConstants.officialDownloadURL.host, "steamcdn-a.akamaihd.net")
        XCTAssertEqual(SteamHelperConstants.serviceName, "com.kinetic.app.SteamHelper")
        XCTAssertTrue(SteamHelperConstants.steamCMDRootURL().path.hasSuffix("/Library/Application Support/Kinetic Steam/SteamCMD"))
        XCTAssertFalse(SteamHelperConstants.steamCMDRootURL().path.contains("/Library/Containers/"),
                       "The helper and the sandboxed app share a folder outside the container")
        XCTAssertTrue(service.installation.isInstalled)
        XCTAssertEqual(fake.processes.map(\.arguments), [["+quit"]], "SteamCMD updates itself once")

        // Apple 芯片上没有 Rosetta 2 时给出明确的提示。
        fake.configure = { process in
            process.script = { $0.emit("steamcmd.sh: line 37: steamcmd: Bad CPU type in executable\n"); $0.finish(126) }
        }
        let retried = await service.install()
        XCTAssertFalse(retried)
        XCTAssertEqual(service.installState, .failed(SteamCMDInstallError.rosettaRequired.localizedDescription))

        // 下载失败也不会留下半安装的状态。
        let (offline, _) = makeService(installed: false, fake: FakeSteamCMD())
        let offlineInstalled = await offline.install()
        XCTAssertFalse(offlineInstalled)
        XCTAssertFalse(offline.installation.isInstalled)
        if case .failed = offline.installState {} else { XCTFail("Expected a failure state") }
    }
}
