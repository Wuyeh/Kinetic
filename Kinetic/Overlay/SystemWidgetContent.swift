import AppKit
import Combine
import SwiftUI

enum SystemWidgetPresentation {
    static let kinds: [WidgetKind] = [.systemOverview, .cpu, .memory, .gpu, .network, .disk, .power, .processes, .aneMemory]
    /// Unsupported-only boards do not start the CPU/network sampler just to show an explanation.
    static let sampledKinds: Set<WidgetKind> = [.systemOverview, .cpu, .memory, .network, .disk, .power]
    private static func row(_ key: String, _ value: String) -> WidgetDataRow { .init(key: "systemWidget." + key, value: value) }
    private static func missing<T>(_ metric: SystemMetric<T>, note: String = "") -> WidgetDataPresentation {
        if case .unavailable(let reason) = metric { return WidgetDataFormat.unavailable(reason, note: note) }
        return WidgetDataFormat.unavailable(.readFailed, note: note)
    }
    static func make(kind: WidgetKind, snapshot: SystemMetricsSnapshot) -> WidgetDataPresentation {
        let text = WidgetDataFormat.text, bytes = WidgetDataFormat.bytes
        switch kind {
        case .cpu, .systemOverview:
            guard let cpu = snapshot.cpu.value, cpu.utilizationPercent.isFinite, (0...100).contains(cpu.utilizationPercent) else { return missing(snapshot.cpu) }
            var result = WidgetDataPresentation(caption: text("systemWidget.cpuUsage"),
                value: WidgetDataFormat.number(cpu.utilizationPercent) + "%", fraction: cpu.utilizationPercent / 100,
                rows: [row("logicalCPUs", String(cpu.logicalProcessorCount))])
            if kind == .systemOverview {
                result.rows = [row("freeMemory", snapshot.memory.value.map { bytes($0.freeBytes) } ?? text("widgetData.unavailable")),
                    row("networkDown", snapshot.network.value.map { WidgetDataFormat.rate($0.receivedBytesPerSecond) } ?? text("widgetData.unavailable")),
                    row("networkUp", snapshot.network.value.map { WidgetDataFormat.rate($0.sentBytesPerSecond) } ?? text("widgetData.unavailable")),
                    row("diskAvailable", snapshot.disk.value.map { bytes($0.availableBytes) } ?? text("widgetData.unavailable")),
                    row("powerSource", snapshot.power.value.map { text("systemWidget.power." + $0.source.rawValue) } ?? text("widgetData.unavailable")),
                    row("gpu", snapshot.gpuUtilizationPercent.value.map { WidgetDataFormat.number($0) + "%" } ?? text("widgetData.unavailable")),
                    row("thermal", thermal(snapshot.thermal)),
                    row("temperature", snapshot.temperatureCelsius.value.map { WidgetDataFormat.number($0) + " °C" } ?? text("widgetData.unavailable")),
                    row("fan", snapshot.fanRevolutionsPerMinute.value.map { $0.map { WidgetDataFormat.number($0, decimals: 0) }.joined(separator: " / ") + " RPM" } ?? text("widgetData.unavailable"))]
            }
            return result
        case .memory:
            guard let memory = snapshot.memory.value else { return missing(snapshot.memory) }
            return .init(caption: text("systemWidget.freeMemory"), value: bytes(memory.freeBytes),
                rows: [row("physicalMemory", bytes(memory.physicalBytes)), row("compressed", bytes(memory.compressedBytes)),
                    row("active", bytes(memory.activeBytes)), row("inactive", bytes(memory.inactiveBytes)),
                    row("wired", bytes(memory.wiredBytes)), row("speculative", bytes(memory.speculativeBytes))],
                note: text("systemWidget.memoryNote"))
        case .gpu:
            if let value = snapshot.gpuUtilizationPercent.value, value.isFinite, (0...100).contains(value) {
                return .init(caption: text("systemWidget.gpu"), value: WidgetDataFormat.number(value) + "%", fraction: value / 100)
            }
            return WidgetDataFormat.unavailable(.unsupported, note: text("systemWidget.gpuNote"))
        case .network:
            guard let network = snapshot.network.value else { return missing(snapshot.network) }
            return .init(caption: text("systemWidget.networkDown"), value: WidgetDataFormat.rate(network.receivedBytesPerSecond),
                rows: [row("networkUp", WidgetDataFormat.rate(network.sentBytesPerSecond)), row("interfaces", String(network.interfaceCount))],
                note: text("systemWidget.networkNote"))
        case .disk:
            guard let disk = snapshot.disk.value else { return missing(snapshot.disk) }
            return .init(caption: text("systemWidget.diskAvailable"), value: bytes(disk.availableBytes),
                fraction: disk.totalBytes > 0 ? Double(disk.availableBytes) / Double(disk.totalBytes) : nil,
                rows: [row("diskTotal", bytes(disk.totalBytes)), row("diskRead", disk.readBytesPerSecond.value.map(WidgetDataFormat.rate) ?? text("widgetData.unavailable")),
                    row("diskWrite", disk.writtenBytesPerSecond.value.map(WidgetDataFormat.rate) ?? text("widgetData.unavailable"))],
                note: text("systemWidget.diskNote"))
        case .power:
            guard let power = snapshot.power.value else { return missing(snapshot.power) }
            let source = text("systemWidget.power." + power.source.rawValue)
            var result = WidgetDataPresentation(caption: source, value: source,
                rows: [row("lowPower", text(power.isLowPowerModeEnabled ? "systemWidget.on" : "systemWidget.off")), row("thermal", thermal(snapshot.thermal))])
            if let battery = power.battery.value {
                result.value = WidgetDataFormat.number(battery.chargePercent, decimals: 0) + "%"
                result.fraction = battery.chargePercent / 100
                if battery.isCharging { result.caption += " · " + text("systemWidget.charging") }
            } else if case .unavailable(let reason) = power.battery, reason != .notPresent {
                result.rows.insert(row("battery", text("widgetData.status." + reason.rawValue)), at: 0)
            }
            return result
        case .processes:
            return WidgetDataFormat.unavailable(.unsupported, note: text("systemWidget.processesNote"))
        case .aneMemory:
            return WidgetDataFormat.unavailable(.unsupported, note: text("systemWidget.aneNote"))
        case .weather, .agentSession:
            return WidgetDataFormat.unavailable(.unsupported)
        }
    }
    private static func thermal(_ metric: SystemMetric<SystemThermalLevel>) -> String {
        metric.value.map { WidgetDataFormat.text("systemWidget.thermal." + $0.rawValue) } ?? WidgetDataFormat.text("widgetData.unavailable")
    }
}

