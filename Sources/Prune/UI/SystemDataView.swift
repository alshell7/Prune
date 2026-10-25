import Observation
import SwiftUI

/// Breaks down what macOS lumps into "System Data" in Storage settings, and says what can be done about each part.
struct SystemDataBucket: Identifiable {
    enum Handling { case review(Category), managed, explore }
    var id: String { title }
    var title: String
    var symbol: String
    var paths: [URL]
    var subtract: [URL] = []
    var explanation: String
    var advice: String
    var handling: Handling
    var size: Int64?
    var top: [(String, Int64)] = []
}

@MainActor
@Observable
final class SystemDataModel {
    static let shared = SystemDataModel()
    var buckets: [SystemDataBucket] = []
    var measuring = false
    var measuredAt: Date?

    var total: Int64 { buckets.reduce(0) { $0 + ($1.size ?? 0) } }

    private static func definitions(hasFDA: Bool) -> [SystemDataBucket] {
        let h = FS.home
        func u(_ p: String) -> URL { p.hasPrefix("/") ? URL(fileURLWithPath: p) : h.appendingPathComponent(p) }
        let assets = u("/System/Library/AssetsV2")
        let simRuntimes = FS.childDirs(assets).filter { $0.lastPathComponent.contains("SimulatorRuntime") }
        let brew = FS.isDir(u("/opt/homebrew")) ? [u("/opt/homebrew")] : [u("/usr/local/Homebrew"), u("/usr/local/Cellar")]
        var list: [SystemDataBucket] = [
            SystemDataBucket(title: "Claude Desktop", symbol: "sparkles", paths: [u("Library/Application Support/Claude")],
                             explanation: "Claude Desktop's sandbox VM disk (≈10 GB), bundled Claude Code builds and web caches.",
                             advice: "The VM is the big part. It's only needed for sandboxed agent tasks and is re-downloaded when used. Old Claude Code builds are safe to remove.",
                             handling: .review(.aiModels)),
            SystemDataBucket(title: "iOS Simulator runtimes", symbol: "iphone", paths: simRuntimes + [u("/Library/Developer/CoreSimulator"), u("Library/Developer/CoreSimulator")],
                             explanation: "Simulator OS images that Xcode downloads (≈8 GB each), plus the caches built for them.",
                             advice: "Keep one only if you run iOS simulators. Deleting it frees about 11 GB, and Xcode re-downloads it on demand (Settings › Components).",
                             handling: .review(.xcode)),
            SystemDataBucket(title: "Android SDK & emulators", symbol: "smartphone", paths: [u("Library/Android"), u(".android")],
                             explanation: "NDK, emulator system images, build-tools and your emulators' virtual disks.",
                             advice: "Prune keeps what your projects pin. Emulators you don't boot are the main thing to drop. Wiping an emulator's data also shrinks it.",
                             handling: .review(.environments)),
            SystemDataBucket(title: "Developer caches & toolchains", symbol: "shippingbox",
                             paths: [".cache", ".gradle", ".cargo", ".rustup", "go", ".npm", ".m2", ".pub-cache", ".bun", ".nvm", ".pyenv", ".local/share", ".cocoapods", ".expo", ".deno"].map(u),
                             explanation: "Hidden folders in your home: package caches, Gradle, Go and Rust toolchains, Hugging Face models.",
                             advice: "Caches re-download on demand. Prune recommends the ones for ecosystems you haven't touched lately.",
                             handling: .review(.devCaches)),
            SystemDataBucket(title: "AI assistant history", symbol: "text.bubble", paths: [u(".claude"), u(".codex")],
                             explanation: "Claude Code and Codex session transcripts, plugins and runtimes.",
                             advice: "Claude Code deletes transcripts older than 30 days on its own (setting: cleanupPeriodDays). Transcripts for deleted folders and old Codex sessions can go.",
                             handling: .review(.aiModels)),
            SystemDataBucket(title: "Xcode data & tools", symbol: "hammer", paths: [u("Library/Developer/Xcode"), u("/Library/Developer/CommandLineTools")],
                             explanation: "DerivedData, device support, archives, and the standalone Command Line Tools.",
                             advice: "With Xcode installed, the Command Line Tools are a duplicate toolchain (≈2 GB).",
                             handling: .review(.xcode)),
            SystemDataBucket(title: "App caches", symbol: "archivebox", paths: [u("Library/Caches")],
                             explanation: "Caches apps rebuild on their own.", advice: "Safe to clear. Quit the app first.",
                             handling: .review(.systemJunk)),
            SystemDataBucket(title: "Other app data", symbol: "app.badge", paths: [u("Library/Application Support")],
                             subtract: [u("Library/Application Support/Claude")],
                             explanation: "Settings, databases and downloads that apps keep (browsers, editors, chat apps).",
                             advice: "Mostly needed. Prune flags data from uninstalled apps under Dangling & Orphaned.",
                             handling: .explore),
            SystemDataBucket(title: "Homebrew", symbol: "mug", paths: brew,
                             explanation: "Formulae you installed with brew and their dependencies.",
                             advice: "`brew cleanup` and `brew autoremove` are handled in Docker & Homebrew. Big formulae you no longer use: `brew uninstall <name>`.",
                             handling: .review(.docker)),
            SystemDataBucket(title: "macOS downloadable assets", symbol: "square.stack.3d.down.right", paths: [assets], subtract: simRuntimes,
                             explanation: "Siri, dictation, language and Apple Intelligence assets that macOS downloads.",
                             advice: "Managed by macOS. They're removed when you turn the related feature off.",
                             handling: .managed),
            SystemDataBucket(title: "System caches, logs & temp", symbol: "gearshape.2", paths: [u("/private/var"), u("/Library/Caches"), u("/Library/Logs"), u("Library/Logs")],
                             explanation: "System-wide caches, logs, temporary files and the swap backing store.",
                             advice: "Managed by macOS. A restart clears temporary files and shrinks swap. Crash reports and logs are in System Junk.",
                             handling: .managed),
        ]
        if hasFDA {
            list.insert(SystemDataBucket(title: "Docker Desktop", symbol: "cube.transparent", paths: [u("Library/Containers/com.docker.docker")],
                                         explanation: "Docker's VM disk holding every image, container, volume and build cache.",
                                         advice: "Start Docker and rescan. Prune then shows what's reclaimable inside (build cache, unused images). Docker shrinks the disk afterwards.",
                                         handling: .review(.docker)), at: 3)
            list.insert(SystemDataBucket(title: "Other app containers", symbol: "shippingbox.and.arrow.backward", paths: [u("Library/Containers"), u("Library/Group Containers")],
                                         subtract: [u("Library/Containers/com.docker.docker")],
                                         explanation: "Data of sandboxed apps (App Store apps, many Apple apps).",
                                         advice: "Mostly needed. Leftovers of uninstalled apps appear under Dangling & Orphaned.",
                                         handling: .explore), at: 8)
        }
        return list
    }

