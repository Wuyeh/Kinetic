import Carbon.HIToolbox
import SwiftUI
import XCTest
@testable import Kinetic

@MainActor
final class GlobalShortcutTests: XCTestCase {
    private let commandOption = KeyShortcut.command | KeyShortcut.option

    func testShortcutsNeedCommandOptionOrControlAndShowLikeMenus() {
        XCTAssertTrue(KeyShortcut(keyCode: UInt16(kVK_ANSI_K), modifiers: KeyShortcut.control).isValid)
        XCTAssertFalse(KeyShortcut(keyCode: UInt16(kVK_ANSI_K), modifiers: KeyShortcut.shift).isValid, "shift alone types text")
        XCTAssertFalse(KeyShortcut(keyCode: UInt16(kVK_ANSI_K), modifiers: 0).isValid)
        let all = KeyShortcut(keyCode: UInt16(kVK_F5), modifiers: KeyShortcut.relevantModifiers | (1 << 23))
        XCTAssertEqual(all.modifiers, KeyShortcut.relevantModifiers, "only command, option, control and shift are kept")
        XCTAssertEqual(all.displayString, "⌃⌥⇧⌘F5")
        XCTAssertEqual(KeyShortcut(keyCode: UInt16(kVK_Space), modifiers: commandOption).displayString, "⌥⌘空格")
        let letter = KeyShortcut(keyCode: UInt16(kVK_ANSI_K), modifiers: commandOption).displayString
        XCTAssertTrue(letter.hasPrefix("⌥⌘")); XCTAssertFalse(letter.contains("键"), letter)
        XCTAssertEqual(GlobalShortcutCenter.carbonModifiers(commandOption), UInt32(cmdKey | optionKey))
    }

    func testDuplicatesAreFoundInListOrder() {
        let shortcut = KeyShortcut(keyCode: UInt16(kVK_ANSI_P), modifiers: commandOption)
        let value = [GlobalShortcutAction.reload.rawValue: shortcut, GlobalShortcutAction.playPauseAll.rawValue: shortcut,
                     GlobalShortcutAction.openSettings.rawValue: KeyShortcut(keyCode: UInt16(kVK_ANSI_O), modifiers: commandOption)]
        XCTAssertEqual(value.duplicateActions, [.reload], "the earlier action in the list keeps it")
        XCTAssertEqual(GlobalShortcutAction.allCases.count, 8)
    }

    func testSettingsKeepShortcutsAndReadOlderSettings() throws {
        var state = SettingsState()
        state.globalShortcuts = [GlobalShortcutAction.toggleAudio.rawValue: KeyShortcut(keyCode: UInt16(kVK_ANSI_M), modifiers: commandOption)]
        state.webMouseInteractionPaused = true
        let decoded = try JSONDecoder().decode(SettingsState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded, state)
        let older = try JSONDecoder().decode(SettingsState.self, from: Data(#"{"appearance":"dark"}"#.utf8))
        XCTAssertEqual(older.globalShortcuts, [:]); XCTAssertFalse(older.webMouseInteractionPaused)
        let messy = #"{"globalShortcuts":{"unknown":{"keyCode":1,"modifiers":1048576},"reload":{"keyCode":15,"modifiers":0}}}"#
        XCTAssertEqual(try JSONDecoder().decode(SettingsState.self, from: Data(messy.utf8)).globalShortcuts, [:],
                       "unknown actions and shortcuts without a modifier are dropped")
    }

    func testCenterRegistersOnlyUsableShortcutsAndDispatchesActions() {
        let suite = "Kinetic.Shortcuts.Tests." + UUID().uuidString
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        let center = GlobalShortcutCenter()
        defer { center.shutdown() }
        var fired: [GlobalShortcutAction] = []
        center.handler = { fired.append($0) }
        // An unlikely combination, so the test never takes one Wu uses.
        let rare = KeyShortcut(keyCode: UInt16(kVK_F19), modifiers: KeyShortcut.relevantModifiers)
        settings.set(\.globalShortcuts, to: [GlobalShortcutAction.reload.rawValue: rare])
        center.start(settings: settings)
        XCTAssertTrue(center.unavailable.isEmpty)
        center.fire(id: UInt32(GlobalShortcutAction.allCases.firstIndex(of: .reload)!))
        XCTAssertEqual(fired, [.reload])
        center.suspend()
        center.fire(id: 0)
        XCTAssertEqual(fired, [.reload], "nothing fires while a shortcut is being recorded")
        center.resume()
        center.fire(id: 99)
        XCTAssertEqual(fired, [.reload])
    }

    /// Offscreen PNGs of Settings › 快捷键 with two shortcuts and a duplicate, light and dark.
    func testShortcutSettingsSnapshots() throws {
        let suite = "Kinetic.Shortcuts.Snapshot." + UUID().uuidString
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        let shared = KeyShortcut(keyCode: UInt16(kVK_ANSI_P), modifiers: commandOption)
        settings.set(\.globalShortcuts, to: [GlobalShortcutAction.playPauseAll.rawValue: shared,
                                             GlobalShortcutAction.reload.rawValue: shared,
                                             GlobalShortcutAction.nextWallpaper.rawValue: KeyShortcut(keyCode: UInt16(kVK_RightArrow), modifiers: commandOption | KeyShortcut.control)])
        let view = GlobalShortcutSettingsView(settings: settings, center: GlobalShortcutCenter()).padding(28)
        let size = CGSize(width: 628, height: 560)
        try R4SnapshotTests.render(view, size: size, name: "module49-shortcuts")
        try R4SnapshotTests.render(view, size: size, name: "module49-shortcuts-dark", appearance: .darkAqua)
    }
}
