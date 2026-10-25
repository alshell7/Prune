import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Notifier.requestAuthorization()
        Task { @MainActor in FolderWatcher.shared.start() }
    }

    // Keep running in the menu bar after the window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct PruneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("Prune", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .defaultSize(width: 1360, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Scan") {
                Button("Scan Now") { model.scan() }.keyboardShortcut("r").disabled(model.isScanning)
                Button("Select All Recommended") { model.selectRecommended() }.keyboardShortcut("a", modifiers: [.command, .shift])
                Button("Review Selection…") { model.review(model.selectedItems) }.keyboardShortcut(.return).disabled(model.selection.isEmpty)
            }
        }

        MenuBarExtra {
            MenuBarView().environment(model)
        } label: {
            MenuBarLabel().environment(model)
        }
        .menuBarExtraStyle(.window)

        // The menu bar panel as a regular window (Window › Quick Panel), handy to keep on screen.
        Window("Quick Panel", id: "quick-panel") {
            MenuBarView().environment(model)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView().environment(model)
        }
    }
}
