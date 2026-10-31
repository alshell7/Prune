import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Notifier.requestAuthorization()
        Task { @MainActor in
            if DemoMode.active { DemoData.install() }
            AppSettings.shared.applyAppearance()
            FolderWatcher.shared.start()
            Updater.shared.startSchedule()
        }
    }

    // Keep running in the menu bar after the window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct PruneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Prune", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .defaultSize(width: 1360, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) {
                Button("About Prune") { openWindow(id: "about") }
                Button("Check for Updates…") { openWindow(id: "about"); Task { await Updater.shared.check() } }
            }
            CommandGroup(replacing: .help) {
                Button("Prune Tour") { ModuleGuide.shared.showTour = true }
                Button("How This Module Works") { ModuleGuide.shared.toggle(model.route ?? .overview) }.keyboardShortcut("/", modifiers: .command)
                Link("Prune on GitHub", destination: AppInfo.repoURL)
            }
            CommandMenu("View Mode") {
                Picker("Appearance", selection: Binding(get: { model.settings.appearance }, set: { model.settings.appearance = $0 })) {
                    Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
                }
            }
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

        Window("About Prune", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        Settings {
            SettingsView().environment(model)
        }
    }
}
