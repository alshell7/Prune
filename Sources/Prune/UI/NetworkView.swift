import AppKit
import SwiftUI

struct AppNet: Identifiable {
    var id: String
    var name: String
    var iconPath: String
    var procs: [ProcInfo]
    var inRate: Double
    var outRate: Double
    var endpoints: [Endpoint]
    var listening: [String]
    var signer: SignatureInfo?
    var isSystem: Bool
    var history: [Double]
    var rate: Double { inRate + outRate }
}

struct NetInsight: Identifiable { var id: String; var icon: String; var tint: Color; var title: String; var detail: String; var appID: String }

struct NetworkView: View {
    @State private var tm = TaskModel.shared
    @State private var mon = NetworkMonitor.shared
    @State private var focused: String?
    @State private var totals: [Double] = []
    @State private var showSystem = false
    @State private var confirm: (String, String, () -> Void)?

    static let oddPorts: Set<Int> = [4444, 1337, 31337, 6667, 6697, 9001, 9030, 9050, 9051, 5555, 12345, 23, 2323]

    private var apps: [AppNet] {
        var dict: [String: AppNet] = [:]
        for p in tm.procs {
            guard let n = mon.byPid[p.pid], n.inRate + n.outRate > 0 || !n.connections.isEmpty || !n.listening.isEmpty else { continue }
            if !showSystem && p.isSystem && n.listening.isEmpty { continue }
            let key = p.appPath ?? p.path
            var a = dict[key] ?? AppNet(id: key, name: p.appName ?? p.name, iconPath: key, procs: [], inRate: 0, outRate: 0, endpoints: [], listening: [],
                                        signer: p.isSystem ? SignatureInfo(trust: .apple) : tm.signers[key], isSystem: p.isSystem, history: [])
            a.procs.append(p)
            a.inRate += n.inRate; a.outRate += n.outRate
            a.endpoints += n.connections
            a.listening += n.listening
            if a.history.isEmpty { a.history = n.history } else {
                a.history = zip(a.history, n.history).map(+) + (n.history.count > a.history.count ? Array(n.history.suffix(n.history.count - a.history.count)) : [])
            }
            dict[key] = a
        }
        return dict.values.sorted { ($0.rate, $0.endpoints.count) > ($1.rate, $1.endpoints.count) }
    }

    private func label(_ host: String) -> String {
        let name = mon.hostnames[host] ?? ""
        if let s = NetworkMonitor.service(name) { return s }
        if ProcessAnalyzer.isPrivate(host + ":0") { return "Local network" }
        return name.isEmpty ? host : name
    }

    private func isUnknown(_ ep: Endpoint) -> Bool {
        let name = mon.hostnames[ep.host]
        return !ProcessAnalyzer.isPrivate(ep.host + ":0") && name != nil && (name!.isEmpty) && ![80, 443, 853, 5223, 993, 587, 465, 22].contains(ep.port)
    }

