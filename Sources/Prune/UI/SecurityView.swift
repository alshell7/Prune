import AppKit
import Observation
import SwiftUI

extension Severity {
    var color: Color {
        switch self {
        case .info: .secondary
        case .low: .blue
        case .medium: .yellow
        case .high: .orange
        case .critical: .red
        }
    }
    var symbol: String {
        switch self {
        case .info: "checkmark.circle"
        case .low: "info.circle"
        case .medium: "exclamationmark.circle"
        case .high: "exclamationmark.triangle"
        case .critical: "xmark.octagon"
        }
    }
}

@MainActor
@Observable
final class SecurityModel {
    static let shared = SecurityModel()
    var report = SecurityReport()
    var scanning = false
    var status = ""
    var scannedAt: Date?
    var area: SecurityArea?
    var showInventory = false
    var focused: String?
    var quarantine: [QuarantineEntry] = Quarantine.load()
    var toast: (ok: Bool, text: String)?
    var osvRunning = false
    var osvDone = false

    var issues: [SecurityFinding] { report.findings.filter { !$0.inventoryOnly } }

    var visible: [SecurityFinding] {
        report.findings.filter { (showInventory || !$0.inventoryOnly) && (area == nil || $0.area == area) }
    }

    func count(_ a: SecurityArea, issuesOnly: Bool = true) -> Int {
        report.findings.filter { $0.area == a && (!issuesOnly || !$0.inventoryOnly) }.count
    }

    func worst(_ a: SecurityArea) -> Severity? { report.findings.filter { $0.area == a && !$0.inventoryOnly }.map(\.severity).max() }

    func scan(settings: SettingsSnapshot) {
        guard !scanning else { return }
        scanning = true
        status = "Starting…"
        osvDone = false
        Task {
            let r = await AppModel.background { SecurityScanner.run(settings: settings) { m in Task { @MainActor in SecurityModel.shared.status = m } } }
            withAnimation(.spring(duration: 0.5)) {
                report = r
                scanning = false
                scannedAt = Date()
            }
            if focused == nil { focused = issues.first?.id }
            if let worst = issues.first, worst.severity >= .high {
                Notifier.post(title: "Security check: \(worst.severity.label.lowercased()) finding", body: worst.title)
            }
        }
    }

    func perform(_ action: SecurityAction, on f: SecurityFinding) {
        Task {
            let r = await AppModel.background { SecurityActions.perform(action, finding: f) }
            withAnimation(.snappy) {
                toast = (r.ok, r.message)
                quarantine = Quarantine.load()
                if r.ok, !isOpenURL(action) {
                    report.findings.removeAll { $0.id == f.id }
                    focused = visible.first?.id
                }
            }
            try? await Task.sleep(for: .seconds(5))
            withAnimation { if toast?.text == r.message { toast = nil } }
        }
    }

    private func isOpenURL(_ a: SecurityAction) -> Bool { if case .openURL = a { return true }; return false }

    func checkOnline() {
        guard !osvRunning else { return }
        osvRunning = true
        let pkgs = report.npmPackages
        Task {
            let found = await AppModel.background { () -> [String: [String]] in
                let items = pkgs.keys.compactMap { key -> (String, String)? in
                    guard let at = key.lastIndex(of: "@"), at != key.startIndex else { return nil }
                    return (String(key[..<at]), String(key[key.index(after: at)...]))
                }
                return PackageAnalyzer.osvMalicious(items)
            }
            for (key, ids) in found {
                let paths = pkgs[key] ?? []
                report.findings.insert(SecurityFinding(
                    id: "osv:\(key)", area: .packages, severity: .critical, title: key, subtitle: "Listed as malicious by OSV.dev (\(ids.joined(separator: ", ")))",
                    evidence: ["OpenSSF/OSV malicious-package advisory: \(ids.joined(separator: ", "))", "Installed in: " + paths.prefix(4).map { FS.tildePath(URL(fileURLWithPath: $0)) }.joined(separator: ", ")],
                    explanation: "OSV.dev aggregates confirmed malicious package reports from the OpenSSF malicious-packages project.",
                    legitNote: nil, recommendation: "Quarantine it, remove it from package.json and the lockfile, reinstall, and rotate any tokens available on this Mac.",
                    actions: [.quarantine(paths: paths)], paths: paths), at: 0)
            }
            osvRunning = false
            osvDone = true
            toast = (found.isEmpty, found.isEmpty ? "OSV.dev: none of your \(pkgs.count) npm packages are listed as malicious." : "OSV.dev flagged \(found.count) package(s).")
        }
    }
}

