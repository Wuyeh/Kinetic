import Foundation

/// Module 41: derives a session's state from the end of its local log. Pure and synchronous.
/// Only record types, tool names, timestamps, the working folder's name and token counts are kept;
/// prompts, replies, tool input and tool output are never stored or shown.
enum AgentSessionLogParser {
    static func claude(lines: [Data], id: String, modified: Date, fallbackProject: String) -> AgentSessionSummary {
        var state = State(provider: .claude, id: id, project: fallbackProject, modified: modified)
        for line in lines {
            // Sub-agent and meta records (command echoes, caveats) never change the main session's phase.
            guard let record = object(line), (record["isSidechain"] as? Bool) != true,
                  (record["isMeta"] as? Bool) != true else { continue }
            if let cwd = record["cwd"] as? String { state.project = folderName(cwd) ?? state.project }
            let time = date(record["timestamp"])
            switch record["type"] as? String {
            case "assistant":
                guard let message = record["message"] as? [String: Any] else { continue }
                if (record["isApiErrorMessage"] as? Bool) == true { state.finish(.failed, at: time); continue }
                if let usage = message["usage"] as? [String: Any] {
                    let parts = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"].compactMap { integer(usage[$0]) }
                    if !parts.isEmpty { state.contextTokens = parts.reduce(0, +) }
                }
                for block in message["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "tool_use" {
                    if let id = block["id"] as? String { state.startTool(id: id, name: block["name"] as? String) }
                }
                let stop = message["stop_reason"] as? String
                if state.hasPendingTools { state.set(.runningTool, at: time) }
                else if ["end_turn", "stop_sequence", "max_tokens", "refusal"].contains(stop) { state.finish(.waitingForInput, at: time) }
                else { state.set(.responding, at: time) }
            case "user":
                guard let message = record["message"] as? [String: Any] else { continue }
                var interrupted = false
                if let blocks = message["content"] as? [[String: Any]] {
                    for block in blocks {
                        switch block["type"] as? String {
                        case "tool_result": if let id = block["tool_use_id"] as? String { state.endTool(id: id) }
                        case "text": interrupted = interrupted || isInterruption(block["text"])
                        default: break
                        }
                    }
                } else { interrupted = isInterruption(message["content"]) }
                if interrupted { state.finish(.interrupted, at: time) }
                else { state.set(state.hasPendingTools ? .runningTool : .responding, at: time) }
            default: continue
            }
        }
        return state.summary
    }

    static func codex(lines: [Data], id: String, modified: Date, fallbackProject: String) -> AgentSessionSummary {
        var state = State(provider: .codex, id: id, project: fallbackProject, modified: modified)
        for line in lines {
            guard let record = object(line), let payload = record["payload"] as? [String: Any] else { continue }
            let time = date(record["timestamp"])
            switch record["type"] as? String {
            case "session_meta", "turn_context":
                if let cwd = payload["cwd"] as? String { state.project = folderName(cwd) ?? state.project }
                if let window = integer(payload["context_window"]) { state.contextWindow = window }
            case "event_msg":
                switch payload["type"] as? String {
                case "task_started":
                    state.finish(.responding, at: time)
                    if let window = integer(payload["model_context_window"]) { state.contextWindow = window }
                case "task_complete": state.finish(.waitingForInput, at: time)
                case "turn_aborted": state.finish(.interrupted, at: time)
                case "error": state.finish(.failed, at: time)
                case "token_count":
                    guard let info = payload["info"] as? [String: Any] else { continue }
                    if let last = info["last_token_usage"] as? [String: Any], let input = integer(last["input_tokens"]) {
                        state.contextTokens = input
                    }
                    if let window = integer(info["model_context_window"]) { state.contextWindow = window }
                default: continue
                }
            case "response_item":
                let kind = payload["type"] as? String ?? ""
                if ["function_call", "custom_tool_call", "local_shell_call"].contains(kind) {
                    state.startTool(id: payload["call_id"] as? String ?? UUID().uuidString,
                                    name: payload["name"] as? String ?? (kind == "local_shell_call" ? "shell" : nil))
                    state.set(.runningTool, at: time)
                } else if kind.hasSuffix("_call_output") {
                    if let id = payload["call_id"] as? String { state.endTool(id: id) }
                    state.set(state.hasPendingTools ? .runningTool : .responding, at: time)
                }
            default: continue
            }
        }
        return state.summary
    }

