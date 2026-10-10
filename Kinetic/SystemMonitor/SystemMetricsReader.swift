import Darwin
import Foundation
import IOKit.ps

struct SystemCPUTicks: Equatable, Sendable {
    let user: UInt64, system: UInt64, idle: UInt64, nice: UInt64
    let processorCount: Int
}
struct SystemInterfaceCounters: Equatable, Sendable {
    let index: UInt32
    let received: UInt64, sent: UInt64
}
struct SystemMetricsRawSample: Equatable, Sendable {
    let date: Date
    let uptime: TimeInterval
    let cpu: SystemMetric<SystemCPUTicks>
    let memory: SystemMetric<SystemMemoryMetrics>
    let network: SystemMetric<[String: SystemInterfaceCounters]>
    let disk: SystemMetric<SystemDiskMetrics>
    let power: SystemMetric<SystemPowerMetrics>
    let thermal: SystemMetric<SystemThermalLevel>
}

/// Read-only public APIs. No subprocess, SMC/private registry keys, credentials or file contents.
struct SystemMetricsReader: Sendable {
    func read() -> SystemMetricsRawSample {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        return .init(date: Date(), uptime: ProcessInfo.processInfo.systemUptime,
                     cpu: cpu(host), memory: memory(host), network: network(),
                     disk: disk(), power: power(), thermal: thermal())
    }

    private func cpu(_ host: host_t) -> SystemMetric<SystemCPUTicks> {
        var processors: natural_t = 0, count: mach_msg_type_number_t = 0
        var info: processor_info_array_t?
        let status = host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &processors, &info, &count)
        guard let info else { return .unavailable(.readFailed) }
        defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                              vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.stride)) }
        guard status == KERN_SUCCESS, processors > 0,
              UInt64(count) == UInt64(processors) * UInt64(CPU_STATE_MAX) else { return .unavailable(.readFailed) }
        var user: UInt64 = 0, system: UInt64 = 0, idle: UInt64 = 0, nice: UInt64 = 0
        for index in 0..<Int(processors) {
            let offset = index * Int(CPU_STATE_MAX)
            user += UInt64(UInt32(bitPattern: info[offset + Int(CPU_STATE_USER)]))
            system += UInt64(UInt32(bitPattern: info[offset + Int(CPU_STATE_SYSTEM)]))
            idle += UInt64(UInt32(bitPattern: info[offset + Int(CPU_STATE_IDLE)]))
            nice += UInt64(UInt32(bitPattern: info[offset + Int(CPU_STATE_NICE)]))
        }
        return .available(.init(user: user, system: system, idle: idle, nice: nice, processorCount: Int(processors)))
    }

    private func memory(_ host: host_t) -> SystemMetric<SystemMemoryMetrics> {
        var pageSize: vm_size_t = 0, statistics = vm_statistics64()
        guard host_page_size(host, &pageSize) == KERN_SUCCESS, pageSize > 0 else { return .unavailable(.readFailed) }
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let status = withUnsafeMutablePointer(to: &statistics) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        guard status == KERN_SUCCESS else { return .unavailable(.readFailed) }
        func bytes(_ pages: UInt32) -> UInt64 { UInt64(pages) * UInt64(pageSize) }
        return .available(.init(physicalBytes: ProcessInfo.processInfo.physicalMemory,
                                freeBytes: bytes(statistics.free_count), activeBytes: bytes(statistics.active_count),
                                inactiveBytes: bytes(statistics.inactive_count), wiredBytes: bytes(statistics.wire_count),
                                compressedBytes: bytes(statistics.compressor_page_count),
                                speculativeBytes: bytes(statistics.speculative_count)))
    }

    private func network() -> SystemMetric<[String: SystemInterfaceCounters]> {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return .unavailable(.readFailed) }
        defer { freeifaddrs(first) }
        var interfaces: [String: SystemInterfaceCounters] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            let flags = item.pointee.ifa_flags
            guard flags & UInt32(IFF_UP) != 0, flags & UInt32(IFF_RUNNING) != 0,
                  flags & UInt32(IFF_LOOPBACK) == 0,
                  item.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
                  let data = item.pointee.ifa_data, let name = item.pointee.ifa_name else { continue }
            let counters = data.assumingMemoryBound(to: if_data.self).pointee
            interfaces[String(cString: name)] = .init(index: if_nametoindex(name),
                received: UInt64(counters.ifi_ibytes), sent: UInt64(counters.ifi_obytes))
        }
        // No active non-loopback interface is unavailable, not a made-up 0 B/s connection.
        return interfaces.isEmpty ? .unavailable(.notPresent) : .available(interfaces)
    }

    private func disk() -> SystemMetric<SystemDiskMetrics> {
        var statistics = statvfs()
        guard statvfs("/", &statistics) == 0, statistics.f_frsize > 0 else { return .unavailable(.readFailed) }
        let total = UInt64(statistics.f_blocks).multipliedReportingOverflow(by: UInt64(statistics.f_frsize))
        let available = UInt64(statistics.f_bavail).multipliedReportingOverflow(by: UInt64(statistics.f_frsize))
        guard !total.overflow, !available.overflow, total.partialValue > 0,
              available.partialValue <= total.partialValue else { return .unavailable(.readFailed) }
        return .available(.init(totalBytes: total.partialValue, availableBytes: available.partialValue,
                                readBytesPerSecond: .unavailable(.unsupported), writtenBytesPerSecond: .unavailable(.unsupported)))
    }

    private func power() -> SystemMetric<SystemPowerMetrics> {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let providing = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return .unavailable(.readFailed) }
        let source: SystemPowerSource
        switch providing as String {
        case kIOPSACPowerValue: source = .external
        case kIOPSBatteryPowerValue: source = .battery
        case kIOPMUPSPowerKey: source = .ups
        default: return .unavailable(.unsupported)
        }
        var battery: SystemMetric<SystemBatteryMetrics> = .unavailable(.notPresent)
        for item in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, item)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            guard let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0,
                  (0...maximum).contains(current), let charging = description[kIOPSIsChargingKey] as? Bool
            else { battery = .unavailable(.readFailed); break }
            battery = .available(.init(chargePercent: Double(current) / Double(maximum) * 100, isCharging: charging)); break
        }
        return .available(.init(source: source, isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled, battery: battery))
    }

    private func thermal() -> SystemMetric<SystemThermalLevel> {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .available(.nominal)
        case .fair: return .available(.fair)
        case .serious: return .available(.serious)
        case .critical: return .available(.critical)
        @unknown default: return .unavailable(.unsupported)
        }
    }
}

