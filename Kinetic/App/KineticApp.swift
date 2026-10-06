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
