import SwiftUI

@MainActor
@Observable
final class SecretsModel {
    static let shared = SecretsModel()
    var report = SecretsReport()
    var loading = false
    var status = ""
    var filter: Filter = .issues
    var focused: String?
    var toast: (ok: Bool, text: String)?

    enum Filter: String, CaseIterable {
        case issues = "Needs attention", pushed = "Pushed", env = "Env files", home = "Home & shell", all = "Everything"
    }

    func adopt(_ r: SecretsReport) {
        withAnimation(.spring(duration: 0.45)) {
            report = r
            if focused == nil { focused = visible.first?.id }
        }
    }

    var visible: [SecretFile] {
        let model = AppModel.shared
        let list = report.files.filter { f in
            guard f.origin == .home || model.inScope(f.url) else { return false }
            switch filter {
            case .issues: return f.isIssue
            case .pushed: return f.pushed && f.hasSecret
            case .env: return f.isEnvFile
            case .home: return f.origin == .home
            case .all: return true
            }
        }
        return list.sorted { ($0.severity, $0.realHits.count) > ($1.severity, $1.realHits.count) }
    }

    func count(_ f: Filter) -> Int {
        report.files.filter { file in
            switch f {
            case .issues: file.isIssue
            case .pushed: file.pushed && file.hasSecret
            case .env: file.isEnvFile
            case .home: file.origin == .home
            case .all: true
            }
        }.count
    }

    func refresh(settings: SettingsSnapshot) {
        guard !loading else { return }
        loading = true
        Task {
            let r = await AppModel.background {
                SecretsEngine.scan(index: ProjectIndex.cached(roots: settings.resolvedScanRoots(), settings: settings), settings: settings) { m in
                    Task { @MainActor in SecretsModel.shared.status = m }
                }
            }
            adopt(r)
            loading = false
        }
    }

    func act(_ label: String, _ file: SecretFile, _ work: @escaping () -> (Bool, String)) {
        Task {
            let r = await AppModel.background(work)
            AuditLog.append([CleanOutcome(title: file.url.lastPathComponent, category: "Secrets", paths: [file.url.path], size: 0, method: label, success: r.0, message: r.1)])
            if r.0 { refreshFile(file) }
            withAnimation(.snappy) { toast = (r.0, r.1) }
            try? await Task.sleep(for: .seconds(6))
            withAnimation { if toast?.text == r.1 { toast = nil } }
        }
    }

    /// Re-reads git state for one file after a fix.
    private func refreshFile(_ file: SecretFile) {
        Task {
            let updated = await AppModel.background { () -> SecretFile in
                var f = file
                guard f.origin == .project, let root = SecretsEngine.repoRoot(for: f.url) else {
                    var st = stat(); lstat(f.url.path, &st); f.worldReadable = st.st_mode & 0o044 != 0; return f
                }
                let rel = String(f.url.resolvingSymlinksInPath().path.dropFirst(root.resolvingSymlinksInPath().path.count + 1))
                if !Git.run(root, ["ls-files", "--", rel]).stdout.isEmpty { f.git = .tracked }
                else { f.git = Git.run(root, ["check-ignore", "-q", "--", rel]).status == 0 ? .ignored : .untracked }
                return f
            }
            withAnimation(.snappy) {
                if let i = report.files.firstIndex(where: { $0.id == file.id }) { report.files[i] = updated }
            }
        }
    }
}

