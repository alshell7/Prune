import Foundation

enum Ecosystem: String, CaseIterable, Hashable {
    case node, deno, rust, go, python, jvm, android, apple, flutter, ruby, php, elixir, haskell, cpp, esp, zig, dotnet, terraform

    var title: String {
        switch self {
        case .node: "Node.js"
        case .deno: "Deno"
        case .rust: "Rust"
        case .go: "Go"
        case .python: "Python"
        case .jvm: "Java/Kotlin (Gradle/Maven)"
        case .android: "Android"
        case .apple: "Apple platforms"
        case .flutter: "Flutter/Dart"
        case .ruby: "Ruby"
        case .php: "PHP"
        case .elixir: "Elixir"
        case .haskell: "Haskell"
        case .cpp: "C/C++ (CMake)"
        case .esp: "ESP-IDF"
        case .zig: "Zig"
        case .dotnet: ".NET"
        case .terraform: "Terraform"
        }
    }
}

extension ScanContext {
    static var allScanners: [Scanner] {
        [ProjectArtifactScanner(), WorktreeScanner(), EnvironmentScanner(), DevCacheScanner(), XcodeScanner(),
         DockerBrewScanner(), EditorScanner(), AIModelScanner(), AIToolsScanner(), SystemJunkScanner(), AppsScanner(),
         DanglingScanner(), LargeFilesScanner()]
    }
}

protocol Scanner {
    var name: String { get }
    func scan(_ ctx: ScanContext, _ progress: ScanProgress) -> [CleanupItem]
}

final class ScanProgress {
    private let handler: (String) -> Void
    init(_ handler: @escaping (String) -> Void) { self.handler = handler }
    func update(_ message: String) { handler(message) }
}

/// Shared, thread-safe state for one scan. The project index is built once, lazily, by whichever scanner asks first.
final class ScanContext {
    let settings: SettingsSnapshot
    let apps: AppIndex
    let running: Set<String>
    let hasFDA: Bool
    let home = FS.home
    var projectProgress: ((String) -> Void)?

    private var _projects: ProjectIndex?
    private let lock = NSLock()

    init(settings: SettingsSnapshot) {
        self.settings = settings
        self.apps = AppIndex.build()
        self.running = SystemInfo.runningBundleIDs()
        self.hasFDA = SystemInfo.hasFullDiskAccess()
    }

    /// Other apps' containers are protected: touching them without Full Disk Access raises a blocking consent prompt.
    func mayTouch(_ url: URL) -> Bool {
        if hasFDA { return true }
        let p = url.path
        return !(p.contains("/Library/Containers/") || p.contains("/Library/Group Containers/") || p.contains("/Library/Mail/") || p.contains("/Library/Messages/"))
    }

    var scanRoots: [URL] {
        var roots = settings.scanRoots.filter { FS.isDir($0) }
        if settings.includeExternalVolumes {
            for v in SystemInfo.externalVolumeRoots() where !settings.excludedVolumes.contains(v.path)
                && !roots.contains(where: { FS.isAncestor($0.path, of: v.path) || $0 == v }) {
                roots.append(v)
            }
        }
        // Remove roots nested inside other roots.
        return roots.filter { r in !roots.contains { $0 != r && FS.isAncestor($0.path, of: r.path) } }
    }

    func projects() -> ProjectIndex {
        lock.lock(); defer { lock.unlock() }
        if let p = _projects { return p }
        let p = ProjectIndex.build(roots: scanRoots, settings: settings) { [weak self] msg in self?.projectProgress?(msg) }
        _projects = p
        return p
    }

    var minBytes: Int64 { Int64(settings.minItemMB) * 1_048_576 }
    var staleDays: Int { settings.staleDays }

    func url(_ path: String) -> URL {
        path.hasPrefix("~/") ? home.appendingPathComponent(String(path.dropFirst(2))) : URL(fileURLWithPath: path)
    }

    /// Human sentence about how recently an ecosystem was used, plus whether it counts as stale.
    func ecosystemStatus(_ eco: Ecosystem?) -> (stale: Bool, note: String) {
        guard let eco else { return (true, "") }
        let idx = projects()
        guard let last = idx.ecosystemActivity[eco] else {
            return (true, "No \(eco.title) projects were found in your scan locations.")
        }
        let days = Age.days(last) ?? 0
        let who = idx.ecosystemLatestProject[eco].map { " (\($0))" } ?? ""
        if days >= staleDays {
            return (true, "Your most recent \(eco.title) project\(who) was last active \(Fmt.ago(last)).")
        }
        return (false, "You worked on \(eco.title)\(who) \(days == 0 ? "today" : "\(Fmt.ago(last))").")
    }

    /// Standard item for a cache folder. Measures it, skips tiny ones, and sets the verdict from risk and ecosystem activity.
    func cacheItem(_ category: Category, path: String, title: String, subtitle: String, ecosystem: Ecosystem? = nil,
                   risk: Risk, what: String, impact: String, restore: String?, whyKeep: String? = nil,
                   action: CleanupAction = .removeFiles, appBundleID: String? = nil, group: String? = nil,
                   measuredSize: Int64? = nil) -> CleanupItem? {
        let u = url(path)
        guard mayTouch(u), FS.exists(u), !settings.isExcluded(u) else { return nil }
        let m = measuredSize.map { SizeResult(bytes: $0) } ?? Sizer.measure(u)
        guard m.bytes >= max(minBytes, 1) else { return nil }
        let status = ecosystemStatus(ecosystem)
        var rec: Recommendation
        var reason: String
        switch risk {
        case .safe:
            rec = .recommended
            reason = "Regenerates automatically."
        case .low:
            if ecosystem == nil || status.stale {
                rec = .recommended
                reason = ecosystem == nil ? "Re-downloaded only when needed." : "Ecosystem idle. " + status.note
            } else {
                rec = .optional
                reason = status.note + " Expect a re-download."
            }
        case .review, .high:
            rec = .optional
            reason = "Holds data that may matter to you."
        }
        if let appBundleID, running.contains(appBundleID) {
            if rec == .recommended { rec = .optional }
            reason += " The app is running. Quit it first for a clean result."
        }
        return CleanupItem(category: category, title: title, subtitle: subtitle, group: group ?? ecosystem?.title,
                           paths: [u], size: m.bytes, risk: risk, recommendation: rec, reason: reason,
                           whatItIs: what, whyRemove: ecosystem.flatMap { _ in status.stale ? status.note : nil },
                           whyKeep: whyKeep ?? (ecosystem != nil && !status.stale ? status.note : nil),
                           impact: impact, restore: restore, lastUsed: m.newest, action: action, appBundleID: appBundleID)
    }
}