/// Delta calculations live outside the GUI and retain only one baseline, not a history.
struct SystemMetricsAccumulator: Sendable {
    static let maximumDeltaInterval: TimeInterval = 10
    private var previous: SystemMetricsRawSample?

    mutating func consume(_ current: SystemMetricsRawSample, resetBaselines: Bool = false) -> SystemMetricsSnapshot {
        let old = resetBaselines ? nil : previous
        previous = current
        let elapsed = old.map { current.uptime - $0.uptime }
        let validInterval = elapsed.map { $0.isFinite && $0 > 0 && $0 <= Self.maximumDeltaInterval } ?? false
        return .init(sampledAt: current.date, cpu: cpu(current.cpu, old: validInterval ? old?.cpu : nil),
                     memory: current.memory, gpuUtilizationPercent: .unavailable(.unsupported),
                     network: network(current.network, old: validInterval ? old?.network : nil, elapsed: elapsed),
                     disk: current.disk, power: current.power, thermal: current.thermal,
                     temperatureCelsius: .unavailable(.unsupported), fanRevolutionsPerMinute: .unavailable(.unsupported))
    }

    private func cpu(_ current: SystemMetric<SystemCPUTicks>, old: SystemMetric<SystemCPUTicks>?) -> SystemMetric<SystemCPUMetrics> {
        guard case .available(let current) = current else { if case .unavailable(let reason) = current { return .unavailable(reason) }; return .unavailable(.readFailed) }
        guard current.processorCount > 0 else { return .unavailable(.readFailed) }
        guard let old = old?.value, old.processorCount == current.processorCount else { return .unavailable(.warmingUp) }
        guard current.user >= old.user, current.system >= old.system, current.idle >= old.idle,
              current.nice >= old.nice else { return .unavailable(.counterReset) }
        // Convert individual deltas before adding, so a fabricated/invalid UInt64 input cannot overflow.
        let busy = Double(current.user - old.user) + Double(current.system - old.system) + Double(current.nice - old.nice)
        let total = busy + Double(current.idle - old.idle)
        guard total > 0, total.isFinite else { return .unavailable(.warmingUp) }
        return .available(.init(utilizationPercent: busy / total * 100, logicalProcessorCount: current.processorCount))
    }

    private func network(_ current: SystemMetric<[String: SystemInterfaceCounters]>,
                         old: SystemMetric<[String: SystemInterfaceCounters]>?, elapsed: TimeInterval?) -> SystemMetric<SystemNetworkMetrics> {
        guard let currentValue = current.value else { if case .unavailable(let reason) = current { return .unavailable(reason) }; return .unavailable(.readFailed) }
        guard !currentValue.isEmpty else { return .unavailable(.notPresent) }
        guard let old = old?.value, let elapsed, elapsed.isFinite, elapsed > 0,
              Set(old.keys) == Set(currentValue.keys) else { return .unavailable(.warmingUp) }
        var received = 0.0, sent = 0.0
        for (name, counters) in currentValue {
            guard let before = old[name], before.index == counters.index else { return .unavailable(.warmingUp) }
            guard counters.received >= before.received, counters.sent >= before.sent else { return .unavailable(.counterReset) }
            received += Double(counters.received - before.received); sent += Double(counters.sent - before.sent)
        }
        let incoming = received / elapsed, outgoing = sent / elapsed
        guard incoming.isFinite, outgoing.isFinite else { return .unavailable(.readFailed) }
        return .available(.init(receivedBytesPerSecond: incoming, sentBytesPerSecond: outgoing, interfaceCount: currentValue.count))
    }
}

protocol SystemMetricsSampling: Sendable {
    func sample(resetBaselines: Bool) async -> SystemMetricsSnapshot
}

actor LiveSystemMetricsSampler: SystemMetricsSampling {
    private let reader = SystemMetricsReader()
    private var accumulator = SystemMetricsAccumulator()
    func sample(resetBaselines: Bool) -> SystemMetricsSnapshot {
        accumulator.consume(reader.read(), resetBaselines: resetBaselines)
    }
}
