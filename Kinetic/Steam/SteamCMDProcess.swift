import Foundation

/// 运行一次 SteamCMD 的抽象。正式环境是 `XPCSteamCMDProcess`（由 Steam 小助手运行）；测试注入假的进程。
/// 回调都在主线程上调用。
@MainActor
protocol SteamCMDProcess: AnyObject {
    var onOutput: (@MainActor (String) -> Void)? { get set }
    var onExit: (@MainActor (Int32) -> Void)? { get set }
    func start() throws
    /// 向标准输入写一行（自动加换行）。用于密码与 Steam 令牌代码，不写入日志、不保存。
    func writeLine(_ line: String)
    func terminate()
}

/// 创建 SteamCMD 进程：`arguments` 是传给 `steamcmd.sh` 的参数。
typealias SteamCMDProcessFactory = @MainActor (_ installation: SteamCMDInstallation, _ arguments: [String]) -> SteamCMDProcess

/// 由 Steam 小助手（XPC 服务，不带沙盒）运行的 SteamCMD。
@MainActor
final class XPCSteamCMDProcess: SteamCMDProcess {
    var onOutput: (@MainActor (String) -> Void)?
    var onExit: (@MainActor (Int32) -> Void)?

    let sessionID = UUID().uuidString
    private let rootPath: String
    private let arguments: [String]
    private let client: SteamHelperClient
    private var exited = false

    init(installation: SteamCMDInstallation, arguments: [String], client: SteamHelperClient? = nil) {
        rootPath = installation.rootURL.path
        self.arguments = arguments
        self.client = client ?? .shared
    }

    func start() throws {
        client.start(self, rootPath: rootPath, arguments: arguments)
    }

    func writeLine(_ line: String) { client.writeLine(line, sessionID: sessionID) }
    func terminate() { client.terminate(sessionID) }

    func receive(_ text: String) { onOutput?(text) }

    func finish(_ status: Int32) {
        guard !exited else { return }
        exited = true
        onExit?(status)
    }
}

/// 与 Steam 小助手的连接。小助手的回报在 XPC 队列上到达，先放进缓冲，再按顺序交给主线程上的会话。
@MainActor
final class SteamHelperClient: NSObject, SteamHelperClientProtocol {
    static let shared = SteamHelperClient()

    /// 小助手异常退出或连接中断时会话的退出码。
    static let helperLostStatus: Int32 = -2

    private var connection: NSXPCConnection?
    private var sessions: [String: XPCSteamCMDProcess] = [:]
    private let buffers = SessionBuffers()

    private func proxy(onError: @escaping @MainActor (String) -> Void) -> SteamHelperProtocol? {
        let connection = connection ?? makeConnection()
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            let message = error.localizedDescription
            Task { @MainActor in onError(message) }
        }
        return proxy as? SteamHelperProtocol
    }

    private func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(serviceName: SteamHelperConstants.serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: SteamHelperProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: SteamHelperClientProtocol.self)
        connection.exportedObject = self
        connection.interruptionHandler = { [weak self] in Task { @MainActor in self?.helperLost() } }
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in
                self?.helperLost()
                self?.connection = nil
            }
        }
        connection.resume()
        self.connection = connection
        return connection
    }

    /// 小助手不在了：所有会话都以失败结束，下次使用时重新连接。
    private func helperLost() {
        let lost = sessions
        sessions.removeAll()
        for (id, session) in lost {
            deliverOutput(of: id, to: session)
            session.finish(Self.helperLostStatus)
        }
    }

    // MARK: - 安装

    func install(into root: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            let finish: @MainActor (String?) -> Void = { message in
                guard !resumed else { return }
                resumed = true
                if let message { continuation.resume(throwing: SteamCMDInstallError.downloadFailed(message)) }
                else { continuation.resume() }
            }
            guard let proxy = proxy(onError: { finish($0) }) else {
                finish(NSLocalizedString("steam.install.error.helperMissing", comment: ""))
                return
            }
            proxy.installSteamCMD(rootPath: root.path) { message in
                Task { @MainActor in finish(message) }
            }
        }
    }

    // MARK: - 会话

    func start(_ session: XPCSteamCMDProcess, rootPath: String, arguments: [String]) {
        sessions[session.sessionID] = session
        let id = session.sessionID
        let fail: @MainActor (String) -> Void = { [weak self] message in
            guard let self, let session = self.sessions.removeValue(forKey: id) else { return }
            session.receive(message + "\n")
            session.finish(Self.helperLostStatus)
        }
        guard let proxy = proxy(onError: fail) else {
            fail(NSLocalizedString("steam.install.error.helperMissing", comment: ""))
            return
        }
        proxy.startSession(id, rootPath: rootPath, arguments: arguments) { message in
            guard let message else { return }
            Task { @MainActor in fail(message) }
        }
    }

    func writeLine(_ line: String, sessionID: String) {
        proxy(onError: { _ in })?.writeLine(line, sessionID: sessionID)
    }

    func terminate(_ sessionID: String) {
        proxy(onError: { _ in })?.terminateSession(sessionID)
    }

    private func deliverOutput(of id: String, to session: XPCSteamCMDProcess) {
        let text = buffers.take(id)
        if !text.isEmpty { session.receive(text) }
    }

    // MARK: - SteamHelperClientProtocol（在 XPC 队列上调用）

    nonisolated func sessionOutput(_ sessionID: String, text: String) {
        buffers.append(text, to: sessionID)
        Task { @MainActor in
            guard let session = self.sessions[sessionID] else { return }
            self.deliverOutput(of: sessionID, to: session)
        }
    }

    nonisolated func sessionExited(_ sessionID: String, status: Int32) {
        Task { @MainActor in
            guard let session = self.sessions.removeValue(forKey: sessionID) else { return }
            // 先交出全部已收到的输出，再报告结束。
            self.deliverOutput(of: sessionID, to: session)
            session.finish(status)
        }
    }
}

/// XPC 队列与主线程之间、按会话分开的输出缓冲。每次取走全部，先后顺序不会乱。
private final class SessionBuffers: @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String: String] = [:]

    func append(_ text: String, to id: String) {
        lock.lock(); defer { lock.unlock() }
        texts[id, default: ""] += text
    }

    func take(_ id: String) -> String {
        lock.lock(); defer { lock.unlock() }
        return texts.removeValue(forKey: id) ?? ""
    }
}
