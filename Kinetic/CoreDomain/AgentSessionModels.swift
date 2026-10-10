import Foundation

/// Module 41: the coding agents whose local session logs the Agent Session widget can read.
enum AgentProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case claude, codex
    var id: String { rawValue }
    var title: String { self == .claude ? "Claude Code" : "Codex" }
    /// Home-relative folder the system open panel starts in.
    var homeFolderName: String { self == .claude ? ".claude" : ".codex" }
    /// Sessions folder inside the granted folder (the user may also grant this folder itself).
    var sessionsFolderName: String { self == .claude ? "projects" : "sessions" }
}

/// What a session is doing now, derived only from log metadata (record types, tool names, timestamps).
enum AgentSessionPhase: String, Equatable, Sendable {
    case responding, runningTool, waitingForInput, interrupted, failed, unknown
    var isActive: Bool { self == .responding || self == .runningTool }
}

/// Metadata only: never prompts, replies, tool input or tool output.
struct AgentSessionSummary: Equatable, Identifiable, Sendable {
    let id: String
    let provider: AgentProvider
    var project: String
    var phase: AgentSessionPhase
    var tool: String?
    var phaseSince: Date?
    var lastActivity: Date
    var contextTokens: Int?
    var contextWindow: Int?
    var contextFraction: Double? {
        guard let contextTokens, let contextWindow, contextWindow > 0, contextTokens >= 0 else { return nil }
        return min(1, Double(contextTokens) / Double(contextWindow))
    }
}

enum AgentSourceStatus: Equatable, Sendable {
    case notConnected, connected, unreadable
}

enum AgentSessionActivity: String, Equatable, Sendable {
    /// No visible widget, so nothing is read.
    case idle
    /// Sleep, lock, display sleep or a critical system condition.
    case paused
    case live
    case disposed
}

struct AgentSessionSnapshot: Equatable, Sendable {
    var activity: AgentSessionActivity
    var sources: [AgentProvider: AgentSourceStatus]
    var sessions: [AgentSessionSummary] = []
    var sampledAt: Date?
    var hasConnectedSource: Bool { sources.values.contains { $0 != .notConnected } }
    static func waiting(_ activity: AgentSessionActivity, sources: [AgentProvider: AgentSourceStatus]) -> Self {
        .init(activity: activity, sources: sources)
    }
}