    private var insights: [NetInsight] {
        var out: [NetInsight] = []
        let list = apps
        if let top = list.first, top.rate > 50_000 {
            out.append(NetInsight(id: "top", icon: "speedometer", tint: .blue, title: "\(top.name) is the top talker",
                                  detail: "\u{2193} \(Fmt.bytes(Int64(top.inRate)))/s  \u{2191} \(Fmt.bytes(Int64(top.outRate)))/s", appID: top.id))
        }
        for a in list {
            for p in a.procs where p.isScriptRuntime && !(mon.byPid[p.pid]?.connections.isEmpty ?? true) {
                let script = p.args.split(separator: " ").dropFirst().first { !$0.hasPrefix("-") }.map(String.init) ?? p.args
                out.append(NetInsight(id: "script\(p.pid)", icon: "scroll", tint: .teal, title: "Script online: \(p.name) \((script as NSString).lastPathComponent)",
                                      detail: "\(Set(mon.byPid[p.pid]?.connections.map(\.host) ?? []).count) destination(s)", appID: a.id))
            }
            let odd = a.endpoints.filter { Self.oddPorts.contains($0.port) || isUnknown($0) }
            if let e = odd.first {
                out.append(NetInsight(id: "odd\(a.id)", icon: "questionmark.diamond", tint: .orange, title: "\(a.name) talks to an unidentified host",
                                      detail: "\(e.display)\(Self.oddPorts.contains(e.port) ? " (port often used by backdoors)" : ", no hostname, unusual port")", appID: a.id))
            }
            for p in a.procs {
                for (ep, interval, count) in mon.beaconing(pid: p.pid).prefix(1) {
                    out.append(NetInsight(id: "beacon\(p.pid)", icon: "dot.radiowaves.right", tint: .red, title: "\(a.name) checks in every ~\(Int(interval))s",
                                          detail: "\(count) repeated connections to \(label(ep.host))", appID: a.id))
                }
            }
            let exposed = a.listening.filter { $0.hasPrefix("*:") || $0.hasPrefix("0.0.0.0") || $0.hasPrefix("[::]") }
            if !exposed.isEmpty && !a.isSystem {
                out.append(NetInsight(id: "listen\(a.id)", icon: "antenna.radiowaves.left.and.right", tint: .yellow, title: "\(a.name) accepts connections from your network",
                                      detail: exposed.prefix(2).joined(separator: ", "), appID: a.id))
            }
            if let s = a.signer, s.isAnonymous, !a.endpoints.isEmpty, !a.procs.contains(where: { ExecutableKind.inDevTools($0.path) }) {
                out.append(NetInsight(id: "unsigned\(a.id)", icon: "signature", tint: .orange, title: "Unsigned program online: \(a.name)",
                                      detail: "\(Set(a.endpoints.map(\.host)).count) destination(s)", appID: a.id))
            }
        }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                appList.frame(minWidth: 380, idealWidth: 420)
                Divider()
                detail.frame(minWidth: 460, maxWidth: .infinity)
            }
        }
        .navigationTitle("Network")
        .onAppear { tm.start() }
        .onDisappear { tm.stop() }
        .onChange(of: mon.lastSample) { _, _ in totals = Array((totals + [mon.totalIn + mon.totalOut]).suffix(60)) }
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Network").font(.title2.weight(.semibold))
                    Text("Which apps and scripts are online, who they talk to, and anything that looks like a backdoor. Everything stays local: hostnames come from your own DNS.")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: 420, alignment: .leading)
                }
                Sparkline(values: totals.isEmpty ? [0, 0] : totals, tint: .blue).frame(width: 220, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\u{2193} \(Fmt.bytes(Int64(mon.totalIn)))/s").font(.title3.monospacedDigit().weight(.semibold)).contentTransition(.numericText())
                    Text("\u{2191} \(Fmt.bytes(Int64(mon.totalOut)))/s").font(.callout.monospacedDigit()).foregroundStyle(.secondary).contentTransition(.numericText())
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(apps.count) apps online").font(.callout.weight(.medium))
                    Text("\(apps.reduce(0) { $0 + $1.endpoints.count }) connections · \(Set(apps.flatMap { $0.endpoints.map(\.host) }).count) hosts").font(.caption).foregroundStyle(.secondary)
                }
            }
            let ins = insights
            if !ins.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(ins) { i in
                            Button { withAnimation(.snappy) { focused = i.appID } } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: i.icon).font(.title3).foregroundStyle(i.tint)
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
            }
        }
        .padding(16)
    }

    private var appList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Online now").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Toggle("macOS services", isOn: $showSystem.animation(.snappy)).toggleStyle(.checkbox).font(.caption)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            let list = apps
            let maxRate = max(list.map(\.rate).max() ?? 1, 1)
            if list.isEmpty {
                VStack(spacing: 8) { ProgressView(); Text("Listening for traffic…").font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $focused) {
                    ForEach(list) { a in
                        HStack(spacing: 8) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: a.iconPath)).resizable().frame(width: 20, height: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.name).lineLimit(1)
                                Text("\(Set(a.endpoints.map(\.host)).count) host(s)" + (a.listening.isEmpty ? "" : " · listening")).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 3) {
                                MiniBar(value: a.inRate / maxRate, tint: .blue).frame(width: 70)
                                MiniBar(value: a.outRate / maxRate, tint: .green).frame(width: 70)
                            }
                            Text(a.rate < 1 ? "idle" : Fmt.bytes(Int64(a.rate)) + "/s").font(.caption.monospacedDigit()).frame(width: 74, alignment: .trailing).contentTransition(.numericText())
                        }
                        .tag(a.id)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let id = focused, let a = apps.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: a.iconPath)).resizable().frame(width: 40, height: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.name).font(.title3.weight(.semibold))
                            Text("\(a.procs.count) process(es) · signed by \(a.isSystem ? "Apple" : (a.signer?.label ?? "…"))").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing) {
                            Text("\u{2193} \(Fmt.bytes(Int64(a.inRate)))/s").font(.callout.monospacedDigit()).foregroundStyle(.blue)
                            Text("\u{2191} \(Fmt.bytes(Int64(a.outRate)))/s").font(.callout.monospacedDigit()).foregroundStyle(.green)
                        }
                    }
                    ConnectionMap(app: a, label: label, unknown: isUnknown).frame(height: 300)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.03)))
                    if a.history.count > 2 {
                        Sparkline(values: a.history, tint: .blue).frame(height: 36)
                    }
                    connectionsTable(a)
                    netActions(a)
                }
                .padding(18)
            }
        } else {
            EmptyStateView(symbol: "network", title: "Select an app", message: "See a live map of every host it talks to, how much it sends, and whether anything looks off.")
        }
    }

    private func connectionsTable(_ a: AppNet) -> some View {
        let grouped = Dictionary(grouping: a.endpoints, by: \.host).map { ($0.key, $0.value) }.sorted { $0.1.count > $1.1.count }
        return VStack(alignment: .leading, spacing: 6) {
            Text("Destinations").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(grouped.prefix(24), id: \.0) { host, eps in
                HStack(spacing: 8) {
                    Circle().fill(color(for: eps[0])).frame(width: 8, height: 8)
                    Text(label(host)).fontWeight(.medium).lineLimit(1)
                    Text(mon.hostnames[host].flatMap { $0.isEmpty ? nil : $0 } ?? host).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text("port \(Set(eps.map(\.port)).sorted().map(String.init).joined(separator: ", "))").font(.caption.monospacedDigit()).foregroundStyle(Self.oddPorts.contains(eps[0].port) ? .orange : .secondary)
                    Text("\u{00D7}\(eps.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if !a.listening.isEmpty {
                Text("Listening").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 6)
                ForEach(Array(Set(a.listening)).sorted(), id: \.self) { l in
                    Label(l + (l.hasPrefix("*") || l.hasPrefix("[::]") || l.hasPrefix("0.0.0.0") ? "  (reachable from other machines)" : "  (this Mac only)"), systemImage: "antenna.radiowaves.left.and.right")
                        .font(.caption.monospaced())
                }
            }
        }
    }

    private func color(for ep: Endpoint) -> Color {
        if ProcessAnalyzer.isPrivate(ep.host + ":0") { return .gray }
        if Self.oddPorts.contains(ep.port) || isUnknown(ep) { return .orange }
        return NetworkMonitor.service(mon.hostnames[ep.host] ?? "") != nil ? .green : .blue
    }

    private func netActions(_ a: AppNet) -> some View {
        let main = a.procs.max { $0.cpu < $1.cpu } ?? a.procs[0]
        return VStack(alignment: .leading, spacing: 8) {
            Text("Actions").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button { confirm = ("Stop \(a.name)?", "Quits all \(a.procs.count) of its processes (SIGTERM).", { for p in a.procs { tm.signal(p, SIGTERM, label: "Stopped") } }) } label: { Label("Stop", systemImage: "stop.circle") }
                    .disabled(a.isSystem)
                Button {
                    confirm = ("Block incoming connections for \(a.name)?", "Adds a block rule for this app to the macOS Application Firewall (needs your administrator password). Outgoing traffic isn't affected. Undo in System Settings › Network › Firewall › Options.", {
                        let path = a.procs[0].appPath ?? a.procs[0].path
                        let r = Shell.runAsAdmin("/usr/libexec/ApplicationFirewall/socketfilterfw --add \(Shell.shellQuote(path)) >/dev/null; /usr/libexec/ApplicationFirewall/socketfilterfw --blockapp \(Shell.shellQuote(path))")
                        tm.flash(r.ok, r.ok ? "Incoming connections to \(a.name) are now blocked." : r.stderr)
                    })
                } label: { Label("Block Incoming", systemImage: "hand.raised") }
                    .disabled(a.isSystem)
                Button { withAnimation { tm.focused = main.pid }; AppModel.shared.open(.taskManager) } label: { Label("Open in Task Manager", systemImage: "cpu") }
                Button { Finder.copy(Set(a.endpoints.map { label($0.host) + " " + $0.display }).sorted().joined(separator: "\n")) } label: { Label("Copy Hosts", systemImage: "doc.on.doc") }
            }
        }
        .buttonStyle(.bordered)
    }
}

