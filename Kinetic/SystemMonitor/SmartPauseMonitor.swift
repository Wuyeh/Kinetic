import AppKit

/// 全局系统条件。Module 26 将强制系统保护与可配置策略分开；Manual Pause 仍由状态机保证优先。
struct SmartPauseConditions: Equatable, Sendable {
    /// 全屏 App 占据主显示器，桌面壁纸窗口完全不可见。
    var fullScreenApp = false
    var screenLocked = false
    var displayAsleep = false
    var systemAsleep = false
    var batteryLow = false
    /// 用户补充的电源条件，各自由「通用」中的开关控制，与「智能暂停」无关。
    var lowPowerMode = false
    var onBatteryPower = false
    var criticalThermal = false
    var criticalMemory = false

}

/// 三个互相独立的设置开关：「智能暂停」（播放）、「低电量模式时暂停」与「使用电池时暂停」（通用）。
struct SmartPausePreferences: Equatable, Sendable {
    var smartPause = true
    var lowPowerMode = true
    var batteryPower = false
    var fullScreen = true
    var occlusion = false
    var excludedApps = Set<String>()

    init(smartPause: Bool = true, lowPowerMode: Bool = true, batteryPower: Bool = false) {
        self.smartPause = smartPause
        self.lowPowerMode = lowPowerMode
        self.batteryPower = batteryPower
    }

    init(settings: SettingsState) {
        self.init(smartPause: settings.smartPauseEnabled,
                  lowPowerMode: settings.pauseInLowPowerMode,
                  batteryPower: settings.pauseOnBatteryPower)
        fullScreen = settings.pauseWhenFullScreen
        occlusion = settings.pauseWhenOccluded
        excludedApps = Set(settings.smartPauseExcludedApps)
    }

    func shouldPause(_ conditions: SmartPauseConditions) -> Bool {
        !reasons(for: conditions).isEmpty
    }
}

/// 可即时查询的系统状态与电源变化通知；真实实现是 `LiveSmartPauseProbe`，测试注入替身。
@MainActor
protocol SmartPauseSystemProbe: AnyObject {
    var isScreenLocked: Bool { get }
    var isDisplayAsleep: Bool { get }
    var isFullScreenAppActive: Bool { get }
    var isBatteryLow: Bool { get }
    var isLowPowerModeEnabled: Bool { get }
    var isOnBatteryPower: Bool { get }
    var isThermalCritical: Bool { get }
    var isMemoryCritical: Bool { get }
    func displayConditions(for displays: [DisplayID]) -> [DisplayID: DisplayPauseConditions]
    func startObservingPressure(_ onChange: @escaping @MainActor () -> Void)
    func stopObservingPressure()
    func startObservingPowerSource(_ onChange: @escaping @MainActor () -> Void)
    func stopObservingPowerSource()
}

extension SmartPauseSystemProbe {
    var isThermalCritical: Bool { false }
    var isMemoryCritical: Bool { false }
    func displayConditions(for displays: [DisplayID]) -> [DisplayID: DisplayPauseConditions] { [:] }
    func startObservingPressure(_ onChange: @escaping @MainActor () -> Void) {}
    func stopObservingPressure() {}
}

/// Module 26：全局安全条件和单屏可见性通过唯一 Runtime 提交；不操作 Renderer 或用户播放意图。
@MainActor
final class SmartPauseMonitor: ObservableObject {
    static let screenLockedNotification = Notification.Name("com.apple.screenIsLocked")
    static let screenUnlockedNotification = Notification.Name("com.apple.screenIsUnlocked")
    /// 有条件成立时定期复查可查询的状态，避免漏掉某个结束通知后一直停在暂停。
    static let recheckInterval: TimeInterval = 5

