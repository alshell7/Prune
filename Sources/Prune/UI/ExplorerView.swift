import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class ExplorerModel {
    struct Entry: Identifiable, Hashable {
        var id: String { url.path }
        var url: URL
        var name: String
        var isDir: Bool
        var size: Int64?
        var newest: Date?
        var unreadable = false
    }

    var path: URL = FS.home
    var entries: [Entry] = []
    var measuring = 0
    var unreadableCount = 0
    private var generation = 0
    private var cache: [String: SizeResult] = [:]

    var total: Int64 { entries.reduce(0) { $0 + ($1.size ?? 0) } }
    var largest: Int64 { entries.map { $0.size ?? 0 }.max() ?? 1 }

    func open(_ url: URL) {
        path = url
        generation += 1
        let gen = generation
        let children = FS.children(url)
        var list: [Entry] = []
        var dirs: [URL] = []
        for c in children {
            let isDir = FS.isDir(c)
            var e = Entry(url: c, name: c.lastPathComponent, isDir: isDir)
            if isDir {
                if let r = cache[c.path] { e.size = r.bytes; e.newest = r.newest; e.unreadable = r.unreadable > 0 } else { dirs.append(c) }
            } else {
                e.size = FS.fileSize(c)
                e.newest = FS.mtime(c)
            }
            list.append(e)
        }
        entries = sorted(list)
        unreadableCount = list.filter(\.unreadable).count
        measuring = dirs.count
        guard !dirs.isEmpty else { return }
        // Measure folders concurrently, publishing each result as it lands.
        DispatchQueue.global(qos: .userInitiated).async {
            DispatchQueue.concurrentPerform(iterations: dirs.count) { i in
                let r = Sizer.measure(dirs[i])
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == gen else { return }
                    self.cache[dirs[i].path] = r
                    if let idx = self.entries.firstIndex(where: { $0.url == dirs[i] }) {
                        self.entries[idx].size = r.bytes
                        self.entries[idx].newest = r.newest
                        self.entries[idx].unreadable = r.unreadable > 0
                    }
                    self.measuring -= 1
                    if self.measuring == 0 {
                        self.entries = self.sorted(self.entries)
                        self.unreadableCount = self.entries.filter(\.unreadable).count
                    }
                }
            }
        }
    }

    func refresh() {
        for e in entries where e.isDir { cache[e.url.path] = nil }
        open(path)
    }

    func invalidate(_ url: URL) {
        var p = url.path
        while p.count > 1 { cache[p] = nil; p = (p as NSString).deletingLastPathComponent }
    }

    private func sorted(_ list: [Entry]) -> [Entry] {
        list.sorted { ($0.size ?? -1, $1.name) > ($1.size ?? -1, $0.name) }
    }
}

