import AppKit
import ServiceManagement
import SwiftUI

struct WatchedView: View {
    @Environment(AppModel.self) private var model
    @State private var watcher = FolderWatcher.shared

    private var suggestions: [URL] {
        ["Documents", "Downloads", "Library/Developer", ".gradle", "Library/Caches"]
            .map { FS.home.appendingPathComponent($0) }.filter(FS.isDir).prefix(4).map { $0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Watched Folders").font(.title2.weight(.semibold))
                    Text("Prune tracks these folders' size in the background (using FSEvents, so it costs almost nothing) and warns you when one grows by more than \(model.settings.growthAlertGB) GB.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button { watcher.measureAll() } label: { Label("Measure All", systemImage: "arrow.clockwise") }
                Button { if let u = Finder.chooseFolder(prompt: "Watch") { watcher.add(u) } } label: { Label("Add Folder…", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)
            Divider()
            if watcher.folders.isEmpty {
                VStack(spacing: 14) {
                    EmptyStateView(symbol: "eye", title: "No watched folders",
                                   message: "Add your projects folder, Downloads or any build output directory to get notified when it balloons.")
                        .frame(maxHeight: 220)
                    HStack {
                        ForEach(suggestions, id: \.self) { u in
                            Button("Watch \(FS.tildePath(u))") { watcher.add(u) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(watcher.folders) { f in
                        HStack(spacing: 12) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: f.path)).resizable().frame(width: 28, height: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(f.name).font(.headline)
                                Text(FS.tildePath(URL(fileURLWithPath: f.path))).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let g = f.growth, abs(g) > 1_000_000 {
                                Label((g > 0 ? "+" : "−") + Fmt.bytes(abs(g)), systemImage: g > 0 ? "arrow.up.right" : "arrow.down.right")
                                    .font(.callout.monospacedDigit())
                                    .foregroundStyle(g > 0 ? .orange : .green)
                                    .help("Change since \(f.baselineDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "baseline")")
                            }
                            VStack(alignment: .trailing, spacing: 2) {
                                if watcher.measuring.contains(f.path) { ProgressView().controlSize(.small) }
                                else { Text(f.lastSize.map(Fmt.bytes) ?? "—").font(.title3.monospacedDigit()) }
                                Text(f.lastChecked.map { "checked " + Fmt.relative($0) } ?? "not measured").font(.caption2).foregroundStyle(.secondary)
                            }
                            .frame(width: 130, alignment: .trailing)
                            Menu {
                                Button("Open in Disk Explorer") { model.showInExplorer(URL(fileURLWithPath: f.path)) }
                                Button("Measure Now") { watcher.measure(f.path) }
                                Button("Reset Baseline") { watcher.resetBaseline(f.path) }
                                Divider()
                                Button("Stop Watching", role: .destructive) { watcher.remove(f.path) }
                            } label: { Image(systemName: "ellipsis.circle") }
                                .menuStyle(.borderlessButton).fixedSize()
                        }
                        .padding(.vertical, 6)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .navigationTitle("Watched Folders")
    }
}

struct HistoryView: View {
    @State private var entries: [CleanOutcome] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("History").font(.title2.weight(.semibold))
                    Text("Every action Prune has taken. Items moved to the Trash can be restored from there.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open Trash") { NSWorkspace.shared.open(FS.home.appendingPathComponent(".Trash")) }
                Button("Show Log File") { Finder.reveal([AuditLog.file]) }
            }
            .padding(16)
            Divider()
            if entries.isEmpty {
                EmptyStateView(symbol: "clock", title: "Nothing yet", message: "Cleanups you run will be listed here.")
            } else {
                Table(entries) {
                    TableColumn("Date") { e in Text(e.date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary) }.width(140)
                    TableColumn("Item") { e in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e.title).lineLimit(1).truncationMode(.middle)
                            if !e.message.isEmpty { Text(e.message).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        }
                    }
                    TableColumn("Action") { e in Text(e.method).foregroundStyle(.secondary).lineLimit(1) }.width(min: 100, ideal: 180)
                    TableColumn("Size") { e in Text(Fmt.bytes(e.size)).monospacedDigit() }.width(80)
                    TableColumn("") { e in Image(systemName: e.success ? "checkmark.circle.fill" : "xmark.octagon.fill").foregroundStyle(e.success ? .green : .red) }.width(24)
                }
            }
        }
        .navigationTitle("History")
        .onAppear { entries = AuditLog.load() }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            scanning.tabItem { Label("Scanning", systemImage: "magnifyingglass") }
            safety.tabItem { Label("Safety", systemImage: "checkmark.shield") }
        }
        .frame(width: 560, height: 460)
    }

    private var general: some View {
        @Bindable var s = model.settings
        return Form {
            Section("Menu bar") {
                Toggle("Show free space next to the menu bar icon", isOn: $s.showFreeSpaceInMenuBar)
                LaunchAtLoginToggle()
            }
            Section("Alerts") {
                Stepper("Warn when free space drops below \(s.lowSpaceAlertGB) GB", value: $s.lowSpaceAlertGB, in: 1...200)
                Stepper("Warn when a watched folder grows by \(s.growthAlertGB) GB", value: $s.growthAlertGB, in: 1...100)
                Button("Allow Notifications…") { Notifier.requestAuthorization() }
            }
            Section("Background scan") {
                Picker("Rescan automatically", selection: $s.autoScanHours) {
                    Text("Never").tag(0); Text("Every 6 hours").tag(6); Text("Daily").tag(24); Text("Weekly").tag(168)
                }
            }
            Section("Permissions") {
                HStack {
                    Image(systemName: model.hasFDA ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(model.hasFDA ? .green : .orange)
                    Text(model.hasFDA ? "Full Disk Access granted" : "Full Disk Access not granted")
                    Spacer()
                    Button("Open Privacy Settings") { SystemInfo.openFullDiskAccessSettings() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var scanning: some View {
        @Bindable var s = model.settings
        return Form {
            Section {
                ForEach(s.scanRoots, id: \.self) { root in
                    HStack {
                        Image(systemName: "folder")
                        Text(FS.tildePath(URL(fileURLWithPath: root)))
                        Spacer()
                        Button { s.scanRoots.removeAll { $0 == root } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                            .disabled(s.scanRoots.count == 1)
                    }
                }
                Button("Add Location…") { if let u = Finder.chooseFolder(prompt: "Add"), !s.scanRoots.contains(u.path) { s.scanRoots.append(u.path) } }
                Toggle("Also scan external volumes", isOn: $s.includeExternalVolumes)
                ForEach(model.volumes.filter { !$0.isBoot }) { v in
                    Toggle(isOn: Binding(get: { !s.excludedVolumes.contains(v.url.path) }, set: { on in
                        if on { s.excludedVolumes.removeAll { $0 == v.url.path } } else { s.excludedVolumes.append(v.url.path) }
                    })) { Label("\(v.name) · \(v.format) · \(Fmt.bytes(v.available)) free", systemImage: "externaldrive") }
                    .disabled(!s.includeExternalVolumes || v.readOnly)
                    .padding(.leading, 16)
                }
            } header: { Text("Where to look for projects") } footer: {
                Text("Caches, toolchains, apps and large files are found system-wide regardless. These locations are where Prune walks for projects, build artifacts and worktrees.")
            }
            Section("Judgement") {
                Stepper("A project is idle after \(s.staleDays) days", value: $s.staleDays, in: 3...365, step: 1)
                Stepper("Large file threshold: \(s.largeFileMB) MB", value: $s.largeFileMB, in: 100...10_000, step: 100)
                Stepper("Hide items smaller than \(s.minItemMB) MB", value: $s.minItemMB, in: 0...500)
            }
        }
        .formStyle(.grouped)
    }

    private var safety: some View {
        @Bindable var s = model.settings
        return Form {
            Section {
                Toggle("Delete Safe items immediately instead of moving them to the Trash", isOn: $s.deleteSafeImmediately)
            } footer: {
                Text("Only affects items rated Safe (caches that regenerate on their own). Everything else always goes to the Trash so you can restore it.")
            }
            Section {
                if s.excludedPaths.isEmpty {
                    Text("Nothing excluded. Use \u{201C}Never Suggest This Again\u{201D} on any item.").foregroundStyle(.secondary)
                }
                ForEach(s.excludedPaths, id: \.self) { p in
                    HStack {
                        Text(FS.tildePath(URL(fileURLWithPath: p))).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { s.excludedPaths.removeAll { $0 == p } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                }
                Button("Exclude a Folder…") { if let u = Finder.chooseFolder(prompt: "Exclude") { s.excludedPaths.append(u.path) } }
            } header: { Text("Never touch") }
            Section("Built-in protections") {
                Text("Prune never touches system folders, keychains, iCloud Drive, Photos and Mail libraries, ~/.ssh, or anything inside a .git folder. It never removes a folder that is itself a git repository, files git tracks, worktrees with uncommitted changes, or apps that are running. Every path is re-checked right before removal.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct LaunchAtLoginToggle: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading) {
            Toggle("Open Prune at login", isOn: Binding(get: { enabled }, set: { on in
                do {
                    if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    enabled = SMAppService.mainApp.status == .enabled
                    error = nil
                } catch { self.error = error.localizedDescription }
            }))
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }
}
