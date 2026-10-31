import Foundation
import Observation

/// Free space over time for every disk Prune has seen, sampled while Prune runs (every 15 minutes, or sooner
/// when free space jumps by 1 GB). Kept for 120 days in Application Support.
@MainActor
@Observable
final class SpaceHistory {
    static let shared = SpaceHistory()

    struct Sample: Codable, Hashable { var date: Date; var free: Int64; var total: Int64 }
    struct Series: Codable, Identifiable { var id: String; var name: String; var isBoot: Bool; var samples: [Sample] }

    private(set) var series: [String: Series] = [:]
    private let file = FS.home.appendingPathComponent("Library/Application Support/Prune/space-history.json")
    private var lastSave = Date.distantPast

    private init() {
        if DemoMode.active { series = DemoData.timeline(); return }
        if let data = try? Data(contentsOf: file), let decoded = try? JSONDecoder().decode([String: Series].self, from: data) { series = decoded }
    }

    func reloadDemo() { series = DemoData.timeline() }

    func record(_ volumes: [VolumeInfo], now: Date = Date()) {
        guard !DemoMode.active else { return }
        var changed = false
        for v in volumes where v.total > 0 {
            let key = v.isBoot ? "boot" : v.url.path
            var s = series[key] ?? Series(id: key, name: v.name, isBoot: v.isBoot, samples: [])
            if let last = s.samples.last, now.timeIntervalSince(last.date) < 900 && abs(last.free - v.available) < 1_000_000_000 { continue }
            s.name = v.name
            s.samples.append(Sample(date: now, free: v.available, total: v.total))
            s.samples.removeAll { now.timeIntervalSince($0.date) > 120 * 86_400 }
            series[key] = s
            changed = true
        }
        if changed && now.timeIntervalSince(lastSave) > 60 { save(); lastSave = now }
    }

    func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(series) { try? data.write(to: file, options: .atomic) }
    }

    func samples(for v: VolumeInfo, days: Int) -> [Sample] {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        return (series[v.isBoot ? "boot" : v.url.path]?.samples ?? []).filter { $0.date >= cutoff }
    }

    struct Forecast { var bytesPerDay: Double; var daysUntilFull: Double? }

    /// Least-squares trend of free space; days until it reaches `floor` when shrinking.
    nonisolated static func forecast(_ samples: [Sample], floor: Int64 = 0) -> Forecast? {
        guard samples.count >= 3, let first = samples.first, let last = samples.last, last.date.timeIntervalSince(first.date) >= 3600 else { return nil }
        let xs = samples.map { $0.date.timeIntervalSince(first.date) / 86_400 }, ys = samples.map { Double($0.free) }
        let n = Double(xs.count), mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        let sxx = zip(xs, xs).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - mx) }
        guard sxx > 0 else { return nil }
        let slope = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) } / sxx
        let days: Double? = slope < -1_000_000 ? max(0, (Double(last.free) - Double(floor)) / -slope) : nil
        return Forecast(bytesPerDay: slope, daysUntilFull: days)
    }
}
