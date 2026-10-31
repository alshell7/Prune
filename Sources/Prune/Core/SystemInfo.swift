import AppKit
import Foundation

struct VolumeInfo: Identifiable, Hashable {
    var id: String { url.path }
    var url: URL
    var name: String
    var total: Int64
    var available: Int64          // includes purgeable space macOS can free on demand
    var availableStrict: Int64    // actually free right now
    var isInternal: Bool
    var isBoot: Bool
    var format: String = ""
    var readOnly = false
    var used: Int64 { max(0, total - available) }
    var purgeable: Int64 { max(0, available - availableStrict) }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

enum SystemInfo {
    static func volumes() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                      .volumeAvailableCapacityForImportantUsageKey, .volumeIsInternalKey,
                                      .volumeIsBrowsableKey, .volumeIsRootFileSystemKey, .volumeIsLocalKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var out: [VolumeInfo] = []
        for u in urls {
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.volumeIsBrowsable == true, v.volumeIsLocal == true,
                  let total = v.volumeTotalCapacity, total > 0 else { continue }
            let strict = Int64(v.volumeAvailableCapacity ?? 0)
            let important = v.volumeAvailableCapacityForImportantUsage ?? strict
            var st = statfs()
            let fs = statfs(u.path, &st) == 0 ? withUnsafePointer(to: st.f_fstypename) { $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) } } : ""
            out.append(VolumeInfo(url: u, name: v.volumeName ?? u.lastPathComponent, total: Int64(total),
                                  available: max(important, strict), availableStrict: strict,
                                  isInternal: v.volumeIsInternal ?? false, isBoot: v.volumeIsRootFileSystem ?? (u.path == "/"),
                                  format: fs.uppercased(), readOnly: (st.f_flags & UInt32(MNT_RDONLY)) != 0))
        }
        return out.sorted { ($0.isBoot ? 0 : 1, $0.name) < ($1.isBoot ? 0 : 1, $1.name) }
    }

    static func bootVolume() -> VolumeInfo? { volumes().first { $0.isBoot } ?? volumes().first }

    /// Mounted local non-boot volumes, including read-only or root-owned volumes.
    /// Reading a drive does not require write permission at its mount point.
    static func externalVolumeRoots() -> [URL] {
        volumes().filter { !$0.isBoot && $0.url.path.hasPrefix("/Volumes/") }
            .map(\.url)
    }

    /// Full Disk Access probe: these locations are readable only with FDA.
    static func hasFullDiskAccess() -> Bool {
        // Only probe FDA-protected folders that fail fast with EPERM (never another app's container,
        // which would raise the "access data from other apps" prompt).
        let probes = [
            FS.home.appendingPathComponent("Library/Safari"),
            URL(fileURLWithPath: "/Library/Application Support/com.apple.TCC"),
        ]
        for p in probes where FS.exists(p) {
            if (try? FileManager.default.contentsOfDirectory(atPath: p.path)) != nil { return true }
            return false
        }
        return true
    }

    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    static func runningBundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    static var currentOSBuild: String {
        Shell.run("/usr/bin/sw_vers", ["-buildVersion"], timeout: 5).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Installed applications, keyed by bundle id, used to spot orphaned app data.
struct AppIndex {
    struct App { var url: URL; var bundleID: String; var name: String }
    var byBundleID: [String: App] = [:]
    var names: Set<String> = []
    var vendorPrefixes: Set<String> = []

    static func build() -> AppIndex {
        var idx = AppIndex()
        let roots = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                     FS.home.appendingPathComponent("Applications").path, "/System/Library/CoreServices"]
        var seen = Set<String>()
        func add(_ url: URL) {
            guard seen.insert(url.path).inserted, let b = Bundle(url: url), let id = b.bundleIdentifier else { return }
            let name = url.deletingPathExtension().lastPathComponent
            if let short = b.infoDictionary?["CFBundleName"] as? String { idx.names.insert(short.lowercased()) }
            idx.byBundleID[id.lowercased()] = App(url: url, bundleID: id, name: name)
            idx.names.insert(name.lowercased())
            idx.names.insert(url.deletingPathExtension().lastPathComponent.lowercased())
            let parts = id.lowercased().split(separator: ".")
            if parts.count >= 2 { idx.vendorPrefixes.insert(parts.prefix(2).joined(separator: ".")) }
        }
        for r in roots {
            for u in FS.children(URL(fileURLWithPath: r)) {
                if u.pathExtension == "app" { add(u) }
                else if FS.isDir(u), !u.lastPathComponent.hasPrefix(".") {
                    for sub in FS.children(u) where sub.pathExtension == "app" { add(sub) }
                }
            }
        }
        return idx
    }

    /// True when a bundle-id-named folder plausibly belongs to something still installed.
    func owns(_ bundleLike: String) -> Bool {
        let id = bundleLike.lowercased()
        if byBundleID[id] != nil { return true }
        // App extensions and helpers: com.vendor.app.Helper → com.vendor.app
        var parts = id.split(separator: ".").map(String.init)
        while parts.count > 2 {
            parts.removeLast()
            if byBundleID[parts.joined(separator: ".")] != nil { return true }
        }
        let p = id.split(separator: ".")
        if p.count >= 2, vendorPrefixes.contains(p.prefix(2).joined(separator: ".")) { return true }
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleLike) != nil { return true }
        return false
    }
}