/// Radial map: the app in the middle, every destination around it; colours show who owns the host.
struct ConnectionMap: View {
    let app: AppNet
    let label: (String) -> String
    let unknown: (Endpoint) -> Bool
    @State private var appear = false
    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { g in
            let hosts = Dictionary(grouping: app.endpoints, by: \.host).map { ($0.key, $0.value) }.sorted { $0.1.count > $1.1.count }.prefix(14)
            let c = CGPoint(x: g.size.width / 2, y: g.size.height / 2)
            let r = min(g.size.width, g.size.height) / 2 - 40
            ZStack {
                ForEach(Array(hosts.enumerated()), id: \.element.0) { i, h in
                    let angle = Double(i) / Double(max(hosts.count, 1)) * 2 * .pi - .pi / 2
                    let pt = CGPoint(x: c.x + CGFloat(cos(angle)) * r * (appear ? 1 : 0.2), y: c.y + CGFloat(sin(angle)) * r * (appear ? 1 : 0.2))
                    let tint = tintFor(h.1[0])
                    Path { p in p.move(to: c); p.addLine(to: pt) }
                        .stroke(tint.opacity(0.7), style: StrokeStyle(lineWidth: min(5, 1 + CGFloat(h.1.count) * 0.6), lineCap: .round, dash: [6, 5], dashPhase: phase))
                    VStack(spacing: 2) {
                        Circle().fill(tint.gradient).frame(width: 12, height: 12)
                        Text(label(h.0)).font(.caption2.weight(.medium)).lineLimit(1).frame(maxWidth: 110)
                            .padding(.horizontal, 5).padding(.vertical, 1).background(.background.opacity(0.85), in: Capsule())
                    }
                    .position(pt)
                    .opacity(appear ? 1 : 0)
                }
                VStack(spacing: 4) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.iconPath)).resizable().frame(width: 40, height: 40)
                        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                    Text(app.name).font(.caption.weight(.semibold))
                }
                .position(c)
                if hosts.isEmpty {
                    Text(app.listening.isEmpty ? "No open connections right now" : "Only listening, no outgoing connections").font(.caption).foregroundStyle(.secondary).position(x: c.x, y: c.y + 46)
                }
            }
        }
        .onAppear {
            withAnimation(.spring(duration: 0.7, bounce: 0.25)) { appear = true }
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = -22 }
        }
        .id(app.id)
    }

    private func tintFor(_ ep: Endpoint) -> Color {
        if ProcessAnalyzer.isPrivate(ep.host + ":0") { return .gray }
        if NetworkView.oddPorts.contains(ep.port) || unknown(ep) { return .orange }
        let l = label(ep.host)
        return l == ep.host ? .blue : .green
    }
}
