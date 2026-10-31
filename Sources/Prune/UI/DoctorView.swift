import Charts
import SwiftUI

// MARK: - Project Doctor

@MainActor
@Observable
final class DoctorModel {
    static let shared = DoctorModel()
    var issues: [DoctorIssue] = []
    var loading = false
    var status = ""
    var checkedAt: Date?
    var busy: String?
    var toast: (ok: Bool, text: String)?

    func refresh(settings: SettingsSnapshot) {
        guard !loading else { return }
        loading = true
        Task {
            let list = await AppModel.background {
                ProjectDoctor.scan(index: ProjectIndex.cached(roots: settings.resolvedScanRoots(), settings: settings)) { m in Task { @MainActor in DoctorModel.shared.status = m } }
            }
            withAnimation(.spring(duration: 0.45)) { issues = list; loading = false; checkedAt = Date() }
        }
    }

    func fix(_ issue: DoctorIssue) {
        busy = issue.id
        Task {
            let r = await AppModel.background { ProjectDoctor.apply(issue) }
            withAnimation(.snappy) {
                busy = nil
                if r.0 { issues.removeAll { $0.id == issue.id } }
                toast = (r.0, r.1)
            }
            if r.0 { AppModel.shared.refreshVolumes() }
            try? await Task.sleep(for: .seconds(6))
            withAnimation { if toast?.text == r.1 { toast = nil } }
        }
    }
}

struct DoctorView: View {
    @Environment(AppModel.self) private var model
    @State private var dm = DoctorModel.shared

    private var visible: [DoctorIssue] { dm.issues.filter { model.inScope($0.path) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(dm.loading ? "Examining projects…" : (visible.isEmpty ? (dm.checkedAt == nil ? "Project Doctor" : "All projects look healthy") : "\(visible.count) thing\(visible.count == 1 ? "" : "s") to fix"))
                            .font(.title2.weight(.semibold)).contentTransition(.numericText())
                        Text(dm.loading ? dm.status : "Finds what breaks when projects move between disks (virtualenvs, worktrees, git object links, symlinks), stale git locks, and repositories that need compacting.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { dm.refresh(settings: model.settings.snapshot) } label: { Label("Examine", systemImage: "stethoscope") }.disabled(dm.loading)
                }
                DiskScopeBar()
                let moves = ProjectDoctor.previousLocations(visible)
                if let (old, n) = moves.first {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.right.doc.on.clipboard").font(.title2).foregroundStyle(.pink)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Projects moved from \(FS.tildePath(URL(fileURLWithPath: old)))").font(.headline)
                            Text("\(n) thing\(n == 1 ? "" : "s") still point to the old location. Fix them below.").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.pink.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
                if visible.isEmpty && !dm.loading {
                    Card {
                        HStack(spacing: 14) {
                            Image(systemName: dm.checkedAt == nil ? "stethoscope" : "heart.text.square.fill").font(.system(size: 34)).foregroundStyle(.pink)
                                .symbolEffect(.pulse, isActive: dm.checkedAt == nil)
                            Text(dm.checkedAt == nil ? "Examine your projects to find broken environments and links." : "No broken environments, links, locks or bloated repositories.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(DoctorIssue.Kind.allCases, id: \.self) { kind in
                    let group = visible.filter { $0.kind == kind }
                    if !group.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("\(kind.rawValue) · \(group.count)", systemImage: kind.symbol).font(.headline)
                            ForEach(group) { issue in row(issue) }
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 1100, alignment: .leading)
        }
        .navigationTitle("Project Doctor")
        .onAppear { if dm.checkedAt == nil && !dm.loading { dm.refresh(settings: model.settings.snapshot) } }
        .overlay(alignment: .bottom) { if let t = dm.toast { ToastView(ok: t.ok, text: t.text) } }
    }

    private func row(_ i: DoctorIssue) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle().fill(i.level == .broken ? Color.red : i.level == .warning ? .orange : .blue).frame(width: 9, height: 9).padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(i.title).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    VolumeBadge(url: i.path)
                }
                Text(i.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(i.evidence, id: \.self) { Text("• " + $0).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                if case .trash(_, let restore?) = i.fix { Text("Recreate with: \(restore)").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                if i.bytes > 0 { Text(Fmt.bytes(i.bytes)).font(.callout.monospacedDigit()) }
                HStack(spacing: 6) {
                    Button { Finder.reveal([i.path]) } label: { Image(systemName: "magnifyingglass") }.help("Reveal in Finder")
                    if !i.fixLabel.isEmpty {
                        Button { dm.fix(i) } label: {
                            if dm.busy == i.id { ProgressView().controlSize(.small) } else { Text(i.fixLabel) }
                        }
                        .buttonStyle(.borderedProminent).disabled(dm.busy != nil)
                    }
                }
            }
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .hoverLift()
    }
}

// MARK: - Maintenance

struct MaintenanceView: View {
    @State private var running: String?
    @State private var output: [String: (Bool, String)] = [:]
    @State private var probes: [String: String] = [:]
    @State private var confirm: MaintenanceTask?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Maintenance").font(.title2.weight(.semibold))
                    Text("Standard macOS fixes, explained. Each one runs only when you click it and is recorded in History.").font(.callout).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12)], spacing: 12) {
                    ForEach(Maintenance.tasks) { task in card(task) }
                }
            }
            .padding(20).frame(maxWidth: 1100, alignment: .leading)
        }
        .navigationTitle("Maintenance")
        .task {
            for task in Maintenance.tasks where task.probe != nil {
                let value = await AppModel.background { task.probe?() }
                probes[task.id] = value
            }
        }
        .alert(confirm.map { "Run \u{201C}\($0.title)\u{201D}?" } ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button("Run") { if let t = confirm { run(t) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text(confirm.map { "\($0.impact)\($0.needsAdmin ? " macOS will ask for your administrator password." : "")" } ?? "") }
    }

    private func card(_ t: MaintenanceTask) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: t.symbol).font(.title2).foregroundStyle(tint(t)).frame(width: 30)
                    .symbolEffect(.pulse, isActive: running == t.id)
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.title).font(.headline)
                    HStack(spacing: 6) {
                        Text(t.effect.rawValue).font(.caption2.weight(.semibold)).foregroundStyle(tint(t))
                        if t.needsAdmin { Label("Admin", systemImage: "lock.fill").font(.caption2).foregroundStyle(.secondary) }
                        if let p = probes[t.id] { Text("· " + p).font(.caption2).foregroundStyle(.secondary) }
                    }
                }
                Spacer()
            }
            Text(t.what).font(.callout)
            Text("When: " + t.when).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if let o = output[t.id] {
                    Label(o.0 ? "Done" : "Failed", systemImage: o.0 ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .font(.caption).foregroundStyle(o.0 ? .green : .red).help(o.1)
                } else if let d = Maintenance.lastRun(t) {
                    Text("Last run \(Fmt.ago(d))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { confirm = t } label: {
                    if running == t.id { ProgressView().controlSize(.small) } else { Text("Run") }
                }
                .disabled(running != nil)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .hoverLift()
    }

    private func tint(_ t: MaintenanceTask) -> Color { t.effect == .space ? .green : t.effect == .fix ? .blue : .secondary }

    private func run(_ t: MaintenanceTask) {
        running = t.id
        Task {
            let r = await AppModel.background { Maintenance.run(t) }
            withAnimation(.snappy) {
                output[t.id] = (r.ok, r.ok ? r.stdout : (r.stderr.isEmpty ? r.stdout : r.stderr))
                running = nil
            }
            if let probe = t.probe { probes[t.id] = await AppModel.background { probe() } }
            AppModel.shared.refreshVolumes()
        }
    }
}

