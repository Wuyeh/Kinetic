import Combine
import Foundation

/// Module 17 的唯一设置存储。状态模型保持纯粹，系统副作用由各模块读取后执行。
@MainActor
final class SettingsStore: ObservableObject {
    static let storageKey = "Kinetic.Settings.v1"
    /// 2026-10-07：旧版本曾默认关闭两个年龄过滤；仅首次采用新默认值时更新一次。
    static let steamAgeRatingDefaultsKey = "Kinetic.Settings.SteamAgeRatingDefaults.v1"

    @Published private(set) var state: SettingsState
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode(SettingsState.self, from: data) {
            state = saved
        } else {
            state = SettingsState()
        }

        // 只更新这两个开关；完成后保留用户之后的手动选择，不能每次启动强制开启。
        if !defaults.bool(forKey: Self.steamAgeRatingDefaultsKey) {
            var updated = state
            updated.steamHideQuestionable = true
            updated.steamHideMature = true
            if let data = try? JSONEncoder().encode(updated) {
                defaults.set(data, forKey: Self.storageKey)
                defaults.set(true, forKey: Self.steamAgeRatingDefaultsKey)
                state = updated
            }
        }
    }

    /// Module 50: settings restored from a backup at launch replace the whole state.
    func replace(with value: SettingsState) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: Self.storageKey)
        state = value
    }

    func set<Value: Equatable>(_ keyPath: WritableKeyPath<SettingsState, Value>, to value: Value) {
        guard state[keyPath: keyPath] != value else { return }
        var updated = state
        updated[keyPath: keyPath] = value
        guard let data = try? JSONEncoder().encode(updated) else { return }
        defaults.set(data, forKey: Self.storageKey)
        state = updated
    }
}