    /// The system's own APFS volumes (Preboot, Recovery, VM swap, Update), from diskutil's per-volume usage.
    nonisolated private static func systemVolumes() -> SystemDataBucket {
        var top: [(String, Int64)] = []
        let r = Shell.run("/usr/sbin/diskutil", ["apfs", "list", "-plist"], timeout: 20)
        if let plist = try? PropertyListSerialization.propertyList(from: Data(r.stdout.utf8), format: nil) as? [String: Any],
           let containers = plist["Containers"] as? [[String: Any]] {
            for c in containers {
                let vols = c["Volumes"] as? [[String: Any]] ?? []
                guard vols.contains(where: { ($0["Roles"] as? [String])?.contains("Data") == true }) else { continue }
                for v in vols {
                    let roles = v["Roles"] as? [String] ?? []
                    guard let role = roles.first(where: { ["Preboot", "Recovery", "VM", "Update"].contains($0) }) else { continue }
                    let used = (v["CapacityInUse"] as? NSNumber)?.int64Value ?? 0
                    top.append((role == "VM" ? "Swap (VM)" : role, used))
                }
            }
        }
        return SystemDataBucket(title: "macOS system volumes", symbol: "internaldrive", paths: [],
                                explanation: "Preboot (boot files and OS components), Recovery, swap for memory pressure, and update staging.",
                                advice: "Managed by macOS and not safe to touch. Swap shrinks after a restart, and Preboot is trimmed by macOS updates.",
                                handling: .managed, size: top.reduce(0) { $0 + $1.1 }, top: top.sorted { $0.1 > $1.1 })
    }

    func measure(hasFDA: Bool) {
        guard !measuring else { return }
        measuring = true
        var defs = Self.definitions(hasFDA: hasFDA)
        buckets = defs
        Task {
            let result = await AppModel.background { () -> [SystemDataBucket] in
                for i in defs.indices {
                    let paths = defs[i].paths.filter(FS.exists)
                    let sizes = Sizer.measureMany(paths + defs[i].subtract.filter(FS.exists))
                    let gross = paths.reduce(Int64(0)) { $0 + (sizes[$1]?.bytes ?? 0) }
                    let minus = defs[i].subtract.reduce(Int64(0)) { $0 + (sizes[$1]?.bytes ?? 0) }
                    defs[i].size = max(0, gross - minus)
                    // Largest children for context.
                    var kids: [(String, Int64)] = []
                    let children = paths.count == 1 ? FS.childDirs(paths[0]).filter { c in !defs[i].subtract.contains(c) } : paths
                    let ks = Sizer.measureMany(Array(children.prefix(400)))
                    for (u, r) in ks where r.bytes > 50_000_000 { kids.append((FS.tildePath(u), r.bytes)) }
                    defs[i].top = Array(kids.sorted { $0.1 > $1.1 }.prefix(4))
                }
                defs.append(Self.systemVolumes())
                return defs.sorted { ($0.size ?? 0) > ($1.size ?? 0) }
            }
            buckets = result
            if ProcessInfo.processInfo.environment["PRUNE_DEBUG"] != nil {
                for b in result { fputs(String(format: "%8.2f GB  %@\n", Double(b.size ?? 0) / 1e9, b.title), stderr) }
            }
            measuring = false
            measuredAt = Date()
        }
    }
}

