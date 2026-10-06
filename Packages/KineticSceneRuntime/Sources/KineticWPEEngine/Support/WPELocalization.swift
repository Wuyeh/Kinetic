import Foundation

extension Bundle {
    /// Upstream resolves engine messages through the app's language bundle. The engine's own
    /// strings are not localized in Kinetic: the key (English) is returned and Kinetic's adapter
    /// maps user-facing failures to its zh-Hans text.
    static var appLanguage: Bundle { Bundle.main }
}
