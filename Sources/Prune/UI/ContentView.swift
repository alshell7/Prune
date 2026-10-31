import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 270, ideal: 290, max: 360)
        } detail: {
            Group {
                switch model.route ?? .overview {
                case .overview: OverviewView()
                case .category(let c): CategoryView(category: c).id(c)
                case .explorer: ExplorerView()
                case .systemData: SystemDataView()
                case .offload: OffloadView()
                case .security: SecurityView()
                case .codeBackup: CodeBackupView()
                case .taskManager: TaskManagerView()
                case .network: NetworkView()
                case .apps: AppsView()
                case .duplicates: DuplicatesView()
                case .watched: WatchedView()
                case .history: HistoryView()
                }
            }
            .frame(minWidth: 640)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.isScanning {
                    ProgressView().controlSize(.small)
                } else {
                    Button { model.scan() } label: { Label(model.hasScanned ? "Rescan" : "Scan", systemImage: "arrow.clockwise") }
                        .help("Scan everything (⌘R)")
                }
                if !model.selection.isEmpty {
                    Button { model.review(model.selectedItems) } label: {
                        Label("Clean \(Fmt.bytes(model.selectedSize))", systemImage: "trash")
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Review the \(model.selectedItems.count) selected items before cleaning")
                }
            }
        }
        .sheet(isPresented: $model.showReview) { ReviewSheet() }
        .task {
            // Launch arguments (e.g. `-PruneAutoScan YES -PruneRoute environments`) for scripted runs.
            let d = UserDefaults.standard
            if let r = d.string(forKey: "PruneRoute") {
                switch r {
                case "explorer": model.route = .explorer
                case "systemData": model.route = .systemData
                case "offload": model.route = .offload
                case "security": model.route = .security
                case "codeBackup": model.route = .codeBackup
                case "taskManager": model.route = .taskManager
                case "network": model.route = .network
                case "apps": model.route = .apps
                case "duplicates": model.route = .duplicates
                case "watched": model.route = .watched
                case "history": model.route = .history
                default: model.route = Category(rawValue: r).map { .category($0) } ?? .overview
                }
            }
            if d.bool(forKey: "PruneAutoScan"), !model.hasScanned, !model.isScanning { model.scan() }
            if d.bool(forKey: "PruneQuickPanel") { openWindow(id: "quick-panel") }
            if d.bool(forKey: "PruneActivate") { NSApp.activate(ignoringOtherApps: true) }
            if d.bool(forKey: "PruneReviewRecommended") {
                while model.isScanning || !model.hasScanned { try? await Task.sleep(for: .milliseconds(300)) }
                model.review(model.items.filter { $0.isActionable && $0.recommendation == .recommended })
            }
        }
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model

    private func scannerFor(_ c: Category) -> String {
        switch c {
        case .projectArtifacts: "Project artifacts"
        case .environments: "Dev environments"
        case .devCaches: "Developer caches"
        case .xcode: "Xcode & simulators"
        case .worktrees: "Git worktrees"
        case .docker: "Docker & Homebrew"
        case .editors: "Editors & IDEs"
        case .aiModels: "AI tools"
        case .systemJunk: "System junk"
        case .applications: "Applications"
        case .dangling: "Dangling items"
        case .largeFiles: "Large files"
        }
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            List(selection: $model.route) {
                Label("Overview", systemImage: "gauge.with.dots.needle.33percent").tag(Route.overview)
                Section("Cleanup") {
                    ForEach(Category.allCases) { c in
                        HStack {
                            Label(c.title, systemImage: c.icon)
                            Spacer()
                            if model.isScanning && !model.finishedScanners.contains(scannerFor(c)) {
                                ProgressView().controlSize(.mini)
                            } else if let s = model.summary.byCategory[c], s.size > 0 {
                                Text(Fmt.bytes(s.size)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
                            }
                        }
                        .tag(Route.category(c))
                    }
                }
                Section("Protect") {
                    Label("Security", systemImage: "shield.lefthalf.filled").tag(Route.security)
                    Label("Code Backup", systemImage: "externaldrive.badge.checkmark").tag(Route.codeBackup)
                Label("Task Manager", systemImage: "cpu").tag(Route.taskManager)
                Label("Network", systemImage: "network").tag(Route.network)
                Label("Apps & Extensions", systemImage: "square.grid.3x3.topleft.filled").tag(Route.apps)
                }
                Section("Tools") {
                    Label("System Data", systemImage: "internaldrive").tag(Route.systemData)
                    Label("Offload to Drive", systemImage: "externaldrive.badge.plus").tag(Route.offload)
                    Label("Disk Explorer", systemImage: "square.grid.3x3.square").tag(Route.explorer)
                    Label("Duplicate Finder", systemImage: "doc.on.doc").tag(Route.duplicates)
                    Label("Watched Folders", systemImage: "eye").tag(Route.watched)
                    Label("History", systemImage: "clock.arrow.circlepath").tag(Route.history)
                }
            }
            .listStyle(.sidebar)
            // A real footer (not an overlay), so it never covers the last sidebar rows.
            SidebarDiskFooter()
        }
    }
}

struct SidebarDiskFooter: View {
    @Environment(AppModel.self) private var model
    @State private var hover = false

    var body: some View {
        if let boot = model.bootVolume {
            let recommended = model.summary.byVolume[boot.url.path]?.recommended ?? 0
            Button { model.open(.overview) } label: {
                HStack(spacing: 10) {
                    DiskRing(volume: boot, reclaimable: recommended, lineWidth: 5).frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(Fmt.bytes(boot.available)) free").font(.caption.weight(.semibold).monospacedDigit())
                            .contentTransition(.numericText())
                        Text(recommended > 0 ? "+\(Fmt.bytes(recommended)) recommended" : boot.name)
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(hover ? 0.06 : 0)))
                .padding(.horizontal, 8).padding(.bottom, 8).padding(.top, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { h in withAnimation(.snappy(duration: 0.15)) { hover = h } }
            .animation(.snappy, value: boot.available)
            .overlay(alignment: .top) { Divider() }
        }
    }
}
