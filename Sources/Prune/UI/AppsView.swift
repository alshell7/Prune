import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class AppsModel {
    static let shared = AppsModel()
    var apps: [AppEntry] = []
    var addOns: [AddOn] = []
    var loading = false
    var status = ""
    var filter: Filter = .all
    var tab: Tab = .apps
    var focused: String?
    var focusedAddOn: String?
    var toast: (ok: Bool, text: String)?

    enum Tab: String, CaseIterable { case apps = "Apps", addOns = "Extensions & Add-ons" }
    enum Filter: String, CaseIterable {
        case all = "All", unused = "Unused", intel = "Intel only", unsigned = "Unsigned", background = "Runs in background", duplicate = "Duplicates", movable = "Movable"
    }

    func matches(_ a: AppEntry) -> Bool { Self.matches(a, filter) }

    static func matches(_ a: AppEntry, _ filter: Filter) -> Bool {
        switch filter {
        case .all: true
        case .unused: a.flags.contains(.unused) || a.flags.contains(.neverOpened)
        case .intel: a.flags.contains(.intelOnly) || a.flags.contains(.cannotRun)
        case .unsigned: a.flags.contains(.unsigned) || a.flags.contains(.damaged)
        case .background: a.flags.contains(.heavyHelpers)
        case .duplicate: a.flags.contains(.duplicate)
        case .movable: { if case .notMovable = a.move { return false }; return !a.isOffloaded }()
        }
    }

    /// Pure: never touch observed state while a view is being drawn.
    func count(_ f: Filter) -> Int { apps.filter { Self.matches($0, f) }.count }

    func load() {
        guard !loading, !DemoMode.active else { return }
        loading = true
        Task {
            let list = await AppModel.background { AppsCatalog.load { m in Task { @MainActor in AppsModel.shared.status = m } } }
            let index = await AppModel.background { AppIndex.build() }
            let addOns = await AppModel.background { AppsCatalog.addOns(apps: list, index: index) }
            withAnimation(.spring(duration: 0.5)) {
                apps = list
                self.addOns = addOns
                loading = false
                if focused == nil { focused = list.first?.id }
                if focusedAddOn == nil { focusedAddOn = addOns.first?.id }
            }
        }
    }

    func flash(_ ok: Bool, _ t: String) {
        withAnimation(.snappy) { toast = (ok, t) }
        Task { try? await Task.sleep(for: .seconds(6)); withAnimation { if toast?.text == t { toast = nil } } }
    }

    func removeStaleRegistration(_ addOn: AddOn) {
        Task {
            let result = await AppModel.background { PluginRegistry.removeStale(addOn) }
            let success = result.0 != nil
            AuditLog.append([CleanOutcome(title: addOn.name, category: "Extensions", paths: [addOn.path], size: 0,
                                          method: "PlugInKit registration", success: success, message: result.1)])
            flash(success, result.1)
            if case .removed? = result.0 {
                addOns.removeAll { $0.id == addOn.id }
                focusedAddOn = addOns.first?.id
            } else if case .disabled? = result.0, let i = addOns.firstIndex(where: { $0.id == addOn.id }) {
                addOns[i].active = false
                addOns[i].note = "This missing extension path is disabled. macOS may eventually remove the registration."
            }
        }
    }
}

extension AppEntry.Flag {
    var tint: Color {
        switch self {
        case .unused, .neverOpened: .orange
        case .intelOnly, .cannotRun: .purple
        case .unsigned, .damaged: .red
        case .duplicate, .installer: .yellow
        case .heavyHelpers: .blue
        }
    }
}

extension AddOn.State {
    var label: String { switch self { case .ok: "OK"; case .outdated: "Obsolete"; case .dangling: "Dangling" } }
    var tint: Color { switch self { case .ok: .green; case .outdated: .purple; case .dangling: .orange } }
}

