import SwiftUI
import AppKit

struct MenuBarMenu: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Hauptfenster öffnen") { openMainWindow() }
            .keyboardShortcut("o")

        Divider()

        Button(model.canApply ? "Erneut anwenden" : "Erneut anwenden") {
            model.apply()
        }
        .disabled(!model.canApply)

        if !model.recents.isEmpty {
            Menu("Letzte Bilder") {
                ForEach(model.recents.prefix(10), id: \.self) { url in
                    Button(url.lastPathComponent) {
                        model.loadSource(url)
                        model.apply()
                    }
                }
            }
        }

        Divider()

        if model.slideshow.isRunning {
            Button("Slideshow stoppen") { model.slideshow.stop() }
            Button("Nächstes Bild") { model.slideshow.skipForward() }
        } else {
            Button("Slideshow starten") { model.slideshow.start() }
                .disabled(model.slideshow.imageCount == 0)
        }

        Divider()

        Toggle("Auto-Reapply bei Monitor-Wechsel", isOn: $model.autoReapply)
        Toggle("Im Dock anzeigen", isOn: $model.showInDock)
        Toggle("Beim Login starten", isOn: Binding(
            get: { LoginItemManager.isEnabled },
            set: { LoginItemManager.setEnabled($0) }
        ))

        Divider()

        Button("Beenden") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func openMainWindow() {
        // Activate so the window comes to the front even if the app was in
        // the background as a menu-bar accessory.
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "main")
    }
}
