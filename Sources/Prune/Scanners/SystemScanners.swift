import AppKit
import Foundation

struct SystemJunkScanner: Scanner {
    let name = "System junk"

    /// ~/Library/Caches children handled by more specific scanners, or owned by macOS itself.
    static let skipCacheNames: Set<String> = [
        "Homebrew", "Yarn", "pip", "CocoaPods", "go-build", "node-gyp", "ms-playwright", "typescript", "electron", "electron-builder",
        "Cypress", "deno", "pypoetry", "pipenv", "org.carthage.CarthageKit", "org.swift.swiftpm", "JetBrains", "com.apple.dt.Xcode",
        "Coursier", "composer", "ccache", "Mozilla.sccache", "GeoServices", "PassKit", "CloudKit", "FamilyCircle", "Metadata",
        "SiriTTS", "com.crashlytics.data", "familycircled", "Prune", "app.prune.mac",
    ]
    /// Vendor folder names that don't match their app's name.
    static let folderAliases: [String: String] = [
        "Google": "com.google.Chrome", "Firefox": "org.mozilla.firefox", "BraveSoftware": "com.brave.Browser",
        "Microsoft Edge": "com.microsoft.edgemac", "Arc": "company.thebrowser.Browser", "Code": "com.microsoft.VSCode",
        "Slack": "com.tinyspeck.slackmacgap", "discord": "com.hnc.Discord", "Claude": "com.anthropic.claudefordesktop",
    ]

    static let chromiumCacheNames: Set<String> = [
        "Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache", "GraphiteDawnCache", "ShaderCache", "GrShaderCache", "component_crx_cache",
    ]

