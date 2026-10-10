enum AppearanceMode: String, Codable, CaseIterable, Sendable {
    case system
    case light
    case dark
}

/// 场景壁纸的画布比例与显示器不同时的显示方式（28.4，用户决定默认「自动」）。
enum SceneDisplayFitSetting: String, Codable, CaseIterable, Sendable {
    /// 比例接近时填满屏幕（与 Wallpaper Engine 一致，裁切少量边缘）；方向不同或裁切超过四分之一时完整显示。
    case automatic
    /// 始终填满屏幕，裁切多出的部分。
    case fill
    /// 始终完整显示，其余部分留边。
    case fit
    /// 用户在「自定义」窗口里选定显示的部分（CustomDisplayFrame）。只在显示器页按显示器、按壁纸使用，全局设置不提供。
    case custom
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
    /// 28.4：场景壁纸比例与显示器不同时的显示方式。
    var sceneDisplayFit: SceneDisplayFitSetting = .automatic
    /// 用户决定（2026-10-07）：默认隐藏这两个年龄分级；SettingsStore 一次性更新旧默认，之后保留手动选择。
    var steamHideQuestionable: Bool = true
    var steamHideMature: Bool = true
    /// Module 49：全局快捷键，键是 `GlobalShortcutAction.rawValue`；默认一个都不设。
    var globalShortcuts: [String: KeyShortcut] = [:]
    /// Module 49：暂停全部网页壁纸的鼠标移动交互（快捷键「网页壁纸鼠标交互开关」与设置 › 网页）。
    var webMouseInteractionPaused: Bool = false
    /// Module 51：用电池、低电量模式或机器偏热时降低场景 / 网页壁纸的帧率。默认开。
    var adaptiveFrameRateEnabled: Bool = true
    /// Module 53：把每台显示器的 macOS 系统壁纸换成 Kinetic 当前壁纸的静止画面。默认关；关闭时换回原来的系统壁纸。
    var systemWallpaperSyncEnabled: Bool = false
    /// Module 54：每天自动检查一次更新，有新版本时提示（下载安装由用户确认）。默认开。
    var automaticUpdateChecksEnabled: Bool = true

    init() {}

    private enum CodingKeys: String, CodingKey {
        case appearance, launchAtLoginEnabled, wallpaperAudioEnabled, smartPauseEnabled,
             webNetworkAccessEnabled, pauseInLowPowerMode, pauseOnBatteryPower,
             pauseWhenFullScreen, pauseWhenOccluded, smartPauseExcludedApps, sceneDisplayFit,
             steamHideQuestionable, steamHideMature, globalShortcuts, webMouseInteractionPaused,
             adaptiveFrameRateEnabled, systemWallpaperSyncEnabled, automaticUpdateChecksEnabled
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
        // 未知值（以后的版本写入的新选项）回到默认，不让整份设置读取失败。
        sceneDisplayFit = (try? container.decodeIfPresent(SceneDisplayFitSetting.self, forKey: .sceneDisplayFit))
            .flatMap { $0 } ?? defaults.sceneDisplayFit
        steamHideQuestionable = try container.decodeIfPresent(Bool.self, forKey: .steamHideQuestionable)
            ?? defaults.steamHideQuestionable
        steamHideMature = try container.decodeIfPresent(Bool.self, forKey: .steamHideMature) ?? defaults.steamHideMature
        // 无法识别的快捷键记录忽略，不影响其他设置。
        globalShortcuts = ((try? container.decodeIfPresent([String: KeyShortcut].self, forKey: .globalShortcuts)) ?? nil)?
            .filter { GlobalShortcutAction(rawValue: $0.key) != nil && $0.value.isValid } ?? defaults.globalShortcuts
        webMouseInteractionPaused = try container.decodeIfPresent(Bool.self, forKey: .webMouseInteractionPaused)
            ?? defaults.webMouseInteractionPaused
        adaptiveFrameRateEnabled = try container.decodeIfPresent(Bool.self, forKey: .adaptiveFrameRateEnabled)
            ?? defaults.adaptiveFrameRateEnabled
        systemWallpaperSyncEnabled = try container.decodeIfPresent(Bool.self, forKey: .systemWallpaperSyncEnabled)
            ?? defaults.systemWallpaperSyncEnabled
        automaticUpdateChecksEnabled = try container.decodeIfPresent(Bool.self, forKey: .automaticUpdateChecksEnabled)
            ?? defaults.automaticUpdateChecksEnabled
    }
}

extension SettingsState {
    /// Steam 页面要隐藏的年龄分级标签，沿用现有筛选器显式选择的例外。
    var steamHiddenAgeRatings: [String] {
        (steamHideQuestionable ? ["Questionable"] : []) + (steamHideMature ? ["Mature"] : [])
    }
}