    private struct State {
        let provider: AgentProvider
        let id: String
        var project: String
        let modified: Date
        var phase = AgentSessionPhase.unknown
        var since: Date?
        var contextTokens: Int?
        var contextWindow: Int?
        private var tools: [(id: String, name: String)] = []
        init(provider: AgentProvider, id: String, project: String, modified: Date) {
            self.provider = provider; self.id = id; self.project = project; self.modified = modified
        }
        var hasPendingTools: Bool { !tools.isEmpty }
        mutating func startTool(id: String, name: String?) {
            tools.removeAll { $0.id == id }; tools.append((id, name.map(AgentSessionLogParser.toolName) ?? "tool"))
            if tools.count > 64 { tools.removeFirst(tools.count - 64) }
        }
        mutating func endTool(id: String) { tools.removeAll { $0.id == id } }
        mutating func set(_ next: AgentSessionPhase, at time: Date?) {
            if next != phase || (next == .runningTool && since == nil) { since = time ?? since }
            phase = next
        }
        mutating func finish(_ next: AgentSessionPhase, at time: Date?) { tools.removeAll(); set(next, at: time) }
        var summary: AgentSessionSummary {
            .init(id: provider.rawValue + ":" + id, provider: provider, project: project, phase: phase,
                  tool: phase == .runningTool ? tools.last?.name : nil, phaseSince: since, lastActivity: modified,
                  contextTokens: contextTokens, contextWindow: contextWindow)
        }
    }

    /// Short, display-safe tool names: MCP tools keep only their final segment.
    static func toolName(_ raw: String) -> String {
        let name = raw.hasPrefix("mcp__") ? (raw.components(separatedBy: "__").last { !$0.isEmpty } ?? raw) : raw
        let cleaned = name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        return String(String.UnicodeScalarView(cleaned).prefix(40))
    }
    static func folderName(_ path: String) -> String? {
        let name = URL(fileURLWithPath: path).lastPathComponent
        guard !name.isEmpty, name != "/" else { return nil }
        let cleaned = name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        return String(String.UnicodeScalarView(cleaned).prefix(80))
    }
    private static func isInterruption(_ value: Any?) -> Bool {
        (value as? String)?.hasPrefix("[Request interrupted by user") == true
    }
    private static func object(_ line: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double >= 0, double < 1e12 else { return nil }
        return Int(double)
    }
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let whole = Date.ISO8601FormatStyle()
    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return (try? fractional.parse(text)) ?? (try? whole.parse(text))
    }
}

/// Bounded reads from the end (or start) of a log that may be hundreds of MB.
enum AgentSessionLogFile {
    static let tailBytes = 256 * 1_024
    static let extendedTailBytes = 2 * 1_048_576
    static let headBytes = 256 * 1_024

    /// Complete lines only: a leading partial line is dropped unless the read starts at the file's start.
    static func tailLines(of url: URL, maximumBytes: Int) throws -> [Data] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let start = size > UInt64(maximumBytes) ? size - UInt64(maximumBytes) : 0
        try handle.seek(toOffset: start)
        let data = try handle.read(upToCount: maximumBytes) ?? Data()
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true).map { Data($0) }
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return lines
    }
    static func firstLine(of url: URL, maximumBytes: Int = headBytes) throws -> Data? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes) ?? Data()
        guard let end = data.firstIndex(of: 0x0A) else { return nil }
        return Data(data[data.startIndex..<end])
    }
}

struct AgentSessionFile: Equatable, Sendable {
    let url: URL
    let provider: AgentProvider
    let modified: Date
    let size: Int
}

/// Finds recently written session logs. Claude Code: `projects/<folder>/<session>.jsonl`;
/// Codex: `sessions/<yyyy>/<mm>/<dd>/rollout-*.jsonl` (a long session keeps its start-date folder).
enum AgentSessionScanner {
    static func files(provider: AgentProvider, root: URL, since: Date) throws -> [AgentSessionFile] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let manager = FileManager.default
        var urls: [URL] = []
        switch provider {
        case .claude:
            for folder in try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles]) {
                guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                urls += (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys),
                                                          options: [.skipsHiddenFiles])) ?? []
            }
        case .codex:
            guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                                                      options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            for case let url as URL in enumerator where enumerator.level <= 4 { urls.append(url) }
        }
        return urls.compactMap { url -> AgentSessionFile? in
            guard url.pathExtension == "jsonl", let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true, let modified = values.contentModificationDate, modified >= since else { return nil }
            return .init(url: url, provider: provider, modified: modified, size: values.fileSize ?? 0)
        }
    }
}

