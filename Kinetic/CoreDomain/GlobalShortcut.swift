import Foundation

/// Module 49: the actions a global shortcut can run (规格 35).
enum GlobalShortcutAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case playPauseAll, nextWallpaper, previousWallpaper, toggleAudio, toggleMouseInteraction, showHide, reload, openSettings

    var id: String { rawValue }
    var title: String {
        switch self {
        case .playPauseAll: return "暂停 / 继续全部"
        case .nextWallpaper: return "下一张壁纸"
        case .previousWallpaper: return "上一张壁纸"
        case .toggleAudio: return "壁纸声音开关"
        case .toggleMouseInteraction: return "网页壁纸鼠标交互开关"
        case .showHide: return "显示 / 隐藏 Kinetic"
        case .reload: return "重新载入壁纸"
        case .openSettings: return "打开设置"
        }
    }
}

/// A key with its modifiers. `modifiers` keeps the raw values of NSEvent.ModifierFlags
/// (command, option, control, shift) so the model stays free of AppKit.
struct KeyShortcut: Codable, Equatable, Hashable, Sendable {
    static let command: UInt = 1 << 20, option: UInt = 1 << 19, control: UInt = 1 << 18, shift: UInt = 1 << 17
    static let relevantModifiers = command | option | control | shift

    var keyCode: UInt16
    var modifiers: UInt

    init(keyCode: UInt16, modifiers: UInt) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.relevantModifiers
    }

    /// Shift alone is not enough: a global shortcut must not swallow ordinary typing.
    var isValid: Bool { modifiers & (Self.command | Self.option | Self.control) != 0 && keyCode < 0x80 }

    /// ⌃⌥⇧⌘, in the order macOS menus show them.
    var modifierSymbols: String {
        (modifiers & Self.control != 0 ? "⌃" : "") + (modifiers & Self.option != 0 ? "⌥" : "")
            + (modifiers & Self.shift != 0 ? "⇧" : "") + (modifiers & Self.command != 0 ? "⌘" : "")
    }
}

extension Dictionary where Key == String, Value == KeyShortcut {
    /// Actions sharing a shortcut with an earlier action in the list.
    var duplicateActions: Set<GlobalShortcutAction> {
        var seen = Set<KeyShortcut>(), duplicates = Set<GlobalShortcutAction>()
        for action in GlobalShortcutAction.allCases {
            guard let shortcut = self[action.rawValue] else { continue }
            if !seen.insert(shortcut).inserted { duplicates.insert(action) }
        }
        return duplicates
    }
}
