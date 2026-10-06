import Combine
import Foundation

/// Module 17 的唯一设置存储。状态模型保持纯粹，系统副作用由各模块读取后执行。
@MainActor
final class SettingsStore: ObservableObject {
    static let storageKey = "Kinetic.Settings.v1"

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