struct SecurityView: View {
    @Environment(AppModel.self) private var model
    @State private var sec = SecurityModel.shared
    @State private var confirm: (SecurityAction, SecurityFinding)?
    @State private var showQuarantine = false
    @State private var confirmOSV = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if sec.report.findings.isEmpty && !sec.scanning {
                intro
            } else {
                HStack(spacing: 0) {
                    list.frame(minWidth: 380, idealWidth: 440)
                    Divider()
                    detail.frame(minWidth: 420, maxWidth: .infinity)
                }
            }
        }
        .navigationTitle("Security")
        .onAppear { if sec.scannedAt == nil && !sec.scanning { sec.scan(settings: model.settings.snapshot) } }
        .overlay(alignment: .bottom) { toastView }
        .sheet(isPresented: $showQuarantine) { QuarantineSheet() }
        .alert(confirm.map { "\($0.0.title)?" } ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), presenting: confirm) { pair in
            Button(pair.0.title, role: { if case .stopProcess = pair.0 { return ButtonRole.destructive }; return nil }()) { sec.perform(pair.0, on: pair.1) }
            Button("Cancel", role: .cancel) {}
        } message: { pair in Text(pair.0.explanation) }
        .alert("Check npm packages online?", isPresented: $confirmOSV) {
            Button("Check with OSV.dev") { sec.checkOnline() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sends the names and versions of your \(sec.report.npmPackages.count) installed npm packages (nothing else: no paths, code or identity) to api.osv.dev, Google's open vulnerability database, to look for packages reported as malware since this version of Prune was built.")
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 16) {
                ShieldBadge(worst: sec.issues.map(\.severity).max(), scanning: sec.scanning, hasRun: sec.scannedAt != nil)
                VStack(alignment: .leading, spacing: 4) {
                    Text(headline).font(.title2.weight(.semibold)).contentTransition(.numericText())
                    Text(sec.scanning ? sec.status : (sec.scannedAt.map { "Checked \(Fmt.relative($0)) · \(sec.report.stats["processes"] ?? 0) processes · \(sec.report.stats["npm packages"] ?? 0) npm packages · \(sec.report.stats["projects"] ?? 0) projects" } ?? "Looks for malware, risky background items, poisoned packages and AI-agent backdoors. Read-only until you choose an action."))
                        .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button { showQuarantine = true } label: { Label("Quarantine (\(sec.quarantine.count))", systemImage: "lock.doc") }
                if !sec.report.npmPackages.isEmpty {
                    Button { confirmOSV = true } label: {
                        if sec.osvRunning { ProgressView().controlSize(.small) } else { Label(sec.osvDone ? "Checked online" : "Check packages online…", systemImage: "network.badge.shield.half.filled") }
                    }.disabled(sec.osvRunning || sec.osvDone)
                }
                Button { sec.scan(settings: model.settings.snapshot) } label: {
                    Label(sec.scannedAt == nil ? "Run Security Check" : "Check Again", systemImage: "shield.lefthalf.filled")
                }
                .buttonStyle(.borderedProminent).disabled(sec.scanning)
            }
            if !sec.report.protections.isEmpty {
                HStack(spacing: 8) {
                    ForEach(sec.report.protections, id: \.name) { p in
                        Button {
                            if let s = p.settingsURL, let u = URL(string: s) { NSWorkspace.shared.open(u) }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: p.on ? "checkmark.shield.fill" : "exclamationmark.shield.fill").foregroundStyle(p.on ? .green : .orange)
                                Text(p.name).font(.caption.weight(.medium))
                            }
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background((p.on ? Color.green : Color.orange).opacity(0.1), in: Capsule())
                        }
                        .buttonStyle(.plain).help(p.detail)
                    }
                }
                areaTiles
            }
        }
        .padding(16)
    }

    private var headline: String {
        if sec.scanning { return "Checking your Mac…" }
        guard sec.scannedAt != nil else { return "Security Check" }
        let n = sec.issues.filter { $0.severity >= .medium }.count
        let low = sec.issues.filter { $0.severity == .low }.count
        if n == 0 { return low == 0 ? "No threats found" : "No threats found · \(low) item\(low == 1 ? "" : "s") worth a look" }
        return "\(n) thing\(n == 1 ? "" : "s") need\(n == 1 ? "s" : "") your attention" + (low > 0 ? " · \(low) worth a look" : "")
    }

    private var areaTiles: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                AreaTile(title: "All", icon: "square.grid.2x2", count: sec.issues.count, total: sec.report.findings.count, worst: sec.issues.map(\.severity).max(), selected: sec.area == nil) {
                    withAnimation(.snappy) { sec.area = nil }
                }
                ForEach(SecurityArea.allCases, id: \.self) { a in
                    let checked = a == .packages ? (sec.report.stats["npm packages"] ?? 0) : (a == .projects ? (sec.report.stats["projects"] ?? 0) : sec.count(a, issuesOnly: false))
                    AreaTile(title: a.rawValue, icon: a.icon, count: sec.count(a), total: checked, worst: sec.worst(a), selected: sec.area == a) {
                        withAnimation(.snappy) { sec.area = sec.area == a ? nil : a }
                    }
                }
            }
        }
    }

    private var intro: some View {
        VStack(spacing: 18) {
            Spacer()
            ShieldBadge(worst: nil, scanning: sec.scanning, hasRun: false, size: 84)
            Text("Is anything on this Mac that shouldn't be?").font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 8) {
                ForEach([("clock.arrow.2.circlepath", "Background items, root helpers, cron, login hooks: who starts what, signed by whom"),
                         ("cpu", "Running processes: disguised names, deleted binaries, temp-folder programs, unknown network peers"),
                         ("shippingbox", "npm & Python packages: known-compromised versions, malicious install scripts, worms, typosquats"),
                         ("sparkles", "AI agents: Claude/Codex/Cursor hooks, MCP servers, third-party skills, hidden-text prompt injection"),
                         ("hammer", "Projects: auto-run VS Code tasks, git hooks and Xcode scripts used by fake job-interview repos"),
                         ("globe", "Browser extensions installed outside the web store with broad access")], id: \.1) { icon, text in
                    Label(text, systemImage: icon).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            Button { sec.scan(settings: model.settings.snapshot) } label: { Text("Run Security Check").frame(minWidth: 180) }
                .buttonStyle(.borderedProminent).controlSize(.large)
            Text("Everything runs locally. Nothing is changed until you pick an action, and every action can be undone from Quarantine.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    // MARK: List

    private var list: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("Show everything (clean items too)", isOn: $sec.showInventory.animation(.snappy)).toggleStyle(.switch).controlSize(.small)
                Spacer()
                Text("\(sec.visible.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            if sec.scanning && sec.report.findings.isEmpty {
                VStack(spacing: 12) { ProgressView(); Text(sec.status).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if sec.visible.isEmpty {
                EmptyStateView(symbol: "checkmark.shield", title: "Nothing here", message: sec.showInventory ? "No items in this area." : "No issues in this area. Turn on \u{201C}Show everything\u{201D} to see what was checked.")
            } else {
                List(selection: $sec.focused) {
                    ForEach(sec.visible) { f in
                        FindingRow(f: f).tag(f.id)
                            .transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity), removal: .opacity.combined(with: .scale(scale: 0.9))))
                    }
                }
                .listStyle(.inset)
                .animation(.snappy, value: sec.visible.map(\.id))
            }
        }
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if let id = sec.focused, let f = sec.report.findings.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: f.severity.symbol).font(.system(size: 30)).foregroundStyle(f.severity.color)
                            .symbolEffect(.bounce, value: f.id)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(f.title).font(.title3.weight(.semibold)).textSelection(.enabled)
                            Text(f.subtitle).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                            HStack(spacing: 6) {
                                SeverityPill(severity: f.severity)
                                Label(f.area.rawValue, systemImage: f.area.icon).font(.caption).foregroundStyle(.secondary)
                                if let s = f.signer { Label(s, systemImage: "signature").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                    if let chain = sec.report.chains[f.id], !chain.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("How it fits together").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            FlowChain(nodes: chain).id(f.id)
                        }
                    }
                    if !f.evidence.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(f.inventoryOnly ? "Notes" : "Why Prune flagged it").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(Array(f.evidence.enumerated()), id: \.offset) { i, e in
                                HStack(alignment: .top, spacing: 8) {
                                    Circle().fill(f.severity.color).frame(width: 6, height: 6).padding(.top, 6)
                                    Text(e).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                }
                                .transition(.opacity.combined(with: .offset(y: 6)))
                            }
                        }
                    }
                    DetailSection(title: "What this is", symbol: "info.circle", text: f.explanation)
                    if let l = f.legitNote { DetailSection(title: "Could be fine if…", symbol: "hand.thumbsup", text: l, tint: .green) }
                    DetailSection(title: "Recommendation", symbol: "lightbulb", text: f.recommendation, tint: f.severity >= .high ? .orange : .accentColor)
                    if !f.actions.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Actions").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                ForEach(f.actions, id: \.self) { a in
                                    Button { confirm = (a, f) } label: { Label(a.title, systemImage: a.symbol) }
                                        .buttonStyle(.bordered).tint(f.severity >= .high ? .red : nil)
                                }
                                if !f.paths.isEmpty { Button { Finder.reveal(f.paths.map { URL(fileURLWithPath: $0) }) } label: { Label("Reveal", systemImage: "magnifyingglass") } }
                            }
                        }
                    }
                }
                .padding(18)
                .animation(.snappy, value: f.id)
            }
        } else {
            EmptyStateView(symbol: "shield.lefthalf.filled", title: "Select a finding", message: "See what it is, how it's wired into your system, and what you can do about it.")
        }
    }

    @ViewBuilder private var toastView: some View {
        if let t = sec.toast {
            Label(t.text, systemImage: t.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder((t.ok ? Color.green : Color.red).opacity(0.4)))
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

// MARK: - Components

struct ShieldBadge: View {
    var worst: Severity?
    var scanning: Bool
    var hasRun: Bool
    var size: CGFloat = 46
    @State private var pulse = false

    var body: some View {
        let color: Color = !hasRun ? .accentColor : (worst.map { $0 >= .medium ? $0.color : .green } ?? .green)
        ZStack {
            Circle().fill(color.opacity(0.12)).frame(width: size * 1.35, height: size * 1.35)
                .scaleEffect(scanning && pulse ? 1.18 : 1).opacity(scanning && pulse ? 0.3 : 1)
            Image(systemName: !hasRun ? "shield.lefthalf.filled" : ((worst ?? .info) >= .medium ? "exclamationmark.shield.fill" : "checkmark.shield.fill"))
                .font(.system(size: size)).foregroundStyle(color)
                .symbolEffect(.pulse, isActive: scanning)
                .contentTransition(.symbolEffect(.replace))
        }
        .onAppear { withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true } }
    }
}

struct SeverityPill: View {
    let severity: Severity
    var body: some View {
        Text(severity.label).font(.caption2.weight(.bold)).textCase(.uppercase)
            .foregroundStyle(severity == .info ? Color.secondary : Color.white)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(severity == .info ? Color.secondary.opacity(0.15) : severity.color, in: Capsule())
    }
}

struct AreaTile: View {
    let title: String
    let icon: String
    let count: Int
    let total: Int
    let worst: Severity?
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: icon).foregroundStyle(selected ? .white : .secondary)
                    Spacer()
                    if count > 0 { Circle().fill(worst?.color ?? .secondary).frame(width: 8, height: 8) }
                }
                Text(title).font(.caption.weight(.semibold)).lineLimit(1)
                Text(count > 0 ? "\(count) issue\(count == 1 ? "" : "s")" : "\(total) checked")
                    .font(.caption2.monospacedDigit()).foregroundStyle(selected ? .white.opacity(0.85) : .secondary)
                    .contentTransition(.numericText())
            }
            .frame(width: 132, alignment: .leading)
            .padding(10)
            .foregroundStyle(selected ? .white : .primary)
            .background(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.background.secondary), in: RoundedRectangle(cornerRadius: 10))
            .scaleEffect(hover ? 1.03 : 1)
            .shadow(color: .black.opacity(hover ? 0.08 : 0), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.snappy(duration: 0.18)) { hover = h } }
    }
}

