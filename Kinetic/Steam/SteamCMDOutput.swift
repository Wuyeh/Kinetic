import Foundation

/// Kinetic 1.0 Module 9 — Steam Acquisition Core。
/// Wallpaper Engine 在 Steam 上的应用编号；创意工坊内容都属于它。
enum SteamWorkshop {
    static let wallpaperEngineAppID = "431960"
}

/// Steam 令牌（Steam Guard）要求的代码类型。
enum SteamGuardKind: String, Equatable, Sendable {
    /// 邮件中的 Steam 令牌代码。
    case email
    /// Steam 手机令牌（两步验证）代码。
    case twoFactor
}

/// 登录失败的原因。
enum SteamLoginFailure: Equatable, Sendable {
    case invalidPassword
    case invalidGuardCode
    case rateLimited
    /// SteamCMD 没有缓存的登录凭据，需要重新输入密码。
    case passwordRequired
    case noConnection
    case other(String)
}

/// SteamCMD 输出中 Kinetic 关心的事件。只识别已知的文案，其余输出忽略。
enum SteamCMDEvent: Equatable, Sendable {
    case passwordPrompt
    case guardCodePrompt(SteamGuardKind)
    /// 需要在 Steam 手机应用中确认这次登录。
    case mobileConfirmationRequested
    case loginSucceeded
    case loginFailed(SteamLoginFailure)
    case downloadSucceeded(workshopID: String, path: String, bytes: Int64?)
    case downloadFailed(workshopID: String, reason: String)
    /// `app_update` 的进度（Module 28：下载 Wallpaper Engine 引擎素材）。不知道总大小时为 nil。
    case appUpdateProgress(Double?)
    case appInstalled(appID: String)
    case appInstallFailed(appID: String, reason: String)
}

/// 把 SteamCMD 的输出流（可能被任意切分）解析为事件。
///
/// SteamCMD 的输入提示（例如 `password:`、`Steam Guard code:`）后面没有换行，所以除了完整的行，
/// 还要检查尚未结束的最后一段；识别出提示后丢弃这一段，避免后续输出到来时重复报告。
struct SteamCMDOutputParser {
    private var fragment = ""

    mutating func consume(_ chunk: String) -> [SteamCMDEvent] {
        var events: [SteamCMDEvent] = []
        // 在累积的文字上清理：控制序列与换行可能被切在两次输出之间。
        fragment = Self.clean(fragment + chunk)
        while let newline = fragment.firstIndex(of: "\n") {
            let line = String(fragment[..<newline])
            fragment = String(fragment[fragment.index(after: newline)...])
            events += Self.events(inLine: line)
        }
        if let prompt = Self.prompt(in: fragment) {
            events.append(prompt)
            fragment = ""
        }
        return events
    }

    /// 进程结束时处理最后一段没有换行的输出。
    mutating func finish() -> [SteamCMDEvent] {
        defer { fragment = "" }
        return fragment.isEmpty ? [] : Self.events(inLine: fragment)
    }

    // MARK: - 识别

    /// 去掉终端控制序列与回车。
    static func clean(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if result.contains("\u{1B}") {
            result = result.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
        }
        return result
    }

