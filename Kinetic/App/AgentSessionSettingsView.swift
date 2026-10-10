import AppKit
import SwiftUI

/// The folders the Agent Session widget may read (Module 41). Nothing is granted by default.
/// Formerly in Settings › 叠加层; opened from the display page's overlay menu since 2026-10-08.
@MainActor
struct AgentSessionSettingsSection: View {
    @ObservedObject var service: AgentSessionService
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("agentSessions.settings.title").font(.headline)
            Text("agentSessions.settings.detail").font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(AgentProvider.allCases) { provider in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(provider.title)
                        Text(service.folders[provider] ?? NSLocalizedString("agentSessions.settings.notConnected", comment: ""))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    if service.isConnected(provider) {
                        Button("agentSessions.settings.disconnect") { error = nil; service.disconnect(provider) }.kineticGlassButton()
                    }
                    Button(service.isConnected(provider) ? "agentSessions.settings.change" : "agentSessions.settings.connect") {
                        choose(provider)
                    }.kineticGlassButton()
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }
    }

    /// The real home folder; inside the sandbox `homeDirectoryForCurrentUser` is the App container.
    private static var userHome: URL {
        if let entry = getpwuid(getuid()), let path = entry.pointee.pw_dir { return URL(fileURLWithPath: String(cString: path), isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private func choose(_ provider: AgentProvider) {
        error = nil
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false; panel.showsHiddenFiles = true
        panel.directoryURL = Self.userHome.appendingPathComponent(provider.homeFolderName, isDirectory: true)
        panel.message = String(format: NSLocalizedString("agentSessions.settings.panel", comment: ""), provider.title, provider.homeFolderName)
        panel.prompt = NSLocalizedString("agentSessions.settings.panelPrompt", comment: "")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try service.connect(provider, folder: url) } catch { self.error = error.localizedDescription }
    }
}

/// 原「设置 › 叠加层」中的 Agent 会话一段，迁到显示器页的叠加层菜单后在这个窗口中打开；内容不变。
@MainActor
final class AgentSessionSettingsWindow: NSObject, NSWindowDelegate {
    let service: AgentSessionService
    private(set) var window: NSWindow?
    init(service: AgentSessionService) { self.service = service }
    @discardableResult func show(activate: Bool = true) -> NSWindow {
        if let window { window.makeKeyAndOrderFront(nil); return window }
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 560, height: 300),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = NSLocalizedString("agentSessions.settings.title", comment: "")
        window.identifier = .init("Kinetic.AgentSessionSettings"); window.isReleasedWhenClosed = false
        window.minSize = .init(width: 460, height: 240)
        OverlaySettingsWindowChrome.apply(to: window)
        window.contentView = NSHostingView(rootView: OverlaySettingsWindowContent(title: window.title) {
            ScrollView {
                AgentSessionSettingsSection(service: service)
                    .frame(maxWidth: .infinity, alignment: .topLeading).padding(24)
            }
        }.environment(\.locale, Locale(identifier: "zh-Hans")))
        window.delegate = self; self.window = window; window.center(); window.makeKeyAndOrderFront(nil)
        if activate { NSApp.activate(ignoringOtherApps: true) }
        return window
    }
    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        window?.delegate = nil; window?.contentView = nil; window = nil
    }
    func close() { window?.close() }
}