    @Published private(set) var conditions = SmartPauseConditions()
    @Published private(set) var globalReasons = Set<SmartPauseReason>()
    @Published private(set) var displayReasons: [DisplayID: Set<SmartPauseReason>] = [:]
    private var displayIDs: [DisplayID] = []
    private var perDisplayConditions: [DisplayID: DisplayPauseConditions] = [:]
    private let usesPerDisplayPolicy: Bool
    private let onDisplayChange: @MainActor (Bool, [DisplayID: Bool]) -> Void
    private var publishedDisplayFlags: [DisplayID: Bool] = [:]
    /// 配置修改后立即使用已观测条件重算；系统保护不能关闭。
    var preferences = SmartPausePreferences() {
        didSet { if oldValue != preferences { publish() } }
    }
    /// 当前交给 Runtime 的值。
    private(set) var isSmartPauseActive = false

    private let probe: SmartPauseSystemProbe
    private let workspaceNotifications: NotificationCenter
    private let distributedNotifications: NotificationCenter
    private let applicationNotifications: NotificationCenter
    private let desktopWindowIdentifier: NSUserInterfaceItemIdentifier
    private let fullScreenSettleDelay: TimeInterval
    private let onChange: @MainActor (Bool) -> Void
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var pendingFullScreenCheck: DispatchWorkItem?
    private var recheckTimer: Timer?
    private(set) var isRunning = false

    init(
        probe: SmartPauseSystemProbe,
        workspaceNotifications: NotificationCenter,
        distributedNotifications: NotificationCenter,
        applicationNotifications: NotificationCenter,
        desktopWindowIdentifier: NSUserInterfaceItemIdentifier,
        fullScreenSettleDelay: TimeInterval = 0.8,
        usesPerDisplayPolicy: Bool = false,
        onDisplayChange: @escaping @MainActor (Bool, [DisplayID: Bool]) -> Void = { _, _ in },
        onChange: @escaping @MainActor (Bool) -> Void
    ) {
        self.probe = probe
        self.workspaceNotifications = workspaceNotifications
        self.distributedNotifications = distributedNotifications
        self.applicationNotifications = applicationNotifications
        self.desktopWindowIdentifier = desktopWindowIdentifier
        self.fullScreenSettleDelay = fullScreenSettleDelay
        self.usesPerDisplayPolicy = usesPerDisplayPolicy
        self.onDisplayChange = onDisplayChange
        self.onChange = onChange
    }

    static func live(runtime: WallpaperRuntimeManager) -> SmartPauseMonitor {
        SmartPauseMonitor(
            probe: LiveSmartPauseProbe(desktopWindowIdentifier: AppDelegate.desktopWallpaperWindowIdentifier),
            workspaceNotifications: NSWorkspace.shared.notificationCenter,
            distributedNotifications: DistributedNotificationCenter.default(), applicationNotifications: .default,
            desktopWindowIdentifier: AppDelegate.desktopWallpaperWindowIdentifier,
            usesPerDisplayPolicy: true,
            onDisplayChange: { [weak runtime] global, displays in runtime?.setSmartPausePolicy(global: global, displays: displays) },
            onChange: { _ in })
    }

    func updateDisplays(_ ids: [DisplayID]) {
        guard displayIDs != ids else { return }
        displayIDs = ids
        if isRunning { refreshQueryableConditions() }
    }

