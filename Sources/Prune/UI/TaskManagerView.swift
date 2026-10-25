import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class TaskModel {
    static let shared = TaskModel()
    var procs: [ProcInfo] = []
    var byPid: [Int32: ProcInfo] = [:]
    var signers: [String: SignatureInfo] = [:]
    var focused: Int32?
    var sort: Sort = .cpu
    var search = ""
    var showSystem = false
    var live = true
    var toast: (ok: Bool, text: String)?
    var cwd: [Int32: String] = [:]
    var openFiles: [Int32: Int] = [:]
    var paused = Set<Int32>()
    private var loop: Task<Void, Never>?

    enum Sort: String, CaseIterable { case cpu = "CPU", memory = "Memory", network = "Network", age = "Newest", name = "Name" }

    struct Group: Identifiable {
        var id: String
        var name: String
        var iconPath: String
        var procs: [ProcInfo]
        var cpu: Double { procs.reduce(0) { $0 + $1.cpu } }
        var mem: Int64 { procs.reduce(0) { $0 + $1.memBytes } }
    }

    func start() {
        NetworkMonitor.shared.start()
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while let self, !Task.isCancelled {
                if self.live || self.procs.isEmpty { await self.refresh() }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func stop() { loop?.cancel(); loop = nil; NetworkMonitor.shared.stop() }

    func refresh() async {
        let snap = await AppModel.background { ProcessCatalog.snapshot() }
        withAnimation(.snappy(duration: 0.25)) {
            procs = snap
            byPid = Dictionary(uniqueKeysWithValues: snap.map { ($0.pid, $0) })
        }
        // Signatures for third-party executables, once per path.
        let unknown = Set(snap.filter { !$0.isSystem }.map { $0.appPath ?? $0.path }).filter { signers[$0] == nil }
        if !unknown.isEmpty {
            let found = await AppModel.background { Dictionary(uniqueKeysWithValues: unknown.map { ($0, CodeSigning.check($0)) }) }
            signers.merge(found) { a, _ in a }
        }
    }

    func net(_ pid: Int32) -> PidNet? { NetworkMonitor.shared.byPid[pid] }
    func rate(_ p: ProcInfo) -> Double { (net(p.pid)?.inRate ?? 0) + (net(p.pid)?.outRate ?? 0) }

    var groups: [Group] {
        let visible = procs.filter { (showSystem || !$0.isSystem) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || ($0.appName ?? "").localizedCaseInsensitiveContains(search) || $0.args.localizedCaseInsensitiveContains(search)) }
        var dict: [String: Group] = [:]
        for p in visible {
            let key = p.appPath ?? p.path
            dict[key, default: Group(id: key, name: p.appName ?? p.name, iconPath: p.appPath ?? p.path, procs: [])].procs.append(p)
        }
        let list = Array(dict.values)
        switch sort {
        case .cpu: return list.sorted { $0.cpu > $1.cpu }
        case .memory: return list.sorted { $0.mem > $1.mem }
        case .network: return list.sorted { $0.procs.reduce(0) { $0 + rate($1) } > $1.procs.reduce(0) { $0 + rate($1) } }
        case .age: return list.sorted { ($0.procs.map(\.elapsed).min() ?? 0) < ($1.procs.map(\.elapsed).min() ?? 0) }
        case .name: return list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    // MARK: Insights

    struct Insight: Identifiable { var id: String; var icon: String; var tint: Color; var title: String; var detail: String; var pid: Int32? }

    var insights: [Insight] {
        var out: [Insight] = []
        let mine = procs.filter { !$0.isSystem && $0.uid == Int(getuid()) }
        let devServers = mine.filter { p in
            let listening = !(net(p.pid)?.listening.isEmpty ?? true)
            let devLike = p.isScriptRuntime && !["bash", "sh", "zsh", "osascript"].contains(p.name)
            let orphan = p.ppid == 1 || byPid[p.ppid] == nil
            return listening && devLike && orphan && p.elapsed > 3600
        }
        for p in devServers.prefix(3) {
            let port = net(p.pid)?.listening.first.map { String($0.split(separator: ":").last ?? "") } ?? "?"
            out.append(Insight(id: "dev\(p.pid)", icon: "server.rack", tint: .orange, title: "Forgotten dev server on :\(port)",
                               detail: "\(p.name), running \(Fmt.age(p.started)) with no terminal attached", pid: p.pid))
        }
        for p in procs.filter({ $0.cpu > 90 }).sorted(by: { $0.cpu > $1.cpu }).prefix(2) {
            out.append(Insight(id: "cpu\(p.pid)", icon: "flame", tint: .red, title: "\(p.appName ?? p.name) is maxing a CPU core",
                               detail: "\(Int(p.cpu))% CPU · running \(Fmt.age(p.started))", pid: p.pid))
        }
        if let hog = mine.max(by: { $0.rssKB < $1.rssKB }), hog.memBytes > 1_500_000_000 {
            out.append(Insight(id: "mem\(hog.pid)", icon: "memorychip", tint: .purple, title: "\(hog.appName ?? hog.name) uses \(Fmt.bytes(hog.memBytes))",
                               detail: "The biggest single process", pid: hog.pid))
        }
        let orphans = Dictionary(grouping: mine.filter { $0.ppid == 1 && $0.appPath == nil && $0.isScriptRuntime }, by: \.name).filter { $0.value.count >= 4 }
        for (name, list) in orphans {
            out.append(Insight(id: "orph\(name)", icon: "square.stack.3d.up", tint: .yellow, title: "\(list.count) orphaned \(name) processes",
                               detail: "\(Fmt.bytes(list.reduce(0) { $0 + $1.memBytes })) of memory, parents long gone", pid: list.first?.pid))
        }
        return out
    }

    // MARK: Actions

    func signal(_ p: ProcInfo, _ sig: Int32, label: String) {
        let protected = p.isSystem && SecurityActions.protectedProcesses.contains(p.name)
        if protected || p.pid <= 1 || p.pid == getpid() { flash(false, "\(p.name) is part of macOS and can't be changed."); return }
        Task {
            let r: (Bool, String) = await AppModel.background {
                if p.uid != Int(getuid()) {
                    let s = Shell.runAsAdmin("kill -\(sig) \(p.pid)")
                    return (s.ok, s.ok ? "" : s.stderr)
                }
                return kill(p.pid, sig) == 0 ? (true, "") : (false, String(cString: strerror(errno)))
            }
            if r.0 {
                if sig == SIGSTOP { paused.insert(p.pid) } else if sig == SIGCONT { paused.remove(p.pid) }
                flash(true, "\(label): \(p.appName ?? p.name) (pid \(p.pid)).")
                AuditLog.append([CleanOutcome(title: p.name, category: "Task Manager", paths: [p.path], size: 0, method: label, success: true, message: "pid \(p.pid)")])
            } else { flash(false, r.1) }
            await refresh()
        }
    }

    func lowerPriority(_ p: ProcInfo) {
        if setpriority(PRIO_PROCESS, id_t(p.pid), 10) == 0 { flash(true, "\(p.name) now runs at low priority.") }
        else { flash(false, "Couldn't change priority: \(String(cString: strerror(errno))).") }
    }

    func flash(_ ok: Bool, _ text: String) {
        withAnimation(.snappy) { toast = (ok, text) }
        Task { try? await Task.sleep(for: .seconds(5)); withAnimation { if toast?.text == text { toast = nil } } }
    }

    func inspect(_ p: ProcInfo) {
        guard cwd[p.pid] == nil else { return }
        Task {
            let (dir, files) = await AppModel.background { (ProcessCatalog.workingDirectory(p.pid), ProcessCatalog.openFileCount(p.pid)) }
            cwd[p.pid] = dir ?? ""
            openFiles[p.pid] = files
        }
    }
}

struct TaskManagerView: View {
    @State private var tm = TaskModel.shared
    @State private var net = NetworkMonitor.shared
    @State private var confirm: (String, String, () -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                list.frame(minWidth: 460, idealWidth: 540)
                Divider()
                detail.frame(minWidth: 400, maxWidth: .infinity)
            }
        }
        .navigationTitle("Task Manager")
        .onAppear { tm.start() }
        .onDisappear { tm.stop() }
        .overlay(alignment: .bottom) {
            if let t = tm.toast {
                Label(t.text, systemImage: t.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .padding(.horizontal, 14).padding(.vertical, 10).background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 16).transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .alert(confirm?.0 ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button(confirm?.0 ?? "OK", role: .destructive) { confirm?.2() }
            Button("Cancel", role: .cancel) {}
        } message: { Text(confirm?.1 ?? "") }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 18) {
                gauge(title: "CPU", value: min(1, tm.procs.reduce(0) { $0 + $1.cpu } / Double(ProcessInfo.processInfo.activeProcessorCount * 100)),
                      label: "\(Int(tm.procs.reduce(0) { $0 + $1.cpu }))%", tint: .blue)
                gauge(title: "Memory", value: Double(tm.procs.reduce(Int64(0)) { $0 + $1.memBytes }) / Double(ProcessInfo.processInfo.physicalMemory),
                      label: Fmt.bytes(tm.procs.reduce(Int64(0)) { $0 + $1.memBytes }), tint: .purple)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Network").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text("\u{2193} \(Fmt.bytes(Int64(net.totalIn)))/s  \u{2191} \(Fmt.bytes(Int64(net.totalOut)))/s").font(.callout.monospacedDigit()).contentTransition(.numericText())
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Processes").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text("\(tm.procs.count)").font(.callout.monospacedDigit()).contentTransition(.numericText())
                }
                Spacer()
                Toggle(isOn: $tm.live) { Label("Live", systemImage: tm.live ? "dot.radiowaves.left.and.right" : "pause") }
                    .toggleStyle(.button)
            }
            if !tm.insights.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(tm.insights) { i in
                            Button { if let pid = i.pid { withAnimation(.snappy) { tm.focused = pid } } } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: i.icon).font(.title3).foregroundStyle(i.tint).symbolEffect(.pulse)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(i.title).font(.callout.weight(.semibold)).lineLimit(1)
                                        Text(i.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                .padding(10)
                                .background(i.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(i.tint.opacity(0.3)))
                                .hoverLift()
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(16)
        .animation(.snappy, value: tm.insights.map(\.id))
    }

    private func gauge(title: String, value: Double, label: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().stroke(tint.opacity(0.15), lineWidth: 5)
                Circle().trim(from: 0, to: max(0.01, min(1, value))).stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90))
            }
            .frame(width: 30, height: 30)
            .animation(.spring(duration: 0.6), value: value)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(label).font(.callout.monospacedDigit()).contentTransition(.numericText())
            }
        }
    }

    // MARK: List

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("Sort", selection: $tm.sort) { ForEach(TaskModel.Sort.allCases, id: \.self) { Text($0.rawValue) } }
                    .pickerStyle(.menu).fixedSize()
                TextField("Filter", text: $tm.search).textFieldStyle(.roundedBorder)
                Toggle("macOS", isOn: $tm.showSystem.animation(.snappy)).toggleStyle(.checkbox).font(.caption).fixedSize().help("Show system processes")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            let maxCPU = max(tm.groups.map(\.cpu).max() ?? 1, 1)
            let maxMem = max(tm.groups.map(\.mem).max() ?? 1, 1)
            List(selection: $tm.focused) {
                ForEach(tm.groups) { g in
                    if g.procs.count == 1, let p = g.procs.first {
                        ProcRow(p: p, title: g.name, iconPath: g.iconPath, cpu: g.cpu, mem: g.mem, maxCPU: maxCPU, maxMem: maxMem, paused: tm.paused.contains(p.pid))
                            .tag(p.pid)
                    } else {
                        DisclosureGroup {
                            ForEach(g.procs.sorted { $0.cpu > $1.cpu }) { p in
                                ProcRow(p: p, title: p.name, iconPath: nil, cpu: p.cpu, mem: p.memBytes, maxCPU: maxCPU, maxMem: maxMem, paused: tm.paused.contains(p.pid))
                                    .tag(p.pid)
                            }
                        } label: {
                            ProcRow(p: g.procs[0], title: "\(g.name)  \u{00B7} \(g.procs.count)", iconPath: g.iconPath, cpu: g.cpu, mem: g.mem, maxCPU: maxCPU, maxMem: maxMem, paused: false)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if let pid = tm.focused, let p = tm.byPid[pid] {
            let origin = ProcessCatalog.origin(p, all: tm.byPid)
            let sig = p.isSystem ? nil : tm.signers[p.appPath ?? p.path]
            let n = tm.net(p.pid)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: p.appPath ?? p.path)).resizable().frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.appName.map { $0 == p.name ? $0 : "\($0) › \(p.name)" } ?? p.name).font(.title3.weight(.semibold))
                            Text(p.path).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        }
                    }
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                        GridRow { stat("CPU", "\(String(format: "%.1f", p.cpu))%"); stat("Memory", Fmt.bytes(p.memBytes)); stat("Running for", Fmt.age(p.started)) }
                        GridRow { stat("PID", "\(p.pid) (parent \(p.ppid))"); stat("User", p.uid == 0 ? "root" : (p.uid == Int(getuid()) ? "you" : "uid \(p.uid)")); stat("Signed by", p.isSystem ? "Apple (system)" : (sig?.label ?? "…")) }
                        GridRow { stat("Network", n.map { "\u{2193}\(Fmt.bytes(Int64($0.inRate)))/s \u{2191}\(Fmt.bytes(Int64($0.outRate)))/s" } ?? "—"); stat("Open files", tm.openFiles[p.pid].map(String.init) ?? "…"); stat("Folder", tm.cwd[p.pid].map { $0.isEmpty ? "—" : FS.tildePath(URL(fileURLWithPath: $0)) } ?? "…") }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Why is it running?").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(origin.summary).font(.callout.weight(.medium))
                        var chain = origin.chain
                        let _ = chain.append(ChainNode(kind: "Signed by", label: p.isSystem ? "Apple" : (sig?.label ?? "checking…"), detail: sig?.teamID ?? "", risky: !(p.isSystem || (sig?.isTrustedVendor ?? true))))
                        let _ = { if let n, !n.connections.isEmpty { chain.append(ChainNode(kind: "Talks to", label: "\(Set(n.connections.map(\.host)).count) host(s)", detail: n.connections.prefix(2).map(\.display).joined(separator: ", "), risky: false)) } }()
                        let _ = { if let n, !n.listening.isEmpty { chain.append(ChainNode(kind: "Listens on", label: n.listening.prefix(2).joined(separator: ", "), detail: "", risky: n.listening.contains { $0.hasPrefix("*") })) } }()
                        FlowChain(nodes: chain).id(p.pid)
                    }
                    if let n, n.history.count > 2 {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Network activity (last \(n.history.count * 2)s)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Sparkline(values: n.history).frame(height: 40)
                        }
                    }
                    DetailSection(title: "Command", symbol: "terminal", text: p.args, mono: true)
                    actions(p, origin: origin)
                }
                .padding(18)
            }
            .onAppear { tm.inspect(p) }
            .onChange(of: pid) { _, _ in tm.inspect(p) }
        } else {
            EmptyStateView(symbol: "cpu", title: "Select a process", message: "See why it's running, who signed it, what it talks to, and stop, pause or disable it.")
        }
    }

    private func stat(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(k).font(.caption2).foregroundStyle(.secondary)
            Text(v).font(.callout.monospacedDigit()).lineLimit(1).truncationMode(.middle)
        }
    }

    @ViewBuilder private func actions(_ p: ProcInfo, origin: (summary: String, chain: [ChainNode])) -> some View {
        let label = p.launchdLabel ?? (p.ppid == 1 ? nil : tm.byPid[p.ppid]?.launchdLabel)
        let plist = label.flatMap(ProcessCatalog.plist(for:))
        VStack(alignment: .leading, spacing: 8) {
            Text("Actions").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button { confirm = ("Stop \(p.name)?", "Asks it to quit (SIGTERM). Unsaved work in it may be lost.", { tm.signal(p, SIGTERM, label: "Stopped") }) } label: { Label("Stop", systemImage: "stop.circle") }
                Button { confirm = ("Force stop \(p.name)?", "Kills it immediately (SIGKILL). It can't save anything.", { tm.signal(p, SIGKILL, label: "Force-stopped") }) } label: { Label("Force Stop", systemImage: "xmark.octagon") }
                if tm.paused.contains(p.pid) {
                    Button { tm.signal(p, SIGCONT, label: "Resumed") } label: { Label("Resume", systemImage: "play.circle") }
                } else {
                    Button { tm.signal(p, SIGSTOP, label: "Paused") } label: { Label("Pause", systemImage: "pause.circle") }
                        .help("Freezes it in place (SIGSTOP) without killing it. Useful to see whether something stops misbehaving.")
                }
                Button { tm.lowerPriority(p) } label: { Label("Lower Priority", systemImage: "tortoise") }.disabled(p.uid != Int(getuid()))
            }
            HStack(spacing: 8) {
                if let label, let plist {
                    Button {
                        let finding = SecurityFinding(id: "tm:\(label)", area: .persistence, severity: .info, title: label, subtitle: "", evidence: [], explanation: "", recommendation: "", actions: [])
                        confirm = ("Disable autostart for \(label)?", "Unloads it and moves \(FS.tildePath(URL(fileURLWithPath: plist))) into Quarantine so it won't start again. Restorable from Security › Quarantine.", {
                            let r = SecurityActions.perform(.disableLaunchItem(plist: plist, label: label, system: plist.hasPrefix("/Library")), finding: finding)
                            tm.flash(r.ok, r.message)
                        })
                    } label: { Label("Disable Autostart", systemImage: "power.circle") }
                }
                if !p.isSystem && p.appPath == nil && FS.exists(URL(fileURLWithPath: p.path)) && !ExecutableKind.inDevTools(p.path) {
                    Button {
                        let finding = SecurityFinding(id: "tm:\(p.path)", area: .processes, severity: .info, title: p.name, subtitle: "", evidence: [], explanation: "", recommendation: "", actions: [])
                        confirm = ("Stop and quarantine \(p.name)?", "Stops it, then moves \(FS.tildePath(URL(fileURLWithPath: p.path))) into Quarantine with execute permission removed.", {
                            tm.signal(p, SIGKILL, label: "Force-stopped")
                            let r = SecurityActions.perform(.quarantine(paths: [p.path]), finding: finding)
                            tm.flash(r.ok, r.message)
                        })
                    } label: { Label("Quarantine Program", systemImage: "lock.doc") }
                }
                Button { Finder.reveal([URL(fileURLWithPath: p.appPath ?? p.path)]) } label: { Label("Reveal", systemImage: "magnifyingglass") }
                Button { Finder.copy(p.args) } label: { Label("Copy Command", systemImage: "doc.on.doc") }
            }
        }
        .buttonStyle(.bordered)
    }
}

