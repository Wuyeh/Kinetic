enum AppearanceMode: String, Codable, CaseIterable, Sendable {
    case system
    case light
    case dark
}

/// 仅定义全局设置与规格默认值；持久化、系统副作用及 UI 绑定留给后续模块。
struct SettingsState: Codable, Equatable, Sendable {
    var appearance: AppearanceMode = .system
    var launchAtLoginEnabled: Bool = false
    var wallpaperAudioEnabled: Bool = false
    var smartPauseEnabled: Bool = true
    var webNetworkAccessEnabled: Bool = true
    /// 用户补充（Module 18 之后）：开启 macOS 低电量模式时自动暂停。独立于「智能暂停」，默认开。
    var pauseInLowPowerMode: Bool = true
    /// 用户补充（Module 18 之后）：使用电池供电时自动暂停。独立于「智能暂停」，默认关。
    var pauseOnBatteryPower: Bool = false
    var pauseWhenFullScreen: Bool = true
    var pauseWhenOccluded: Bool = false
    /// Bundle IDs only; exceptions affect fullscreen / occlusion, never safety or power rules.
    var smartPauseExcludedApps: [String] = []

    init() {}

    private enum CodingKeys: String, CodingKey {
        case appearance, launchAtLoginEnabled, wallpaperAudioEnabled, smartPauseEnabled,
             webNetworkAccessEnabled, pauseInLowPowerMode, pauseOnBatteryPower,
             pauseWhenFullScreen, pauseWhenOccluded, smartPauseExcludedApps
    }

    /// 缺少的键使用默认值：旧版本保存的设置在新增选项后仍能完整读取，不会整体回退为默认值。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SettingsState()
        appearance = try container.decodeIfPresent(AppearanceMode.self, forKey: .appearance) ?? defaults.appearance
        launchAtLoginEnabled = try container.decodeIfPresent(Bool.self, forKey: .launchAtLoginEnabled)
            ?? defaults.launchAtLoginEnabled
        wallpaperAudioEnabled = try container.decodeIfPresent(Bool.self, forKey: .wallpaperAudioEnabled)
            ?? defaults.wallpaperAudioEnabled
        smartPauseEnabled = try container.decodeIfPresent(Bool.self, forKey: .smartPauseEnabled)
            ?? defaults.smartPauseEnabled
        webNetworkAccessEnabled = try container.decodeIfPresent(Bool.self, forKey: .webNetworkAccessEnabled)
            ?? defaults.webNetworkAccessEnabled
        pauseInLowPowerMode = try container.decodeIfPresent(Bool.self, forKey: .pauseInLowPowerMode)
            ?? defaults.pauseInLowPowerMode
        pauseOnBatteryPower = try container.decodeIfPresent(Bool.self, forKey: .pauseOnBatteryPower)
            ?? defaults.pauseOnBatteryPower
        pauseWhenFullScreen = try container.decodeIfPresent(Bool.self, forKey: .pauseWhenFullScreen)
            ?? defaults.pauseWhenFullScreen
        pauseWhenOccluded = try container.decodeIfPresent(Bool.self, forKey: .pauseWhenOccluded)
            ?? defaults.pauseWhenOccluded
        smartPauseExcludedApps = try container.decodeIfPresent([String].self, forKey: .smartPauseExcludedApps)
            ?? defaults.smartPauseExcludedApps
    }
}