    static func live(onChange: @escaping @MainActor (Bool) -> Void) -> SmartPauseMonitor {
        SmartPauseMonitor(
            probe: LiveSmartPauseProbe(desktopWindowIdentifier: AppDelegate.desktopWallpaperWindowIdentifier),
            workspaceNotifications: NSWorkspace.shared.notificationCenter,
            distributedNotifications: DistributedNotificationCenter.default(),
            applicationNotifications: .default,
            desktopWindowIdentifier: AppDelegate.desktopWallpaperWindowIdentifier,
            onChange: onChange
        )
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true

        // Mac 睡眠：只在 willSleep 与 didWake 之间成立。
        observe(workspaceNotifications, NSWorkspace.willSleepNotification) { $0.update { $0.systemAsleep = true } }
        // 醒来时在同一次更新里重新读取其他条件：醒来直接进入锁屏时不能先继续再暂停。
        observe(workspaceNotifications, NSWorkspace.didWakeNotification) {
            $0.refreshQueryableConditions { $0.systemAsleep = false }
        }
        // 显示器睡眠。
        observe(workspaceNotifications, NSWorkspace.screensDidSleepNotification) { $0.update { $0.displayAsleep = true } }
        observe(workspaceNotifications, NSWorkspace.screensDidWakeNotification) {
            $0.refreshLockAndFullScreen { $0.displayAsleep = false }
        }
        // 锁屏；切换到其他用户时桌面同样不可见，按锁屏处理。
        observe(distributedNotifications, Self.screenLockedNotification) { $0.update { $0.screenLocked = true } }
        observe(distributedNotifications, Self.screenUnlockedNotification) { $0.update { $0.screenLocked = false } }
        observe(workspaceNotifications, NSWorkspace.sessionDidResignActiveNotification) { $0.update { $0.screenLocked = true } }
        observe(workspaceNotifications, NSWorkspace.sessionDidBecomeActiveNotification) { $0.refreshLockAndFullScreen() }
        // 全屏 App：壁纸窗口的遮挡状态随之变化；进入 / 退出全屏会切换 Space，动画结束后再确认一次。
        observeDesktopWindow(NSWindow.didChangeOcclusionStateNotification) { monitor in
            monitor.update { $0.fullScreenApp = monitor.probe.isFullScreenAppActive }
        }
        observeDesktopWindow(NSWindow.willCloseNotification) { monitor in
            monitor.update { $0.fullScreenApp = false }
            // willClose arrives before the window disappears from NSApp.windows.
            if monitor.usesPerDisplayPolicy {
                DispatchQueue.main.async { [weak monitor] in
                    guard let monitor, monitor.isRunning else { return }
                    monitor.refreshQueryableConditions()
                }
            }
        }
        observe(workspaceNotifications, NSWorkspace.activeSpaceDidChangeNotification) {
            $0.refreshFullScreenNowAndAfterSettling()
        }
        observe(applicationNotifications, NSApplication.didChangeScreenParametersNotification) {
            $0.refreshFullScreenNowAndAfterSettling()
        }
        observe(workspaceNotifications, NSWorkspace.didActivateApplicationNotification) {
            $0.refreshFullScreenNowAndAfterSettling()
        }
        // Read before registering, as required by ProcessInfo's thermal notification contract.
        _ = probe.isThermalCritical
        observe(applicationNotifications, ProcessInfo.thermalStateDidChangeNotification) { $0.refreshQueryableConditions() }
        probe.startObservingPressure { [weak self] in
            guard let self, self.isRunning else { return }
            self.refreshQueryableConditions()
        }
        // 低电量、接上 / 拔掉电源。
        probe.startObservingPowerSource { [weak self] in
            guard let self, self.isRunning else { return }
            self.update {
                $0.batteryLow = self.probe.isBatteryLow
                $0.onBatteryPower = self.probe.isOnBatteryPower
            }
        }
        // macOS 低电量模式。
        observe(applicationNotifications, .NSProcessInfoPowerStateDidChange) { monitor in
            monitor.update { $0.lowPowerMode = monitor.probe.isLowPowerModeEnabled }
        }

        refreshQueryableConditions()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        observers.forEach { center, token in center.removeObserver(token) }
        observers = []
        pendingFullScreenCheck?.cancel()
        pendingFullScreenCheck = nil
        recheckTimer?.invalidate()
        recheckTimer = nil
        probe.stopObservingPowerSource()
        probe.stopObservingPressure()
    }

