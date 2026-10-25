import SwiftUI

struct CategoryView: View {
    let category: Category
    @Environment(AppModel.self) private var model
    @State private var sortOrder = [KeyPathComparator(\CleanupItem.size, order: .reverse)]
    @State private var focused: CleanupItem.ID?
    @State private var showInspector = true
    @State private var filter: Filter = .all
    @State private var search = ""

    enum Filter: String, CaseIterable { case all = "All", recommended = "Recommended", optional = "Optional", keep = "Keep" }

    private var rows: [CleanupItem] {
        var list = model.items(in: category)
        switch filter {
        case .all: break
        case .recommended: list = list.filter { $0.recommendation == .recommended }
        case .optional: list = list.filter { $0.recommendation == .optional }
        case .keep: list = list.filter { $0.recommendation == .keep || !$0.isActionable }
        }
        if !search.isEmpty {
            list = list.filter { $0.title.localizedCaseInsensitiveContains(search) || $0.subtitle.localizedCaseInsensitiveContains(search) || ($0.group ?? "").localizedCaseInsensitiveContains(search) }
        }
        return list.sorted(using: sortOrder)
    }

    var body: some View {
        let all = model.items(in: category)
        HStack(spacing: 0) {
            main(all)
            if showInspector {
                Divider()
                Group {
                    if let id = focused, let item = model.items.first(where: { $0.id == id }) {
                        ItemDetailView(item: item)
                    } else {
                        EmptyStateView(symbol: "sidebar.right", title: "Select an item", message: "See what it is, why Prune suggests it, and what removing it would do.")
                    }
                }
                .frame(width: 340)
                .background(.background.secondary)
            }
        }
        .navigationTitle(category.title)
        .toolbar {
            ToolbarItem {
                Button { withAnimation { showInspector.toggle() } } label: { Label("Details", systemImage: "sidebar.right") }
                    .help("Show or hide details")
            }
        }
        .onAppear {
            if let f = model.focusedItemID, all.contains(where: { $0.id == f }) { focused = f }
            else { focused = rows.first?.id }
        }
        .onChange(of: model.items.count) { _, _ in
            if focused == nil || !model.items.contains(where: { $0.id == focused }) { focused = rows.first?.id }
        }
    }

    @ViewBuilder private func main(_ all: [CleanupItem]) -> some View {
        VStack(spacing: 0) {
            header(all)
            Divider()
            if all.isEmpty {
                if model.isScanning {
                    EmptyStateView(symbol: "hourglass", title: "Scanning…", message: "Results appear here as soon as this analyzer finishes.")
                } else {
                    EmptyStateView(symbol: model.hasScanned ? "checkmark.seal" : category.icon,
                                   title: model.hasScanned ? "Nothing to clean here" : "Not scanned yet",
                                   message: model.hasScanned ? "Prune didn't find anything in this category worth your attention." : "Run a scan to analyze \(category.title.lowercased()).")
                }
            } else {
                table
                Divider()
                actionBar(all)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func header(_ all: [CleanupItem]) -> some View {
        let s = model.summary.byCategory[category]
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: category.icon).font(.system(size: 26)).foregroundStyle(Color.accentColor).frame(width: 34)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(category.title).font(.title2.weight(.semibold))
                        if let s, s.size > 0 { Text(Fmt.bytes(s.size)).font(.title2.monospacedDigit()).foregroundStyle(.secondary) }
                    }
                    Text(category.blurb).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 10) {
                Picker("", selection: $filter) { ForEach(Filter.allCases, id: \.self) { Text($0.rawValue) } }
                    .pickerStyle(.segmented).fixedSize().labelsHidden()
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary)
                    TextField("Filter", text: $search).textFieldStyle(.plain)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
                .frame(maxWidth: 200)
            }
        }
        .padding(16)
    }

    private func actionBar(_ all: [CleanupItem]) -> some View {
        let selectedHere = all.filter { model.selection.contains($0.id) }
        return HStack(spacing: 10) {
            if selectedHere.isEmpty {
                Text("\(all.count) items · \(all.filter { $0.recommendation == .recommended && $0.isActionable }.count) recommended")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("\(selectedHere.count) selected · \(Fmt.bytes(Cleaner.effectiveSize(selectedHere)))")
                    .font(.callout.monospacedDigit().weight(.medium))
            }
            Spacer()
            Button("Select Recommended") { model.selectRecommended(in: category) }
                .disabled(!all.contains { $0.isActionable && $0.recommendation == .recommended })
            Button("Clear") { model.clearSelection(in: category) }.disabled(selectedHere.isEmpty)
            Button { model.review(selectedHere) } label: { Text("Review & Clean…") }
                .buttonStyle(.borderedProminent)
                .disabled(selectedHere.isEmpty)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
    }

    private var maxSize: Int64 { model.items(in: category).map(\.size).max() ?? 1 }

    private var table: some View {
        Table(rows, selection: $focused, sortOrder: $sortOrder) {
            TableColumn("") { item in
                Toggle("", isOn: Binding(get: { model.selection.contains(item.id) }, set: { _ in model.toggle(item) }))
                    .toggleStyle(.checkbox).labelsHidden()
                    .disabled(!item.isActionable)
                    .help(item.lockedReason ?? (item.isActionable ? "Select for cleanup" : "Informational"))
            }
            .width(22)
            TableColumn("Item", value: \.title) { item in
                HStack(spacing: 6) {
                    if item.lockedReason != nil { Image(systemName: "lock.fill").foregroundStyle(.secondary).font(.caption) }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).lineLimit(1).truncationMode(.middle)
                        Text((item.group.map { $0 + " · " } ?? "") + item.reason)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    }
                }
                .padding(.vertical, 3)
                .contextMenu { rowMenu(item) }
            }
            .width(min: 180, ideal: 280)
            TableColumn("Size", value: \.size) { item in
                SizeCell(size: item.size, max: maxSize, estimate: item.sizeIsEstimate)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 100, ideal: 112)
            TableColumn("Activity", value: \.lastUsedSort) { item in
                Text(item.lastUsed.map { Fmt.age($0) } ?? "—").foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            .width(min: 56, ideal: 70)
            TableColumn("Risk", value: \.riskSort) { item in RiskBadge(risk: item.risk, compact: true) }
                .width(min: 78, ideal: 84)
            TableColumn("Verdict", value: \.recommendationSort) { item in VerdictBadge(rec: item.recommendation) }
                .width(min: 104, ideal: 108)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
    }

    @ViewBuilder private func rowMenu(_ item: CleanupItem) -> some View {
        Button(model.selection.contains(item.id) ? "Deselect" : "Select") { model.toggle(item) }.disabled(!item.isActionable)
        Button("Reveal in Finder") { Finder.reveal(item.paths) }.disabled(item.paths.isEmpty)
        if let p = item.paths.first { Button("Open in Disk Explorer") { model.showInExplorer(p) } }
        Button("Copy Path") { Finder.copy(item.paths.map(\.path).joined(separator: "\n")) }.disabled(item.paths.isEmpty)
        Divider()
        Button("Never Suggest This Again") { model.exclude(item) }.disabled(item.paths.isEmpty)
    }
}

