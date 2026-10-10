import Foundation

/// A missing reading is never represented by a fabricated zero.
enum SystemMetricUnavailable: String, Equatable, Sendable {
    case noVisibleSubscribers, paused, disposed, warmingUp, counterReset
    case readFailed, unsupported, notPresent
}

enum SystemMetric<Value: Equatable & Sendable>: Equatable, Sendable {
    case available(Value)
    case unavailable(SystemMetricUnavailable)

    var value: Value? { if case .available(let value) = self { return value }; return nil }
}

struct SystemCPUMetrics: Equatable, Sendable {
    /// Aggregate busy time across all logical CPUs, normalized to 0...100.
    let utilizationPercent: Double
    let logicalProcessorCount: Int
}

struct SystemMemoryMetrics: Equatable, Sendable {
    let physicalBytes: UInt64
    let freeBytes: UInt64
    let activeBytes: UInt64
    let inactiveBytes: UInt64
    let wiredBytes: UInt64
    /// Physical pages occupied by the compressor, not their uncompressed size.
    let compressedBytes: UInt64
    let speculativeBytes: UInt64
    // These are Mach VM counters, not Activity Monitor's "Memory Used" or GPU/ANE memory.
}

struct SystemNetworkMetrics: Equatable, Sendable {
    let receivedBytesPerSecond: Double
    let sentBytesPerSecond: Double
    let interfaceCount: Int
}

struct SystemDiskMetrics: Equatable, Sendable {
    /// Capacity of the system volume; this does not claim system-wide I/O throughput.
    let totalBytes: UInt64
    let availableBytes: UInt64
    let readBytesPerSecond: SystemMetric<Double>
    let writtenBytesPerSecond: SystemMetric<Double>
}

enum SystemPowerSource: String, Equatable, Sendable { case external, battery, ups }
struct SystemBatteryMetrics: Equatable, Sendable {
    let chargePercent: Double
    let isCharging: Bool
}
struct SystemPowerMetrics: Equatable, Sendable {
    let source: SystemPowerSource
    let isLowPowerModeEnabled: Bool
    let battery: SystemMetric<SystemBatteryMetrics>
}
enum SystemThermalLevel: String, Equatable, Sendable { case nominal, fair, serious, critical }

/// A single immutable snapshot is shared by all system widgets. No UI or renderer dependency.
struct SystemMetricsSnapshot: Equatable, Sendable {
    let sampledAt: Date?
    let cpu: SystemMetric<SystemCPUMetrics>
    let memory: SystemMetric<SystemMemoryMetrics>
    let gpuUtilizationPercent: SystemMetric<Double>
    let network: SystemMetric<SystemNetworkMetrics>
    let disk: SystemMetric<SystemDiskMetrics>
    let power: SystemMetric<SystemPowerMetrics>
    let thermal: SystemMetric<SystemThermalLevel>
    let temperatureCelsius: SystemMetric<Double>
    let fanRevolutionsPerMinute: SystemMetric<[Double]>

    static func unavailable(_ reason: SystemMetricUnavailable) -> Self {
        .init(sampledAt: nil, cpu: .unavailable(reason), memory: .unavailable(reason),
              gpuUtilizationPercent: .unavailable(reason), network: .unavailable(reason),
              disk: .unavailable(reason), power: .unavailable(reason), thermal: .unavailable(reason),
              temperatureCelsius: .unavailable(reason), fanRevolutionsPerMinute: .unavailable(reason))
    }
}