/// Each visible provider leases the same App-owned service; it never owns a sampler or timer.
@MainActor
final class SystemWidgetContent: WidgetContent {
    let kind: WidgetKind
    private let service: SystemMetricsService
    private let state: WidgetDataViewState
    private let host: NSHostingView<WidgetDataView>
    private var lease: SystemMetricsSubscription?
    private var observation: AnyCancellable?
    private var context: OverlayContext?
    var displayView: NSView { host }
    var onFailure: (@MainActor () -> Void)?
    private(set) var isPlaying = false
    private(set) var isDisposed = false
    private(set) var snapshot: SystemMetricsSnapshot
    var presentation: WidgetDataPresentation { state.presentation }

    init(configuration: WidgetConfiguration, service: SystemMetricsService) throws {
        _ = try configuration.validated()
        guard SystemWidgetPresentation.kinds.contains(configuration.kind) else { throw WidgetBoardError.invalidLayout }
        kind = configuration.kind; self.service = service; snapshot = service.snapshot
        state = WidgetDataViewState(configuration: configuration, presentation: SystemWidgetPresentation.make(kind: kind, snapshot: snapshot))
        host = NSHostingView(rootView: WidgetDataView(state: state)); host.wantsLayer = true; host.layer?.backgroundColor = NSColor.clear.cgColor
        if SystemWidgetPresentation.sampledKinds.contains(kind) { lease = service.subscribe(isVisible: false) }
    }
    func update(configuration: WidgetConfiguration, context: OverlayContext) throws {
        guard !isDisposed, configuration.kind == kind, context.frame.width.isFinite, context.frame.height.isFinite,
              context.frame.width > 0, context.frame.height > 0 else { throw WidgetBoardError.invalidLayout }
        _ = try configuration.validated(); self.context = context; state.update(configuration: configuration, context: context)
        if context.isPaused { pause() }
    }
    func play() {
        guard !isDisposed, !isPlaying, context?.isPaused == false else { return }; isPlaying = true
        observation = service.$snapshot.sink { [weak self] snapshot in
            guard let self, self.isPlaying else { return }
            // Safety broadcasts can precede the board's pause callback. Keep the last real frame.
            if snapshot.sampledAt == nil, self.snapshot.sampledAt != nil,
               let reason = Self.reason(snapshot.cpu), [.paused, .noVisibleSubscribers, .disposed].contains(reason) { return }
            self.snapshot = snapshot
            let presentation = SystemWidgetPresentation.make(kind: self.kind, snapshot: snapshot)
            if self.state.presentation != presentation { self.state.presentation = presentation }
        }
        lease?.setVisible(true)
    }
    private static func reason<T>(_ metric: SystemMetric<T>) -> SystemMetricUnavailable? {
        if case .unavailable(let reason) = metric { return reason }; return nil
    }
    func pause() { isPlaying = false; observation = nil; lease?.setVisible(false) }
    func dispose() {
        guard !isDisposed else { return }; pause(); isDisposed = true; lease?.cancel(); lease = nil; context = nil
        onFailure = nil; host.removeFromSuperview()
    }
    deinit { observation?.cancel(); let lease = lease; Task { @MainActor in lease?.cancel() } }
}

extension WidgetContentRegistry {
    func registerSystemWidgets(service: SystemMetricsService) {
        for kind in SystemWidgetPresentation.kinds {
            register(kind) { configuration in try SystemWidgetContent(configuration: configuration, service: service) }
        }
    }
}
