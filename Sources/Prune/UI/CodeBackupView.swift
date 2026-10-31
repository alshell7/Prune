import AppKit
import Observation
import SwiftUI

extension RepoStatus.Level {
    var color: Color {
        switch self {
        case .backedUp: .green
        case .uncommitted: .yellow
        case .unpushed: .orange
        case .noRemote: Color(red: 0.95, green: 0.35, blue: 0.2)
        case .noGit: .red
        case .unknown: .purple
        }
    }
}

@MainActor
@Observable
final class CodeBackupModel {
    static let shared = CodeBackupModel()
    var repos: [RepoStatus] = []
    var loading = false
    var status = ""
    var checkedAt: Date?
    var showVendored = false
    var level: RepoStatus.Level?
    var focused: String?
    var busy: String?
    var toast: (ok: Bool, text: String)?

    var visible: [RepoStatus] { repos.filter { (showVendored || !$0.vendored) && (level == nil || $0.level == level) && AppModel.shared.inScope($0.path) } }
    var own: [RepoStatus] { repos.filter { !$0.vendored } }
    var atRisk: [RepoStatus] { own.filter { $0.level >= .uncommitted } }

    func refresh(settings: SettingsSnapshot) {
        guard !loading else { return }
        loading = true
        Task {
            let list = await AppModel.background { CodeBackup.analyze(settings: settings) { m in Task { @MainActor in CodeBackupModel.shared.status = m } } }
            withAnimation(.spring(duration: 0.5)) {
                repos = list
                loading = false
                checkedAt = Date()
                if focused == nil { focused = visible.first?.id }
            }
        }
    }

    func run(_ label: String, on repo: RepoStatus, _ work: @escaping () -> (Bool, String)) {
        busy = repo.id
        Task {
            let r = await AppModel.background(work)
            let updated = await AppModel.background {
                FS.exists(repo.path.appendingPathComponent(".git")) ? CodeBackup.gitStatus(repo.path, linked: repo.isWorktree) : CodeBackup.folderStatus(repo.path, idx: nil)
            }
            withAnimation(.snappy) {
                if let i = repos.firstIndex(where: { $0.id == repo.id }) {
                    var u = updated; u.vendored = repo.vendored; u.lastActivity = repo.lastActivity
                    if u.sourceBytes == 0 { u.sourceBytes = repo.sourceBytes }
                    repos[i] = u
                }
                busy = nil
                toast = (r.0, "\(label): \(r.1)")
            }
            AuditLog.append([CleanOutcome(title: repo.name, category: "Code backup", paths: [repo.path.path], size: 0, method: label, success: r.0, message: r.1)])
            try? await Task.sleep(for: .seconds(6))
            withAnimation { toast = nil }
        }
    }
}

struct CodeBackupView: View {
    @Environment(AppModel.self) private var model
    @State private var cb = CodeBackupModel.shared
    @State private var confirm: PendingAction?

