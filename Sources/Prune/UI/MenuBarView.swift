import AppKit
import SwiftUI

struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let boot = model.bootVolume
        let low = boot.map { $0.available < Int64(model.settings.lowSpaceAlertGB) * 1_000_000_000 } ?? false
        HStack(spacing: 4) {
            Image(systemName: low ? "externaldrive.badge.exclamationmark" : (model.isScanning ? "arrow.triangle.2.circlepath" : "internaldrive"))
            if model.settings.showFreeSpaceInMenuBar, let b = boot {
                Text(ByteCountFormatter.string(fromByteCount: b.available, countStyle: .file))
            }
        }
    }
}

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var watcher = FolderWatcher.shared
    @State private var confirmQuick = false
    @State private var quickResult: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            disk
            Divider()
            scanSection
            if !model.items.isEmpty {
                quickClean
                suggestions
            }
            Divider()
            watched
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 370)
    }

    private func openMain(_ route: Route? = nil, focus: String? = nil) {
        if let route { model.open(route, focus: focus) }
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    private var disk: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let b = model.bootVolume {
                HStack(alignment: .firstTextBaseline) {
                    Text(Fmt.bytes(b.available)).font(.system(size: 24, weight: .semibold, design: .rounded))
                    Text("free on \(b.name)").foregroundStyle(.secondary)
                    Spacer()
                    Text("of \(Fmt.bytes(b.total))").font(.caption).foregroundStyle(.secondary)
                }
                DiskBar(volume: b, height: 8)
                if b.purgeable > 500_000_000 {
                    Text("Includes \(Fmt.bytes(b.purgeable)) macOS can purge on demand").font(.caption2).foregroundStyle(.secondary)
                }
            }
            ForEach(model.volumes.filter { !$0.isBoot }) { v in
                HStack {
                    Image(systemName: "externaldrive").foregroundStyle(.secondary)
                    Text(v.name).font(.caption)
                    Spacer()
                    Text("\(Fmt.bytes(v.available)) free").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var scanSection: some View {
        HStack {
            if model.isScanning {
                ProgressView().controlSize(.small)
                Text("Scanning… \(model.finishedScanners.count)/\(model.scanners.count)").font(.callout)
            } else if model.items.isEmpty {
                Image(systemName: "sparkle.magnifyingglass").foregroundStyle(Color.accentColor)
                Text(model.settings.lastScanDate == nil ? "Scan to see what can go." : "Scan again for fresh suggestions.").font(.callout)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(Fmt.bytes(model.summary.recommended)) recommended").font(.headline)
                    Text("Scanned \(Fmt.relative(model.settings.lastScanDate))").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(model.items.isEmpty ? "Scan" : "Rescan") { model.scan() }.disabled(model.isScanning || model.isCleaning)
        }
    }

    private var quickClean: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let quickResult {
                Label(quickResult, systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.isCleaning {
                HStack { ProgressView().controlSize(.small); Text(model.cleanProgress?.current ?? "Cleaning…").font(.caption).lineLimit(1).truncationMode(.middle) }
            } else if model.summary.safeQuickWinSize > 0 {
                if confirmQuick {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Clean \(model.summary.safeQuickWins.count) safe items (\(Fmt.bytes(model.summary.safeQuickWinSize)))?").font(.callout.weight(.semibold))
                        Text("Only caches and leftovers that regenerate on their own. Nothing from running apps.").font(.caption).foregroundStyle(.secondary)
                        @Bindable var s = model.settings
                        Toggle("Delete immediately to free space now (instead of Trash)", isOn: $s.deleteSafeImmediately)
                            .toggleStyle(.checkbox).font(.caption)
                        HStack {
                            Button("Cancel") { confirmQuick = false }
                            Spacer()
                            Button("Clean") {
                                confirmQuick = false
                                let list = model.summary.safeQuickWins
                                Task {
                                    let out = await model.clean(list)
                                    let ok = out.filter { $0.success && $0.method != "Skipped" }
                                    let size = Fmt.bytes(ok.reduce(0) { $0 + $1.size })
                                    quickResult = model.settings.deleteSafeImmediately ? "Freed \(size)." : "Moved \(size) to the Trash. Empty it to free the space."
                                }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(10)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                } else {
                    Button { confirmQuick = true; quickResult = nil } label: {
                        HStack {
                            Image(systemName: "wand.and.stars")
                            Text("Quick clean safe items")
                            Spacer()
                            Text(Fmt.bytes(model.summary.safeQuickWinSize)).monospacedDigit()
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
        }
    }

    private var suggestions: some View {
        let top = model.items.filter { $0.isActionable && $0.recommendation == .recommended && $0.risk != .safe }.prefix(5)
        return VStack(alignment: .leading, spacing: 4) {
            if !top.isEmpty {
                Text("Worth reviewing").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(Array(top)) { item in
                    Button { openMain(.category(item.category), focus: item.id) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: item.category.icon).frame(width: 18).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(item.title).lineLimit(1).truncationMode(.middle)
                                Text(item.reason).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(Fmt.bytes(item.size)).font(.callout.monospacedDigit())
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var watched: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Watched folders").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { if let u = Finder.chooseFolder(prompt: "Watch") { watcher.add(u) } } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).help("Watch a folder")
            }
            if watcher.folders.isEmpty {
                Text("Add a folder to track its size and get alerts when it grows.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(watcher.folders.prefix(6)) { f in
                Button { openMain(.watched) } label: {
                    HStack {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        Text(f.name).lineLimit(1)
                        Spacer()
                        if let g = f.growth, abs(g) > 50_000_000 {
                            Text((g > 0 ? "+" : "−") + Fmt.bytes(abs(g))).font(.caption.monospacedDigit()).foregroundStyle(g > 0 ? .orange : .green)
                        }
                        if watcher.measuring.contains(f.path) { ProgressView().controlSize(.mini) }
                        else { Text(f.lastSize.map(Fmt.bytes) ?? "—").font(.callout.monospacedDigit()) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Open Prune") { openMain() }
            Button("Explorer") { openMain(.explorer) }
            Spacer()
            SettingsLink { Image(systemName: "gearshape") }.buttonStyle(.borderless)
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.buttonStyle(.borderless).help("Quit Prune")
        }
    }
}
