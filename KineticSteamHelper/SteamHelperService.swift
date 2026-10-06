import Foundation

final class SteamHelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let service = SteamHelperService(connection: connection)
        connection.exportedInterface = NSXPCInterface(with: SteamHelperProtocol.self)
        connection.remoteObjectInterface = NSXPCInterface(with: SteamHelperClientProtocol.self)
        connection.exportedObject = service
        connection.invalidationHandler = { service.terminateAll() }
        connection.resume()
        return true
    }
}

/// 运行 SteamCMD。只接受 Kinetic 的 SteamCMD 目录（`~/Library/Application Support/Kinetic Steam/SteamCMD`），
/// 不运行其他位置的任何程序；写入标准输入的内容（密码、令牌代码）不记录、不保存。
final class SteamHelperService: NSObject, SteamHelperProtocol {
    private weak var connection: NSXPCConnection?
    private let queue = DispatchQueue(label: "com.kinetic.app.SteamHelper.sessions")
    private var sessions: [String: Session] = [:]

    /// SteamCMD 在伪终端中运行（`SteamCMDTerminalProcess`），输入提示能及时送达。
    private typealias Session = SteamCMDTerminalProcess

    init(connection: NSXPCConnection) {
        self.connection = connection
    }

    private var client: SteamHelperClientProtocol? {
        connection?.remoteObjectProxy as? SteamHelperClientProtocol
    }

    /// 只允许 Kinetic 自己的 SteamCMD 目录。
    private func validatedRoot(_ path: String) -> URL? {
        let expected = SteamHelperConstants.steamCMDRootURL().standardizedFileURL.resolvingSymlinksInPath()
        let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        return root.path == expected.path ? root : nil
    }

    func installSteamCMD(rootPath: String, withReply reply: @escaping (String?) -> Void) {
        guard let root = validatedRoot(rootPath) else { reply("无效的 SteamCMD 位置"); return }
        Task {
            do {
                let archive = try await SteamCMDArchive.download(from: SteamHelperConstants.officialDownloadURL)
                defer { try? FileManager.default.removeItem(at: archive) }
                try SteamCMDArchive.extract(archive: archive, into: root)
                reply(nil)
            } catch {
                reply(error.localizedDescription)
            }
        }
    }

    func startSession(_ sessionID: String, rootPath: String, arguments: [String],
                      withReply reply: @escaping (String?) -> Void) {
        guard let root = validatedRoot(rootPath) else { reply("无效的 SteamCMD 位置"); return }
        let script = root.appendingPathComponent("steamcmd.sh")
        guard FileManager.default.isReadableFile(atPath: script.path) else { reply("SteamCMD 尚未安装"); return }

        let home = root.appendingPathComponent("home", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        var environment = ProcessInfo.processInfo.environment
        // 让 SteamCMD 的用户目录也留在 Kinetic 的目录里，不写入用户电脑上 Steam 客户端的目录。
        environment["HOME"] = home.path
        let session: Session
        do {
            session = try Session(executable: URL(fileURLWithPath: "/bin/bash"), arguments: [script.path] + arguments,
                                  directory: root, environment: environment, queue: queue)
        } catch {
            reply(error.localizedDescription)
            return
        }
        session.onOutput = { [weak self] data in
            self?.client?.sessionOutput(sessionID, text: String(decoding: data, as: UTF8.self))
        }
        session.onExit = { [weak self] status in
            guard let self else { return }
            self.client?.sessionExited(sessionID, status: status)
            self.sessions.removeValue(forKey: sessionID)
        }
        queue.sync { sessions[sessionID] = session }
        do {
            try session.start()
            reply(nil)
        } catch {
            _ = queue.sync { sessions.removeValue(forKey: sessionID) }
            reply(error.localizedDescription)
        }
    }

    func writeLine(_ line: String, sessionID: String) {
        queue.async {
            self.sessions[sessionID]?.writeLine(line)
        }
    }

    func terminateSession(_ sessionID: String) {
        queue.async {
            self.sessions[sessionID]?.terminate()
        }
    }

    /// App 断开时结束所有 SteamCMD。
    func terminateAll() {
        queue.async {
            for session in self.sessions.values { session.terminate() }
        }
    }
}
