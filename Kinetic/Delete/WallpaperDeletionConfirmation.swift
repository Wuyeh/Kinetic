import AppKit
import SwiftUI

/// 删除确认弹窗。只有用户点「删除」才会删除；回车不会触发任何按钮，Esc 取消，初始焦点在「取消」。
@MainActor
enum WallpaperDeletionConfirmation {
    static func makeAlert(for wallpaper: Wallpaper) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(format: NSLocalizedString("delete.confirm.title", comment: ""), wallpaper.name)
        alert.informativeText = NSLocalizedString("delete.confirm.message", comment: "")
        let cancel = alert.addButton(withTitle: NSLocalizedString("delete.confirm.cancel", comment: ""))
        let delete = alert.addButton(withTitle: NSLocalizedString("delete.confirm.delete", comment: ""))
        // 两个按钮都不是默认按钮：「取消」保持透明样式，危险动作不会被回车误触。
        cancel.keyEquivalent = "\u{1b}"
        delete.keyEquivalent = ""
        delete.hasDestructiveAction = true
        alert.window.initialFirstResponder = cancel
        return alert
    }

    static func isDeleteResponse(_ response: NSApplication.ModalResponse) -> Bool {
        response == .alertSecondButtonReturn
    }

    /// 以窗口表单显示；没有可用窗口时退回 App 级弹窗。
    static func present(for wallpaper: Wallpaper, in window: NSWindow?,
                        completion: @escaping @MainActor (Bool) -> Void) {
        let alert = makeAlert(for: wallpaper)
        guard let window, window.isVisible, window.attachedSheet == nil else {
            completion(isDeleteResponse(alert.runModal()))
            return
        }
        alert.beginSheetModal(for: window) { response in
            completion(isDeleteResponse(response))
        }
    }
}

/// 主窗口的弱引用，供删除确认以表单方式显示。
@MainActor
final class LibraryWindowReference {
    weak var window: NSWindow?
}

/// Backspace（或 Delete）请求删除当前选中的壁纸。
/// 文字输入框正在编辑、窗口已有表单或不是当前窗口时不拦截按键。
struct DeleteKeyHandler: NSViewRepresentable {
    let isEnabled: Bool
    let windowReference: LibraryWindowReference
    let action: () -> Void

    func makeNSView(context: Context) -> DeleteKeyHandlerView {
        let view = DeleteKeyHandlerView()
        update(view)
        return view
    }

    func updateNSView(_ view: DeleteKeyHandlerView, context: Context) {
        update(view)
    }

    static func dismantleNSView(_ view: DeleteKeyHandlerView, coordinator: ()) {
        view.stopMonitoring()
    }

    private func update(_ view: DeleteKeyHandlerView) {
        view.isEnabled = isEnabled
        view.action = action
        view.windowReference = windowReference
        windowReference.window = view.window
    }
}

@MainActor
final class DeleteKeyHandlerView: NSView {
    var isEnabled = false
    var action: () -> Void = {}
    weak var windowReference: LibraryWindowReference?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowReference?.window = window
        if window == nil { stopMonitoring() } else { startMonitoring() }
    }

    func startMonitoring() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.shouldHandle(event) else { return event }
            self.action()
            return nil
        }
    }

    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    func shouldHandle(_ event: NSEvent) -> Bool {
        guard isEnabled, let window, event.window === window, window.isKeyWindow,
              window.attachedSheet == nil else { return false }
        guard Self.isDeleteKey(event.keyCode, modifiers: event.modifierFlags) else { return false }
        return !(window.firstResponder is NSText)
    }

    /// Backspace = keyCode 51，Forward Delete = 117；不带 ⌘ / ⌥ / ⌃ / ⇧。
    nonisolated static func isDeleteKey(_ keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        (keyCode == 51 || keyCode == 117)
            && modifiers.intersection([.command, .option, .control, .shift]).isEmpty
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}
