import AppKit
import Foundation
import Observation
import UserNotifications

enum Route: Hashable {
    case overview
    case category(Category)
    case explorer
    case systemData
    case offload
    case security
    case codeBackup
    case taskManager
    case network
    case apps
    case duplicates
    case watched
    case history
}

struct ScanSummary {
    var reclaimable: Int64 = 0
    var recommended: Int64 = 0
    var recommendedCount = 0
    var byRisk: [Risk: Int64] = [:]
    var byCategory: [Category: (size: Int64, recommended: Int, count: Int)] = [:]
    var safeQuickWins: [CleanupItem] = []
    var safeQuickWinSize: Int64 = 0
    var byVolume: [String: (reclaimable: Int64, recommended: Int64)] = [:]
}

struct CleanProgress { var done: Int; var total: Int; var current: String }

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let settings = AppSettings.shared
    let scanners: [Scanner] = ScanContext.allScanners

    var items: [CleanupItem] = [] { didSet { recomputeSummary() } }
    var selection: Set<String> = [] { didSet { recomputeSelection() } }
    private(set) var summary = ScanSummary()
    private(set) var selectedItems: [CleanupItem] = []
    private(set) var selectedSize: Int64 = 0

    var isScanning = false
    var scannerStatus: [String: String] = [:] { didSet { lastProgressAt = Date() } }
    var lastProgressAt = Date()
    var finishedScanners: Set<String> = []
    var timedOut: Set<String> = []
    var scanDuration: TimeInterval?
    var hasScanned = false
    var scanCoverageWarning: String?

    var volumes: [VolumeInfo] = []
    var hasFDA = true
    var route: Route? = .overview
    var focusedItemID: String?
    var explorerPath: URL?

    var reviewItems: [CleanupItem] = []
    var showReview = false
    var isCleaning = false
    var cleanProgress: CleanProgress?
    var lastOutcomes: [CleanOutcome] = []

    private var lowSpaceNotified = false
    private var timerTask: Task<Void, Never>?

    private init() {
        refreshVolumes()
        hasFDA = SystemInfo.hasFullDiskAccess()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                self?.tick()
            }
        }
    }

    var bootVolume: VolumeInfo? { volumes.first { $0.isBoot } ?? volumes.first }

    func refreshVolumes() { volumes = SystemInfo.volumes(); recomputeSummary() }

    private func tick() {
        refreshVolumes()
        if let boot = bootVolume {
            let threshold = Int64(settings.lowSpaceAlertGB) * 1_000_000_000
            if boot.available < threshold && !lowSpaceNotified {
                lowSpaceNotified = true
                Notifier.post(title: "Low disk space", body: "Only \(Fmt.bytes(boot.available)) free on \(boot.name). Open Prune to see what's safe to clean.")
            } else if boot.available > threshold + 1_000_000_000 {
                lowSpaceNotified = false
            }
        }
        if settings.autoScanHours > 0, !isScanning, !isCleaning {
            let due = (settings.lastScanDate ?? .distantPast).addingTimeInterval(TimeInterval(settings.autoScanHours) * 3600)
            if Date() > due { scan() }
        }
    }

    // MARK: - Scanning

    func scan() {
        guard !isScanning, !isCleaning else { return }
        isScanning = true
        items = []
        selection = []
        scannerStatus = [:]
        finishedScanners = []
        timedOut = []
        scanCoverageWarning = nil
        hasFDA = SystemInfo.hasFullDiskAccess()
        let started = Date()
        let snapshot = settings.snapshot
        let scanners = self.scanners

        Task {
            let ctx = await Self.background { ScanContext(settings: snapshot) }
            ctx.projectProgress = { msg in Task { @MainActor in AppModel.shared.scannerStatus["Project index"] = msg } }
            await withTaskGroup(of: (String, [CleanupItem]).self) { group in
                for s in scanners {
                    group.addTask {
                        let progress = ScanProgress { msg in Task { @MainActor in AppModel.shared.scannerStatus[s.name] = msg } }
                        // A watchdog keeps one stuck analyzer (e.g. a blocked file system call) from stalling the whole scan.
                        let result = await Self.background(timeout: 300) { s.scan(ctx, progress) }
                        if result == nil { Task { @MainActor in AppModel.shared.timedOut.insert(s.name) } }
                        return (s.name, result ?? [])
                    }
                }
                for await (name, result) in group {
                    finishedScanners.insert(name)
                    scannerStatus[name] = "Done"
                    items = Self.finalize(items + ctx.markReadOnly(result), minBytes: ctx.minBytes)
                }
            }
            scannerStatus["Project index"] = nil
            scanCoverageWarning = ctx.projectCoverageWarning()
            isScanning = false
            hasScanned = true
            scanDuration = Date().timeIntervalSince(started)
            settings.lastScanDate = Date()
            // Protection checks are read-only, so they refresh alongside each scan.
            SecurityModel.shared.scan(settings: snapshot)
            CodeBackupModel.shared.refresh(settings: snapshot)
            refreshVolumes()
            if summary.recommended > 5_000_000_000, NSApp.isActive == false {
                Notifier.post(title: "Scan complete", body: "Prune found \(Fmt.bytes(summary.recommended)) it recommends cleaning.")
            }
        }
    }

    /// Runs blocking work off the cooperative pool; returns nil if it doesn't finish in time.
    nonisolated static func background<T>(timeout: TimeInterval, _ work: @escaping () -> T) async -> T? {
        await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
            let lock = NSLock()
            var done = false
            let finish: (T?) -> Void = { value in
                lock.lock(); defer { lock.unlock() }
                guard !done else { return }
                done = true
                cont.resume(returning: value)
            }
            DispatchQueue.global(qos: .userInitiated).async { finish(work()) }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    nonisolated static func background<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async { cont.resume(returning: work()) }
        }
    }

    /// Resolves overlaps between scanners and orders results.
    nonisolated static func finalize(_ items: [CleanupItem], minBytes: Int64) -> [CleanupItem] {
        var out: [CleanupItem] = []
        var seenIDs = Set<String>()
        let priority: [Category] = [.environments, .devCaches, .xcode, .editors, .aiModels, .worktrees, .projectArtifacts, .dangling, .systemJunk, .applications, .docker, .largeFiles]
        let sorted = items.sorted { (priority.firstIndex(of: $0.category) ?? 99) < (priority.firstIndex(of: $1.category) ?? 99) }
        var filePaths = Set<String>()
        var claimed: [String: String] = [:]
        for i in sorted {
            guard seenIDs.insert(i.id).inserted else { continue }
            if i.category == .largeFiles, let p = i.paths.first?.path, Cleaner.claimedOwner(of: p, in: claimed) != nil { continue }
            if case .removeFiles = i.action, i.paths.count == 1 {
                if filePaths.contains(i.paths[0].path) { continue }   // same folder reported by two scanners
                filePaths.insert(i.paths[0].path)
            }
            if i.category != .largeFiles {
                for p in i.paths where claimed[p.path] == nil { claimed[p.path] = i.title }
            }
            out.append(i)
        }
        return out.sorted { $0.size > $1.size }
    }

    // MARK: - Derived data

    private func recomputeSummary() {
        var s = ScanSummary()
        let actionable = items.filter(\.countsAsReclaimable)
        s.reclaimable = Cleaner.effectiveSize(actionable)
        let rec = actionable.filter { $0.recommendation == .recommended }
        s.recommended = Cleaner.effectiveSize(rec)
        s.recommendedCount = rec.count
        s.byVolume = Self.volumeTotals(actionable, volumes: volumes)
        for r in Risk.allCases { s.byRisk[r] = Cleaner.effectiveSize(rec.filter { $0.risk == r }) }
        for c in Category.allCases {
            let inCat = items.filter { $0.category == c }
            let act = inCat.filter(\.countsAsReclaimable)
            s.byCategory[c] = (Cleaner.effectiveSize(act), act.filter { $0.recommendation == .recommended }.count, inCat.count)
        }
        // "Quick wins": recommended, safe, nothing running, no admin prompt, files only.
        s.safeQuickWins = rec.filter { item in
            guard item.risk == .safe, !item.needsAdmin else { return false }
            if let b = item.appBundleID, NSRunningApplication.runningApplications(withBundleIdentifier: b).isEmpty == false { return false }
            switch item.action {
            case .removeFiles: return true
            case .command(let c): return !c.needsAdmin
            default: return false
            }
        }
        s.safeQuickWinSize = Cleaner.effectiveSize(s.safeQuickWins)
        summary = s
        recomputeSelection()
    }

    /// Do not credit an external disk's cleanup to the startup disk. Items spanning multiple
    /// volumes or without paths cannot be attributed safely to one volume.
    nonisolated static func volumeTotals(_ items: [CleanupItem], volumes: [VolumeInfo]) -> [String: (reclaimable: Int64, recommended: Int64)] {
        let roots = volumes.sorted { $0.url.path.count > $1.url.path.count }
        var grouped: [String: [CleanupItem]] = [:]
        for item in items where !item.paths.isEmpty {
            let locations = item.paths.map { path in
                roots.first { path.path == $0.url.path || FS.isAncestor($0.url.path, of: path.path) }?.url.path
            }
            guard let first = locations.first ?? nil, locations.allSatisfy({ $0 == first }) else { continue }
            grouped[first, default: []].append(item)
        }
        return grouped.mapValues { list in
            (Cleaner.effectiveSize(list), Cleaner.effectiveSize(list.filter { $0.recommendation == .recommended }))
        }
    }

    private func recomputeSelection() {
        selectedItems = items.filter { selection.contains($0.id) && $0.isActionable }
        selectedSize = Cleaner.effectiveSize(selectedItems)
    }

    func items(in c: Category) -> [CleanupItem] { items.filter { $0.category == c } }

    func toggle(_ item: CleanupItem) {
        guard item.isActionable else { return }
        if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
    }

    func selectRecommended(in c: Category? = nil) {
        var s = selection
        for i in items where i.isActionable && i.recommendation == .recommended && (c == nil || i.category == c) { s.insert(i.id) }
        selection = s
    }

    func clearSelection(in c: Category? = nil) {
        if let c { selection.subtract(items.filter { $0.category == c }.map(\.id)) } else { selection = [] }
    }

    func exclude(_ item: CleanupItem) {
        for p in item.paths where !settings.excludedPaths.contains(p.path) { settings.excludedPaths.append(p.path) }
        items.removeAll { $0.id == item.id }
        selection.remove(item.id)
    }

    // MARK: - Cleaning

    func review(_ list: [CleanupItem]) {
        reviewItems = list.filter(\.isActionable)
        lastOutcomes = []
        showReview = true
    }

    func clean(_ list: [CleanupItem]) async -> [CleanOutcome] {
        guard !isCleaning else { return [] }
        isCleaning = true
        cleanProgress = CleanProgress(done: 0, total: list.count, current: "Preparing…")
        let deleteSafe = settings.deleteSafeImmediately
        let outcomes = await Self.background {
            Cleaner.clean(list, deleteSafeImmediately: deleteSafe) { done, total, current in
                Task { @MainActor in AppModel.shared.cleanProgress = CleanProgress(done: done, total: total, current: current) }
            }
        }
        let succeeded = Set(outcomes.filter { $0.success && $0.method != "Skipped" }.compactMap(\.itemID))
        let skippedOK = Set(outcomes.filter { $0.method == "Skipped" }.compactMap(\.itemID))
        items.removeAll { succeeded.contains($0.id) || skippedOK.contains($0.id) }
        selection.subtract(succeeded.union(skippedOK))
        lastOutcomes = outcomes
        isCleaning = false
        cleanProgress = nil
        refreshVolumes()
        return outcomes
    }

    // MARK: - Navigation helpers

    func open(_ route: Route, focus: String? = nil) {
        self.route = route
        focusedItemID = focus
    }

    func showInExplorer(_ url: URL) {
        explorerPath = FS.isDir(url) ? url : url.deletingLastPathComponent()
        route = .explorer
    }
}

enum Notifier {
    static var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    static func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