/// Re-reads a log only when its size or modification date changed.
actor AgentSessionReader {
    struct Result: Sendable { var sessions: [AgentSessionSummary]; var unreadable: Set<AgentProvider> }
    static let recentWindow: TimeInterval = 6 * 3_600
    static let maximumSessions = 8
    /// A full folder scan finds new sessions; between scans only known recent logs are checked.
    static let rescanInterval: TimeInterval = 15

    private var parsed: [URL: (modified: Date, size: Int, summary: AgentSessionSummary)] = [:]
    private var codexProjects: [URL: String] = [:]
    private var candidates: [AgentProvider: [URL]] = [:]
    private var scannedAt: [AgentProvider: Date] = [:]
    private var roots: [AgentProvider: URL] = [:]

    func read(roots next: [AgentProvider: URL], now: Date) -> Result {
        if next != roots { roots = next; candidates = [:]; scannedAt = [:] }
        var unreadable = Set<AgentProvider>(), files: [AgentSessionFile] = []
        let since = now.addingTimeInterval(-Self.recentWindow)
        for (provider, root) in next.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            do {
                if let last = scannedAt[provider], now.timeIntervalSince(last) < Self.rescanInterval, now >= last {
                    files += (candidates[provider] ?? []).compactMap { Self.stat($0, provider: provider, since: since) }
                } else {
                    let found = try AgentSessionScanner.files(provider: provider, root: root, since: since)
                    candidates[provider] = found.map(\.url); scannedAt[provider] = now
                    files += found
                }
            } catch { unreadable.insert(provider); candidates[provider] = nil; scannedAt[provider] = nil }
        }
        let recent = files.sorted { $0.modified > $1.modified }.prefix(Self.maximumSessions)
        var sessions: [AgentSessionSummary] = []
        for file in recent {
            if let cached = parsed[file.url], cached.modified == file.modified, cached.size == file.size {
                sessions.append(cached.summary); continue
            }
            guard let summary = summarize(file) else { continue }
            parsed[file.url] = (file.modified, file.size, summary)
            sessions.append(summary)
        }
        let kept = Set(recent.map(\.url))
        parsed = parsed.filter { kept.contains($0.key) }
        codexProjects = codexProjects.filter { kept.contains($0.key) }
        return .init(sessions: Self.ordered(sessions), unreadable: unreadable)
    }

    /// Active sessions first, then the most recently written.
    static func ordered(_ sessions: [AgentSessionSummary]) -> [AgentSessionSummary] {
        sessions.sorted {
            if $0.phase.isActive != $1.phase.isActive { return $0.phase.isActive }
            if $0.lastActivity != $1.lastActivity { return $0.lastActivity > $1.lastActivity }
            return $0.id < $1.id
        }
    }

    private static func stat(_ url: URL, provider: AgentProvider, since: Date) -> AgentSessionFile? {
        var url = url
        url.removeAllCachedResourceValues() // URL instances cache resource values; a log keeps growing.
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true, let modified = values.contentModificationDate, modified >= since else { return nil }
        return .init(url: url, provider: provider, modified: modified, size: values.fileSize ?? 0)
    }

    private func summarize(_ file: AgentSessionFile) -> AgentSessionSummary? {
        let id = file.url.deletingPathExtension().lastPathComponent
        func parse(_ lines: [Data]) -> AgentSessionSummary {
            switch file.provider {
            case .claude:
                return AgentSessionLogParser.claude(lines: lines, id: id, modified: file.modified,
                                                    fallbackProject: file.url.deletingLastPathComponent().lastPathComponent)
            case .codex:
                return AgentSessionLogParser.codex(lines: lines, id: id, modified: file.modified,
                                                   fallbackProject: codexProject(file.url) ?? "Codex")
            }
        }
        guard let lines = try? AgentSessionLogFile.tailLines(of: file.url, maximumBytes: AgentSessionLogFile.tailBytes) else { return nil }
        var summary = parse(lines)
        // One very large tool result can fill the whole tail; look further back once.
        if summary.phase == .unknown, file.size > AgentSessionLogFile.tailBytes,
           let more = try? AgentSessionLogFile.tailLines(of: file.url, maximumBytes: AgentSessionLogFile.extendedTailBytes) {
            summary = parse(more)
        }
        return summary
    }

    /// The working folder from Codex's first record, read once per log.
    private func codexProject(_ url: URL) -> String? {
        if let known = codexProjects[url] { return known }
        guard let line = try? AgentSessionLogFile.firstLine(of: url),
              let record = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let payload = record["payload"] as? [String: Any], let cwd = payload["cwd"] as? String,
              let name = AgentSessionLogParser.folderName(cwd) else { return nil }
        codexProjects[url] = name
        return name
    }
}
