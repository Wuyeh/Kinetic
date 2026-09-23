enum AppearanceMode: String, Codable, CaseIterable, Sendable {
    case system
    case light
    case dark
}

/// 仅定义全局设置与默认值，不包含持久化、系统副作用或 UI 绑定。
struct SettingsState: Codable, Equatable, Sendable {
    var appearance: AppearanceMode = .system
    var launchAtLoginEnabled: Bool = false
    var wallpaperAudioEnabled: Bool = false
    var smartPauseEnabled: Bool = true
    var webNetworkAccessEnabled: Bool = true
}