    func scan(_ ctx: ScanContext, _ progress: ScanProgress) -> [CleanupItem] {
        var items: [CleanupItem] = []
        let h = FS.home
        let lib = h.appendingPathComponent("Library")

        // App caches in ~/Library/Caches
        progress.update("Measuring app caches…")
        let caches = FS.childDirs(lib.appendingPathComponent("Caches")).filter { d in
            let n = d.lastPathComponent
            return !n.hasPrefix("com.apple.") && !Self.skipCacheNames.contains(n) && !n.hasPrefix(".")
        }
        let sizes = Sizer.measureMany(caches)
        for d in caches {
            guard let m = sizes[d], m.bytes >= max(ctx.minBytes, 5 * 1_048_576) else { continue }
            let n = d.lastPathComponent
            let app = ctx.apps.byBundleID[n.lowercased()] ?? Self.folderAliases[n].flatMap { ctx.apps.byBundleID[$0.lowercased()] }
            let appName = app?.name ?? n
            let running = ctx.running.contains(n) || (app.map { ctx.running.contains($0.bundleID) } ?? false)
            if n.hasSuffix(".ShipIt") {
                let product = String(n.dropLast(".ShipIt".count))
                let pname = ctx.apps.byBundleID[product.lowercased()]?.name ?? product
                items.append(CleanupItem(
                    category: .systemJunk, title: "\(pname) · updater leftovers", subtitle: FS.tildePath(d), group: "Updater leftovers",
                    paths: [d], size: m.bytes, risk: .safe, recommendation: .recommended,
                    reason: "Old update downloads (Squirrel/ShipIt).",
                    whatItIs: "Update packages that \(pname)'s auto-updater downloaded and already installed.",
                    whyRemove: "The update was already applied. These are stale copies of the full app.",
                    impact: "None. The next update downloads only what it needs.", restore: nil, lastUsed: m.newest))
                continue
            }
            let spotify = n.lowercased().contains("spotify")
            let uninstalled = app == nil && n.split(separator: ".").count >= 3 && !ctx.apps.owns(n) && !running
            items.append(CleanupItem(
                category: .systemJunk, title: uninstalled ? "\(n) cache (app not installed)" : "\(appName) cache", subtitle: FS.tildePath(d), group: "App caches",
                paths: [d], size: m.bytes, risk: spotify ? .low : .safe,
                recommendation: running ? .optional : (spotify ? .optional : .recommended),
                reason: running ? "\(appName) is running. Quit it first for a clean result." : (uninstalled ? "The app that created it is no longer installed." : "Apps rebuild their caches as needed."),
                whatItIs: "Cached data \(appName) stores to speed things up: downloaded images, web content, thumbnails.",
                whyKeep: spotify ? "Contains offline-downloaded music." : nil,
                impact: "\(appName) may feel slower the first time it re-fetches what it needs.", restore: "Automatic",
                lastUsed: m.newest, appBundleID: app?.bundleID ?? (n.contains(".") ? n : nil)))
        }

        // Chromium/Electron caches inside Application Support (Claude, Slack, Discord, VS Code, Chrome profiles…)
        progress.update("Looking for Electron & browser caches…")
        let support = lib.appendingPathComponent("Application Support")
        for appDir in FS.childDirs(support) where !appDir.lastPathComponent.hasPrefix("com.apple") {
            var targets: [URL] = []
            var scanDirs = [appDir]
            // Chrome-style profiles one level down (Default, Profile 1…)
            for sub in FS.childDirs(appDir) where sub.lastPathComponent == "Default" || sub.lastPathComponent.hasPrefix("Profile ") || sub.lastPathComponent == "Chrome" || sub.lastPathComponent == "Chrome Beta" {
                scanDirs.append(sub)
                for p in FS.childDirs(sub) where p.lastPathComponent == "Default" || p.lastPathComponent.hasPrefix("Profile ") { scanDirs.append(p) }
            }
            for s in scanDirs {
                for c in FS.childDirs(s) where Self.chromiumCacheNames.contains(c.lastPathComponent) { targets.append(c) }
                let sw = s.appendingPathComponent("Service Worker/CacheStorage")
                if FS.isDir(sw) { targets.append(sw) }
            }
            guard !targets.isEmpty else { continue }
            let total = Sizer.measureMany(targets).values.reduce(0) { $0 + $1.bytes }
            guard total >= max(ctx.minBytes, 20 * 1_048_576) else { continue }
            let name = appDir.lastPathComponent
            let app = Self.folderAliases[name].flatMap { ctx.apps.byBundleID[$0.lowercased()] }
                ?? ctx.apps.byBundleID.values.first { $0.name.lowercased() == name.lowercased() || $0.url.deletingPathExtension().lastPathComponent.lowercased() == name.lowercased() }
            let running = app.map { ctx.running.contains($0.bundleID) } ?? false
            let display = app?.name ?? name
            items.append(CleanupItem(
                category: .systemJunk, title: "\(display) · web caches", subtitle: "\(targets.count) cache folders", group: "App caches",
                paths: targets, size: total, risk: .safe, recommendation: running ? .optional : .recommended,
                reason: running ? "\(name) is running. Quit it first." : "Chromium/Electron caches that rebuild automatically.",
                whatItIs: "HTTP cache, compiled JavaScript (Code Cache) and GPU shader caches that \(name)'s embedded Chromium keeps.",
                impact: "\(name) starts a little slower once while it rebuilds them. Logins and settings are not affected.",
                restore: "Automatic", appBundleID: app?.bundleID))
        }
        if let i = ctx.cacheItem(.systemJunk, path: "~/Library/Application Support/Google/GoogleUpdater/crx_cache", title: "Google Updater download cache",
                                 subtitle: "~/Library/Application Support/Google/GoogleUpdater/crx_cache", risk: .safe,
                                 what: "Chrome component and update packages that were already installed.", impact: "None.", restore: nil, group: "Updater leftovers") {
            items.append(i)
        }

        // Logs & crash reports
        progress.update("Measuring logs…")
        let logs = lib.appendingPathComponent("Logs")
        let logDirs = FS.children(logs).filter { !["DiagnosticReports", "Prune", "CoreSimulator", "JetBrains", "Google"].contains($0.lastPathComponent) }
        let logTotal = Sizer.measureMany(logDirs).values.reduce(0) { $0 + $1.bytes }
        if logTotal >= ctx.minBytes {
            items.append(CleanupItem(
                category: .systemJunk, title: "User logs", subtitle: "~/Library/Logs", group: "Logs", paths: logDirs, size: logTotal,
                risk: .safe, recommendation: .recommended, reason: "Diagnostic logs apps write over time.",
                whatItIs: "Log files written by apps and background services.", impact: "None. Apps create new logs as needed.", restore: nil))
        }
        if let i = ctx.cacheItem(.systemJunk, path: "~/Library/Logs/DiagnosticReports", title: "Crash reports", subtitle: "~/Library/Logs/DiagnosticReports", risk: .safe,
                                 what: "Crash and hang reports. macOS already forwards them if you share analytics.", impact: "You can't review past crashes.", restore: nil, group: "Logs") {
            items.append(i)
        }
        let sysDiag = URL(fileURLWithPath: "/Library/Logs/DiagnosticReports")
        let sysReports = FS.children(sysDiag)
        if !sysReports.isEmpty {
            let total = Sizer.measureMany(sysReports).values.reduce(0) { $0 + $1.bytes }
            if total >= ctx.minBytes {
                items.append(CleanupItem(
                    category: .systemJunk, title: "System crash reports", subtitle: sysDiag.path, group: "Logs", paths: sysReports, size: total,
                    risk: .safe, recommendation: .optional, reason: "Needs your administrator password.",
                    whatItIs: "Crash reports from system processes.", impact: "None.", restore: nil, needsAdmin: true))
            }
        }

        // iOS firmware and device backups
        for dir in ["iPhone Software Updates", "iPad Software Updates", "iPod Software Updates"] {
            if let i = ctx.cacheItem(.systemJunk, path: "~/Library/iTunes/\(dir)", title: dir, subtitle: "~/Library/iTunes/\(dir)", risk: .safe,
                                     what: "Downloaded iOS/iPadOS firmware (.ipsw) used for restores.", impact: "Finder downloads firmware again if you restore a device.",
                                     restore: "Automatic", group: "Devices") { items.append(i) }
        }
        let backups = lib.appendingPathComponent("Application Support/MobileSync/Backup")
        for b in FS.childDirs(backups) {
            let m = Sizer.measure(b)
            guard m.bytes >= ctx.minBytes else { continue }
            let info = NSDictionary(contentsOf: b.appendingPathComponent("Info.plist"))
            let device = info?["Device Name"] as? String ?? b.lastPathComponent
            let date = info?["Last Backup Date"] as? Date ?? m.newest
            let old = (Age.days(date) ?? 0) > 180
            items.append(CleanupItem(
                category: .systemJunk, title: "Device backup · \(device)", subtitle: (info?["Product Name"] as? String) ?? "iOS backup", group: "Devices",
                paths: [b], size: m.bytes, risk: .high, recommendation: .optional,
                reason: old ? "Last backed up \(Fmt.ago(date))." : "Backed up \(Fmt.ago(date)).",
                whatItIs: "A local Finder backup of \(device): messages, photos (if not in iCloud), app data.",
                whyKeep: "This may be the only copy of the device's data if iCloud Backup is off.",
                impact: "You can no longer restore \(device) to this point.", restore: "Back up the device again in Finder", lastUsed: date))
        }

        // Trash
        let trash = h.appendingPathComponent(".Trash")
        let tm = Sizer.measure(trash)
        if tm.bytes >= ctx.minBytes {
            items.append(CleanupItem(
                id: "trash", category: .systemJunk, title: "Trash", subtitle: "Everything already in the Trash", group: "Trash",
                paths: [trash], size: tm.bytes, risk: .high, recommendation: .optional,
                reason: "Space is only freed once the Trash is emptied.",
                whatItIs: "Files you (or Prune) moved to the Trash. They still take up disk space.",
                whyKeep: "Emptying is permanent. Make sure nothing in there is needed.",
                impact: "Everything in the Trash is erased permanently.", restore: nil, action: .emptyTrash))
        } else if tm.unreadable > 0 {
            items.append(CleanupItem(
                id: "trash", category: .systemJunk, title: "Trash", subtitle: "Size unknown. Grant Full Disk Access to measure.", group: "Trash",
                paths: [trash], size: 0, risk: .high, recommendation: .optional, reason: "Prune can't read the Trash without Full Disk Access.",
                whatItIs: "Files waiting in the Trash.", impact: "Everything in the Trash is erased permanently.", restore: nil, action: .emptyTrash, sizeIsEstimate: true))
        }

        // Trash folders on other analyzed disks (/Volumes/X/.Trashes/<uid>).
        for root in ctx.externalScanRoots where ctx.volumes.contains(where: { $0.url.path == root.path }) {
            let t = root.appendingPathComponent(".Trashes/\(getuid())")
            let m = Sizer.measure(t)
            guard m.bytes >= ctx.minBytes else { continue }
            items.append(CleanupItem(
                id: "trash:\(root.path)", category: .systemJunk, title: "Trash on \(root.lastPathComponent)", subtitle: t.path, group: "Trash",
                paths: [t], size: m.bytes, risk: .high, recommendation: .optional,
                reason: "Files deleted from this disk still use its space until the Trash is emptied.",
                whatItIs: "Items you moved to the Trash from \(root.lastPathComponent). macOS keeps a separate Trash on each disk.",
                whyKeep: "Emptying is permanent.", impact: "Everything in the Trash is erased permanently (all disks).", restore: nil, action: .emptyTrash))
        }

        // Local Time Machine snapshots
        let snaps = Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"], timeout: 15).stdout
            .split(separator: "\n").filter { $0.contains("com.apple.TimeMachine") }
        if !snaps.isEmpty {
            items.append(CleanupItem(
                id: "tm-snapshots", category: .systemJunk, title: "Local Time Machine snapshots", subtitle: "\(snaps.count) snapshot\(snaps.count == 1 ? "" : "s")", group: "Snapshots",
                paths: [], size: 0, risk: .low, recommendation: .optional,
                reason: "macOS frees these automatically under pressure, but thinning them now gives the space back immediately.",
                whatItIs: "Hourly APFS snapshots kept on the internal disk while your backup drive is away. Their size shows up as \u{201C}purgeable\u{201D}.",
                whyKeep: "They let you restore recent file versions even without the backup disk.",
                impact: "Local restore points are removed. Your Time Machine backups on the external drive are untouched.",
                restore: nil, action: .command(ShellCommand(tool: "/usr/bin/tmutil", args: ["thinlocalsnapshots", "/", "999999999999", "4"], needsAdmin: true)),
                needsAdmin: true, sizeIsEstimate: true))
        }
        return items
    }
}