struct ExplorerView: View {
    @Environment(AppModel.self) private var model
    @State private var explorer = ExplorerModel()
    @State private var selection: ExplorerModel.Entry.ID?
    @State private var confirmTrash: ExplorerModel.Entry?
    @State private var codeRisk: String?
    @State private var errorMessage: String?
    @AppStorage("explorerMode") private var mapMode = true

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if explorer.unreadableCount > 0 && !model.hasFDA {
                HStack {
                    Image(systemName: "lock").foregroundStyle(.orange)
                    Text("\(explorer.unreadableCount) folder(s) couldn't be fully read. Sizes are lower bounds. Grant Full Disk Access for exact numbers.").font(.caption)
                    Spacer()
                    Button("Open Settings") { SystemInfo.openFullDiskAccessSettings() }.controlSize(.small)
                }
                .padding(.horizontal, 16).padding(.vertical, 6)
                .background(Color.orange.opacity(0.08))
            }
            if mapMode { mapPane } else { list }
        }
        .navigationTitle("Disk Explorer")
        .onAppear { explorer.open(model.explorerPath ?? FS.home) }
        .onChange(of: model.explorerPath) { _, new in if let new { explorer.open(new) } }
        .alert("Move to Trash?", isPresented: Binding(get: { confirmTrash != nil }, set: { if !$0 { confirmTrash = nil } }), presenting: confirmTrash) { e in
            Button("Move to Trash", role: .destructive) { trash(e) }
            Button("Cancel", role: .cancel) {}
        } message: { e in
            Text("\u{201C}\(e.name)\u{201D} (\(Fmt.bytes(e.size ?? 0))) will be moved to the Trash. You can restore it from there."
                 + (codeRisk.map { "\n\n\u{26A0}\u{FE0F} \($0) Push or copy it somewhere first." } ?? ""))
        }
        .alert("Can't remove this", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: { Text(errorMessage ?? "") }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { explorer.open(explorer.path.deletingLastPathComponent()) } label: { Image(systemName: "chevron.up") }
                .disabled(explorer.path.path == "/")
                .help("Enclosing folder")
            Menu {
                Button("Home") { explorer.open(FS.home) }
                Divider()
                ForEach(model.volumes) { v in Button("\(v.name) (\(Fmt.bytes(v.available)) free)") { explorer.open(v.url) } }
                Divider()
                Button("Choose Folder…") { if let u = Finder.chooseFolder() { explorer.open(u) } }
            } label: { Image(systemName: "externaldrive") }
                .menuStyle(.borderlessButton).fixedSize()
            breadcrumbs
            Spacer()
            Picker("", selection: $mapMode.animation(.snappy)) {
                Image(systemName: "square.grid.3x3.square").tag(true).help("Map")
                Image(systemName: "list.bullet").tag(false).help("List")
            }
            .pickerStyle(.segmented).fixedSize().labelsHidden()
            if explorer.measuring > 0 {
                ProgressView().controlSize(.small)
                Text("Measuring \(explorer.measuring)…").font(.caption).foregroundStyle(.secondary)
            } else {
                Text(Fmt.bytes(explorer.total)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            Button { explorer.refresh() } label: { Image(systemName: "arrow.clockwise") }.help("Re-measure")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var breadcrumbs: some View {
        let comps = explorer.path.pathComponents
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(comps.enumerated()), id: \.offset) { i, c in
                    if i > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                    Button(c == "/" ? "Macintosh HD" : c) {
                        let p = NSString.path(withComponents: Array(comps.prefix(i + 1)))
                        explorer.open(URL(fileURLWithPath: p))
                    }
                    .buttonStyle(.borderless)
                    .font(i == comps.count - 1 ? .callout.weight(.semibold) : .callout)
                }
            }
        }
    }

    private var selectedEntry: ExplorerModel.Entry? { explorer.entries.first { $0.id == selection } }

    private var mapPane: some View {
        VStack(spacing: 0) {
            TreemapView(entries: explorer.entries,
                        onOpen: { e in if e.isDir && e.url.pathExtension != "app" { withAnimation(.snappy) { explorer.open(e.url) } } else { Finder.reveal([e.url]) } },
                        onSelect: { e in selection = e.id })
                .padding(12)
                .id(explorer.path)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
                .overlay {
                    if explorer.entries.allSatisfy({ ($0.size ?? 0) == 0 }) {
                        VStack(spacing: 8) { ProgressView(); Text("Measuring…").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            Divider()
            HStack(spacing: 14) {
                ForEach(TreemapView.Kind.allCases, id: \.self) { k in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(TreemapView.color(k, name: "x")).frame(width: 10, height: 10)
                        Text(k.rawValue).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let e = selectedEntry {
                    Text("\(e.name) · \(Fmt.bytes(e.size ?? 0))").font(.caption.weight(.medium)).lineLimit(1)
                    Button("Reveal") { Finder.reveal([e.url]) }.controlSize(.small)
                    Button("Move to Trash…") {
                        if let reason = SafetyGuard.check(e.url, allowAppBundle: e.url.pathExtension == "app") { errorMessage = reason }
                        else { codeRisk = CodeBackup.riskSummary(for: e.url); confirmTrash = e }
                    }.controlSize(.small)
                } else {
                    Text("Click to select · double-click a folder to open").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
    }

    private var list: some View {
        List(explorer.entries, selection: $selection) { e in
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: e.url.path))
                    .resizable().frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(e.name).lineLimit(1).truncationMode(.middle)
                    GeometryReader { geo in
                        let frac = Double(e.size ?? 0) / Double(max(explorer.largest, 1))
                        Capsule().fill(Color.accentColor.opacity(0.75))
                            .frame(width: max(2, geo.size.width * frac), height: 4)
                    }
                    .frame(height: 4)
                }
                Spacer(minLength: 12)
                Text(e.newest.map { Fmt.ago($0) } ?? "").font(.caption).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
                Group {
                    if let s = e.size { Text((e.unreadable ? "≥ " : "") + Fmt.bytes(s)) } else { ProgressView().controlSize(.mini) }
                }
                .font(.callout.monospacedDigit()).frame(width: 90, alignment: .trailing)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { if e.isDir && !e.url.pathExtension.hasSuffix("app") { explorer.open(e.url) } else { Finder.reveal([e.url]) } }
            .contextMenu {
                if e.isDir { Button("Open") { explorer.open(e.url) } }
                Button("Reveal in Finder") { Finder.reveal([e.url]) }
                Button("Copy Path") { Finder.copy(e.url.path) }
                if e.isDir {
                    Button("Watch This Folder") { FolderWatcher.shared.add(e.url) }
                }
                Divider()
                Button("Move to Trash…", role: .destructive) {
                    if let reason = SafetyGuard.check(e.url, allowAppBundle: e.url.pathExtension == "app") { errorMessage = reason }
                    else { codeRisk = CodeBackup.riskSummary(for: e.url); confirmTrash = e }
                }
            }
            .tag(e.id)
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .overlay {
            if explorer.entries.isEmpty && explorer.measuring == 0 {
                EmptyStateView(symbol: "folder", title: "Empty or unreadable", message: "This folder has no entries Prune can read.")
            }
        }
    }

    private func trash(_ e: ExplorerModel.Entry) {
        let item = CleanupItem(category: .largeFiles, title: e.name, paths: [e.url], size: e.size ?? 0, risk: .review, recommendation: .optional,
                               reason: "Removed from Disk Explorer", whatItIs: "", impact: "", action: e.url.pathExtension == "app" ? .uninstallApp : .removeFiles)
        Task {
            let out = await AppModel.background { Cleaner.clean([item], deleteSafeImmediately: false) { _, _, _ in } }
            if let o = out.first, !o.success { errorMessage = o.message.isEmpty ? "Couldn't move it to the Trash." : o.message }
            explorer.invalidate(e.url)
            explorer.open(explorer.path)
            model.refreshVolumes()
        }
    }
}
