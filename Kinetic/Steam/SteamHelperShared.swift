import Foundation

/// Kinetic 1.0 Module 9：主 App 与 Steam 小助手（不带沙盒的 XPC 服务 `KineticSteamHelper`）共用的定义。
///
/// 为什么需要小助手：App 沙盒中下载的程序都带隔离属性，沙盒内既不能运行、也不能去掉这个属性（实测
/// `Operation not permitted`）。用户决定：Kinetic 本体保留沙盒，SteamCMD 的下载、解压与运行交给小助手。
/// 两边通过 `~/Library/Application Support/Kinetic Steam/` 交换文件（App 用临时例外权限读写这个目录）。
enum SteamHelperConstants {
    /// XPC 服务的标识（= 小助手的 bundle identifier）。
    static let serviceName = "com.kinetic.app.SteamHelper"
    /// Valve 官方的 macOS SteamCMD 安装包。
    static let officialDownloadURL = URL(string: "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_osx.tar.gz")!
    /// 共享目录在用户目录中的相对位置（App 的 entitlements 中有同一个路径）。
    static let sharedFolderRelativePath = "Library/Application Support/Kinetic Steam"

    /// 用户真实的主目录（沙盒中 `NSHomeDirectory()` 是容器目录，不能用）。
    static func realHomeDirectory() -> URL {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    /// `~/Library/Application Support/Kinetic Steam/`
    static func sharedRootURL() -> URL {
        realHomeDirectory().appendingPathComponent(sharedFolderRelativePath, isDirectory: true)
    }

    /// Kinetic 的 SteamCMD 目录。小助手只在这里运行 `steamcmd.sh`。
    static func steamCMDRootURL() -> URL {
        sharedRootURL().appendingPathComponent("SteamCMD", isDirectory: true)
    }
}

/// 小助手提供的能力。回复中的字符串为 nil 表示成功，否则是给用户看的失败原因。
@objc protocol SteamHelperProtocol {
    /// 下载 Valve 官方安装包并解压到 `rootPath`。
    func installSteamCMD(rootPath: String, withReply reply: @escaping (String?) -> Void)
    /// 在 `rootPath` 中启动一次 `steamcmd.sh arguments…`。输出与结束通过 `SteamHelperClientProtocol` 回报。
    func startSession(_ sessionID: String, rootPath: String, arguments: [String], withReply reply: @escaping (String?) -> Void)
    /// 向会话的标准输入写一行（密码、Steam 令牌代码）。小助手不记录、不保存。
    func writeLine(_ line: String, sessionID: String)
    func terminateSession(_ sessionID: String)
}

/// 主 App 接收小助手回报。
@objc protocol SteamHelperClientProtocol {
    func sessionOutput(_ sessionID: String, text: String)
    func sessionExited(_ sessionID: String, status: Int32)
}

/// SteamCMD 安装包的下载与解压（小助手使用；测试也用它模拟安装）。
enum SteamCMDArchive {
    static func download(from url: URL) async throws -> URL {
        let (temporary, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            try? FileManager.default.removeItem(at: temporary)
            throw ArchiveError(message: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("steamcmd-\(UUID().uuidString).tar.gz")
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    static func extract(archive: URL, into root: URL) throws {
        let fileManager = FileManager()
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", archive.path, "-C", root.path]
        tar.standardOutput = FileHandle.nullDevice
        tar.standardError = FileHandle.nullDevice
        do { try tar.run() } catch { throw ArchiveError(message: "tar: \(error.localizedDescription)") }
        tar.waitUntilExit()
        guard tar.terminationStatus == 0,
              fileManager.isReadableFile(atPath: root.appendingPathComponent("steamcmd.sh").path) else {
            throw ArchiveError(message: "tar \(tar.terminationStatus)")
        }
    }

    struct ArchiveError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}

/// 在伪终端中运行 SteamCMD（小助手使用；测试也用它）。
///
/// SteamCMD 的输入提示（`password:`、`Steam Guard code:`、`Two-factor code:`）没有换行。通过管道运行时，
/// 这些提示会一直留在 SteamCMD 的输出缓冲里，直到进程结束才出现，Kinetic 就等不到提示、无法回答。
/// 在终端里，读取输入前会先送出提示，与用户在“终端”中看到的一致。终端关闭了回显，写入的密码与令牌代码
/// 不会出现在输出里。
///
/// `steamcmd.sh` 是 bash 脚本，真正的 SteamCMD 是它的子进程。进程以新的会话（进程组）启动，结束时向整组发
/// 信号：只结束 bash 会留下仍在等待输入的 SteamCMD，旧版小助手因此一直读它的输出直到内存耗尽。
final class SteamCMDTerminalProcess: @unchecked Sendable {
    enum TerminalError: LocalizedError {
        case unavailable(Int32)
        case launchFailed(Int32)
        var errorDescription: String? {
            switch self {
            case .unavailable(let code): return "无法创建终端（\(code)）"
            case .launchFailed(let code): return "无法启动 SteamCMD（\(code)）"
            }
        }
    }

    private let executable: String
    private let arguments: [String]
    private let directory: String
    private let environment: [String: String]
    private let queue: DispatchQueue
    private var master: Int32 = -1
    private var slave: Int32 = -1
    private var pid: pid_t = 0
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private let drained = DispatchGroup()
    private var isDrained = false
    private var hasExited = false
    /// 每次读取的最大字节数。小助手只转发输出，不在内存中累积。
    static let readChunk = 16 * 1024

    /// 在 `queue` 上回报输出。
    var onOutput: ((Data) -> Void)?
    /// 输出读完（或进程结束 2 秒后）在 `queue` 上回报退出码（被信号结束时为信号编号，与 `Process` 相同）。
    var onExit: ((Int32) -> Void)?

    init(executable: URL, arguments: [String], directory: URL, environment: [String: String], queue: DispatchQueue) throws {
        self.executable = executable.path
        self.arguments = arguments
        self.directory = directory.path
        var environment = environment
        environment["TERM"] = "dumb"
        self.environment = environment
        self.queue = queue
        var size = winsize(ws_row: 50, ws_col: 400, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else { throw TerminalError.unavailable(errno) }
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        _ = fcntl(slave, F_SETFD, FD_CLOEXEC)
        // 关闭回显：两端都设置（macOS 上终端设置可经主端或从端写入），之后再读回确认。
        var settings = termios()
        if tcgetattr(slave, &settings) == 0 || tcgetattr(master, &settings) == 0 {
            settings.c_lflag &= ~tcflag_t(ECHO | ECHOE | ECHOK | ECHOKE | ECHONL | ECHOCTL)
            _ = tcsetattr(slave, TCSANOW, &settings)
            _ = tcsetattr(master, TCSANOW, &settings)
        }
    }

    /// 终端的回显是否已关闭（测试用）。
    var isEchoDisabled: Bool {
        var settings = termios()
        let fd = slave >= 0 ? slave : master
        guard fd >= 0, tcgetattr(fd, &settings) == 0 else { return false }
        return settings.c_lflag & tcflag_t(ECHO) == 0
    }

    deinit {
        if pid > 0, !hasExited { kill(-pid, SIGKILL) }
        if slave >= 0 { close(slave) }
        if readSource == nil, master >= 0 { close(master) }
    }

    var isRunning: Bool { pid > 0 && !hasExited }

    func start() throws {
        let master = master
        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        drained.enter()
        source.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: Self.readChunk)
            let count = read(master, &buffer, buffer.count)
            if count > 0 {
                self?.onOutput?(Data(buffer[0..<count]))
            } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                // 0 = 结束；-1（EIO）= 所有终端端口都已关闭。
                self?.readSource?.cancel()
            }
        }
        source.setCancelHandler { [weak self] in
            close(master)
            self?.isDrained = true
            self?.drained.leave()
        }
        readSource = source
        source.resume()

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for target: Int32 in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            posix_spawn_file_actions_adddup2(&actions, slave, target)
        }
        posix_spawn_file_actions_addchdir_np(&actions, directory)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var defaults = sigset_t()
        sigfillset(&defaults)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)
        // 新会话：SteamCMD 与它的子进程同属一组，结束时一起结束；其他打开的文件不带给子进程。
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT
                                                    | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        // 在子进程里再关一次回显（有的系统只接受终端所属会话内的设置），然后换成 SteamCMD 本身。
        let shell = "/bin/sh"
        let command = [shell, "-c", "/bin/stty -echo 2>/dev/null; exec \"$0\" \"$@\"", executable] + arguments
        let argv: [UnsafeMutablePointer<CChar>?] = command.map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var child: pid_t = 0
        let result = posix_spawn(&child, shell, &actions, &attributes, argv, envp)
        guard result == 0 else {
            source.cancel()
            throw TerminalError.launchFailed(result)
        }
        pid = child
        // 子进程已有自己的终端端口；父进程关掉它，子进程结束后读取才会得到 EIO / 结束。
        close(slave)
        slave = -1

