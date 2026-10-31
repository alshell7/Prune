import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if !model.hasFDA { fdaBanner }
                if let warning = model.scanCoverageWarning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange).padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                }
                if let boot = model.bootVolume {
                    Card {
                        DiskHero(volume: boot, recommended: model.summary.byVolume[boot.url.path]?.recommended ?? 0,
                                 optional: max(0, (model.summary.byVolume[boot.url.path]?.reclaimable ?? 0) - (model.summary.byVolume[boot.url.path]?.recommended ?? 0)))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                DisksSection()
                if model.isScanning {
                    scanProgress
                } else if !model.hasScanned && model.items.isEmpty {
                    hero
                }
                protectRow
                if !model.items.isEmpty {
                    summaryCard
                    categoryGrid
                    topSuggestions
                }
            }
            .padding(24)
            .frame(maxWidth: 1100, alignment: .leading)
        }
        .navigationTitle("Overview")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Prune").font(.largeTitle.weight(.bold))
            Text("Smart disk cleanup for developers. Every suggestion explains what it is, why, and what happens if you remove it.")
                .foregroundStyle(.secondary)
        }
    }

    private var fdaBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Grant Full Disk Access for a complete scan").font(.headline)
                Text("Without it macOS hides the Trash, app containers, Mail downloads and device backups from Prune. Prune only reads locally and never uploads anything.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Settings") { SystemInfo.openFullDiskAccessSettings() }
        }
        .padding(14)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    private var hero: some View {
        Card {
            HStack(spacing: 18) {
                Image(systemName: "sparkle.magnifyingglass").font(.system(size: 40)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Find what's eating your disk").font(.title2.weight(.semibold))
                    Text("Prune walks your projects, toolchains, caches and apps, cross-checks each folder against your git status and build files, and only recommends what's safe to remove. Nothing is deleted until you review it.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button { model.scan() } label: { Text("Scan").frame(minWidth: 80) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
    }

    private var scanProgress: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Scanning… \(model.finishedScanners.count) of \(model.scanners.count) analyzers done").font(.headline)
                }
                if let walk = model.scannerStatus["Project index"] {
                    Text("Walking \(walk)").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    if ctx.date.timeIntervalSince(model.lastProgressAt) > 6 && !model.hasFDA {
                        Label("Waiting on macOS? If a dialog asks whether Prune may access a folder, click Allow. Grant Full Disk Access to skip these prompts for good.", systemImage: "hand.raised")
                            .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(model.scanners, id: \.name) { s in
                        HStack(spacing: 6) {
                            Image(systemName: model.finishedScanners.contains(s.name) ? "checkmark.circle.fill" : "circle.dotted")
                                .foregroundStyle(model.finishedScanners.contains(s.name) ? .green : .secondary)
                            Text(s.name).font(.callout)
                            if !model.finishedScanners.contains(s.name), let st = model.scannerStatus[s.name] {
                                Text(st).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                }
            }
        }
    }

    private var summaryCard: some View {
        Card {
            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recommended cleanup").font(.subheadline).foregroundStyle(.secondary)
                    Text(Fmt.bytes(model.summary.recommended)).font(.system(size: 40, weight: .bold, design: .rounded))
                    Text("\(model.summary.recommendedCount) items · \(Fmt.bytes(model.summary.reclaimable)) reclaimable in total, including optional items")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider().frame(height: 70)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach([Risk.safe, .low, .review, .high], id: \.self) { r in
                        if let v = model.summary.byRisk[r], v > 0 {
                            HStack(spacing: 8) {
                                RiskBadge(risk: r, compact: true).frame(width: 92, alignment: .leading)
                                Text(Fmt.bytes(v)).font(.callout.monospacedDigit())
                            }
                        }
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    Button {
                        let rec = model.items.filter { $0.isActionable && $0.recommendation == .recommended }
                        model.selection = Set(rec.map(\.id))
                        model.review(rec)
                    } label: { Text("Review Recommended…").frame(minWidth: 170) }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(model.summary.recommendedCount == 0)
                    if model.summary.safeQuickWinSize > 0 {
                        Button {
                            model.selection = Set(model.summary.safeQuickWins.map(\.id))
                            model.review(model.summary.safeQuickWins)
                        } label: { Text("Only safe items (\(Fmt.bytes(model.summary.safeQuickWinSize)))").frame(minWidth: 170) }
                    }
                }
            }
        }
    }

    /// Security and code-backup status at a glance.
    private var protectRow: some View {
        let sec = SecurityModel.shared
        let cb = CodeBackupModel.shared
        let worst = sec.issues.map(\.severity).max()
        return HStack(spacing: 12) {
            StatusTile(icon: worst.map { $0 >= .medium ? "exclamationmark.shield.fill" : "checkmark.shield.fill" } ?? "shield.lefthalf.filled",
                       tint: sec.scannedAt == nil ? .accentColor : (worst.map { $0 >= .medium ? $0.color : .green } ?? .green),
                       title: "Security",
                       value: sec.scanning ? "Checking…" : (sec.scannedAt == nil ? "Not checked yet" : (sec.issues.filter { $0.severity >= .medium }.isEmpty ? "No threats found" : { let n = sec.issues.filter { $0.severity >= .medium }.count; return "\(n) need\(n == 1 ? "s" : "") attention" }())),
                       detail: sec.report.protections.filter { !$0.on }.map { "\($0.name) off" }.joined(separator: " · "),
                       busy: sec.scanning) { model.open(.security) }
            StatusTile(icon: cb.atRisk.isEmpty ? "checkmark.icloud.fill" : "exclamationmark.icloud.fill",
                       tint: cb.checkedAt == nil ? .accentColor : (cb.atRisk.isEmpty ? .green : .orange),
                       title: "Code Backup",
                       value: cb.loading ? "Checking…" : (cb.checkedAt == nil ? "Not checked yet" : (cb.atRisk.isEmpty ? "No local changes ahead" : "\(cb.atRisk.count) project\(cb.atRisk.count == 1 ? "" : "s") need attention")),
                       detail: cb.checkedAt == nil ? "" : "\(cb.own.filter { $0.level == .uncommitted }.count) with uncommitted edits",
                       busy: cb.loading) { model.open(.codeBackup) }
        }
    }

    private var categoryGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("By category").font(.title3.weight(.semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
                ForEach(Category.allCases) { c in
                    let s = model.summary.byCategory[c]
                    Button { model.open(.category(c)) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Image(systemName: c.icon).font(.title3).foregroundStyle(Color.accentColor)
                                Spacer()
                                if let s, s.recommended > 0 {
                                    Text("\(s.recommended) recommended").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                                }
                            }
                            Text(c.title).font(.headline).foregroundStyle(.primary)
                            Text(s.map { $0.size > 0 ? Fmt.bytes($0.size) : ($0.count > 0 ? "\($0.count) items to review" : "Nothing found") } ?? "—")
                                .font(.title3.monospacedDigit()).foregroundStyle((s?.size ?? 0) > 0 ? .primary : .secondary)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
                        .contentShape(Rectangle())
                        .hoverLift()
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var topSuggestions: some View {
        let top = model.items.filter { $0.isActionable && $0.recommendation == .recommended }.prefix(10)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Biggest recommended wins").font(.title3.weight(.semibold))
            VStack(spacing: 0) {
                ForEach(Array(top)) { item in
                    Button { model.open(.category(item.category), focus: item.id) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.category.icon).frame(width: 22).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title).lineLimit(1).truncationMode(.middle)
                                Text(item.reason).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            RiskBadge(risk: item.risk, compact: true)
                            Text(Fmt.bytes(item.size)).font(.callout.monospacedDigit()).frame(width: 84, alignment: .trailing)
                            Image(systemName: model.selection.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(model.selection.contains(item.id) ? Color.accentColor : .secondary)
                                .onTapGesture { model.toggle(item) }
                        }
                        .padding(.vertical, 8).padding(.horizontal, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider().padding(.leading, 44)
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
