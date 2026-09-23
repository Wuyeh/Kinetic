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

        Settings {
            Color(nsColor: .windowBackgroundColor)
                .frame(width: 480, height: 320)
                .environment(\.locale, Locale(identifier: "zh-Hans"))
        }

        MenuBarExtra("app.name", systemImage: "photo") {
            Text("menu.placeholder")
                .environment(\.locale, Locale(identifier: "zh-Hans"))
        }
        .menuBarExtraStyle(.menu)
    }
}
