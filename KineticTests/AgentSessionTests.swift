import AppKit
import XCTest
@testable import Kinetic

/// Module 41: Agent Session Widget — log metadata parsing, bounded reads, the shared reader and the tile.
@MainActor
final class AgentSessionTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() { roots.forEach { try? FileManager.default.removeItem(at: $0) }; roots = []; super.tearDown() }

    private func folder() throws -> URL {
        let root = TestWorkspaceDirectory.make(".build/AgentSessionTests")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root); return root
    }
    private func line(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }
    private func write(_ records: [[String: Any]], to url: URL, modified: Date = Date()) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (records.map { String(decoding: line($0), as: UTF8.self) }.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }
    private static func stamp(_ seconds: Int) -> String { "2026-10-08T06:" + String(format: "%02d:%02d", seconds / 60, seconds % 60) + ".000Z" }
    private func claudeUser(_ content: Any, at seconds: Int, extra: [String: Any] = [:]) -> [String: Any] {
        ["type": "user", "cwd": "/Users/me/Projects/Kinetic", "timestamp": Self.stamp(seconds),
         "message": ["role": "user", "content": content]].merging(extra) { $1 }
    }
    private func claudeAssistant(_ blocks: [[String: Any]], stop: String?, at seconds: Int, extra: [String: Any] = [:]) -> [String: Any] {
        ["type": "assistant", "cwd": "/Users/me/Projects/Kinetic", "timestamp": Self.stamp(seconds),
         "message": ["role": "assistant", "content": blocks, "stop_reason": stop as Any,
                     "usage": ["input_tokens": 2, "cache_read_input_tokens": 37_000, "cache_creation_input_tokens": 598, "output_tokens": 50]]]
            .merging(extra) { $1 }
    }
    private func parseClaude(_ records: [[String: Any]]) -> AgentSessionSummary {
        AgentSessionLogParser.claude(lines: records.map(line), id: "s1", modified: Date(), fallbackProject: "-Users-me-Projects-Kinetic")
    }

    func testClaudePhasesComeFromRecordTypesToolNamesAndUsageOnly() {
        let prompt = claudeUser("secret prompt text", at: 0)
        var summary = parseClaude([prompt])
        XCTAssertEqual(summary.phase, .responding); XCTAssertEqual(summary.project, "Kinetic"); XCTAssertEqual(summary.provider, .claude)
        let thinking = claudeAssistant([["type": "thinking", "thinking": "private"]], stop: "tool_use", at: 3)
        XCTAssertEqual(parseClaude([prompt, thinking]).phase, .responding, "No tool block yet")
        let bash = claudeAssistant([["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "secret"]]], stop: "tool_use", at: 5)
        summary = parseClaude([prompt, thinking, bash])
        XCTAssertEqual(summary.phase, .runningTool); XCTAssertEqual(summary.tool, "Bash")
        XCTAssertEqual(summary.contextTokens, 37_600); XCTAssertNil(summary.contextWindow); XCTAssertNil(summary.contextFraction)
        XCTAssertEqual(summary.phaseSince, try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(Self.stamp(5)))
        let sidechain = claudeAssistant([["type": "tool_use", "id": "x", "name": "Grep"]], stop: "end_turn", at: 6, extra: ["isSidechain": true])
        let meta = claudeUser("<local-command-caveat>", at: 6, extra: ["isMeta": true])
        summary = parseClaude([prompt, bash, sidechain, meta])
        XCTAssertEqual(summary.tool, "Bash", "Sub-agent and meta records never change the main session")
        let result = claudeUser([["type": "tool_result", "tool_use_id": "t1", "content": "secret output"]], at: 9)
        summary = parseClaude([prompt, bash, result]); XCTAssertEqual(summary.phase, .responding); XCTAssertNil(summary.tool)
        let mcp = claudeAssistant([["type": "tool_use", "id": "t2", "name": "mcp__hearthbot__update_status"]], stop: "tool_use", at: 12)
        XCTAssertEqual(parseClaude([prompt, mcp]).tool, "update_status")
        let done = claudeAssistant([["type": "text", "text": "reply"]], stop: "end_turn", at: 20)
        summary = parseClaude([prompt, bash, result, done])
        XCTAssertEqual(summary.phase, .waitingForInput); XCTAssertNil(summary.tool)
        let interrupted = claudeUser([["type": "text", "text": "[Request interrupted by user for tool use]"]], at: 21)
        XCTAssertEqual(parseClaude([prompt, bash, interrupted]).phase, .interrupted)
        let failure = claudeAssistant([["type": "text", "text": "API Error"]], stop: "stop_sequence", at: 22, extra: ["isApiErrorMessage": true])
        XCTAssertEqual(parseClaude([prompt, failure]).phase, .failed)
        XCTAssertEqual(parseClaude([]).phase, .unknown)
        XCTAssertEqual(parseClaude([]).project, "-Users-me-Projects-Kinetic")
        // Nothing from prompts, replies, tool input or output reaches the summary.
        let text = String(describing: parseClaude([prompt, thinking, bash, result, done]))
        for secret in ["secret", "private", "reply"] { XCTAssertFalse(text.contains(secret)) }
    }

    func testCodexPhasesContextUsageAndProjectFolder() {
        func event(_ type: String, _ payload: [String: Any], at seconds: Int) -> Data {
            line(["type": type, "timestamp": Self.stamp(seconds), "payload": payload])
        }
        let meta = event("session_meta", ["cwd": "/Users/me/Kinetic", "context_window": 258_400, "base_instructions": "long"], at: 0)
        let started = event("event_msg", ["type": "task_started", "model_context_window": 272_000], at: 1)
        let call = event("response_item", ["type": "custom_tool_call", "call_id": "c1", "name": "exec", "input": "rm -rf secret"], at: 2)
        let tokens = event("event_msg", ["type": "token_count", "info": ["last_token_usage": ["input_tokens": 136_000, "output_tokens": 10],
                                                                          "model_context_window": 272_000]], at: 3)
        let output = event("response_item", ["type": "custom_tool_call_output", "call_id": "c1", "output": "secret"], at: 4)
        let complete = event("event_msg", ["type": "task_complete", "last_agent_message": "secret"], at: 9)
        func parse(_ lines: [Data]) -> AgentSessionSummary {
            AgentSessionLogParser.codex(lines: lines, id: "rollout-1", modified: Date(), fallbackProject: "Codex")
        }
        var summary = parse([meta, started, call, tokens])
        XCTAssertEqual(summary.phase, .runningTool); XCTAssertEqual(summary.tool, "exec"); XCTAssertEqual(summary.project, "Kinetic")
        XCTAssertEqual(summary.contextTokens, 136_000); XCTAssertEqual(summary.contextWindow, 272_000)
        XCTAssertEqual(summary.contextFraction ?? 0, 0.5, accuracy: 0.001); XCTAssertEqual(summary.id, "codex:rollout-1")
        summary = parse([meta, started, call, tokens, output]); XCTAssertEqual(summary.phase, .responding)
        summary = parse([meta, started, call, output, complete]); XCTAssertEqual(summary.phase, .waitingForInput)
        XCTAssertEqual(parse([started, event("event_msg", ["type": "turn_aborted"], at: 5)]).phase, .interrupted)
        XCTAssertEqual(parse([started, event("event_msg", ["type": "error", "message": "x"], at: 5)]).phase, .failed)
        XCTAssertEqual(parse([started]).project, "Codex", "Falls back to the first record's folder, read separately")
        XCTAssertFalse(String(describing: parse([meta, started, call, output, complete])).contains("secret"))
    }

    func testBoundedReadsDropPartialLinesAndLookFurtherPastOneHugeRecord() async throws {
        let root = try folder()
        let url = root.appendingPathComponent("projects/p/big.jsonl")
        let filler = claudeUser("x", at: 0)
        let huge = claudeUser([["type": "tool_result", "tool_use_id": "t9", "content": String(repeating: "y", count: 400_000)]], at: 2)
        let bash = claudeAssistant([["type": "tool_use", "id": "t9", "name": "Bash"]], stop: "tool_use", at: 1)
        try write(Array(repeating: filler, count: 3_000) + [bash, huge], to: url)
        let tail = try AgentSessionLogFile.tailLines(of: url, maximumBytes: AgentSessionLogFile.tailBytes)
        XCTAssertTrue(tail.isEmpty, "The only record ending in the tail started before it")
        let result = await AgentSessionReader().read(roots: [.claude: root.appendingPathComponent("projects")], now: Date())
        XCTAssertEqual(result.sessions.first?.phase, .responding, "The extended read reaches the tool result")
        let small = root.appendingPathComponent("small.jsonl")
        try write([filler, bash], to: small)
        XCTAssertEqual(try AgentSessionLogFile.tailLines(of: small, maximumBytes: 1_000_000).count, 2)
        XCTAssertNotNil(try AgentSessionLogFile.firstLine(of: small))
    }

    func testReaderFindsRecentSessionsOrdersActiveFirstAndCachesUnchangedLogs() async throws {
        let root = try folder(), now = Date()
        let claude = root.appendingPathComponent("claude/projects"), codex = root.appendingPathComponent("codex/sessions")
        let working = claudeAssistant([["type": "tool_use", "id": "t", "name": "Edit"]], stop: "tool_use", at: 1)
        let done = claudeAssistant([["type": "text", "text": "ok"]], stop: "end_turn", at: 2)
        try write([claudeUser("a", at: 0), done], to: claude.appendingPathComponent("-Users-me-A/a.jsonl"), modified: now.addingTimeInterval(-60))
        try write([claudeUser("b", at: 0), working], to: claude.appendingPathComponent("-Users-me-B/b.jsonl"), modified: now.addingTimeInterval(-600))
        try write([claudeUser("c", at: 0), done], to: claude.appendingPathComponent("-Users-me-C/old.jsonl"), modified: now.addingTimeInterval(-7 * 3_600))
        let meta: [String: Any] = ["type": "session_meta", "timestamp": Self.stamp(0), "payload": ["cwd": "/x/LongRun"]]
        let started: [String: Any] = ["type": "event_msg", "timestamp": Self.stamp(1), "payload": ["type": "task_started"]]
        // A long session keeps its start-date folder.
        try write([meta, started], to: codex.appendingPathComponent("2026/09/22/rollout-1.jsonl"), modified: now.addingTimeInterval(-30))
        let reader = AgentSessionReader()
        var result = await reader.read(roots: [.claude: claude, .codex: codex], now: now)
        XCTAssertEqual(result.sessions.count, 3, "Logs older than six hours are left out")
        XCTAssertEqual(result.sessions.map(\.phase), [.responding, .runningTool, .waitingForInput], "Active first, then most recent")
        XCTAssertEqual(result.sessions.first?.project, "LongRun"); XCTAssertTrue(result.unreadable.isEmpty)
        // Unchanged logs are served from the cache; a rewritten one is parsed again on the next full scan.
        try write([claudeUser("a", at: 0), working], to: claude.appendingPathComponent("-Users-me-A/a.jsonl"), modified: now)
        result = await reader.read(roots: [.claude: claude, .codex: codex], now: now.addingTimeInterval(1))
        XCTAssertEqual(result.sessions.filter { $0.phase == .runningTool }.count, 2)
        result = await reader.read(roots: [.claude: root.appendingPathComponent("missing")], now: now)
        XCTAssertEqual(result.unreadable, [.claude]); XCTAssertTrue(result.sessions.isEmpty)
        for index in 0..<12 {
            try write([claudeUser("n", at: 0)], to: claude.appendingPathComponent("-Users-me-N/\(index).jsonl"), modified: now)
        }
        result = await AgentSessionReader().read(roots: [.claude: claude], now: now.addingTimeInterval(2))
        XCTAssertEqual(result.sessions.count, AgentSessionReader.maximumSessions)
    }

    private func service(reader: CountingAgentReader, scheduler: WidgetMetricsScheduler, defaults: UserDefaults) -> AgentSessionService {
        let plain = EngineAssetsBookmarks(make: { try $0.bookmarkData() },
                                          resolve: { var stale = false
                                                     let url = try URL(resolvingBookmarkData: $0, bookmarkDataIsStale: &stale); return (url, stale) })
        return AgentSessionService(reader: reader, scheduler: scheduler, defaults: defaults, bookmarks: plain)
    }

    func testServiceReadsOnlyGrantedFoldersOnlyWhileAVisibleTileIsShown() async throws {
        let root = try folder(), suite = "AgentSessionTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let claude = root.appendingPathComponent(".claude"); try FileManager.default.createDirectory(at: claude.appendingPathComponent("projects"), withIntermediateDirectories: true)
        let empty = root.appendingPathComponent("empty"); try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let reader = CountingAgentReader(), scheduler = WidgetMetricsScheduler()
        let sessions = service(reader: reader, scheduler: scheduler, defaults: defaults)
        XCTAssertEqual(sessions.snapshot.sources[.claude], .notConnected); XCTAssertFalse(sessions.snapshot.hasConnectedSource)
        XCTAssertThrowsError(try sessions.connect(.claude, folder: empty))
        try sessions.connect(.claude, folder: claude)
        XCTAssertEqual(sessions.snapshot.sources[.claude], .connected); XCTAssertNotNil(sessions.folders[.claude])
        let lease = sessions.subscribe(isVisible: false)
        try await Task.sleep(nanoseconds: 50_000_000)
        var calls = await reader.calls
        XCTAssertEqual(calls, 0); XCTAssertFalse(sessions.isReading); XCTAssertTrue(scheduler.active.isEmpty)
        lease.setVisible(true)
        try await waitUntil { sessions.snapshot.activity == .live }
        calls = await reader.calls
        XCTAssertEqual(calls, 1); XCTAssertEqual(scheduler.active.first?.interval, AgentSessionService.normalInterval)
        let roots = await reader.lastRoots
        XCTAssertEqual(roots[.claude]?.lastPathComponent, "projects"); XCTAssertNil(roots[.codex])
        XCTAssertEqual(sessions.snapshot.sessions.first?.project, "Fixture")
        sessions.updateSystemConditions(.init(screenLocked: true))
        XCTAssertEqual(sessions.snapshot.activity, .paused); XCTAssertFalse(sessions.isReading); XCTAssertTrue(scheduler.active.isEmpty)
        sessions.updateSystemConditions(.init(lowPowerMode: true))
        try await waitUntil { sessions.snapshot.activity == .live }
        XCTAssertEqual(scheduler.active.first?.interval, AgentSessionService.energySavingInterval)
        lease.setVisible(false)
        XCTAssertEqual(sessions.snapshot.activity, .idle); XCTAssertFalse(sessions.isReading)
        lease.setVisible(true); try await waitUntil { sessions.snapshot.activity == .live }
        scheduler.fire(); try await Task.sleep(nanoseconds: 20_000_000)
        sessions.disconnect(.claude)
        XCTAssertEqual(sessions.snapshot.sources[.claude], .notConnected); XCTAssertNil(sessions.folders[.claude])
        XCTAssertFalse(sessions.isReading, "With no folder granted nothing is read, even while shown")
        XCTAssertTrue(scheduler.active.isEmpty)
        lease.cancel(); XCTAssertEqual(sessions.subscriberCount, 0); XCTAssertFalse(sessions.isReading)
        sessions.shutdown(); XCTAssertEqual(sessions.snapshot.activity, .disposed)
        _ = sessions.subscribe(); XCTAssertEqual(sessions.subscriberCount, 0)
    }

    func testPresentationExplainsSetupAndShowsTheMostRelevantSession() {
        let now = Date()
        let text = WidgetDataFormat.text
        var snapshot = AgentSessionSnapshot.waiting(.idle, sources: [.claude: .notConnected, .codex: .notConnected])
        var view = AgentSessionWidgetPresentation.make(snapshot: snapshot, now: now)
        XCTAssertTrue(view.isUnavailable); XCTAssertEqual(view.value, text("agentWidget.notConnected"))
        snapshot = .init(activity: .live, sources: [.claude: .connected, .codex: .notConnected], sessions: [], sampledAt: now)
        view = AgentSessionWidgetPresentation.make(snapshot: snapshot, now: now)
        XCTAssertEqual(view.value, text("agentWidget.none")); XCTAssertFalse(view.isUnavailable)
        snapshot.sources[.claude] = .unreadable
        XCTAssertTrue(AgentSessionWidgetPresentation.make(snapshot: snapshot, now: now).isUnavailable)
        let running = AgentSessionSummary(id: "codex:1", provider: .codex, project: "Kinetic", phase: .runningTool, tool: "exec",
                                          phaseSince: now.addingTimeInterval(-185), lastActivity: now,
                                          contextTokens: 136_000, contextWindow: 272_000)
        let waiting = AgentSessionSummary(id: "claude:2", provider: .claude, project: "Kinetic", phase: .waitingForInput,
                                          phaseSince: now.addingTimeInterval(-4_000), lastActivity: now.addingTimeInterval(-4_000))
        let twin = AgentSessionSummary(id: "claude:3", provider: .claude, project: "Kinetic", phase: .interrupted,
                                       lastActivity: now.addingTimeInterval(-30))
        snapshot = .init(activity: .live, sources: [.claude: .connected, .codex: .connected], sessions: [running, waiting, twin], sampledAt: now)
        view = AgentSessionWidgetPresentation.make(snapshot: snapshot, now: now)
        XCTAssertEqual(view.caption, "Codex · Kinetic")
        XCTAssertEqual(view.value, String(format: text("agentWidget.phase.tool"), "exec"))
        XCTAssertEqual(view.fraction ?? 0, 0.5, accuracy: 0.001); XCTAssertEqual(view.symbol, "gearshape.2")
        XCTAssertEqual(view.rows.first?.value, String(format: text("agentWidget.activeCount"), 1, 3))
        XCTAssertEqual(Set(view.rows.map(\.id)).count, view.rows.count, "Two sessions in the same folder keep distinct rows")
        XCTAssertTrue(view.rows[1].isLiteralKey); XCTAssertTrue(view.rows[1].value.contains(text("agentWidget.phase.waitingForInput")))
        XCTAssertTrue(view.note.contains(WidgetDataFormat.number(136) + "K"))
        XCTAssertTrue(view.note.contains(String(format: text("agentWidget.minutes"), 3)))
        XCTAssertEqual(AgentSessionWidgetPresentation.duration(4_000), String(format: text("agentWidget.hours"), 1, 6))
        XCTAssertEqual(AgentSessionWidgetPresentation.compact(1_250_000), WidgetDataFormat.number(1.25, decimals: 2) + "M")
        XCTAssertEqual(AgentSessionWidgetPresentation.compact(999), "999")
    }

    func testTileLeasesTheServiceOnlyWhileShownAndReleasesIt() async throws {
        let suite = "AgentSessionTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let sessions = service(reader: CountingAgentReader(), scheduler: WidgetMetricsScheduler(), defaults: defaults)
        let configuration = WidgetConfiguration(kind: .agentSession, size: .medium)
        XCTAssertThrowsError(try AgentSessionWidgetContent(configuration: WidgetConfiguration(kind: .cpu), service: sessions))
        weak var released: AgentSessionWidgetContent?
        do {
            let tile = try AgentSessionWidgetContent(configuration: configuration, service: sessions)
            released = tile
            XCTAssertEqual(sessions.subscriberCount, 1); XCTAssertEqual(sessions.visibleSubscriberCount, 0)
            XCTAssertEqual(tile.presentation.value, WidgetDataFormat.text("agentWidget.notConnected"))
            try tile.update(configuration: configuration, context: .init(frame: .init(x: 0, y: 0, width: 320, height: 160),
                backingScaleFactor: 2, maximumFramesPerSecond: 30, allowsAnimation: true, isPaused: false))
            tile.play(); XCTAssertEqual(sessions.visibleSubscriberCount, 1)
            tile.pause(); XCTAssertEqual(sessions.visibleSubscriberCount, 0)
            tile.play(); tile.dispose(); XCTAssertEqual(sessions.subscriberCount, 0)
            XCTAssertThrowsError(try tile.update(configuration: configuration, context: .init(frame: .init(x: 0, y: 0, width: 1, height: 1),
                backingScaleFactor: 2, maximumFramesPerSecond: 30, allowsAnimation: true, isPaused: false)))
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(released)
        let registry = WidgetContentRegistry(); registry.registerAgentSessionWidget(service: sessions)
        let made = try XCTUnwrap(try registry.make(configuration)); made.dispose()
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool, timeout: TimeInterval = 3) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition() && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition())
    }
}

actor CountingAgentReader: AgentSessionReading {
    private(set) var calls = 0
    private(set) var lastRoots: [AgentProvider: URL] = [:]
    func read(roots: [AgentProvider: URL], now: Date) -> AgentSessionReader.Result {
        calls += 1; lastRoots = roots
        let session = AgentSessionSummary(id: "claude:fixture", provider: .claude, project: "Fixture", phase: .responding,
                                          phaseSince: now, lastActivity: now)
        return .init(sessions: roots.isEmpty ? [] : [session], unreadable: [])
    }
}