        let exit = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: queue)
        exit.setEventHandler { [weak self] in self?.reap(blocking: true) }
        exitSource = exit
        exit.resume()
        // 进程可能在监视开始前就已结束。
        queue.async { [weak self] in self?.reap(blocking: false) }
    }

    private func reap(blocking: Bool) {
        guard pid > 0, !hasExited else { return }
        var status: Int32 = 0
        let result = waitpid(pid, &status, blocking ? 0 : WNOHANG)
        guard result == pid else { return }
        hasExited = true
        exitSource?.cancel()
        // 组里如果还有留下的进程（例如 bash 先退出），一并结束。
        kill(-pid, SIGKILL)
        let low = status & 0x7f
        let code = low == 0 ? (status >> 8) & 0xff : low
        // 后台进程可能还拿着终端：最多等 2 秒把剩下的输出读完。
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !self.isDrained else { return }
            self.readSource?.cancel()
        }
        drained.notify(queue: queue) { [weak self] in self?.onExit?(code) }
    }

    /// 写一行到 SteamCMD 的输入（在 `queue` 上调用）。
    func writeLine(_ line: String) {
        guard !isDrained, isRunning else { return }
        var bytes = Array((line + "\n").utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBufferPointer { write(master, $0.baseAddress! + offset, bytes.count - offset) }
            if written <= 0 { break }
            offset += written
        }
        for index in bytes.indices { bytes[index] = 0 }
    }

    /// 结束 SteamCMD 与它的子进程：先请求结束，3 秒后仍在运行则强制结束。
    func terminate() {
        guard isRunning else { return }
        let group = pid
        kill(-group, SIGTERM)
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, !self.hasExited else { return }
            kill(-group, SIGKILL)
        }
    }
}