// MARK: - Space Timeline

struct SpaceTimelineView: View {
    @Environment(AppModel.self) private var model
    @State private var days = 7
    @State private var history = SpaceHistory.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Space Timeline").font(.title2.weight(.semibold))
                        Text("Free space on each disk while Prune runs, with the trend and a forecast.").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("", selection: $days) {
                        Text("24 hours").tag(1); Text("7 days").tag(7); Text("30 days").tag(30); Text("90 days").tag(90)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 320)
                }
                ForEach(model.volumes) { v in diskCard(v) }
                let cleanups = AuditLog.load().filter { $0.success && $0.size > 0 && $0.date > Date().addingTimeInterval(-Double(days) * 86_400) }
                if !cleanups.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Freed by Prune in this period: \(Fmt.bytes(cleanups.reduce(0) { $0 + $1.size }))", systemImage: "sparkles").font(.headline)
                            Text("\(cleanups.count) cleanups. See History for details.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(20).frame(maxWidth: 1100, alignment: .leading)
        }
        .navigationTitle("Space Timeline")
    }

    private func diskCard(_ v: VolumeInfo) -> some View {
        let samples = history.samples(for: v, days: days)
        let forecast = SpaceHistory.forecast(samples, floor: v.isBoot ? Int64(model.settings.lowSpaceAlertGB) * 1_000_000_000 : 0)
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: v.isBoot ? "internaldrive.fill" : "externaldrive.fill").foregroundStyle(.secondary)
                    Text(v.name).font(.headline)
                    Text("\(Fmt.bytes(v.available)) free").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    if let f = forecast { forecastLabel(f, v) }
                }
                if samples.count < 2 {
                    Text("Collecting data. Prune records free space every 15 minutes while it's running (including from the menu bar).")
                        .font(.callout).foregroundStyle(.secondary).frame(height: 60)
                } else {
                    Chart(samples, id: \.date) { s in
                        AreaMark(x: .value("Time", s.date), y: .value("Free", Double(s.free) / 1e9))
                            .foregroundStyle(LinearGradient(colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Time", s.date), y: .value("Free", Double(s.free) / 1e9))
                            .foregroundStyle(Color.accentColor).interpolationMethod(.monotone)
                    }
                    .chartYAxisLabel("GB free")
                    .frame(height: 160)
                }
            }
        }
    }

    @ViewBuilder private func forecastLabel(_ f: SpaceHistory.Forecast, _ v: VolumeInfo) -> some View {
        let perDay = Fmt.bytes(Int64(abs(f.bytesPerDay)))
        if let d = f.daysUntilFull {
            Label(d < 1 ? "Fills up within a day at \(perDay)/day" : "Full in ~\(Int(d)) day\(Int(d) == 1 ? "" : "s") at \(perDay)/day",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.medium)).foregroundStyle(d < 14 ? .red : .orange)
        } else if f.bytesPerDay > 0 {
            Label("Gaining \(perDay)/day", systemImage: "arrow.up.right").font(.callout).foregroundStyle(.green)
        } else {
            Label("Stable", systemImage: "equal").font(.callout).foregroundStyle(.secondary)
        }
    }
}