    static func prompt(in text: String) -> SteamCMDEvent? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed.hasSuffix("password:") { return .passwordPrompt }
        if trimmed.hasSuffix("steam guard code:") { return .guardCodePrompt(.email) }
        if trimmed.hasSuffix("two-factor code:") || trimmed.hasSuffix("two factor code:") {
            return .guardCodePrompt(.twoFactor)
        }
        return nil
    }

    static func events(inLine rawLine: String) -> [SteamCMDEvent] {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return [] }
        if let prompt = prompt(in: line) { return [prompt] }
        let lower = line.lowercased()

        if lower.hasPrefix("success. downloaded item") {
            return downloadSuccess(line).map { [$0] } ?? []
        }
        if lower.hasPrefix("error! download item") {
            return downloadFailure(line).map { [$0] } ?? []
        }
        if lower.hasPrefix("success! app '"), lower.contains("fully installed"), let id = singleQuoted(line) {
            return [.appInstalled(appID: id)]
        }
        if lower.hasPrefix("error! failed to install app '") || (lower.hasPrefix("error! app '") && lower.contains("after update job")),
           let id = singleQuoted(line) {
            let reason = parenthesised(after: ["failed to install app"], in: line) ?? line
            return [.appInstallFailed(appID: id, reason: reason)]
        }
        if lower.contains("update state"), lower.contains("progress:") {
            return [.appUpdateProgress(appUpdateFraction(line))]
        }
        if lower.contains("confirm the login in the steam mobile app") {
            return [.mobileConfirmationRequested]
        }
        if lower.contains("logged in ok") || lower.contains("waiting for user info...ok") {
            return [.loginSucceeded]
        }
        if lower.contains("cached credentials not found") || lower.contains("password required") {
            return [.loginFailed(.passwordRequired)]
        }
        if let reason = parenthesised(after: ["failed", "error"], in: line),
           lower.contains("logging in") || lower.hasPrefix("failed") || lower.hasPrefix("error (") ||
           lower.contains("login failure") {
            return [.loginFailed(loginFailure(reason))]
        }
        return []
    }

    static func loginFailure(_ reason: String) -> SteamLoginFailure {
        let lower = reason.lowercased()
        if lower.contains("invalid password") { return .invalidPassword }
        if lower.contains("rate limit") { return .rateLimited }
        if lower.contains("auth code") || lower.contains("two-factor") || lower.contains("two factor") ||
            lower.contains("steam guard") { return .invalidGuardCode }
        if lower.contains("password") && (lower.contains("required") || lower.contains("cached")) { return .passwordRequired }
        if lower.contains("no connection") || lower.contains("timeout") || lower.contains("service unavailable") {
            return .noConnection
        }
        return .other(reason)
    }

    /// `Success. Downloaded item 123 to "/path" (456 bytes)`
    private static func downloadSuccess(_ line: String) -> SteamCMDEvent? {
        let words = line.split(separator: " ")
        guard words.count >= 4 else { return nil }
        let id = String(words[3])
        guard let open = line.firstIndex(of: "\""),
              let close = line[line.index(after: open)...].firstIndex(of: "\"") else { return nil }
        let path = String(line[line.index(after: open)..<close])
        var bytes: Int64?
        if let size = parenthesised(after: [""], in: String(line[close...])) {
            bytes = Int64(size.split(separator: " ").first ?? "")
        }
        return .downloadSucceeded(workshopID: id, path: path, bytes: bytes)
    }

    /// `ERROR! Download item 123 failed (Access Denied).`
    private static func downloadFailure(_ line: String) -> SteamCMDEvent? {
        let words = line.split(separator: " ")
        guard words.count >= 4 else { return nil }
        let reason = parenthesised(after: ["failed"], in: line) ?? line
        return .downloadFailed(workshopID: String(words[3]), reason: reason)
    }

    /// `Update state (0x61) downloading, progress: 12.34 (101376000 / 821397392)`：按字节计算；总数为 0 时用百分比。
    static func appUpdateFraction(_ line: String) -> Double? {
        guard let range = line.range(of: "progress:", options: .caseInsensitive) else { return nil }
        let rest = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        let percent = Double(rest.prefix { $0.isNumber || $0 == "." })
        if let bytes = parenthesised(after: [""], in: rest) {
            let parts = bytes.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, let done = Double(parts[0]), let total = Double(parts[1]), total > 0 {
                return min(1, max(0, done / total))
            }
        }
        guard let percent, percent > 0 else { return nil }
        return min(1, percent / 100)
    }

    /// 第一对单引号里的文字（`App '431960'`）。
    private static func singleQuoted(_ line: String) -> String? {
        guard let open = line.firstIndex(of: "'"),
              let close = line[line.index(after: open)...].firstIndex(of: "'") else { return nil }
        let value = String(line[line.index(after: open)..<close])
        return value.isEmpty ? nil : value
    }

    /// 第一个关键字之后第一对括号里的文字。关键字为空串时从头找。
    private static func parenthesised(after keywords: [String], in line: String) -> String? {
        let lower = line.lowercased()
        for keyword in keywords {
            let start: String.Index
            if keyword.isEmpty {
                start = line.startIndex
            } else if let range = lower.range(of: keyword) {
                start = line.index(line.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: range.upperBound))
            } else { continue }
            guard let open = line[start...].firstIndex(of: "("),
                  let close = line[open...].firstIndex(of: ")") else { continue }
            return String(line[line.index(after: open)..<close])
        }
        return nil
    }
}
