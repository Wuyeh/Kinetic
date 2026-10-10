import SwiftUI

@main
struct KineticApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("app.name", id: "main") {
            MainShellView(appDelegate: appDelegate)
                .environment(\.locale, Locale(identifier: "zh-Hans"))
        }
        .defaultSize(
            width: MainWindowDesignTokens.Window.defaultWidth,
            height: MainWindowDesignTokens.Window.defaultHeight
        )
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("检查更新…") { appDelegate.updates?.checkForUpdates() }
                    .disabled(appDelegate.updates?.isRunning != true)
            }
            CommandGroup(after: .help) {
                Button("onboarding.showAgain") { appDelegate.showWelcome() }
                    .disabled(appDelegate.onboarding == nil)
            }
            CommandGroup(after: .importExport) {
                Button("浏览 Apple 航拍…") { appDelegate.showAppleAerials() }
                    .disabled(appDelegate.library == nil)
            }
        }

        Settings {
            KineticSettingsView(appDelegate: appDelegate)
                .environment(\.locale, Locale(identifier: "zh-Hans"))
        }

        MenuBarExtra {
            KineticMenuBarControllerView(appDelegate: appDelegate)
                .environment(\.locale, Locale(identifier: "zh-Hans"))
        } label: {
            KineticMenuBarStatusView(appDelegate: appDelegate)
        }
        .menuBarExtraStyle(.menu)
    }
}