struct AppsView: View {
    @Environment(AppModel.self) private var model
    @State private var am = AppsModel.shared
    @State private var off = OffloadModel.shared
    @State private var confirm: (String, String, String, () -> Void)?
    @State private var moveData = true
    @State private var removingExtension: AddOn?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if am.loading && am.apps.isEmpty {
                VStack(spacing: 10) { ProgressView(); Text(am.status).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if am.tab == .apps {
                HStack(spacing: 0) {
                    appList.frame(minWidth: 380, idealWidth: 430)
                    Divider()
                    appDetail.frame(minWidth: 440, maxWidth: .infinity)
                }
            } else {
                HStack(spacing: 0) {
                    addOnList.frame(minWidth: 380, idealWidth: 430)
                    Divider()
                    addOnDetail.frame(minWidth: 440, maxWidth: .infinity)
                }
            }
        }
        .navigationTitle("Apps & Extensions")
        .onAppear { if am.apps.isEmpty { am.load() }; off.refresh() }
        .sheet(isPresented: $off.showProgress) { OffloadProgressSheet() }
        .onChange(of: off.running) { _, running in if !running { am.load() } }
        .sheet(item: $removingExtension) { x in SystemExtensionRemovalSheet(addOn: x) { removed in
            if removed { withAnimation { am.addOns.removeAll { $0.id == x.id } } }
        } }
        .alert(confirm?.0 ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button(confirm?.2 ?? "OK") { confirm?.3() }
            Button("Cancel", role: .cancel) {}
        } message: { Text(confirm?.1 ?? "") }
        .overlay(alignment: .bottom) {
            if let t = am.toast {
                Label(t.text, systemImage: t.ok ? "checkmark.circle.fill" : "xmark.octagon.fill").lineLimit(3)
                    .padding(.horizontal, 14).padding(.vertical, 10).frame(maxWidth: 560)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .padding(.bottom, 16).transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Apps & Extensions").font(.title2.weight(.semibold))
                    Text("\(am.apps.count) apps · \(Fmt.bytes(am.apps.reduce(0) { $0 + $1.totalSize })) including their data · \(am.addOns.filter { $0.state != .ok }.count) add-ons worth a look")
                        .font(.callout).foregroundStyle(.secondary).contentTransition(.numericText())
                }
                Spacer()
                Picker("", selection: $am.tab.animation(.snappy)) { ForEach(AppsModel.Tab.allCases, id: \.self) { Text($0.rawValue) } }
                    .pickerStyle(.segmented).fixedSize().labelsHidden()
                Button { am.load() } label: { Image(systemName: "arrow.clockwise") }.disabled(am.loading)
            }
            if am.tab == .apps && !am.apps.isEmpty {
                let palette: [Color] = [.indigo, .blue, .teal, .purple, .pink, .orange, .mint, .brown, .cyan, .yellow]
                let top = am.apps.prefix(9)
                StackedBar(segments: top.enumerated().map { BarSegment(label: $0.element.name, value: $0.element.totalSize, color: palette[$0.offset % palette.count]) }
                           + [BarSegment(label: "Other apps", value: am.apps.dropFirst(9).reduce(0) { $0 + $1.totalSize }, color: .gray)], height: 20) { seg in
                    if let a = am.apps.first(where: { $0.name == seg.label }) { withAnimation { am.focused = a.id; am.filter = .all } }
                }
            }
        }
        .padding(16)
    }

    // MARK: Apps

    private var appList: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(AppsModel.Filter.allCases, id: \.self) { f in
                        let n = am.count(f)
                        Button { withAnimation(.snappy) { am.filter = f } } label: {
                            Text(f == .all ? "All \(n)" : "\(f.rawValue) \(n)").font(.caption.weight(.medium))
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .foregroundStyle(am.filter == f ? Color.white : (n == 0 ? Color.secondary : Color.primary))
                                .background(am.filter == f ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(0.06)), in: Capsule())
                        }
                        .buttonStyle(.plain).disabled(n == 0 && f != .all)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            Divider()
            let list = am.apps.filter(am.matches)
            let maxSize = max(list.map(\.totalSize).max() ?? 1, 1)
            List(selection: $am.focused) {
                ForEach(list) { a in
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: a.path)).resizable().frame(width: 30, height: 30)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 5) {
                                Text(a.name).fontWeight(.medium).lineLimit(1)
                                if a.isOffloaded { Image(systemName: "externaldrive.fill").font(.caption2).foregroundStyle(.teal).help("Moved to another drive") }
                                if a.running { Circle().fill(.green).frame(width: 6, height: 6).help("Running") }
                            }
                            HStack(spacing: 4) {
                                ForEach(a.flags.prefix(3), id: \.self) { f in
                                    Text(f.rawValue).font(.system(size: 9, weight: .semibold)).foregroundStyle(f.tint)
                                        .padding(.horizontal, 5).padding(.vertical, 1).background(f.tint.opacity(0.12), in: Capsule())
                                }
                                if a.flags.isEmpty { Text(a.lastUsed.map { "Used \(Fmt.ago($0))" } ?? "").font(.caption2).foregroundStyle(.secondary) }
                            }
                        }
                        Spacer()
                        SizeCell(size: a.totalSize, max: maxSize)
                    }
                    .padding(.vertical, 2)
                    .tag(a.id)
                }
            }
            .listStyle(.inset)
            .animation(.snappy, value: list.map(\.id))
        }
    }

    @ViewBuilder private var appDetail: some View {
        if let id = am.focused, let a = am.apps.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 14) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: a.path)).resizable().frame(width: 60, height: 60)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(a.name).font(.title2.weight(.semibold))
                            Text("\(a.bundleID) · v\(a.version)").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            HStack(spacing: 8) {
                                Label(a.signer.label, systemImage: a.signer.isTrustedVendor ? "checkmark.seal" : "exclamationmark.triangle").foregroundStyle(a.signer.isTrustedVendor ? Color.secondary : Color.orange)
                                Label(a.arch.rawValue, systemImage: "cpu").foregroundStyle(a.arch == .intel || a.arch == .legacy ? Color.purple : Color.secondary)
                                if let u = a.updater { Label(u, systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.secondary) }
                            }
                            .font(.caption)
                        }
                    }
                    // Size: the app vs its data
                    StackedBar(segments: [BarSegment(label: "App", value: a.appSize, color: .indigo), BarSegment(label: "Its data", value: a.dataSize, color: .teal)], height: 16)
                    HStack(spacing: 18) {
                        info("Last opened", a.lastUsed.map { Fmt.relative($0) } ?? "never (per Spotlight)")
                        info("Installed", a.added.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—")
                        info("Source", a.appStore ? "App Store" : (a.signer.trust == .developerID ? "Direct download" : "Unknown"))
                    }
                    if !a.flags.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(a.flags, id: \.self) { f in Label(explain(f, a), systemImage: "circle.fill").font(.callout).foregroundStyle(.primary).symbolRenderingMode(.palette) }
                        }
                    }
                    componentsTree(a)
                    if !a.dataPaths.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Its data on this Mac").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(a.dataPaths, id: \.self) { d in
                                HStack {
                                    Image(systemName: "folder").foregroundStyle(.secondary)
                                    Text(FS.tildePath(d)).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Button { Finder.reveal([d]) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                    moveCard(a)
                    HStack(spacing: 8) {
                        Button {
                            let item = CleanupItem(category: .applications, title: a.name, subtitle: "Uninstall", paths: [a.url] + a.dataPaths + a.components.filter { $0.kind == .externalAgent }.map { URL(fileURLWithPath: $0.path) },
                                                   size: a.totalSize, risk: .review, recommendation: .optional, reason: "Uninstall from Apps",
                                                   whatItIs: "\(a.name) and its data.", impact: "Moved to the Trash.", action: .uninstallApp, lockedReason: a.running ? "Running" : nil, appBundleID: a.bundleID)
                            model.review([item])
                        } label: { Label("Uninstall…", systemImage: "trash") }
                            .disabled(a.running || a.bundleID.hasPrefix("com.apple."))
                        Button { NSWorkspace.shared.open(a.url) } label: { Label("Open", systemImage: "arrow.up.forward.app") }
                        Button { Finder.reveal([a.url]) } label: { Label("Reveal", systemImage: "magnifyingglass") }
                    }
                    .buttonStyle(.bordered)
                }
                .padding(18)
            }
        } else {
            EmptyStateView(symbol: "app.dashed", title: "Select an app", message: "See what it installs, how much space it and its data use, and whether it can move to another drive.")
        }
    }

    private func info(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 1) { Text(k).font(.caption2).foregroundStyle(.secondary); Text(v).font(.callout) }
    }

    private func explain(_ f: AppEntry.Flag, _ a: AppEntry) -> String {
        switch f {
        case .unused: return "Not opened in \(Fmt.age(a.lastUsed ?? a.added))."
        case .neverOpened: return "Installed \(Fmt.ago(a.added)) and never opened."
        case .intelOnly: return "Intel-only: runs through Rosetta, and is likely outdated or abandoned."
        case .cannotRun: return "32-bit or PowerPC: can't run on this Mac at all."
        case .unsigned: return "Not signed by an identified developer. Make sure you trust where it came from."
        case .damaged: return "Its signature doesn't match its contents: modified after signing, or corrupted."
        case .duplicate: return "Installed more than once (same bundle ID)."
        case .installer: return "Looks like an installer or uninstaller left in Applications."
        case .heavyHelpers: return "Starts things automatically at login or in the background."
        }
    }

    /// What the app puts into the system, as a small tree.
    private func componentsTree(_ a: AppEntry) -> some View {
        let groups = Dictionary(grouping: a.components, by: \.kind)
        return VStack(alignment: .leading, spacing: 6) {
            Text("What it installs").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if groups.isEmpty {
                Label("Nothing outside its own bundle. Self-contained.", systemImage: "checkmark.circle").font(.callout).foregroundStyle(.green)
            } else {
                HStack(alignment: .top, spacing: 0) {
                    VStack(spacing: 4) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: a.path)).resizable().frame(width: 28, height: 28)
                        Text(a.name).font(.caption2.weight(.semibold)).lineLimit(1)
                    }
                    .frame(width: 80)
                    .padding(.top, 6)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(groups.keys).sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { k in
                            HStack(spacing: 6) {
                                ArrowLink(risky: [.helper, .launchDaemon, .systemExtension].contains(k)).frame(width: 28, height: 12)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("\(k.rawValue)\(groups[k]!.count > 1 ? "s ×\(groups[k]!.count)" : "")").font(.caption.weight(.semibold))
                                        .foregroundStyle([.helper, .launchDaemon, .systemExtension].contains(k) ? .orange : .primary)
                                    Text(groups[k]!.prefix(3).map(\.name).joined(separator: ", ")).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))
                            }
                        }
                    }
                }
            }
        }
    }

    private func moveCard(_ a: AppEntry) -> some View {
        let (tint, title, reasons): (Color, String, [String]) = {
            if a.isOffloaded { return (.teal, "Already on another drive", ["Bring it back from Offload › On your drives."]) }
            switch a.move {
            case .movable: return (.green, "Can move to another drive", ["Self-contained. A link stays in /Applications so it opens as usual while the drive is connected."])
            case .caution(let r): return (.orange, "Can move, with caveats", r)
            case .notMovable(let r): return (.red, "Should stay where it is", r)
            }
        }()
        let canMove: Bool = { if case .notMovable = a.move { return false }; return !a.isOffloaded }()
        return VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: canMove ? "externaldrive.badge.plus" : (a.isOffloaded ? "externaldrive.fill" : "externaldrive.badge.xmark")).font(.headline).foregroundStyle(tint)
            ForEach(reasons, id: \.self) { Text("• " + $0).font(.callout).fixedSize(horizontal: false, vertical: true) }
            if a.running && canMove { Text("• It's running now. Quit it before moving.").font(.callout).foregroundStyle(.orange) }
            if canMove {
                if let root = off.destinationRoot {
                    HStack {
                        Toggle("Also move its data (\(Fmt.bytes(a.movableDataSize)))", isOn: $moveData).toggleStyle(.checkbox).font(.caption)
                            .disabled(a.movableData.isEmpty)
                        Spacer()
                        Button {
                            confirm = ("Move \(a.name) to \(root.deletingLastPathComponent().lastPathComponent)?",
                                       "Copies \(a.name) (\(Fmt.bytes(a.appSize))) to \(root.path)/Applications, checks every file and the code signature, then replaces it in /Applications with a link." + (moveData && !a.movableData.isEmpty ? " Its Application Support data moves too, also linked." : "") + " Keep the drive connected to use it. Bring it back anytime from Offload.",
                                       "Move", {
                                off.moveApp(a, moveData: moveData)
                            })
                        } label: { Label("Move to Drive…", systemImage: "externaldrive.badge.plus") }
                            .buttonStyle(.borderedProminent)
                            .disabled(a.running || off.running)
                            .help(a.running ? "Quit \(a.name) first." : "")
                    }
                } else {
                    Text("Connect an external drive (APFS) to move apps. Pick it in Offload to Drive.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(0.3)))
    }

    // MARK: Add-ons

    private var addOnList: some View {
        List(selection: $am.focusedAddOn) {
            ForEach(AddOn.Kind.allCases, id: \.self) { kind in
                let items = am.addOns.filter { $0.kind == kind }
                if !items.isEmpty {
                    Section(kind.rawValue) {
                        ForEach(items) { x in
                            HStack(spacing: 8) {
                                Circle().fill(x.state.tint).frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(x.name).lineLimit(1)
                                    Text(x.owner.map { "from \($0)" } ?? "no owning app").font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if x.state != .ok {
                                    Text(x.state.label).font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                                        .padding(.horizontal, 6).padding(.vertical, 2).background(x.state.tint, in: Capsule())
                                }
                            }
                            .tag(x.id)
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
        .overlay { if am.addOns.isEmpty && !am.loading { EmptyStateView(symbol: "puzzlepiece.extension", title: "No third-party add-ons", message: "Nothing is plugged into macOS beyond your apps.") } }
    }

    @ViewBuilder private var addOnDetail: some View {
        if let id = am.focusedAddOn, let x = am.addOns.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        Image(systemName: "puzzlepiece.extension.fill").font(.system(size: 30)).foregroundStyle(x.state.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(x.name).font(.title3.weight(.semibold))
                            Text(x.kind.rawValue.dropLast() + " · " + x.state.label).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    FlowChain(nodes: [
                        ChainNode(kind: "Installed by", label: x.owner ?? "Unknown (app gone)", detail: "", risky: x.owner == nil),
                        ChainNode(kind: x.kind.rawValue, label: x.name, detail: x.bundleID, risky: x.state != .ok),
                        ChainNode(kind: "Loaded into", label: loadedInto(x.kind), detail: x.kind == .appExtension ? (x.active ? "registered" : "disabled") : (x.active ? "active" : "inactive"), risky: x.state == .dangling && x.active),
                    ]).id(x.id)
                    DetailSection(title: "What Prune found", symbol: "info.circle", text: x.note, tint: x.state == .ok ? .secondary : x.state.tint)
                    DetailSection(title: "Location", symbol: "folder", text: x.path, mono: true)
                    if let s = x.signer { DetailSection(title: "Signed by", symbol: "signature", text: s.label) }
                    HStack(spacing: 8) {
                        if x.kind == .appExtension && x.state == .dangling && x.active {
                            Button {
                                confirm = ("Remove stale registration?", "Prune will ask macOS to remove this missing extension's registration. If macOS cannot remove a missing bundle, Prune will disable all stale registrations with the same identifier instead. It will refuse if another copy exists or its drive is disconnected.", "Continue", {
                                    am.removeStaleRegistration(x)
                                })
                            } label: { Label("Remove stale registration…", systemImage: "minus.circle") }
                        }
                        if x.removable && x.state != .ok {
                            Button {
                                confirm = ("Quarantine \(x.name)?", "Moves it into Prune's Quarantine (restorable from Security). \(x.needsAdmin ? "Needs your administrator password. " : "")Some add-ons only stop loading after a restart.", "Quarantine", {
                                    let f = SecurityFinding(id: "addon:\(x.path)", area: .persistence, severity: .info, title: x.name, subtitle: "", evidence: [], explanation: "", recommendation: "", actions: [])
                                    let r = SecurityActions.perform(.quarantine(paths: [x.path]), finding: f)
                                    am.flash(r.ok, r.message)
                                    if r.ok { am.addOns.removeAll { $0.id == x.id } }
                                })
                            } label: { Label("Quarantine", systemImage: "lock.doc") }
                        }
                        if x.kind == .systemExtension && x.state == .dangling {
                            Button { removingExtension = x } label: { Label("Remove…", systemImage: "trash") }.buttonStyle(.borderedProminent)
                        }
                        if x.kind == .appExtension && x.state == .ok {
                            Button {
                                Task {
                                    let r = await AppModel.background { PluginRegistry.setEnabled(x, !x.active) }
                                    am.flash(r.0, r.1)
                                    if r.0, let i = am.addOns.firstIndex(where: { $0.id == x.id }) { withAnimation(.snappy) { am.addOns[i].active.toggle() } }
                                }
                            } label: { Label(x.active ? "Disable" : "Enable", systemImage: x.active ? "pause.circle" : "play.circle") }
                        }
                        if x.kind == .systemExtension || x.kind == .appExtension {
                            Button { SystemExtensions.openSettings() } label: { Label("Login Items & Extensions", systemImage: "gearshape") }
                        }
                        if FS.exists(URL(fileURLWithPath: x.path)) { Button { Finder.reveal([URL(fileURLWithPath: x.path)]) } label: { Label("Reveal", systemImage: "magnifyingglass") } }
                    }
                    .buttonStyle(.bordered)

                }
                .padding(18)
            }
        } else {
            EmptyStateView(symbol: "puzzlepiece.extension", title: "Select an add-on", message: "Drivers, plug-ins and extensions that hook into macOS, and whether their app still exists.")
        }
    }

    private func loadedInto(_ k: AddOn.Kind) -> String {
        switch k {
        case .systemExtension: "macOS kernel services"
        case .audioDriver: "Core Audio (every app's sound)"
        case .appExtension: "Host apps & Finder"
        case .quickLook: "Quick Look"
        case .spotlight: "Spotlight indexing"
        case .prefPane: "System Settings"
        case .internetPlugin: "Web browsers (legacy)"
        case .screenSaver: "Screen saver"
        case .inputMethod: "Keyboard input"
        case .kext: "Kernel (legacy)"
        }
    }
}

extension OffloadModel {
    func moveApp(_ app: AppEntry, moveData: Bool) {
        guard let root = destinationRoot, !running else { return }
        running = true
        outcomes = []
        showProgress = true
        let options = OffloadOptions(destinationRoot: root, checksums: checksums, trashOriginals: false)
        let engine = OffloadEngine { p in Task { @MainActor in OffloadModel.shared.progress = p } }
        self.engine = engine
        Task {
            let results = await AppModel.background { engine.offloadApp(app, moveData: moveData, options: options) }
            outcomes = results
            running = false
            records = OffloadRegistry.load()
            AppModel.shared.refreshVolumes()
        }
    }
}

/// Step-by-step removal of a system extension whose app is gone. macOS only lets the owning app (or SIP-off
/// tooling) uninstall one, so Prune does what is possible and verifies each step.
struct SystemExtensionRemovalSheet: View {
    let addOn: AddOn
    var done: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var record: SystemExtensionRecord?
    @State private var leftovers: [URL] = []
    @State private var sip = true
    @State private var message: (Bool, String)?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "puzzlepiece.extension.fill").font(.system(size: 30)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Remove \(addOn.name)").font(.title3.weight(.semibold))
                    Text("\(record?.kindLabel ?? "System extension") · team \(record?.teamID ?? "?") · \(record?.state.replacingOccurrences(of: "_", with: " ") ?? "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let app = record?.containerApp {
                Text("Installed by \((app as NSString).lastPathComponent), which is gone. Only the installing app can normally uninstall a system extension, so Prune does it in steps.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            step(1, "Stop it from loading", done: record.map { !$0.isEnabled } ?? true,
                 detail: sip ? "Turn it off in System Settings › General › Login Items & Extensions (click ⓘ next to Driver or Network Extensions). Prune re-checks when you come back."
                             : "System Integrity Protection is off, so macOS can uninstall it directly.") {
                if sip { SystemExtensions.openSettings() } else { uninstall() }
            } label: { sip ? "Open Settings" : "Uninstall" }
            step(2, "Remove leftover files", done: leftovers.isEmpty,
                 detail: leftovers.isEmpty ? "No leftover support files or launch items from this vendor." : leftovers.map { FS.tildePath($0) }.joined(separator: "\n")) {
                quarantineLeftovers()
            } label: { "Quarantine \(leftovers.count)" }
            let vendor = record.flatMap { SystemExtensions.vendorUninstallers[$0.vendorPrefix] }
            step(3, "Remove macOS's copy", done: record == nil,
                 detail: "macOS keeps its own copy until the installing app asks to remove it. \(vendor.map { "Reinstall \($0.name) and run its uninstaller, or" } ?? "Reinstall the app and use its uninstaller, or") leave it turned off: a disabled extension doesn't load.") {
                if let v = vendor, let u = URL(string: v.url) { NSWorkspace.shared.open(u) }
            } label: { vendor != nil ? "Uninstall guide" : "" }
            if let m = message {
                Label(m.1, systemImage: m.0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").font(.callout).foregroundStyle(m.0 ? .green : .orange)
            }
            HStack {
                Button("Check Again") { reload() }
                Spacer()
                Button("Done") { done(record == nil); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22).frame(width: 540)
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in reload() }
    }

    private func step(_ n: Int, _ title: String, done: Bool, detail: String, action: @escaping () -> Void, label: () -> String) -> some View {
        let text = label()
        return HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.green : Color.secondary.opacity(0.15)).frame(width: 26, height: 26)
                if done { Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white).transition(.scale) }
                else { Text("\(n)").font(.caption.weight(.bold)) }
            }
            .animation(.spring(duration: 0.4), value: done)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            Spacer()
            if !done && !text.isEmpty { Button(text, action: action).disabled(working) }
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func reload() {
        Task {
            let (r, l, s) = await AppModel.background { () -> (SystemExtensionRecord?, [URL], Bool) in
                let rec = SystemExtensions.records().first { $0.identifier == addOn.bundleID }
                let ids = Array(AppIndex.build().byBundleID.keys)
                return (rec, rec.map { SystemExtensions.leftovers(for: $0, installedBundleIDs: ids) } ?? [], SystemExtensions.sipEnabled)
            }
            withAnimation(.snappy) { record = r; leftovers = l; sip = s }
        }
    }

    private func uninstall() {
        guard let r = record else { return }
        working = true
        Task {
            let res = await AppModel.background { SystemExtensions.uninstall(r) }
            working = false
            message = (res.ok, res.ok ? "macOS removed the extension. It may finish after a restart." : res.stderr)
            reload()
        }
    }

    private func quarantineLeftovers() {
        working = true
        let paths = leftovers.map(\.path)
        Task {
            let f = SecurityFinding(id: "sysext:\(addOn.bundleID)", area: .persistence, severity: .info, title: addOn.name, subtitle: "", evidence: [], explanation: "", recommendation: "", actions: [])
            let r = await AppModel.background { SecurityActions.perform(.quarantine(paths: paths), finding: f) }
            working = false
            message = (r.ok, r.message)
            reload()
        }
    }
}
