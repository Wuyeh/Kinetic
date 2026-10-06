import AppKit
import IOKit.ps

/// Module 18：真实的系统状态查询。只读取状态，不修改任何系统设置，也不读取其他 App 的窗口或画面。
@MainActor
final class LiveSmartPauseProbe: SmartPauseSystemProbe {
    /// 使用电池供电且电量不高于此百分比时视为低电量。实现默认值，不在 v0.1 界面暴露。
    nonisolated static let lowBatteryThreshold = 20

    private var powerSource: CFRunLoopSource?
    private var powerHandler: (@MainActor () -> Void)?
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private(set) var isMemoryCritical = false
    var isThermalCritical: Bool { ProcessInfo.processInfo.thermalState == .critical }

    var isScreenLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    var isDisplayAsleep: Bool {
        let displays = DisplayRegistry.systemDisplays()
        return !displays.isEmpty && displays.allSatisfy { CGDisplayIsAsleep($0.desktop.id) != 0 }
    }

    /// 全屏 App 占据主显示器时，桌面所在的 Space 不再显示，Kinetic 的壁纸窗口随之完全不可见。
    /// 直接看壁纸窗口的遮挡状态，而不是猜测别的窗口是否“全屏”：带刘海的屏幕上全屏窗口不覆盖顶部一条，
    /// 普通最大化窗口时菜单栏下仍能看到壁纸，这两种情况都不会误判。只在壁纸窗口已显示时判断。
    var isFullScreenAppActive: Bool {
        guard let window = NSApp.windows.first(where: { $0.identifier == desktopWindowIdentifier }),
              window.isVisible
        else { return false }
        return !window.occlusionState.contains(.visible)
    }

    private let desktopWindowIdentifier: NSUserInterfaceItemIdentifier

    init(desktopWindowIdentifier: NSUserInterfaceItemIdentifier) {
        self.desktopWindowIdentifier = desktopWindowIdentifier
    }

    func displayConditions(for displays: [DisplayID]) -> [DisplayID: DisplayPauseConditions] {
        let hardware = Dictionary(uniqueKeysWithValues: DisplayRegistry.systemDisplays().map { ($0.id, $0.desktop.id) })
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        return Dictionary(uniqueKeysWithValues: displays.map { id in
            let identifier = desktopWindowIdentifier.rawValue + "." + id.rawValue
            let window = NSApp.windows.first { $0.identifier?.rawValue == identifier }
            var value = Self.visibility(isVisible: window?.isVisible ?? false,
                                        onActiveSpace: window?.isOnActiveSpace ?? true,
                                        occluded: window.map { !$0.occlusionState.contains(.visible) } ?? false)
            value.asleep = hardware[id].map { CGDisplayIsAsleep($0) != 0 } ?? false
            value.frontmostBundleID = frontmost
            return (id, value)
        })
    }

    /// Only Kinetic's own window is inspected: no screen recording or Accessibility permission.
    /// A hidden desktop on another Space is the fullscreen case; same-Space coverage is occlusion.
    nonisolated static func visibility(isVisible: Bool, onActiveSpace: Bool, occluded: Bool) -> DisplayPauseConditions {
        guard isVisible else { return DisplayPauseConditions() }
        return DisplayPauseConditions(fullScreenApp: !onActiveSpace, occluded: onActiveSpace && occluded)
    }

    func startObservingPressure(_ onChange: @escaping @MainActor () -> Void) {
        guard memoryPressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let source = self.memoryPressureSource else { return }
                self.isMemoryCritical = source.data.contains(.critical)
                onChange()
            }
        }
        memoryPressureSource = source
        source.resume()
    }

    func stopObservingPressure() {
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
    }

    var isBatteryLow: Bool {
        guard let reading = Self.batteryReading() else { return false }
        return Self.isBatteryLow(onBattery: reading.onBattery, percent: reading.percent)
    }

    var isLowPowerModeEnabled: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    /// 当前由电池供电（拔掉电源）。台式 Mac 始终为 false。
    var isOnBatteryPower: Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue()
        else { return false }
        return (type as String) == kIOPSBatteryPowerValue
    }

    func startObservingPowerSource(_ onChange: @escaping @MainActor () -> Void) {
        guard powerSource == nil else { return }
        powerHandler = onChange
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let probe = Unmanaged<LiveSmartPauseProbe>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { probe.powerHandler?() }
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        powerSource = source
    }

    func stopObservingPowerSource() {
        if let powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes)
            CFRunLoopSourceInvalidate(powerSource)
        }
        powerSource = nil
        powerHandler = nil
    }

    // MARK: - 纯判断（可单独测试）

    nonisolated static func isBatteryLow(onBattery: Bool, percent: Int) -> Bool {
        onBattery && percent <= lowBatteryThreshold
    }

    /// 内置电池的供电状态与电量百分比；台式 Mac 没有内置电池时返回 nil。
    nonisolated static func batteryReading() -> (onBattery: Bool, percent: Int)? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?
                    .takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            else { continue }
            let onBattery = description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = description[kIOPSMaxCapacityKey] as? Int ?? 100
            guard maximum > 0 else { continue }
            return (onBattery, current * 100 / maximum)
        }
        return nil
    }

    deinit { memoryPressureSource?.cancel() }
}
