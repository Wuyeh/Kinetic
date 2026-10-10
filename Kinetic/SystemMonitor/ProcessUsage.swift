import AppKit
import Combine
import Darwin

/// Module 52：Kinetic 自己这个进程的占用（与「活动监视器」的 CPU、内存列同一口径）。
/// 网页壁纸的 WebKit 内容进程与 Steam 小助手是独立进程，不计在内。
struct ProcessUsage: Equatable, Sendable {
    var cpuPercent: Double
    var memoryBytes: UInt64

    /// "Kinetic 占用 CPU 3.2% · 内存 412 MB"
    var summary: String {
        let cpu = cpuPercent < 10 ? String(format: "%.1f", cpuPercent) : String(format: "%.0f", cpuPercent)
        let memory = ByteCountFormatter.string(fromByteCount: Int64(memoryBytes), countStyle: .memory)
        return "Kinetic 占用 CPU \(cpu)% · 内存 \(memory)"
    }

    /// The kernel's own decaying per-thread CPU usage (no second sample needed) and the physical footprint.
    static func current() -> ProcessUsage? {
        var threads: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)),
                          vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        }
        var total = 0.0
        for index in 0..<Int(count) {
            var info = thread_basic_info()
            var infoCount = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                    thread_info(threads[index], thread_flavor_t(THREAD_BASIC_INFO), $0, &infoCount)
                }
            }
            if result == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 {
                total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100
            }
            mach_port_deallocate(mach_task_self_, threads[index])
        }
        var vm = task_vm_info_data_t()
        var vmCount = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let vmResult = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vmCount)
            }
        }
        return ProcessUsage(cpuPercent: total, memoryBytes: vmResult == KERN_SUCCESS ? vm.phys_footprint : 0)
    }
}

/// Samples only while a menu of Kinetic is open (the menu bar menu): once when it opens, then every 2 s.
@MainActor
final class PerformanceStripModel: ObservableObject {
    @Published private(set) var usage: ProcessUsage?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private let read: () -> ProcessUsage?

    init(read: @escaping () -> ProcessUsage? = ProcessUsage.current) {
        self.read = read
        usage = read()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.startSampling() }
        })
        observers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopSampling() }
        })
    }

    var isSampling: Bool { timer != nil }

    func startSampling() {
        sample()
        guard timer == nil else { return }
        let next = Timer(timeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.sample() } }
        next.tolerance = 0.5
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }

    func stopSampling() { timer?.invalidate(); timer = nil }

    func sample() {
        let value = read()
        if value != usage { usage = value }
    }

    func shutdown() {
        stopSampling()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }
}