struct AppsScanner: Scanner {
    let name = "Applications"

    static let leftoverDirs = ["Application Support", "Caches", "Containers", "HTTPStorages", "WebKit", "Logs", "Application Scripts", "Saved Application State"]

    static func leftovers(bundleID: String, appName: String) -> [URL] {
        let lib = FS.home.appendingPathComponent("Library")
        var out: [URL] = []
        for d in leftoverDirs {
            out.append(lib.appendingPathComponent(d).appendingPathComponent(bundleID))
            if d == "Saved Application State" { out.append(lib.appendingPathComponent(d).appendingPathComponent(bundleID + ".savedState")) }
        }
        out.append(lib.appendingPathComponent("Preferences/\(bundleID).plist"))
        out.append(lib.appendingPathComponent("Cookies/\(bundleID).binarycookies"))
        out.append(lib.appendingPathComponent("HTTPStorages/\(bundleID).binarycookies"))
        if appName.count > 2 {
            out.append(lib.appendingPathComponent("Application Support/\(appName)"))
            out.append(lib.appendingPathComponent("Logs/\(appName)"))
            out.append(lib.appendingPathComponent("Caches/\(appName)"))
        }
        return out.filter(FS.exists)
    }

    func scan(_ ctx: ScanContext, _ progress: ScanProgress) -> [CleanupItem] {
        var items: [CleanupItem] = []
        progress.update("Checking when apps were last used…")
        let selfID = Bundle.main.bundleIdentifier ?? "app.prune.mac"
        let devHeavy: [String: String] = [
            "com.apple.dt.xcode": "Xcode is only needed for Apple-platform development. Command Line Tools (`xcode-select --install`, ~1 GB) cover git, clang and most Homebrew builds.",
            "com.google.android.studio": "Android Studio is only needed for Android development and emulators. Your Gradle builds keep working from the command line with a JDK and the SDK.",
            "com.docker.docker": "Docker Desktop is only needed when you run containers. Its disk image (in Docker & Homebrew) is often much larger than the app.",
        ]
        for app in ctx.apps.byBundleID.values {
            let path = app.url.path
            guard path.hasPrefix("/Applications/") || path.hasPrefix(FS.home.path + "/Applications/") else { continue }
            let id = app.bundleID
            if id.hasPrefix("com.apple.") && id.lowercased() != "com.apple.dt.xcode" { continue }
            if id == selfID { continue }
            let lastUsed = Spotlight.lastUsed(app.url)
            let added = Spotlight.attribute(app.url, "kMDItemDateAdded") as? Date
            let reference = lastUsed ?? added
            let days = Age.days(reference) ?? 0
            let dev = devHeavy[id.lowercased()]
            guard days >= 60 || (dev != nil && days >= ctx.staleDays * 2) else { continue }
            let leftovers = Self.leftovers(bundleID: id, appName: app.name).filter(ctx.mayTouch)
            let appSize = Spotlight.physicalSize(app.url) ?? Sizer.measure(app.url).bytes
            let leftSize = Sizer.measureMany(leftovers).values.reduce(0) { $0 + $1.bytes }
            let total = appSize + leftSize
            guard total >= max(ctx.minBytes, 20 * 1_048_576) else { continue }
            let running = ctx.running.contains(id)
            let fromStore = FS.exists(app.url.appendingPathComponent("Contents/_MASReceipt"))
            let rec: Recommendation = running ? .keep : (days >= 365 ? .recommended : .optional)
            items.append(CleanupItem(
                category: .applications, title: app.name, subtitle: lastUsed == nil ? "No record of being opened" : "Last opened \(Fmt.relative(lastUsed))",
                group: dev != nil ? "Developer tools" : "Apps", paths: [app.url] + leftovers, size: total, risk: .review, recommendation: rec,
                reason: running ? "Running now." : (lastUsed == nil ? "Spotlight has no record of you opening it (installed \(Fmt.ago(added)))." : "Not opened in \(Fmt.age(lastUsed))."),
                whatItIs: "\(app.name) (\(Fmt.bytes(appSize))) plus \(leftovers.count) support folder\(leftovers.count == 1 ? "" : "s") in your Library (\(Fmt.bytes(leftSize))).",
                whyRemove: dev ?? (days >= 365 ? "You haven't used it in over a year." : nil),
                whyKeep: "Its settings, documents stored inside the app's container, and licenses go with it.",
                impact: "The app and its support files move to the Trash. Restore them from there if needed.",
                restore: fromStore ? "Reinstall from the App Store" : "Reinstall from the developer's website",
                lastUsed: reference, action: .uninstallApp, lockedReason: running ? "\(app.name) is running." : nil, appBundleID: id))
        }

        // Orphaned data from apps that are no longer installed.
        progress.update("Looking for leftovers of uninstalled apps…")
        let lib = FS.home.appendingPathComponent("Library")
        let bundleLike = try! NSRegularExpression(pattern: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9_-]+){2,}$"#)
        var orphans: [String: [URL]] = [:]
        for dir in ["Containers", "Application Support", "HTTPStorages", "WebKit", "Saved Application State", "Application Scripts"] where ctx.mayTouch(lib.appendingPathComponent(dir + "/x")) {
            for u in FS.children(lib.appendingPathComponent(dir)) {
                var n = u.lastPathComponent
                if n.hasSuffix(".savedState") { n = String(n.dropLast(".savedState".count)) }
                if n.hasSuffix(".binarycookies") { n = String(n.dropLast(".binarycookies".count)) }
                guard bundleLike.firstMatch(in: n, range: NSRange(n.startIndex..., in: n)) != nil else { continue }
                let lower = n.lowercased()
                if lower.hasPrefix("com.apple.") || lower.hasPrefix("group.") || n.hasSuffix(".ShipIt") { continue }
                if ctx.running.contains(n) || ctx.apps.owns(n) { continue }
                if SystemJunkScanner.skipCacheNames.contains(n) { continue }
                orphans[lower, default: []].append(u)
            }
        }
        let all = orphans.values.flatMap { $0 }
        let osizes = Sizer.measureMany(all)
        var small: [URL] = []
        var smallTotal: Int64 = 0
        for (id, urls) in orphans {
            let total = urls.reduce(Int64(0)) { $0 + (osizes[$1]?.bytes ?? 0) }
            let holdsData = urls.contains { $0.path.contains("/Containers/") || $0.path.contains("/Application Support/") }
            if total < max(ctx.minBytes, 2 * 1_048_576) {
                small += urls; smallTotal += total
                continue
            }
            let newest = urls.compactMap { osizes[$0]?.newest }.max()
            items.append(CleanupItem(
                category: .dangling, title: id, subtitle: "Leftovers of an uninstalled app", group: "Uninstalled apps",
                paths: urls, size: total, risk: holdsData ? .review : .safe, recommendation: holdsData ? .optional : .recommended,
                reason: "No installed app has the identifier \(id).",
                whatItIs: "Data left in \(Set(urls.map { $0.deletingLastPathComponent().lastPathComponent }).sorted().joined(separator: ", ")) by an app that is no longer installed.",
                whyRemove: "The app is gone, so this data does nothing.",
                whyKeep: holdsData ? "If you plan to reinstall the app, its settings and documents would be restored from here." : nil,
                impact: "Moved to the Trash.", restore: "Restore from Trash", lastUsed: newest))
        }
        if smallTotal >= 512 * 1024 {
            items.append(CleanupItem(
                category: .dangling, title: "Small leftovers of uninstalled apps", subtitle: "\(small.count) items", group: "Uninstalled apps",
                paths: small, size: smallTotal, risk: .review, recommendation: .optional, reason: "Each one is tiny. Together they're clutter.",
                whatItIs: "Preferences, caches and containers left by apps that are no longer installed.",
                whyKeep: "Only matters if you plan to reinstall one of those apps.", impact: "Moved to the Trash.", restore: "Restore from Trash"))
        }
        return items
    }
}

