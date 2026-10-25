import Foundation

/// Headless mode: `Prune --scan [--all]` prints what the GUI would show. Never deletes anything.
enum CLI {
    static func run(_ args: [String]) {
        let showAll = args.contains("--all")
        let started = Date()
        let ctx = ScanContext(settings: AppSettings.shared.snapshot)
        ctx.projectProgress = { _ in }
        let scanners: [Scanner] = ScanContext.allScanners
        var results = [[CleanupItem]](repeating: [], count: scanners.count)
        var timings = [TimeInterval](repeating: 0, count: scanners.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: scanners.count) { i in
            let t = Date()
            let r = scanners[i].scan(ctx, ScanProgress { _ in })
            lock.lock(); results[i] = r; timings[i] = Date().timeIntervalSince(t); lock.unlock()
        }
        let items = AppModel.finalize(results.flatMap { $0 }, minBytes: ctx.minBytes)
        let idx = ctx.projects()

        print("Prune scan · \(String(format: "%.1f", Date().timeIntervalSince(started)))s · \(idx.dirsVisited) dirs walked · \(idx.projects.count) projects · \(items.count) items")
        for (i, s) in scanners.enumerated() { print(String(format: "  %-20@ %5.1fs  %3d items", s.name as NSString, timings[i], results[i].count)) }
        let actionable = items.filter(\.countsAsReclaimable)
        print("Reclaimable: \(Fmt.bytes(Cleaner.effectiveSize(actionable)))  Recommended: \(Fmt.bytes(Cleaner.effectiveSize(actionable.filter { $0.recommendation == .recommended })))")
        for c in Category.allCases {
            let list = items.filter { $0.category == c }
            guard !list.isEmpty else { continue }
            print("\n== \(c.title) · \(Fmt.bytes(Cleaner.effectiveSize(list.filter(\.countsAsReclaimable))))")
            for i in (showAll ? list : Array(list.prefix(25))) {
                let lock = i.lockedReason != nil ? " 🔒" : ""
                print(String(format: "  %10@  %-11@ %-8@ %@ — %@%@",
                             Fmt.bytes(i.size) as NSString, i.recommendation.label as NSString, i.risk.label as NSString,
                             i.title as NSString, i.reason as NSString, lock as NSString))
            }
            if !showAll && list.count > 25 { print("  … \(list.count - 25) more") }
        }
    }
}
