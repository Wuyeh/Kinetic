import AppKit
import Combine
import SwiftUI

enum AgentSessionWidgetPresentation {
    static func make(snapshot: AgentSessionSnapshot, now: Date) -> WidgetDataPresentation {
        let text = WidgetDataFormat.text
        guard snapshot.hasConnectedSource else {
            return .init(caption: text("widgets.kind.agentSession"), value: text("agentWidget.notConnected"),
                         note: text("agentWidget.setup"), isUnavailable: true)
        }
        switch snapshot.activity {
        case .idle, .paused, .disposed:
            return WidgetDataFormat.unavailable(snapshot.activity == .paused ? .paused :
                                                    snapshot.activity == .disposed ? .disposed : .noVisibleSubscribers)
        case .live: break
        }
        let problems = AgentProvider.allCases.filter { snapshot.sources[$0] == .unreadable }
            .map { String(format: text("agentWidget.unreadable"), $0.title) }
        guard let top = snapshot.sessions.first else {
            return .init(caption: text("widgets.kind.agentSession"), value: text("agentWidget.none"),
                         symbol: "moon.zzz", note: ([text("agentWidget.noneNote")] + problems).joined(separator: "\n"),
                         isUnavailable: problems.count == snapshot.sources.values.filter { $0 != .notConnected }.count)
        }
        let reference = snapshot.sampledAt ?? now
        let active = snapshot.sessions.filter { $0.phase.isActive }.count
        var rows = [WidgetDataRow(key: "agentWidget.active", value: String(format: text("agentWidget.activeCount"), active, snapshot.sessions.count))]
        var used: Set<String> = [label(top), "agentWidget.active"]
        for session in snapshot.sessions.dropFirst() {
            var key = label(session), copy = 2
            while used.contains(key) { key = label(session) + " (\(copy))"; copy += 1 }
            used.insert(key)
            rows.append(.init(key: key, value: status(session, now: reference), isLiteralKey: true))
        }
        var notes: [String] = []
        if let tokens = top.contextTokens { notes.append(String(format: text("agentWidget.context"), compact(tokens))) }
        if let since = top.phaseSince { notes.append(String(format: text("agentWidget.since"), duration(reference.timeIntervalSince(since)))) }
        return .init(caption: label(top), value: phase(top), symbol: symbol(top.phase), fraction: top.contextFraction,
                     rows: rows, note: ([notes.joined(separator: " · ")] + problems).filter { !$0.isEmpty }.joined(separator: "\n"))
    }

    static func label(_ session: AgentSessionSummary) -> String { session.provider.title + " · " + session.project }
    static func phase(_ session: AgentSessionSummary) -> String {
        let text = WidgetDataFormat.text
        if session.phase == .runningTool, let tool = session.tool { return String(format: text("agentWidget.phase.tool"), tool) }
        return text("agentWidget.phase." + session.phase.rawValue)
    }
    static func status(_ session: AgentSessionSummary, now: Date) -> String {
        phase(session) + " · " + duration(now.timeIntervalSince(session.phaseSince ?? session.lastActivity))
    }
    static func symbol(_ phase: AgentSessionPhase) -> String {
        switch phase {
        case .responding: return "ellipsis.bubble"
        case .runningTool: return "gearshape.2"
        case .waitingForInput: return "text.cursor"
        case .interrupted: return "pause.circle"
        case .failed: return "exclamationmark.triangle"
        case .unknown: return "questionmark"
        }
    }
    static func duration(_ seconds: TimeInterval) -> String {
        let text = WidgetDataFormat.text
        guard seconds.isFinite, seconds >= 60 else { return text("agentWidget.justNow") }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return String(format: text("agentWidget.minutes"), minutes) }
        return String(format: text("agentWidget.hours"), minutes / 60, minutes % 60)
    }
    /// 37,600 → "37.6K"; 1,250,000 → "1.25M".
    static func compact(_ tokens: Int) -> String {
        let value = Double(tokens)
        if value >= 1_000_000 { return WidgetDataFormat.number(value / 1_000_000, decimals: 2) + "M" }
        if value >= 1_000 { return WidgetDataFormat.number(value / 1_000, decimals: 1) + "K" }
        return String(tokens)
    }
}

/// Each visible tile leases the App-owned service; it never opens a folder or owns a timer.
@MainActor
final class AgentSessionWidgetContent: WidgetContent {
    private let service: AgentSessionService
    private let now: () -> Date
    private let state: WidgetDataViewState
    private let host: NSHostingView<WidgetDataView>
    private var lease: AgentSessionSubscription?
    private var observation: AnyCancellable?
    private var context: OverlayContext?
    var displayView: NSView { host }
    var onFailure: (@MainActor () -> Void)?
    private(set) var isPlaying = false
    private(set) var isDisposed = false
    var presentation: WidgetDataPresentation { state.presentation }

    init(configuration: WidgetConfiguration, service: AgentSessionService, now: @escaping () -> Date = Date.init) throws {
        _ = try configuration.validated(); guard configuration.kind == .agentSession else { throw WidgetBoardError.invalidLayout }
        self.service = service; self.now = now
        state = WidgetDataViewState(configuration: configuration,
                                    presentation: AgentSessionWidgetPresentation.make(snapshot: service.snapshot, now: now()))
        host = NSHostingView(rootView: WidgetDataView(state: state)); host.wantsLayer = true; host.layer?.backgroundColor = NSColor.clear.cgColor
        lease = service.subscribe(isVisible: false)
    }
    func update(configuration: WidgetConfiguration, context: OverlayContext) throws {
        guard !isDisposed, configuration.kind == .agentSession, context.frame.width.isFinite, context.frame.height.isFinite,
              context.frame.width > 0, context.frame.height > 0 else { throw WidgetBoardError.invalidLayout }
        _ = try configuration.validated(); self.context = context; state.update(configuration: configuration, context: context)
        if context.isPaused { pause() }
    }
    func play() {
        guard !isDisposed, !isPlaying, context?.isPaused == false else { return }; isPlaying = true
        observation = service.$snapshot.sink { [weak self] snapshot in
            guard let self, self.isPlaying else { return }
            // A pause broadcast can precede the board's own pause callback. Keep the last real frame.
            if snapshot.activity != .live, self.state.presentation.isUnavailable == false, snapshot.hasConnectedSource { return }
            let presentation = AgentSessionWidgetPresentation.make(snapshot: snapshot, now: self.now())
            if self.state.presentation != presentation { self.state.presentation = presentation }
        }
        lease?.setVisible(true)
    }
    func pause() { isPlaying = false; observation = nil; lease?.setVisible(false) }
    func dispose() {
        guard !isDisposed else { return }; pause(); isDisposed = true; lease?.cancel(); lease = nil; context = nil
        onFailure = nil; host.removeFromSuperview()
    }
    deinit { observation?.cancel(); let lease = lease; Task { @MainActor in lease?.cancel() } }
}

extension WidgetContentRegistry {
    func registerAgentSessionWidget(service: AgentSessionService) {
        register(.agentSession) { configuration in try AgentSessionWidgetContent(configuration: configuration, service: service) }
    }
}