struct ProcRow: View {
    let p: ProcInfo
    let title: String
    let iconPath: String?
    let cpu: Double
    let mem: Int64
    let maxCPU: Double
    let maxMem: Int64
    let paused: Bool

    var body: some View {
        HStack(spacing: 8) {
            if let iconPath { Image(nsImage: NSWorkspace.shared.icon(forFile: iconPath)).resizable().frame(width: 18, height: 18) }
            Text(title).lineLimit(1).truncationMode(.middle)
            if paused { Image(systemName: "pause.fill").font(.caption2).foregroundStyle(.orange) }
            Spacer(minLength: 6)
            MiniBar(value: cpu / maxCPU, tint: .blue).frame(width: 40)
            Text(String(format: "%.0f%%", cpu)).font(.caption.monospacedDigit()).frame(width: 34, alignment: .trailing).contentTransition(.numericText())
            MiniBar(value: Double(mem) / Double(maxMem), tint: .purple).frame(width: 40)
            Text(Fmt.bytes(mem)).font(.caption.monospacedDigit()).frame(width: 64, alignment: .trailing).contentTransition(.numericText())
        }
    }
}

struct MiniBar: View {
    let value: Double
    let tint: Color
    var body: some View {
        GeometryReader { g in
            Capsule().fill(tint.opacity(0.15))
                .overlay(alignment: .leading) { Capsule().fill(tint.opacity(0.8)).frame(width: g.size.width * max(0.02, min(1, value))) }
        }
        .frame(height: 5)
        .animation(.snappy, value: value)
    }
}

struct Sparkline: View {
    let values: [Double]
    var tint: Color = .accentColor
    var body: some View {
        GeometryReader { g in
            let maxV = max(values.max() ?? 1, 1)
            let step = g.size.width / CGFloat(max(values.count - 1, 1))
            let points = values.enumerated().map { CGPoint(x: CGFloat($0.offset) * step, y: g.size.height * (1 - CGFloat($0.element / maxV))) }
            ZStack {
                Path { p in
                    guard let f = points.first else { return }
                    p.move(to: CGPoint(x: f.x, y: g.size.height)); points.forEach { p.addLine(to: $0) }; p.addLine(to: CGPoint(x: points.last!.x, y: g.size.height))
                }
                .fill(LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                Path { p in guard let f = points.first else { return }; p.move(to: f); points.dropFirst().forEach { p.addLine(to: $0) } }
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
            .animation(.snappy, value: values)
        }
    }
}