extension SystemDataBucket.Handling {
    var isManaged: Bool { if case .managed = self { return true }; return false }
}

struct SystemDataView: View {
    @Environment(AppModel.self) private var model
    @State private var data = SystemDataModel.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("System Data").font(.largeTitle.weight(.bold))
                        Text("macOS's Storage settings files everything that isn't an app, document, photo or mail under \u{201C}System Data\u{201D}. On a developer Mac that's mostly SDKs, simulators, VMs, caches and hidden tool folders. Here's what it's made of on this Mac, and what you can do about each part.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button { data.measure(hasFDA: model.hasFDA) } label: { Label("Measure", systemImage: "arrow.clockwise") }
                        .disabled(data.measuring)
                }
                Card { VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        if data.measuring { ProgressView().controlSize(.small) }
                        Text(Fmt.bytes(data.total)).font(.system(size: 34, weight: .bold, design: .rounded))
                        Text(data.measuring ? "measured so far" : "measured across these areas").foregroundStyle(.secondary)
                        Spacer()
                    }
                    if !data.buckets.isEmpty && data.total > 0 {
                        let palette: [Color] = [.blue, .purple, .teal, .orange, .pink, .indigo, .mint, .brown, .cyan, .yellow, .green, .gray, .red]
                        StackedBar(segments: data.buckets.enumerated().map { i, b in
                            BarSegment(label: b.title, value: b.size ?? 0, color: b.handling.isManaged ? .gray : palette[i % palette.count])
                        })
                        .padding(.vertical, 6)
                    }
                    Text("Storage settings refreshes its figure slowly. After a cleanup it can show the old number for hours, or until you restart.\(model.hasFDA ? "" : " Grant Full Disk Access to include Docker and app containers.")")
                        .font(.caption).foregroundStyle(.secondary)
                } }
                VStack(spacing: 10) {
                    ForEach(data.buckets) { b in row(b) }
                }
            }
            .padding(24)
            .frame(maxWidth: 1000, alignment: .leading)
        }
        .navigationTitle("System Data")
        .onAppear { if data.buckets.isEmpty { data.measure(hasFDA: model.hasFDA) } }
    }

    private func row(_ b: SystemDataBucket) -> some View {
        let maxSize = max(data.buckets.compactMap(\.size).max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: b.symbol).font(.title3).foregroundStyle(Color.accentColor).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(b.title).font(.headline)
                    Text(b.explanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if let s = b.size { Text(Fmt.bytes(s)).font(.title3.monospacedDigit().weight(.semibold)) } else { ProgressView().controlSize(.small) }
            }
            GeometryReader { geo in
                Capsule().fill(handlingColor(b).opacity(0.7))
                    .frame(width: max(3, geo.size.width * Double(b.size ?? 0) / Double(maxSize)), height: 5)
            }
            .frame(height: 5)
            if !b.top.isEmpty {
                Text(b.top.map { "\($0.0) \(Fmt.bytes($0.1))" }.joined(separator: "  ·  "))
                    .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack(alignment: .top) {
                Label(b.advice, systemImage: icon(b)).font(.callout).fixedSize(horizontal: false, vertical: true)
                Spacer()
                switch b.handling {
                case .review(let c):
                    Button("Review in \(c.title)") {
                        if !model.hasScanned && !model.isScanning { model.scan() }
                        model.open(.category(c))
                    }
                case .explore:
                    if let p = b.paths.first { Button("Explore") { model.showInExplorer(p) } }
                case .managed:
                    Text("Managed by macOS").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    private func handlingColor(_ b: SystemDataBucket) -> Color {
        if case .managed = b.handling { return .gray }
        if case .explore = b.handling { return .blue }
        return .accentColor
    }

    private func icon(_ b: SystemDataBucket) -> String {
        switch b.handling {
        case .review: "lightbulb"
        case .explore: "magnifyingglass"
        case .managed: "lock"
        }
    }
}