    struct PendingAction: Identifiable {
        var id = UUID()
        var title: String
        var message: String
        var button: String
        var work: () -> Void
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                list.frame(minWidth: 380, idealWidth: 440)
                Divider()
                detail.frame(minWidth: 440, maxWidth: .infinity)
            }
        }
        .navigationTitle("Code Backup")
        .onAppear { if cb.repos.isEmpty && !cb.loading { cb.refresh(settings: model.settings.snapshot) } }
        .alert(confirm?.title ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), presenting: confirm) { c in
            Button(c.button) { c.work() }
            Button("Cancel", role: .cancel) {}
        } message: { c in Text(c.message) }
        .overlay(alignment: .bottom) {
            if let t = cb.toast {
                Label(t.text, systemImage: t.ok ? "checkmark.circle.fill" : "xmark.octagon.fill").lineLimit(3)
                    .padding(.horizontal, 14).padding(.vertical, 10).frame(maxWidth: 560)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .padding(.bottom, 16).transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: Header with the at-a-glance bar

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(cb.loading ? "Checking your projects…" : headline).font(.title2.weight(.semibold)).contentTransition(.numericText())
                    Text(cb.loading ? cb.status : "Prune checks projects for code that may not be backed up in Git: no repository or remote, unpushed commits, local-only branches, stashes and uncommitted edits.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button { cb.refresh(settings: model.settings.snapshot) } label: { Label("Check Again", systemImage: "arrow.clockwise") }
                    .disabled(cb.loading)
            }
            DiskScopeBar { v in
                let n = cb.atRisk.filter { v == nil || model.volume(for: $0.path)?.url.path == v!.url.path }.count
                return n > 0 ? "\(n) at risk" : nil
            }
            if !cb.own.isEmpty {
                StackedLevelBar(repos: cb.own, selected: cb.level) { l in withAnimation(.snappy) { cb.level = cb.level == l ? nil : l } }
            }
        }
        .padding(16)
    }

    private var headline: String {
        let n = cb.atRisk.count
        if cb.own.isEmpty { return "Code Backup" }
        return n == 0 ? "No local changes ahead of known remotes" : "\(n) of \(cb.own.count) projects need attention"
    }

    // MARK: List

    private var list: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("Show dependency checkouts", isOn: $cb.showVendored.animation(.snappy)).toggleStyle(.switch).controlSize(.small)
                Spacer()
                Text("\(cb.visible.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            if cb.loading && cb.repos.isEmpty {
                VStack(spacing: 10) { ProgressView(); Text(cb.status).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $cb.focused) {
                    ForEach(cb.visible) { r in
                        HStack(spacing: 10) {
                            Image(systemName: r.level.symbol).foregroundStyle(r.level.color).frame(width: 20)
                                .symbolEffect(.bounce, value: r.level)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 5) { Text(r.name).fontWeight(.medium); VolumeBadge(url: r.path) }
                                Text(r.headline).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Text(FS.tildePath(r.path.deletingLastPathComponent())).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            if cb.busy == r.id { ProgressView().controlSize(.small) }
                        }
                        .padding(.vertical, 3)
                        .tag(r.id)
                    }
                }
                .listStyle(.inset)
                .animation(.snappy, value: cb.visible.map(\.id))
            }
        }
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if let id = cb.focused, let r = cb.repos.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        Image(systemName: r.level.symbol).font(.system(size: 30)).foregroundStyle(r.level.color).symbolEffect(.bounce, value: r.id)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.name).font(.title3.weight(.semibold))
                            Text(r.level.title + " · " + r.level.blurb).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    WhereCodeLivesDiagram(repo: r).id(r.id)
                    facts(r)
                    actions(r)
                }
                .padding(18)
            }
        } else {
            EmptyStateView(symbol: "externaldrive.badge.checkmark", title: "Select a project", message: "See where its code lives and what isn't backed up.")
        }
    }

    private func facts(_ r: RepoStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let b = r.currentBranch, !b.isEmpty { fact("arrow.triangle.branch", "On branch \(b)") }
            if let c = r.lastCommit { fact("clock", "Last commit \(Fmt.ago(c))") }
            if let a = r.lastActivity { fact("pencil", "Last edited \(Fmt.ago(a))") }
            if r.isGit, let f = r.lastFetch { fact("arrow.down.circle", "Remote status as of the last fetch, \(Fmt.ago(f))") }
            if r.isGit && r.lastFetch == nil && !r.remotes.isEmpty { fact("arrow.down.circle", "Never fetched: run Fetch for accurate ahead/behind counts") }
            if r.stashes > 0 { fact("tray.full", "\(r.stashes) stash\(r.stashes == 1 ? "" : "es"), which never leave this Mac. Apply and commit them to back them up.") }
            if r.isWorktree { fact("square.on.square", "Linked worktree. Its commits live in the main repository.") }
            if let error = r.analysisError { fact("exclamationmark.triangle", error) }
            if r.detachedUnpushed > 0 { fact("arrow.triangle.branch", "Detached HEAD has unpushed commits. Create a branch before pushing them.") }
            if r.vendored { fact("shippingbox", "Looks like a dependency checkout. Its upstream is the backup.") }
        }
    }

    private func fact(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon).font(.callout).foregroundStyle(.secondary)
    }

    @ViewBuilder private func actions(_ r: RepoStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Make it safe").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                if !r.isGit {
                    Button { confirm = PendingAction(title: "Initialize git in \(r.name)?", message: "Runs `git init` and adds a starter .gitignore (node_modules, build output, .env…). Nothing is committed or uploaded. Review `git status`, then make your first commit.", button: "Initialize") {
                        let ecos = Set(ProjectIndex.markerFiles.filter { FS.exists(r.path.appendingPathComponent($0.key)) }.map(\.value))
                        cb.run("Initialize git", on: r) { CodeBackup.initialize(r.path, ecosystems: ecos) }
                    } } label: { Label("Initialize Git", systemImage: "plus.circle") }
                }
                if r.level != .unknown && r.isGit && r.remotes.isEmpty && r.hasCommits && !r.isWorktree {
                    if CodeBackup.gh != nil {
                        Button { confirm = PendingAction(title: "Create a private GitHub repo for \(r.name)?",
                                                         message: "Creates a PRIVATE repository \u{201C}\(r.name)\u{201D} on the account currently signed in to the GitHub CLI, sets it as origin, and pushes every local branch. Check that no secrets are committed first.", button: "Create & Push") {
                            cb.run("Create GitHub repo", on: r) { CodeBackup.createPrivateRepo(r) }
                        } } label: { Label("Create Private GitHub Repo", systemImage: "icloud.and.arrow.up") }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Text("Add a remote (e.g. `gh repo create --private --source . --push`) to back it up.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if r.level != .unknown && r.isGit && !r.remotes.isEmpty && r.unpushedCommits > 0 {
                    let branches = r.branches.filter { $0.ahead > 0 || $0.localOnlyCommits > 0 }.map(\.name)
                    Button { confirm = PendingAction(title: "Push \(branches.count) branch\(branches.count == 1 ? "" : "es")?",
                                                     message: "Pushes \(branches.joined(separator: ", ")) to \(r.remotes.keys.contains("origin") ? "origin" : (r.remotes.keys.first ?? "the remote")) (\(r.remotes["origin"] ?? r.remotes.values.first ?? "")). Branches without an upstream get one.", button: "Push") {
                        cb.run("Push", on: r) { CodeBackup.push(r) }
                    } } label: { Label("Push", systemImage: "arrow.up.circle") }
                        .buttonStyle(.borderedProminent)
                }
                if r.level != .unknown && r.isGit && !r.remotes.isEmpty {
                    Button { cb.run("Fetch", on: r) { CodeBackup.fetch(r) } } label: { Label("Fetch", systemImage: "arrow.down.circle") }
                }
                Button { openTerminal(r.path) } label: { Label("Terminal", systemImage: "terminal") }
                Button { Finder.reveal([r.path]) } label: { Label("Reveal", systemImage: "magnifyingglass") }
            }
            .disabled(cb.busy != nil)
            if r.modified + r.untracked > 0 {
                Text("Uncommitted edits need a commit from you. Prune won't commit for you, because that's your call.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func openTerminal(_ url: URL) {
        let app = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Segmented bar of projects by backup level; click a segment to filter.
struct StackedLevelBar: View {
    let repos: [RepoStatus]
    let selected: RepoStatus.Level?
    let onSelect: (RepoStatus.Level) -> Void
    @State private var grow = false

    var body: some View {
        let counts = RepoStatus.Level.allCases.reversed().map { l in (l, repos.filter { $0.level == l }.count) }.filter { $0.1 > 0 }
        let total = max(1, repos.count)
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { g in
                HStack(spacing: 3) {
                    ForEach(counts, id: \.0) { l, n in
                        RoundedRectangle(cornerRadius: 5)
                            .fill(l.color.gradient)
                            .opacity(selected == nil || selected == l ? 1 : 0.3)
                            .frame(width: grow ? max(8, (g.size.width - CGFloat(counts.count * 3)) * CGFloat(n) / CGFloat(total)) : 8)
                            .overlay(Text("\(n)").font(.caption.weight(.bold)).foregroundStyle(.white).opacity(n > 0 ? 1 : 0))
                            .onTapGesture { onSelect(l) }
                            .help("\(l.title): \(n)")
                    }
                }
            }
            .frame(height: 24)
            HStack(spacing: 14) {
                ForEach(counts, id: \.0) { l, n in
                    Button { onSelect(l) } label: {
                        HStack(spacing: 5) { Circle().fill(l.color).frame(width: 8, height: 8); Text("\(l.title) \(n)").font(.caption) }
                    }.buttonStyle(.plain)
                }
            }
        }
        .onAppear { withAnimation(.spring(duration: 0.8, bounce: 0.25)) { grow = true } }
    }
}

/// Literal picture: this Mac on the left, the remote on the right, one arrow per branch.
struct WhereCodeLivesDiagram: View {
    let repo: RepoStatus
    @State private var appear = false

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            box(icon: "laptopcomputer", title: "This Mac", subtitle: FS.tildePath(repo.path), tint: repo.level >= .unpushed ? repo.level.color : .accentColor) {
                if !repo.isGit {
                    Label("Files only, no history", systemImage: "doc.on.doc").font(.caption)
                } else {
                    ForEach(repo.branches.prefix(6), id: \.name) { b in
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.triangle.branch").font(.caption2)
                            Text(b.name).font(.caption.monospaced()).lineLimit(1)
                            if b.ahead + b.localOnlyCommits > 0 { Text("+\(b.ahead + b.localOnlyCommits)").font(.caption2.bold()).foregroundStyle(.orange) }
                        }
                    }
                    if repo.branches.count > 6 { Text("+\(repo.branches.count - 6) more").font(.caption2).foregroundStyle(.secondary) }
                    if repo.modified + repo.untracked > 0 { Label("\(repo.modified + repo.untracked) uncommitted", systemImage: "pencil").font(.caption).foregroundStyle(.yellow) }
                    if repo.stashes > 0 { Label("\(repo.stashes) stash", systemImage: "tray.full").font(.caption).foregroundStyle(.orange) }
                }
            }
            VStack(spacing: 6) {
                if repo.level == .unknown {
                    SyncArrow(state: .broken).frame(width: 74, height: 16)
                    Text("status unknown").font(.caption2).foregroundStyle(.secondary)
                } else if !repo.isGit || repo.remotes.isEmpty {
                    SyncArrow(state: .broken).frame(width: 74, height: 16)
                    Text(repo.isGit ? "nothing to sync to" : "not tracked").font(.caption2).foregroundStyle(.red)
                } else if repo.unpushedCommits > 0 || repo.detachedUnpushed > 0 || repo.modified + repo.untracked > 0 {
                    SyncArrow(state: .pending).frame(width: 74, height: 16)
                    Text("Local changes").font(.caption2.bold()).foregroundStyle(.orange)
                } else {
                    SyncArrow(state: .synced).frame(width: 74, height: 16)
                    Text("last known state").font(.caption2).foregroundStyle(.green)
                }
            }
            .opacity(appear ? 1 : 0)
            box(icon: repo.remotes.isEmpty ? "icloud.slash" : "icloud", title: repo.level == .unknown ? "Remote unknown" : (repo.remotes.isEmpty ? "No remote" : "Remote"),
                subtitle: repo.level == .unknown ? "Git could not check" : (repo.remotes["origin"].map(shortRemote) ?? repo.remotes.values.first.map(shortRemote) ?? "No Git remote is configured"),
                tint: repo.level == .unknown ? .gray : (repo.remotes.isEmpty ? .red : .green), dashed: repo.remotes.isEmpty) {
                ForEach(repo.branches.filter { $0.upstream != nil }.prefix(6), id: \.name) { b in
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch").font(.caption2)
                        Text(b.upstream ?? "").font(.caption.monospaced()).lineLimit(1)
                        if b.behind > 0 { Text("\u{2193}\(b.behind)").font(.caption2).foregroundStyle(.secondary) }
                    }
                }
            }
            .opacity(appear ? 1 : 0.2)
        }
        .onAppear { withAnimation(.easeOut(duration: 0.5).delay(0.1)) { appear = true } }
    }

    private func shortRemote(_ url: String) -> String {
        url.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "git@", with: "").replacingOccurrences(of: ".git", with: "").replacingOccurrences(of: ":", with: "/")
    }

    private func box<C: View>(icon: String, title: String, subtitle: String, tint: Color, dashed: Bool = false, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.title3).foregroundStyle(tint)
                Text(title).font(.headline)
            }
            Text(subtitle).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            Divider()
            content()
        }
        .padding(12)
        .frame(width: 180, alignment: .leading)
        .frame(minHeight: 130, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 12).fill(tint.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: dashed ? [5, 4] : [])))
    }
}

struct SyncArrow: View {
    enum State { case synced, pending, broken }
    let state: State
    @SwiftUI.State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { g in
            let y = g.size.height / 2
            let color: Color = state == .synced ? .green : (state == .pending ? .orange : .red)
            ZStack {
                Path { p in p.move(to: CGPoint(x: 4, y: y)); p.addLine(to: CGPoint(x: g.size.width - 8, y: y)) }
                    .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: state == .synced ? [] : [6, 5], dashPhase: phase))
                if state == .broken {
                    Image(systemName: "xmark").font(.caption.bold()).foregroundStyle(.red).position(x: g.size.width / 2, y: y)
                        .background(Circle().fill(.background).frame(width: 16, height: 16).position(x: g.size.width / 2, y: y))
                } else {
                    Path { p in
                        p.move(to: CGPoint(x: g.size.width - 12, y: y - 5)); p.addLine(to: CGPoint(x: g.size.width - 4, y: y)); p.addLine(to: CGPoint(x: g.size.width - 12, y: y + 5))
                    }.stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .onAppear { if state == .pending { withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { phase = -22 } } }
    }
}