struct FindingRow: View {
    let f: SecurityFinding
    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(f.severity == .info ? Color.secondary.opacity(0.25) : f.severity.color).frame(width: 4, height: 34)
            Image(systemName: f.area.icon).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(f.title).lineLimit(1).truncationMode(.middle)
                Text(f.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if !f.inventoryOnly { SeverityPill(severity: f.severity) }
        }
        .padding(.vertical, 3)
    }
}

/// Literal picture of how a finding is wired: nodes joined by arrows, risky links in warm colours.
struct FlowChain: View {
    let nodes: [ChainNode]
    @State private var shown = 0

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(Array(nodes.enumerated()), id: \.offset) { i, n in
                    if i > 0 {
                        ArrowLink(risky: n.risky).frame(width: 34, height: 14)
                            .opacity(i < shown ? 1 : 0)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(n.kind.uppercased()).font(.system(size: 9, weight: .bold)).foregroundStyle(n.risky ? .orange : .secondary)
                        Text(n.label).font(.callout.weight(.medium)).lineLimit(2).frame(maxWidth: 170, alignment: .leading)
                        if !n.detail.isEmpty { Text(n.detail).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).frame(maxWidth: 170, alignment: .leading) }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(n.risky ? Color.orange.opacity(0.1) : Color.primary.opacity(0.04)))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(n.risky ? Color.orange.opacity(0.7) : Color.primary.opacity(0.1), lineWidth: n.risky ? 1.5 : 1))
                    .help(n.detail)
                    .scaleEffect(i < shown ? 1 : 0.85)
                    .opacity(i < shown ? 1 : 0)
                }
            }
            .padding(.vertical, 4)
        }
        .onAppear {
            shown = 0
            for i in 0...nodes.count {
                withAnimation(.spring(duration: 0.4).delay(Double(i) * 0.12)) { shown = i + 1 }
            }
        }
    }
}

