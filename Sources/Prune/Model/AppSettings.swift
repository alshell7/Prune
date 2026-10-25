import Foundation
import Observation

struct WatchedFolder: Codable, Hashable, Identifiable {
    var path: String
    var baselineSize: Int64?
    var baselineDate: Date?
    var lastSize: Int64?
    var lastChecked: Date?
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var growth: Int64? {
        guard let a = baselineSize, let b = lastSize else { return nil }
        return b - a
    }
}

/// Immutable copy of settings handed to scanners running off the main thread.
struct SettingsSnapshot {
    var scanRoots: [URL]
    var includeExternalVolumes: Bool
    var excludedVolumes: [String] = []
    var staleDays: Int
    var largeFileMB: Int
    var minItemMB: Int
    var excludedPaths: [String]

    func isExcluded(_ url: URL) -> Bool {
        let p = url.path
        return excludedPaths.contains { p == $0 || p.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }
}

@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    var scanRoots: [String] { didSet { save() } }
    var includeExternalVolumes: Bool { didSet { save() } }
    /// Mounted disks the user switched off for analysis (by mount path).
    var excludedVolumes: [String] { didSet { save() } }
    var staleDays: Int { didSet { save() } }
    var largeFileMB: Int { didSet { save() } }
    var minItemMB: Int { didSet { save() } }
    var excludedPaths: [String] { didSet { save() } }
    /// When true, items rated Safe are deleted immediately instead of going to the Trash.
    var deleteSafeImmediately: Bool { didSet { save() } }
    var showFreeSpaceInMenuBar: Bool { didSet { save() } }
    var lowSpaceAlertGB: Int { didSet { save() } }
    var growthAlertGB: Int { didSet { save() } }
    var watchedFolders: [WatchedFolder] { didSet { save() } }
    var autoScanHours: Int { didSet { save() } }
    var lastScanDate: Date? { didSet { save() } }

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        scanRoots = defaults.stringArray(forKey: "scanRoots") ?? [home]
        includeExternalVolumes = defaults.object(forKey: "includeExternalVolumes") as? Bool ?? true
        excludedVolumes = defaults.stringArray(forKey: "excludedVolumes") ?? []
        staleDays = defaults.object(forKey: "staleDays") as? Int ?? 30
        largeFileMB = defaults.object(forKey: "largeFileMB") as? Int ?? 500
        minItemMB = defaults.object(forKey: "minItemMB") as? Int ?? 1
        excludedPaths = defaults.stringArray(forKey: "excludedPaths") ?? []
        deleteSafeImmediately = defaults.object(forKey: "deleteSafeImmediately") as? Bool ?? false
        showFreeSpaceInMenuBar = defaults.object(forKey: "showFreeSpaceInMenuBar") as? Bool ?? true
        lowSpaceAlertGB = defaults.object(forKey: "lowSpaceAlertGB") as? Int ?? 10
        growthAlertGB = defaults.object(forKey: "growthAlertGB") as? Int ?? 2
        autoScanHours = defaults.object(forKey: "autoScanHours") as? Int ?? 0
        lastScanDate = defaults.object(forKey: "lastScanDate") as? Date
        if let data = defaults.data(forKey: "watchedFolders"),
           let list = try? JSONDecoder().decode([WatchedFolder].self, from: data) {
            watchedFolders = list
        } else {
            watchedFolders = []
        }
    }

    private func save() {
        defaults.set(scanRoots, forKey: "scanRoots")
        defaults.set(includeExternalVolumes, forKey: "includeExternalVolumes")
        defaults.set(excludedVolumes, forKey: "excludedVolumes")
        defaults.set(staleDays, forKey: "staleDays")
        defaults.set(largeFileMB, forKey: "largeFileMB")
        defaults.set(minItemMB, forKey: "minItemMB")
        defaults.set(excludedPaths, forKey: "excludedPaths")
        defaults.set(deleteSafeImmediately, forKey: "deleteSafeImmediately")
        defaults.set(showFreeSpaceInMenuBar, forKey: "showFreeSpaceInMenuBar")
        defaults.set(lowSpaceAlertGB, forKey: "lowSpaceAlertGB")
        defaults.set(growthAlertGB, forKey: "growthAlertGB")
        defaults.set(autoScanHours, forKey: "autoScanHours")
        defaults.set(lastScanDate, forKey: "lastScanDate")
        if let data = try? JSONEncoder().encode(watchedFolders) {
            defaults.set(data, forKey: "watchedFolders")
        }
    }

    var snapshot: SettingsSnapshot {
        SettingsSnapshot(
            scanRoots: scanRoots.map { URL(fileURLWithPath: $0) },
            includeExternalVolumes: includeExternalVolumes,
            excludedVolumes: excludedVolumes,
            staleDays: max(staleDays, 1),
            largeFileMB: max(largeFileMB, 50),
            minItemMB: max(minItemMB, 0),
            excludedPaths: excludedPaths
        )
    }
}
