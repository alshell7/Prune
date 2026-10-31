import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var guide = ModuleGuide.shared

    @ViewBuilder private var detailContent: some View {
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
        case .secrets: SecretsView()
        case .doctor: DoctorView()
        case .maintenance: MaintenanceView()
        case .timeline: SpaceTimelineView()
        case .watched: WatchedView()
        case .history: HistoryView()
        }
    }

    // Plain layout: the intro card sits above the module (not in the toolbar's safe area), and routes switch
    // instantly. Cross-fading two module views left the outgoing one clickable during the animation.
    private var detailColumn: some View {
        VStack(spacing: 0) {
            if guide.isVisible(model.route ?? .overview) { ModuleIntroCard(route: model.route ?? .overview) }
            detailContent
        }
        .frame(minWidth: 640)
    }

    var body: some View {
        @Bindable var model = model
        Group {
            if DemoMode.active {
                // README captures: the glass sidebar is composited outside the app and can't be rendered offscreen,
                // so the same Sidebar view sits in a plain floating column.
                HStack(spacing: 0) {
                    Sidebar()
                        .padding(.top, 34)
                        .frame(width: 270)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.08)))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .shadow(color: .black.opacity(0.10), radius: 8, y: 2)
                        .padding(8)
                        .ignoresSafeArea(.container, edges: .top)
                    detailColumn
                }
            } else {
                NavigationSplitView {
                    Sidebar()
                        .navigationSplitViewColumnWidth(min: 270, ideal: 290, max: 360)
                } detail: {
                    detailColumn
                }
            }
        }
        .sheet(isPresented: $guide.showTour) { WelcomeTour() }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { guide.toggle(model.route ?? .overview) } label: {
                    Label("How it works", systemImage: "questionmark.circle")
                }
                .help("Show or hide how this module works (⌘/)")
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
                case "secrets": model.route = .secrets
                case "doctor": model.route = .doctor
                case "maintenance": model.route = .maintenance
                case "timeline": model.route = .timeline
                case "watched": model.route = .watched
                case "history": model.route = .history
                default: model.route = Category(rawValue: r).map { .category($0) } ?? .overview
                }
            }
            if d.bool(forKey: "PruneAutoScan"), !model.hasScanned, !model.isScanning { model.scan() }
            if DemoMode.active, let out = d.string(forKey: "PruneShots") {
                try? await Task.sleep(for: .seconds(2))
                await DemoDirector(root: URL(fileURLWithPath: out)).run { openWindow(id: $0) }
            }
            // Diagnostics: step through every module (like clicking each sidebar row).
            if d.bool(forKey: "PruneVisitAll") {
                let all: [Route] = [.overview] + Category.allCases.map { .category($0) } + [.security, .secrets, .codeBackup, .taskManager, .network, .apps,
                                     .systemData, .offload, .explorer, .duplicates, .doctor, .maintenance, .timeline, .watched, .history, .overview]
                for r in all { model.route = r; FileHandle.standardError.write(Data("route → \(r.guideKey)\n".utf8)); try? await Task.sleep(for: .milliseconds(900)) }
                print("visit done")
            }
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

    struct Entry: Identifiable {
        var route: Route
        var title: String
        var symbol: String
        var detail: String? = nil
        var busy = false
        var badge: (count: Int, tint: Color)? = nil
        var id: Route { route }
    }

    /// The sidebar as data, rendered by the native list (and by README captures).
    var sections: [(title: String?, entries: [Entry])] {
        let cleanup = Category.allCases.map { c -> Entry in
            let busy = model.isScanning && !model.finishedScanners.contains(scannerFor(c))
            let size = model.summary.byCategory[c].flatMap { $0.size > 0 ? Fmt.bytes($0.size) : nil }
            return Entry(route: .category(c), title: c.title, symbol: c.icon, detail: busy ? nil : size, busy: busy)
        }
        func badge(_ n: Int, _ tint: Color) -> (Int, Color)? { n > 0 ? (n, tint) : nil }
        return [
            (nil, [Entry(route: .overview, title: "Overview", symbol: "gauge.with.dots.needle.33percent")]),
            ("Cleanup", cleanup),
            ("Protect", [
                Entry(route: .security, title: "Security", symbol: "shield.lefthalf.filled", badge: badge(SecurityModel.shared.issues.filter { $0.severity >= .medium }.count, .orange)),
                Entry(route: .secrets, title: "Secrets", symbol: "key.fill", badge: badge(SecretsModel.shared.report.issues.filter { $0.severity >= .high }.count, .red)),
                Entry(route: .codeBackup, title: "Code Backup", symbol: "externaldrive.badge.checkmark", badge: badge(CodeBackupModel.shared.atRisk.count, .orange)),
                Entry(route: .taskManager, title: "Task Manager", symbol: "cpu"),
                Entry(route: .network, title: "Network", symbol: "network"),
                Entry(route: .apps, title: "Apps & Extensions", symbol: "square.grid.3x3.topleft.filled"),
            ]),
            ("Tools", [
                Entry(route: .systemData, title: "System Data", symbol: "internaldrive"),
                Entry(route: .offload, title: "Offload to Drive", symbol: "externaldrive.badge.plus"),
                Entry(route: .explorer, title: "Disk Explorer", symbol: "square.grid.3x3.square"),
                Entry(route: .duplicates, title: "Duplicate Finder", symbol: "doc.on.doc"),
                Entry(route: .doctor, title: "Project Doctor", symbol: "stethoscope", badge: badge(DoctorModel.shared.issues.filter { $0.level == .broken }.count, .pink)),
                Entry(route: .maintenance, title: "Maintenance", symbol: "wrench.and.screwdriver"),
                Entry(route: .timeline, title: "Space Timeline", symbol: "chart.xyaxis.line"),
                Entry(route: .watched, title: "Watched Folders", symbol: "eye"),
                Entry(route: .history, title: "History", symbol: "clock.arrow.circlepath"),
            ]),
        ]
    }

    @ViewBuilder func row(_ e: Entry) -> some View {
        HStack {
            Label(e.title, systemImage: e.symbol)
            Spacer()
            if e.busy {
                ProgressView().controlSize(.mini)
            } else if let b = e.badge {
                Text("\(b.count)").font(.caption2.weight(.bold).monospacedDigit()).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 1).background(b.tint, in: Capsule())
            } else if let d = e.detail {
                Text(d).font(.caption2.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
            }
        }
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            if DemoMode.active {
                CaptureSidebarList(sidebar: self)
            } else {
                List(selection: $model.route) {
                    ForEach(sections.indices, id: \.self) { i in
                        let section = sections[i]
                        if let title = section.title {
                            Section(title) { ForEach(section.entries) { e in row(e).tag(e.route) } }
                        } else {
                            ForEach(section.entries) { e in row(e).tag(e.route) }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
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