    /// 重新读取可查询的条件（锁屏、显示器睡眠、全屏 App、低电量）。Mac 睡眠只由通知决定。
    /// `also` 中的修改与读取结果合并为一次更新，避免中间状态造成一次多余的继续 / 暂停。
    func refreshQueryableConditions(also change: (inout SmartPauseConditions) -> Void = { _ in }) {
        update {
            change(&$0)
            $0.screenLocked = probe.isScreenLocked
            $0.displayAsleep = probe.isDisplayAsleep
            $0.fullScreenApp = probe.isFullScreenAppActive
            $0.batteryLow = probe.isBatteryLow
            $0.lowPowerMode = probe.isLowPowerModeEnabled
            $0.onBatteryPower = probe.isOnBatteryPower
            $0.criticalThermal = probe.isThermalCritical
            $0.criticalMemory = probe.isMemoryCritical
        }
    }

    // MARK: - 内部

    private func refreshLockAndFullScreen(also change: (inout SmartPauseConditions) -> Void = { _ in }) {
        update {
            change(&$0)
            $0.screenLocked = probe.isScreenLocked
            $0.fullScreenApp = probe.isFullScreenAppActive
        }
    }

    private func refreshFullScreenNowAndAfterSettling() {
        update { $0.fullScreenApp = probe.isFullScreenAppActive }
        pendingFullScreenCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                self.update { $0.fullScreenApp = self.probe.isFullScreenAppActive }
            }
        }
        pendingFullScreenCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + fullScreenSettleDelay, execute: work)
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ handler: @escaping @MainActor @Sendable (SmartPauseMonitor) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                handler(self)
            }
        }
        observers.append((center, token))
    }

    /// 只关心 Kinetic 自己的桌面壁纸窗口（它随壁纸启用 / 停止而创建、关闭）。
    private func observeDesktopWindow(_ name: Notification.Name,
                                      _ handler: @escaping @MainActor @Sendable (SmartPauseMonitor) -> Void) {
        let identifier = desktopWindowIdentifier
        let token = applicationNotifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, self.isRunning,
                      let windowID = (note.object as? NSWindow)?.identifier,
                      windowID == identifier || windowID.rawValue.hasPrefix(identifier.rawValue + ".") else { return }
                handler(self)
            }
        }
        observers.append((applicationNotifications, token))
    }

    private func update(_ change: (inout SmartPauseConditions) -> Void) {
        var next = conditions
        change(&next)
        if usesPerDisplayPolicy { next.fullScreenApp = false }
        if next != conditions { conditions = next }
        if usesPerDisplayPolicy { perDisplayConditions = probe.displayConditions(for: displayIDs) }
        publish()
    }

    private func publish() {
        let reasons = preferences.reasons(for: conditions)
        if globalReasons != reasons { globalReasons = reasons }
        let individual = Dictionary(uniqueKeysWithValues: displayIDs.map {
            ($0, preferences.reasons(for: perDisplayConditions[$0] ?? DisplayPauseConditions()))
        })
        let combined = individual.mapValues { $0.union(reasons) }
        if displayReasons != combined { displayReasons = combined }
        let active = !reasons.isEmpty
        let flags = individual.mapValues { !$0.isEmpty }
        let globalChanged = active != isSmartPauseActive
        if globalChanged {
            isSmartPauseActive = active
            onChange(active)
        }
        if usesPerDisplayPolicy, globalChanged || flags != publishedDisplayFlags {
            publishedDisplayFlags = flags
            onDisplayChange(active, flags)
        }
        updateRecheckTimer()
    }

    private func updateRecheckTimer() {
        // 只在确实暂停着时复查（例如整天用电池时也只是低频、容忍度较大的检查）。
        let needsRecheck = isRunning && (isSmartPauseActive || publishedDisplayFlags.values.contains(true)) && !conditions.systemAsleep
        if needsRecheck, recheckTimer == nil {
            let timer = Timer(timeInterval: Self.recheckInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshQueryableConditions() }
            }
            timer.tolerance = 1
            RunLoop.main.add(timer, forMode: .common)
            recheckTimer = timer
        } else if !needsRecheck {
            recheckTimer?.invalidate()
            recheckTimer = nil
        }
    }

    deinit {
        observers.forEach { center, token in center.removeObserver(token) }
        recheckTimer?.invalidate()
    }
}