struct DanglingScanner: Scanner {
    let name = "Dangling items"

    func scan(_ ctx: ScanContext, _ progress: ScanProgress) -> [CleanupItem] {
        var items: [CleanupItem] = []
        progress.update("Checking for broken links…")
        let h = FS.home.path
        for dir in ["/usr/local/bin", "/opt/homebrew/bin", h + "/.local/bin", h + "/bin", h + "/go/bin", h + "/.npm-global/bin"] {
            let d = URL(fileURLWithPath: dir)
            var broken: [URL] = []
            for e in FS.list(dir) ?? [] where e.isLink {
                let u = d.appendingPathComponent(e.name)
                if (try? FileManager.default.destinationOfSymbolicLink(atPath: u.path)) != nil,
                   !FileManager.default.fileExists(atPath: u.path) { broken.append(u) }  // fileExists follows the link
            }
            guard !broken.isEmpty else { continue }
            let admin = !FileManager.default.isWritableFile(atPath: dir)
            items.append(CleanupItem(
                category: .dangling, title: "Broken command links in \(FS.tildePath(d))", subtitle: broken.prefix(5).map(\.lastPathComponent).joined(separator: ", ") + (broken.count > 5 ? "…" : ""),
                group: "Broken links", paths: broken, size: 0, risk: .safe, recommendation: .recommended,
                reason: "\(broken.count) command\(broken.count == 1 ? "" : "s") point to files that no longer exist.",
                whatItIs: "Symlinks left behind when a tool or app was uninstalled: \(broken.map(\.lastPathComponent).joined(separator: ", ")).",
                whyRemove: "Running them only produces \u{201C}no such file\u{201D} errors, and they can shadow working installs later in PATH.",
                impact: "None.", restore: nil, needsAdmin: admin))
        }

        progress.update("Checking launch agents…")
        for (dir, admin) in [(h + "/Library/LaunchAgents", false), ("/Library/LaunchAgents", true), ("/Library/LaunchDaemons", true)] {
            for u in FS.children(URL(fileURLWithPath: dir)) where u.pathExtension == "plist" {
                guard let data = try? Data(contentsOf: u),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { continue }
                let program = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first
                guard let program, program.hasPrefix("/"), !FileManager.default.fileExists(atPath: program) else { continue }
                if program.hasPrefix("/System/") || program.hasPrefix("/usr/") && !program.hasPrefix("/usr/local/") { continue }
                let label = plist["Label"] as? String ?? u.deletingPathExtension().lastPathComponent
                items.append(CleanupItem(
                    category: .dangling, title: label, subtitle: dir.hasSuffix("Daemons") ? "Launch daemon" : "Launch agent", group: "Background items",
                    paths: [u], size: FS.fileSize(u), risk: .safe, recommendation: .recommended,
                    reason: "Its program \(program) no longer exists.",
                    whatItIs: "A background job definition that launchd tries to start at login/boot. Its program was removed (usually with the app).",
                    whyRemove: "launchd keeps trying (and failing) to start it, which shows up in System Settings › Login Items.",
                    impact: "None. The program it starts is already gone.", restore: nil, needsAdmin: admin))
            }
        }
        return items
    }
}