struct ArrowLink: View {
    let risky: Bool
    @State private var phase: CGFloat = 0
    var body: some View {
        GeometryReader { g in
            let mid = g.size.height / 2
            ZStack {
                Path { p in p.move(to: CGPoint(x: 2, y: mid)); p.addLine(to: CGPoint(x: g.size.width - 6, y: mid)) }
                    .stroke(risky ? Color.orange : Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3], dashPhase: phase))
                Path { p in
                    p.move(to: CGPoint(x: g.size.width - 8, y: mid - 4)); p.addLine(to: CGPoint(x: g.size.width - 2, y: mid)); p.addLine(to: CGPoint(x: g.size.width - 8, y: mid + 4))
                }
                .stroke(risky ? Color.orange : Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
        .onAppear { withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = -14 } }
    }
}

struct QuarantineSheet: View {
    @State private var sec = SecurityModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Quarantine", systemImage: "lock.doc").font(.title3.weight(.semibold))
                Spacer()
                Button("Reveal Folder") { Finder.reveal([Quarantine.root]) }
            }
            Text("Items here were moved out of the way with execute permission removed, and can't run. Restore puts them back exactly where they were. Config backups are copies taken before Prune edited a file.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if sec.quarantine.isEmpty {
                EmptyStateView(symbol: "lock.open", title: "Quarantine is empty", message: "Nothing has been contained.")
            } else {
                List(sec.quarantine) { e in
                    HStack(alignment: .top) {
                        Image(systemName: e.isConfigBackup ? "doc.on.doc" : "lock.doc.fill").foregroundStyle(e.isConfigBackup ? Color.secondary : Color.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.reason).lineLimit(2)
                            Text(e.items.map { FS.tildePath(URL(fileURLWithPath: $0.original)) }.joined(separator: ", ")).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                            Text(e.date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button("Restore") {
                            message = Quarantine.restore(e) ?? "Restored."
                            sec.quarantine = Quarantine.load()
                        }
                        Button("Delete", role: .destructive) { Quarantine.deleteForever(e); sec.quarantine = Quarantine.load() }
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }
            HStack {
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640, height: 480)
    }
}