struct ItemDetailView: View {
    let item: CleanupItem
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title).font(.title3.weight(.semibold)).textSelection(.enabled)
                    if !item.subtitle.isEmpty { Text(item.subtitle).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                    HStack(spacing: 8) {
                        Text((item.sizeIsEstimate ? "≈ " : "") + Fmt.bytes(item.size)).font(.title2.weight(.bold).monospacedDigit())
                        Spacer()
                        RiskBadge(risk: item.risk)
                        VerdictBadge(rec: item.recommendation)
                    }
                }

                if let locked = item.lockedReason {
                    Label(locked, systemImage: "lock.fill")
                        .font(.callout).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }

                Label(item.reason, systemImage: item.recommendation == .recommended ? "lightbulb.fill" : item.recommendation == .keep ? "hand.raised.fill" : "lightbulb")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(item.recommendation == .recommended ? Color.accentColor : .primary)
                    .fixedSize(horizontal: false, vertical: true)

                DetailSection(title: "What it is", symbol: "info.circle", text: item.whatItIs)
                if let w = item.whyRemove { DetailSection(title: "Why it's not needed", symbol: "minus.circle", text: w, tint: .green) }
                if let k = item.whyKeep { DetailSection(title: "Why you might keep it", symbol: "exclamationmark.circle", text: k, tint: .orange) }
                DetailSection(title: "If you remove it", symbol: "arrow.uturn.backward.circle", text: item.impact)
                if let r = item.restore { DetailSection(title: "How to get it back", symbol: "arrow.clockwise.circle", text: r, mono: r.contains(" ") && !r.contains(". ")) }
                if !item.usedBy.isEmpty { DetailSection(title: "Used by", symbol: "link", text: item.usedBy.joined(separator: "\n")) }
                DetailSection(title: "Action", symbol: "gearshape", text: item.actionDescription + (item.risk == .safe && model.settings.deleteSafeImmediately && item.action == .removeFiles ? " (deleted immediately, see Settings)" : ""))
                if let d = item.lastUsed { DetailSection(title: "Last activity", symbol: "clock", text: "\(Fmt.relative(d)) · \(d.formatted(date: .abbreviated, time: .shortened))") }

                if !item.paths.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Location\(item.paths.count > 1 ? "s (\(item.paths.count))" : "")", systemImage: "folder").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(item.paths.prefix(12), id: \.self) { p in
                            HStack(spacing: 6) {
                                Text(FS.tildePath(p)).font(.caption.monospaced()).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                                Spacer()
                                Button { Finder.reveal([p]) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless).help("Reveal in Finder")
                            }
                        }
                        if item.paths.count > 12 { Text("and \(item.paths.count - 12) more").font(.caption).foregroundStyle(.secondary) }
                    }
                }

                HStack {
                    Button(model.selection.contains(item.id) ? "Deselect" : "Select") { model.toggle(item) }
                        .disabled(!item.isActionable)
                    Button("Reveal") { Finder.reveal(item.paths) }.disabled(item.paths.isEmpty)
                    Spacer()
                    Menu {
                        if let p = item.paths.first { Button("Open in Disk Explorer") { model.showInExplorer(p) } }
                        Button("Copy Paths") { Finder.copy(item.paths.map(\.path).joined(separator: "\n")) }
                        Divider()
                        Button("Never Suggest This Again") { model.exclude(item) }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).fixedSize()
                }
            }
            .padding(16)
        }
    }
}