struct LargeFilesScanner: Scanner {
    let name = "Large files"

    static let installerExts: Set<String> = ["dmg", "pkg", "mpkg", "iso", "xip", "ipsw"]
    static let vmExts: Set<String> = ["vdi", "vmdk", "qcow2", "utm", "vhdx", "img", "raw"]

    func scan(_ ctx: ScanContext, _ progress: ScanProgress) -> [CleanupItem] {
        var items: [String: CleanupItem] = [:]
        let threshold = Int64(ctx.settings.largeFileMB) * 1_048_576
        progress.update("Querying Spotlight for large files…")
        var paths = Spotlight.find("kMDItemFSSize >= \(threshold)", timeout: 40)
        for root in ctx.scanRoots where !root.path.hasPrefix(FS.home.path) {
            paths += Spotlight.find("kMDItemFSSize >= \(threshold)", onlyIn: root.path, timeout: 40)
        }
        // Many removable disks have Spotlight disabled or lack an index entirely.
        progress.update("Checking selected external drives…")
        paths += ctx.projects().largeFiles.map(\.path)
        let installed = ctx.apps.names
        for p in Set(paths) {
            if p.hasPrefix("/System/") || p.hasPrefix("/Library/") || p.contains(".app/") || p.hasPrefix("/Applications/")
                || p.hasPrefix("/private/") || p.contains("/.Trash/") || p.contains("/node_modules/") || p.contains(".photoslibrary") { continue }
            let u = URL(fileURLWithPath: p)
            guard ctx.mayTouch(u), !ctx.settings.isExcluded(u) else { continue }
            if p.hasPrefix("/Volumes/"), !ctx.includesExternalFile(p) { continue }
            var st = stat()
            guard lstat(p, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
            let size = Int64(st.st_blocks) * 512
            guard size >= threshold else { continue }
            items[p] = item(ctx, u, size: size, installedNames: installed)
        }

        // Old installers and large downloads.
        progress.update("Checking Downloads…")
        // ~/Downloads plus Downloads folders kept on analyzed external drives (top level or one folder down).
        var downloadFolders = [FS.home.appendingPathComponent("Downloads")]
        for root in ctx.externalScanRoots {
            downloadFolders.append(root.appendingPathComponent("Downloads"))
            downloadFolders += FS.childDirs(root).filter { !$0.lastPathComponent.hasPrefix(".") }.map { $0.appendingPathComponent("Downloads") }
        }
        let children = downloadFolders.filter { FS.isDir($0) && !ctx.settings.isExcluded($0) }
            .flatMap { FS.children($0).filter { !$0.lastPathComponent.hasPrefix(".") } }
        let sizes = Sizer.measureMany(children)
        for u in children where items[u.path] == nil {
            guard let m = sizes[u] else { continue }
            let ext = u.pathExtension.lowercased()
            let isInstaller = Self.installerExts.contains(ext)
            let mtime = FS.mtime(u)
            let days = Age.days(Spotlight.lastUsed(u) ?? mtime) ?? 0
            if isInstaller && m.bytes >= 5 * 1_048_576 && days >= 3 {
                items[u.path] = item(ctx, u, size: m.bytes, installedNames: installed)
            } else if m.bytes >= 100 * 1_048_576 && days >= 90 {
                items[u.path] = item(ctx, u, size: m.bytes, installedNames: installed)
            }
        }
        return Array(items.values)
    }

    private func item(_ ctx: ScanContext, _ u: URL, size: Int64, installedNames: Set<String>) -> CleanupItem {
        let ext = u.pathExtension.lowercased()
        let lastUsed = Spotlight.lastUsed(u) ?? FS.mtime(u)
        let days = Age.days(lastUsed) ?? 0
        let inDownloads = u.deletingLastPathComponent().lastPathComponent == "Downloads"
        let base = u.deletingPathExtension().lastPathComponent.lowercased()
        let alreadyInstalled = installedNames
            .filter { $0.count > 3 && (base.contains($0) || base.contains($0.replacingOccurrences(of: " ", with: ""))) }
            .max { $0.count < $1.count }

        if u.lastPathComponent == "Docker.raw" || u.lastPathComponent == "Docker.qcow2" {
            return CleanupItem(category: .largeFiles, title: u.lastPathComponent, subtitle: FS.tildePath(u), group: "Virtual disks", paths: [u], size: size,
                               risk: .high, recommendation: .keep, reason: "Docker Desktop's VM disk. Prune it from inside (Docker & Homebrew).",
                               whatItIs: "All Docker images, containers and volumes.", impact: "Deleting wipes Docker entirely.", action: .none, lockedReason: "Managed by Docker")
        }
        if Self.installerExts.contains(ext) {
            return CleanupItem(category: .largeFiles, title: u.lastPathComponent, subtitle: FS.tildePath(u.deletingLastPathComponent()), group: "Installers",
                               paths: [u], size: size, risk: .low, recommendation: (alreadyInstalled != nil || days >= 14) ? .recommended : .optional,
                               reason: alreadyInstalled != nil ? "Looks already installed (\(alreadyInstalled!.capitalized))." : "Installer, last opened \(Fmt.ago(lastUsed)).",
                               whatItIs: "A disk image / installer package. After installation it's no longer needed.",
                               whyKeep: "Keep it only if it's hard to download again (old versions, licensed software).",
                               impact: "Moved to the Trash.", restore: "Download it again from the vendor", lastUsed: lastUsed)
        }
        let isVM = Self.vmExts.contains(ext)
        return CleanupItem(category: .largeFiles, title: u.lastPathComponent, subtitle: FS.tildePath(u.deletingLastPathComponent()),
                           group: isVM ? "Virtual disks" : (inDownloads ? "Downloads" : "Large files"),
                           paths: [u], size: size, risk: .review, recommendation: (inDownloads && days >= 180) ? .recommended : .optional,
                           reason: "Last opened \(Fmt.ago(lastUsed)).",
                           whatItIs: isVM ? "A virtual machine disk image." : "A large file. Prune can't tell what it's for, so only you can decide.",
                           whyKeep: "Personal files can't be regenerated. Be sure before removing.",
                           impact: "Moved to the Trash.", restore: "Restore from Trash", lastUsed: lastUsed)
    }
}