struct SecretsView: View {
    @Environment(AppModel.self) private var model
    @State private var sm = SecretsModel.shared
    @State private var confirm: (title: String, message: String, button: String, work: () -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                list.frame(minWidth: 360, idealWidth: 420)
                Divider()
                detail.frame(minWidth: 440, maxWidth: .infinity)
            }
        }
        .navigationTitle("Secrets")
        .onAppear { if sm.report.scannedAt == nil && !sm.loading { sm.refresh(settings: model.settings.snapshot) } }
        .alert(confirm?.title ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button(confirm?.button ?? "OK") { confirm?.work() }
            Button("Cancel", role: .cancel) {}
        } message: { Text(confirm?.message ?? "") }
        .overlay(alignment: .bottom) { if let t = sm.toast { ToastView(ok: t.ok, text: t.text) } }
    }

    private var header: some View {
        let issues = sm.report.issues
        let pushed = sm.report.files.filter { $0.pushed && $0.hasSecret }.count
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(sm.loading ? "Looking for secrets…" : (issues.isEmpty ? "No exposed secrets found" : "\(issues.count) file\(issues.count == 1 ? "" : "s") need attention"))
                        .font(.title2.weight(.semibold)).contentTransition(.numericText())
                    Text(sm.loading ? sm.status : "API keys, tokens, passwords and .env files in your projects and home folder, checked against git. Values are never stored or shown in full.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { sm.refresh(settings: model.settings.snapshot) } label: { Label("Scan Again", systemImage: "arrow.clockwise") }.disabled(sm.loading)
            }
            HStack(spacing: 10) {
                tile("exclamationmark.icloud.fill", .red, "\(pushed)", "pushed to a remote")
                tile("doc.badge.gearshape.fill", .orange, "\(sm.report.files.filter { $0.isEnvFile && $0.git != .ignored && !$0.isExample }.count)", "env files not ignored")
                tile("terminal.fill", .purple, "\(sm.report.files.filter { $0.isShellProfile && $0.hasSecret }.count)", "secrets in shell profiles")
                tile("doc.on.doc.fill", .blue, "\(sm.report.reused.count)", "reused secrets")
                tile("doc.text.magnifyingglass", .secondary, "\(sm.report.filesChecked.formatted())", "files checked")
            }
            HStack {
                Picker("", selection: $sm.filter) {
                    ForEach(SecretsModel.Filter.allCases, id: \.self) { f in Text("\(f.rawValue) \(sm.count(f))").tag(f) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 560)
                Spacer()
            }
            DiskScopeBar()
        }
        .padding(16)
    }

    private func tile(_ symbol: String, _ tint: Color, _ value: String, _ label: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint).font(.title3)
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(.headline.monospacedDigit()).contentTransition(.numericText())
                Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    private var list: some View {
        List(selection: $sm.focused) {
            ForEach(sm.visible) { f in
                HStack(spacing: 10) {
                    Image(systemName: f.origin == .home ? "house.fill" : (f.isEnvFile ? "doc.badge.gearshape" : "doc.text"))
                        .foregroundStyle(f.severity.color).frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(f.url.lastPathComponent).fontWeight(.medium).lineLimit(1)
                            if f.pushed && f.hasSecret { Text("PUSHED").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white).padding(.horizontal, 5).padding(.vertical, 1).background(Color.red, in: Capsule()) }
                        }
                        Text(f.project.map { $0.lastPathComponent + " · " } ?? "" + (f.label ?? "")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Text(f.headline).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    VolumeBadge(url: f.url)
                    SeverityPill(severity: f.severity)
                }
                .padding(.vertical, 2)
                .tag(f.id)
            }
        }
        .listStyle(.inset)
        .overlay {
            if sm.visible.isEmpty && !sm.loading {
                EmptyStateView(symbol: "checkmark.shield", title: "Nothing here", message: sm.report.scannedAt == nil ? "Run a scan to check your projects." : "No files match this filter.")
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let id = sm.focused, let f = sm.report.files.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        Image(systemName: f.hasSecret ? "key.fill" : "doc.badge.gearshape.fill").font(.system(size: 30)).foregroundStyle(f.severity.color)
                            .symbolEffect(.bounce, value: f.id)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.url.lastPathComponent).font(.title3.weight(.semibold))
                            Text(FS.tildePath(f.url)).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                        }
                        Spacer()
                        SeverityPill(severity: f.severity)
                    }
                    FlowChain(nodes: chain(f)).id(f.id)
                    if !f.hits.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("What Prune found", systemImage: "eye.trianglebadge.exclamationmark").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(f.hits.prefix(40)) { h in hitRow(f, h) }
                        }
                    }
                    DetailSection(title: "Why it matters", symbol: "info.circle", text: advice(f), tint: f.severity >= .medium ? f.severity.color : .secondary)
                    actions(f)
                }
                .padding(18)
            }
        } else {
            EmptyStateView(symbol: "key.viewfinder", title: "Select a file", message: "See which values look like credentials, whether git tracks or pushed them, and what to do.")
        }
    }

    private func chain(_ f: SecretFile) -> [ChainNode] {
        if f.origin == .home {
            return [ChainNode(kind: "File", label: f.label ?? f.url.lastPathComponent, detail: f.worldReadable ? "readable by others" : "only you", risky: f.worldReadable),
                    ChainNode(kind: "Read by", label: f.isShellProfile ? "Every program you start" : "Its tool", detail: f.isShellProfile ? "incl. npm/pip install scripts" : "", risky: f.isShellProfile && f.hasSecret)]
        }
        return [ChainNode(kind: "File", label: f.url.lastPathComponent, detail: "\(f.realHits.count) secret\(f.realHits.count == 1 ? "" : "s")", risky: f.hasSecret),
                ChainNode(kind: "Git", label: f.git.rawValue.capitalized, detail: f.inHistory ? "in history" : "", risky: f.git == .tracked || f.git == .untracked),
                ChainNode(kind: "Remote", label: f.pushed ? "Pushed" : "Not pushed", detail: f.pushed ? "left this Mac" : "local only", risky: f.pushed)]
    }

    private func hitRow(_ f: SecretFile, _ h: SecretHit) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("L\(h.line)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(h.provider.map { "\($0) · \(h.kind)" } ?? h.kind).font(.callout.weight(.medium))
                    if h.lowImpact { Text("low impact").font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 5).background(Color.secondary.opacity(0.12), in: Capsule()) }
                }
                Text(h.masked).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                Text(h.why).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            ConfidenceMeter(value: h.confidence).frame(width: 60)
            Button { SecretsEngine.openInEditor(f.url, line: h.line) } label: { Image(systemName: "arrow.up.forward.square") }
                .buttonStyle(.borderless).help("Open at line \(h.line)")
        }
        .padding(8)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .opacity(h.lowImpact ? 0.65 : 1)
    }

    private func advice(_ f: SecretFile) -> String {
        if f.pushed && f.hasSecret { return "These values are on a remote branch, so anyone with access to the repository (or a fork, or a CI log) may have them. Rotate them at the provider first, then stop tracking the file." }
        if f.git == .tracked && f.hasSecret { return "Git tracks this file, so the next push publishes the values. Stop tracking it and keep real values in an ignored file." }
        if f.inHistory && f.hasSecret { return "The file is no longer tracked, but an earlier commit contains it. Rotate the values; rewriting history alone doesn't revoke a leaked key." }
        if f.origin == .home && f.isShellProfile { return "Secrets exported from a shell profile are visible to every program you start, including package install scripts, the most common target of supply-chain malware." }
        if f.origin == .home { return f.worldReadable ? "Other accounts on this Mac can read this file. Restrict it to your account." : "A normal place for this tool to keep its login. Nothing to do unless you no longer use the tool." }
        if f.git == .untracked && f.isEnvFile { return "Git isn't ignoring this env file, so a git add . would commit it. Add it to .gitignore." }
        if f.git == .ignored { return "Git ignores this file, which is the right place for local secrets. Make sure backups and sync tools treat it with the same care." }
        return "No action needed."
    }

    @ViewBuilder private func actions(_ f: SecretFile) -> some View {
        HStack(spacing: 8) {
            if f.origin == .project && f.git == .tracked {
                Button {
                    confirm = ("Stop tracking \(f.url.lastPathComponent)?", "Runs git rm --cached (the file stays on disk) and adds it to .gitignore. Commit the change afterwards. Values already in history are not removed, so rotate them.", "Stop Tracking", {
                        sm.act("Stop tracking", f) { SecretsEngine.stopTracking(f.url) }
                    })
                } label: { Label("Stop tracking…", systemImage: "eye.slash") }
            }
            if f.origin == .project && f.git == .untracked {
                Button { sm.act("Add to .gitignore", f) { SecretsEngine.addToGitignore(f.url) } } label: { Label("Add to .gitignore", systemImage: "plus.square.dashed") }
            }
            if f.isEnvFile && !f.isExample && !FS.exists(f.url.deletingLastPathComponent().appendingPathComponent(f.url.lastPathComponent + ".example")) {
                Button { sm.act("Create example", f) { SecretsEngine.makeExample(f.url) } } label: { Label("Create .example", systemImage: "doc.badge.plus") }
                    .help("Writes the same keys with empty values: safe to commit")
            }
            if f.worldReadable {
                Button { sm.act("Restrict permissions", f) { SecretsEngine.restrictPermissions(f.url) } } label: { Label("Only me (600)", systemImage: "lock") }
            }
            Button { Finder.reveal([f.url]) } label: { Label("Reveal", systemImage: "magnifyingglass") }
            if f.hasSecret {
                Button {
                    SecretsEngine.ignore(f)
                    withAnimation { sm.report.files.removeAll { $0.id == f.id }; sm.focused = sm.visible.first?.id }
                } label: { Label("Not a secret", systemImage: "hand.thumbsdown") }
                    .help("Hide these values from future scans")
            }
        }
        .buttonStyle(.bordered)
    }
}

struct ConfidenceMeter: View {
    let value: Double
    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(value >= 0.85 ? Color.red : value >= 0.65 ? .orange : .yellow).frame(width: g.size.width * value)
                }
            }
            .frame(height: 5)
            Text("\(Int(value * 100))% sure").font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .help("How confident Prune is that this is a real credential")
    }
}
