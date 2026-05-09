import SwiftUI
import AppKit

@main
struct MultiMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("MultiMonitor", id: "main") {
            ContentView()
                .environmentObject(model)
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra("MultiMonitor", systemImage: "rectangle.split.2x1") {
            MenuBarMenu()
                .environmentObject(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Stay alive in the menu bar after the user closes the main window.
    /// The "Beenden" item in the menu bar quits the app explicitly.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The activation policy is set by AppModel.showInDock's didSet during
        // its restorePersistedState(); here we just bring the app forward.
        NSApp.activate(ignoringOtherApps: true)
    }
}
