import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

/// Module 49：系统级快捷键。使用公开的 Carbon `RegisterEventHotKey`：不需要辅助功能权限、不监听其他按键，
/// 只在按下已登记的组合键时收到事件。设置改变时整体重新登记；录入新快捷键期间暂停全部快捷键。
@MainActor
final class GlobalShortcutCenter: ObservableObject {
    /// 已设置但系统不让登记的动作（通常是其他程序已占用这个组合键）。
    @Published private(set) var unavailable: Set<GlobalShortcutAction> = []
    var handler: ((GlobalShortcutAction) -> Void)?

    private var registered: [GlobalShortcutAction: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    private var shortcuts: [String: KeyShortcut] = [:]
    private var suspended = false
    private var subscription: AnyCancellable?
    private static let signature: OSType = 0x4B4E5443 // "KNTC"

    init() {}

    /// 跟随设置；首次调用时安装事件处理。
    func start(settings: SettingsStore) {
        installHandlerIfNeeded()
        subscription = settings.$state.map(\.globalShortcuts).removeDuplicates().sink { [weak self] value in
            self?.shortcuts = value
            self?.registerAll()
        }
    }

    func suspend() { suspended = true; unregisterAll() }
    func resume() { suspended = false; registerAll() }

    func shutdown() {
        subscription = nil
        unregisterAll()
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
    }

    func fire(id: UInt32) {
        guard !suspended, let action = GlobalShortcutAction.allCases.indices.contains(Int(id))
                ? GlobalShortcutAction.allCases[Int(id)] : nil else { return }
        handler?(action)
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var hotKey = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            guard status == noErr, hotKey.signature == GlobalShortcutCenter.signature else { return OSStatus(eventNotHandledErr) }
            let center = Unmanaged<GlobalShortcutCenter>.fromOpaque(context).takeUnretainedValue()
            let id = hotKey.id
            DispatchQueue.main.async { MainActor.assumeIsolated { center.fire(id: id) } }
            return noErr
        }, 1, &type, context, &eventHandler)
    }

    private func registerAll() {
        unregisterAll()
        guard !suspended else { return }
        var failed = Set<GlobalShortcutAction>()
        let duplicates = shortcuts.duplicateActions
        for (index, action) in GlobalShortcutAction.allCases.enumerated() {
            guard let shortcut = shortcuts[action.rawValue], shortcut.isValid, !duplicates.contains(action) else { continue }
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(shortcut.keyCode), Self.carbonModifiers(shortcut.modifiers),
                                             EventHotKeyID(signature: Self.signature, id: UInt32(index)),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { registered[action] = ref } else { failed.insert(action) }
        }
        if unavailable != failed { unavailable = failed }
    }

    private func unregisterAll() {
        for ref in registered.values { UnregisterEventHotKey(ref) }
        registered = [:]
    }

    static func carbonModifiers(_ modifiers: UInt) -> UInt32 {
        var value: UInt32 = 0
        if modifiers & KeyShortcut.command != 0 { value |= UInt32(cmdKey) }
        if modifiers & KeyShortcut.option != 0 { value |= UInt32(optionKey) }
        if modifiers & KeyShortcut.control != 0 { value |= UInt32(controlKey) }
        if modifiers & KeyShortcut.shift != 0 { value |= UInt32(shiftKey) }
        return value
    }
}

extension KeyShortcut {
    /// "⌃⌥K" — the key as the current keyboard layout prints it.
    var displayString: String { modifierSymbols + Self.keyName(keyCode) }

    static func keyName(_ code: UInt16) -> String {
        let special: [Int: String] = [
            kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "空格", kVK_Delete: "⌫", kVK_Escape: "⎋", kVK_ForwardDelete: "⌦",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
            kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
            kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19"]
        if let name = special[Int(code)] { return name }
        if let character = translated(code), !character.isEmpty { return character.uppercased() }
        return "键 \(code)"
    }

    private static func translated(_ code: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> String? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeys: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count, &length, &characters)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: characters, count: length)
        }
    }
}

/// Settings › 快捷键：每个动作一行，点按后按下组合键录入。Esc 取消，Delete 清除。
@MainActor
struct GlobalShortcutSettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var center: GlobalShortcutCenter
    @State private var recording: GlobalShortcutAction?
    @State private var hint: String?
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("为常用操作设置全局快捷键，在任何程序里都能使用。默认没有设置。").foregroundStyle(.secondary)
            let shortcuts = settings.state.globalShortcuts
            let duplicates = shortcuts.duplicateActions
            ForEach(GlobalShortcutAction.allCases) { action in
                HStack(spacing: 10) {
                    Text(action.title).frame(maxWidth: .infinity, alignment: .leading)
                    Button { toggleRecording(action) } label: {
                        Text(label(for: action, shortcut: shortcuts[action.rawValue]))
                            .monospacedDigit()
                            .foregroundStyle(recording == action ? AnyShapeStyle(MainWindowDesignTokens.accent)
                                             : shortcuts[action.rawValue] == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                            .frame(minWidth: 120)
                    }
                    .kineticGlassButton()
                    .accessibilityLabel(action.title + "快捷键")
                    Button { clear(action) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).help("清除")
                        .opacity(shortcuts[action.rawValue] == nil ? 0 : 1)
                        .disabled(shortcuts[action.rawValue] == nil)
                        .accessibilityLabel("清除" + action.title + "快捷键")
                }
                if duplicates.contains(action) {
                    Text("与其他操作的快捷键相同，未启用。").font(.caption).foregroundStyle(.red)
                } else if center.unavailable.contains(action) {
                    Text("这个组合键已被系统或其他程序占用，请换一个。").font(.caption).foregroundStyle(.red)
                }
            }
            if let hint { Text(hint).font(.caption).foregroundStyle(.red) }
            Text("快捷键需要包含 ⌘、⌥ 或 ⌃。录入时按 Esc 取消，按 Delete 清除。")
                .font(.caption).foregroundStyle(.secondary)
            Text("「下一张 / 上一张壁纸」作用于正在轮播壁纸列表的显示器；「网页壁纸鼠标交互开关」只影响开启了鼠标移动交互的网页壁纸。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onDisappear { stopRecording() }
    }

    private func label(for action: GlobalShortcutAction, shortcut: KeyShortcut?) -> String {
        if recording == action { return "请按组合键…" }
        return shortcut?.displayString ?? "未设置"
    }

    private func toggleRecording(_ action: GlobalShortcutAction) {
        if recording == action { stopRecording(); return }
        stopRecording()
        recording = action
        hint = nil
        center.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { handle(event) }
            return nil
        }
    }

    private func handle(_ event: NSEvent) {
        guard let action = recording else { return }
        switch Int(event.keyCode) {
        case kVK_Escape: stopRecording(); return
        case kVK_Delete, kVK_ForwardDelete:
            if event.modifierFlags.intersection([.command, .option, .control]).isEmpty { clear(action); stopRecording(); return }
        default: break
        }
        let shortcut = KeyShortcut(keyCode: event.keyCode, modifiers: event.modifierFlags.rawValue)
        guard shortcut.isValid else { hint = "需要包含 ⌘、⌥ 或 ⌃。"; NSSound.beep(); return }
        var next = settings.state.globalShortcuts
        next[action.rawValue] = shortcut
        settings.set(\.globalShortcuts, to: next)
        stopRecording()
    }

    private func clear(_ action: GlobalShortcutAction) {
        var next = settings.state.globalShortcuts
        next[action.rawValue] = nil
        settings.set(\.globalShortcuts, to: next)
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording != nil { recording = nil; center.resume() }
    }
}
