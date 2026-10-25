import Foundation

struct XcodeScanner: Scanner {
    let name = "Xcode & simulators"

    func scan(_ ctx: ScanContext, _ progress: ScanProgress) -> [CleanupItem] {
        var items: [CleanupItem] = []
        let dev = FS.home.appendingPathComponent("Library/Developer")
        let xcodeRunning = ctx.running.contains("com.apple.dt.Xcode")
        let apple = ctx.ecosystemStatus(.apple)

        // DerivedData, one item per project.
        progress.update("Reading DerivedData…")
        let dd = dev.appendingPathComponent("Xcode/DerivedData")
        let ddDirs = FS.childDirs(dd)
        let ddSizes = Sizer.measureMany(ddDirs)
        for d in ddDirs {
            guard let m = ddSizes[d], m.bytes >= ctx.minBytes else { continue }
            let plist = NSDictionary(contentsOf: d.appendingPathComponent("info.plist"))
            let ws = plist?["WorkspacePath"] as? String
            let missing = ws.map { !FS.exists(URL(fileURLWithPath: $0)) } ?? false
            let days = Age.days(m.newest) ?? 999
            let project = d.lastPathComponent.replacingOccurrences(of: #"-[a-z]{28}$"#, with: "", options: .regularExpression)
            let rec: Recommendation = (missing || days >= 7) ? .recommended : .optional
            let reason = missing ? "The project no longer exists at \(FS.tildePath(URL(fileURLWithPath: ws!)))."
                : days >= 7 ? "Not built in \(Fmt.age(m.newest))." : "Built \(days == 0 ? "today" : Fmt.age(m.newest) + " ago")."
            items.append(CleanupItem(
                category: .xcode, title: "DerivedData · \(project)", subtitle: ws.map { FS.tildePath(URL(fileURLWithPath: $0)) } ?? "Shared Xcode data",
                group: "DerivedData", paths: [d], size: m.bytes, risk: .safe, recommendation: rec, reason: reason,
                whatItIs: "Xcode's build products, intermediates and index for this project.",
                whyRemove: missing ? "Its project was deleted or moved, so nothing will ever use this build data again." : nil,
                whyKeep: rec == .optional ? "You built this recently. The next build will be a clean build." : nil,
                impact: "The next build in Xcode is a full rebuild and the project is re-indexed.", restore: "Build in Xcode",
                lastUsed: m.newest, appBundleID: "com.apple.dt.Xcode"))
        }

        // Device support files: keep the newest per platform.
        for platform in ["iOS", "watchOS", "tvOS", "visionOS", "macOS"] {
            let root = dev.appendingPathComponent("Xcode/\(platform) DeviceSupport")
            let versions = FS.childDirs(root)
            guard !versions.isEmpty else { continue }
            let sizes = Sizer.measureMany(versions)
            let newest = versions.max { Versions.compare($0.lastPathComponent, $1.lastPathComponent) }
            for v in versions {
                guard let m = sizes[v], m.bytes >= ctx.minBytes else { continue }
                let isNewest = v == newest
                items.append(CleanupItem(
                    category: .xcode, title: "\(platform) Device Support \(v.lastPathComponent)", subtitle: FS.tildePath(v), group: "Device Support",
                    paths: [v], size: m.bytes, risk: .low, recommendation: isNewest ? .optional : .recommended,
                    reason: isNewest ? "Newest version, probably matching a device you use." : "Superseded by \(newest?.lastPathComponent ?? "a newer version").",
                    whatItIs: "Debug symbols Xcode copied from a physical \(platform) device the first time you connected it.",
                    whyRemove: isNewest ? nil : "Your devices have moved on to a newer OS version.",
                    impact: "If a device with this exact OS version connects again, Xcode re-copies its symbols (a few minutes).",
                    restore: "Automatic when the device connects", lastUsed: m.newest))
            }
        }

        // Archives: needed to symbolicate crashes of shipped builds.
        let archives = dev.appendingPathComponent("Xcode/Archives")
        var archiveList: [URL] = []
        for day in FS.childDirs(archives) { archiveList += FS.childDirs(day).filter { $0.pathExtension == "xcarchive" } }
        let aSizes = Sizer.measureMany(archiveList)
        for a in archiveList {
            guard let m = aSizes[a], m.bytes >= ctx.minBytes else { continue }
            let info = NSDictionary(contentsOf: a.appendingPathComponent("Info.plist"))
            let name = info?["Name"] as? String ?? a.deletingPathExtension().lastPathComponent
            let props = info?["ApplicationProperties"] as? [String: Any]
            let ver = [props?["CFBundleShortVersionString"] as? String, props?["CFBundleVersion"] as? String].compactMap { $0 }.joined(separator: " (") + ((props?["CFBundleVersion"] != nil && props?["CFBundleShortVersionString"] != nil) ? ")" : "")
            let created = info?["CreationDate"] as? Date ?? m.newest
            let old = (Age.days(created) ?? 0) > 365
            items.append(CleanupItem(
                category: .xcode, title: "Archive · \(name) \(ver)", subtitle: FS.tildePath(a), group: "Archives",
                paths: [a], size: m.bytes, risk: .review, recommendation: .optional,
                reason: old ? "Over a year old." : "Created \(Fmt.ago(created)).",
                whatItIs: "A signed build archive with dSYMs, used to upload to App Store Connect and to symbolicate crash reports from that release.",
                whyRemove: old ? "If this version is no longer in users' hands, you don't need its symbols." : nil,
                whyKeep: "Without the dSYMs, crash reports from this exact build can't be symbolicated (unless they were uploaded to Crashlytics/App Store Connect).",
                impact: "The archive moves to the Trash.", restore: "Re-archiving produces a different binary. Old dSYMs can't be recreated.",
                lastUsed: created))
        }

        // Simple safe caches.
        let simple: [(String, String, String, String)] = [
            ("~/Library/Developer/CoreSimulator/Caches", "Simulator caches", "Dyld and runtime caches built for simulators.", "Rebuilt the next time a simulator boots."),
            ("~/Library/Developer/Xcode/UserData/Previews", "SwiftUI Previews data", "Simulator devices and build products used by SwiftUI Previews.", "The next preview takes longer to start."),
            ("~/Library/Caches/com.apple.dt.Xcode", "Xcode cache", "Xcode's own caches (downloads, documentation, indexing helpers).", "Rebuilt by Xcode as needed."),
            ("~/Library/Developer/Xcode/DocumentationCache", "Documentation cache", "Downloaded documentation index.", "Re-downloaded when you open docs."),
            ("~/Library/Developer/Xcode/Products", "Xcode Products", "Exported build products.", "Rebuild to recreate."),
            ("~/Library/Logs/CoreSimulator", "Simulator logs", "Logs from simulator devices.", "None."),
            ("~/Library/Developer/Xcode/iOS Device Logs", "Device logs", "Crash and console logs pulled from devices.", "None."),
        ]
        for (path, title, what, impact) in simple {
            if let i = ctx.cacheItem(.xcode, path: path, title: title, subtitle: path, ecosystem: nil, risk: .safe, what: what, impact: impact,
                                     restore: "Automatic", appBundleID: path.contains("dt.Xcode") ? "com.apple.dt.Xcode" : nil) {
                items.append(i)
            }
        }

        guard Shell.which("xcrun") != nil, FS.isDir(URL(fileURLWithPath: "/Applications/Xcode.app")) || FS.isDir(dev.appendingPathComponent("CoreSimulator")) else { return items }
        let xcrun = Shell.which("xcrun")!

        // Simulator runtimes
        progress.update("Querying simulator runtimes…")
        let rr = Shell.run(xcrun, ["simctl", "runtime", "list", "-j"], timeout: 30)
        if rr.ok, let json = try? JSONSerialization.jsonObject(with: Data(rr.stdout.utf8)) as? [String: [String: Any]] {
            let runtimes = json.values
            var newestByPlatform: [String: String] = [:]
            for r in runtimes {
                let p = r["platformIdentifier"] as? String ?? "", v = r["version"] as? String ?? "0"
                if let cur = newestByPlatform[p] { if Versions.compare(cur, v) { newestByPlatform[p] = v } } else { newestByPlatform[p] = v }
            }
            let iso = ISO8601DateFormatter()
            for r in runtimes {
                guard let id = r["identifier"] as? String else { continue }
                let platform = (r["platformIdentifier"] as? String ?? "").replacingOccurrences(of: "com.apple.platform.", with: "").replacingOccurrences(of: "simulator", with: "")
                let version = r["version"] as? String ?? "?"
                let size = (r["sizeBytes"] as? NSNumber)?.int64Value ?? 0
                let deletable = r["deletable"] as? Bool ?? false
                let lastUsed = (r["lastUsedAt"] as? String).flatMap { iso.date(from: $0) }
                let isNewest = newestByPlatform[r["platformIdentifier"] as? String ?? ""] == version
                let platformName = ["iphone": "iOS", "watch": "watchOS", "appletv": "tvOS", "xr": "visionOS"][platform] ?? platform
                var rec: Recommendation
                var reason: String
                if !deletable { rec = .keep; reason = "Managed by the system and can't be deleted from here." }
                else if !isNewest { rec = .recommended; reason = "Older \(platformName) runtime. \(newestByPlatform[r["platformIdentifier"] as? String ?? ""] ?? "") is installed." }
                else if apple.stale && (Age.days(lastUsed) ?? 999) >= ctx.staleDays { rec = .optional; reason = "Only \(platformName) runtime, not used in \(Fmt.age(lastUsed)). " + apple.note }
                else { rec = .keep; reason = "Your current \(platformName) simulator runtime." }
                items.append(CleanupItem(
                    category: .xcode, title: "\(platformName) \(version) Simulator runtime", subtitle: r["build"] as? String ?? "", group: "Simulator runtimes",
                    paths: [URL(fileURLWithPath: r["path"] as? String ?? "/Library/Developer/CoreSimulator")], size: size, risk: .low,
                    recommendation: rec, reason: reason,
                    whatItIs: "A complete \(platformName) operating system image used by every \(platformName) simulator of this version.",
                    whyRemove: rec == .recommended ? "You have a newer runtime, and new simulators default to it." : nil,
                    whyKeep: isNewest ? "Without a runtime you can't run \(platformName) simulators until you download one again (Xcode › Settings › Components)." : "Keep it only if you need to test on \(platformName) \(version) specifically.",
                    impact: "Simulators using this runtime become unavailable.", restore: "Xcode › Settings › Components",
                    lastUsed: lastUsed, action: deletable ? .command(ShellCommand(tool: xcrun, args: ["simctl", "runtime", "delete", id])) : .none,
                    lockedReason: deletable ? nil : "Not deletable"))
            }
        }

        // Unavailable simulators and stale device data.
        let dr = Shell.run(xcrun, ["simctl", "list", "devices", "-j"], timeout: 30)
        if dr.ok, let json = try? JSONSerialization.jsonObject(with: Data(dr.stdout.utf8)) as? [String: Any],
           let devices = json["devices"] as? [String: [[String: Any]]] {
            var unavailableSize: Int64 = 0
            var unavailableCount = 0
            let iso = ISO8601DateFormatter()
            for (_, list) in devices {
                for d in list {
                    let dataSize = (d["dataPathSize"] as? NSNumber)?.int64Value ?? 0
                    if d["isAvailable"] as? Bool == false { unavailableCount += 1; unavailableSize += dataSize; continue }
                    guard dataSize >= 300 * 1_048_576, let udid = d["udid"] as? String, d["state"] as? String == "Shutdown" else { continue }
                    let booted = (d["lastBootedAt"] as? String).flatMap { iso.date(from: $0) }
                    let days = Age.days(booted) ?? 999
                    guard days >= ctx.staleDays else { continue }
                    let name = d["name"] as? String ?? udid
                    items.append(CleanupItem(
                        category: .xcode, title: "Simulator data · \(name)", subtitle: udid, group: "Simulators",
                        paths: [URL(fileURLWithPath: d["dataPath"] as? String ?? "")], size: dataSize, risk: .low, recommendation: .recommended,
                        reason: booted == nil ? "Never booted (as far as Xcode recorded)." : "Not booted in \(Fmt.age(booted)).",
                        whatItIs: "Apps, files and settings stored inside this simulator.",
                        impact: "The simulator is reset to factory state. The device itself stays.", restore: "Reinstall your app on it",
                        lastUsed: booted, action: .command(ShellCommand(tool: xcrun, args: ["simctl", "erase", udid]))))
                }
            }
            if unavailableCount > 0 {
                items.append(CleanupItem(
                    id: "simctl-unavailable", category: .xcode, title: "Unavailable simulators", subtitle: "\(unavailableCount) device\(unavailableCount == 1 ? "" : "s")",
                    group: "Simulators", paths: [], size: unavailableSize,
                    risk: .safe, recommendation: .recommended, reason: "Their runtime is gone, so they can never boot again.",
                    whatItIs: "Simulator devices whose OS runtime was removed or belongs to an old Xcode.",
                    impact: "None. They can't run.", restore: nil,
                    action: .command(ShellCommand(tool: xcrun, args: ["simctl", "delete", "unavailable"]))))
            }
        }

        // System-wide dyld caches for macOS builds you're no longer running.
        let dyld = URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Caches/dyld")
        let build = SystemInfo.currentOSBuild
        for d in FS.childDirs(dyld) where !build.isEmpty && d.lastPathComponent != build {
            let m = Sizer.measure(d)
            guard m.bytes >= ctx.minBytes else { continue }
            items.append(CleanupItem(
                category: .xcode, title: "Simulator dyld cache for macOS \(d.lastPathComponent)", subtitle: d.path, group: "Simulator runtimes",
                paths: [d], size: m.bytes, risk: .safe, recommendation: .recommended,
                reason: "Built for macOS build \(d.lastPathComponent). You're on \(build).",
                whatItIs: "Shared-library caches CoreSimulator generates per macOS build.",
                impact: "None. The current build has its own cache.", restore: "Automatic",
                lastUsed: m.newest, needsAdmin: true))
        }
        // Command Line Tools duplicate Xcode's toolchain when Xcode is the active developer directory.
        let clt = URL(fileURLWithPath: "/Library/Developer/CommandLineTools")
        let active = Shell.run("/usr/bin/xcode-select", ["-p"], timeout: 5).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if FS.isDir(clt), active.contains(".app/Contents/Developer") {
            let m = Sizer.measure(clt)
            if m.bytes >= ctx.minBytes {
                items.append(CleanupItem(
                    category: .xcode, title: "Command Line Tools (duplicate of Xcode)", subtitle: clt.path, group: "Toolchains",
                    paths: [clt], size: m.bytes, risk: .low, recommendation: .optional,
                    reason: "xcode-select points at Xcode, so these tools aren't the ones in use.",
                    whatItIs: "Apple's standalone compiler toolchain (clang, git, make, Python 3, SDKs). With full Xcode installed and selected (\(active)), Xcode's own copy is used instead.",
                    whyRemove: "git, clang, swift and make already resolve to Xcode's toolchain. This is a second copy.",
                    whyKeep: "If you ever uninstall or switch away from Xcode, you'll need them back. Homebrew may also suggest reinstalling them when it checks your setup.",
                    impact: "Nothing changes while Xcode stays installed and selected.",
                    restore: "xcode-select --install", lastUsed: m.newest, needsAdmin: true))
            }
        }
        _ = xcodeRunning
        return items
    }
}

struct DockerBrewScanner: Scanner {
    let name = "Docker & Homebrew"

    static func parseSize(_ s: String) -> Int64 {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let r = t.range(of: #"^[0-9.]+"#, options: .regularExpression), let n = Double(t[r]) else { return 0 }
        let unit = t[r.upperBound...].trimmingCharacters(in: .whitespaces).uppercased()
        let mult: Double = unit.hasPrefix("T") ? 1e12 : unit.hasPrefix("G") ? 1e9 : unit.hasPrefix("M") ? 1e6 : unit.hasPrefix("K") ? 1e3 : 1
        return Int64(n * mult)
    }

    func scan(_ ctx: ScanContext, _ progress: ScanProgress) -> [CleanupItem] {
        var items: [CleanupItem] = []
        progress.update("Checking Docker…")
        let rawPaths = ["~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw", "~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.qcow2"]
        let raw = rawPaths.map(ctx.url).filter(ctx.mayTouch).first(where: FS.exists)

        if let docker = Shell.which("docker"), Shell.run(docker, ["info", "--format", "{{.ServerVersion}}"], timeout: 8).ok {
            let df = Shell.run(docker, ["system", "df", "--format", "{{json .}}"], timeout: 60)
            for line in df.stdout.split(separator: "\n") {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let type = obj["Type"] as? String else { continue }
                let reclaim = Self.parseSize((obj["Reclaimable"] as? String ?? "0B").components(separatedBy: " (").first ?? "0B")
                guard reclaim >= max(ctx.minBytes, 1) else { continue }
                let total = obj["TotalCount"].map { "\($0)" } ?? "?"
                let active = obj["Active"].map { "\($0)" } ?? "?"
                switch type {
                case "Build Cache":
                    items.append(CleanupItem(category: .docker, title: "Docker build cache", subtitle: "\(total) entries", group: "Docker",
                                             paths: [], size: reclaim, risk: .safe, recommendation: .recommended,
                                             reason: "Layers cached by BuildKit. Rebuilt on demand.",
                                             whatItIs: "Intermediate layers from `docker build`.", impact: "The next image builds don't hit the cache and run every step.",
                                             restore: "docker build", action: .command(ShellCommand(tool: docker, args: ["builder", "prune", "-a", "-f"])), sizeIsEstimate: true))
                case "Images":
                    items.append(CleanupItem(category: .docker, title: "Unused Docker images", subtitle: "\(total) images, \(active) in use", group: "Docker",
                                             paths: [], size: reclaim, risk: .low, recommendation: .optional,
                                             reason: "Images no container uses.",
                                             whatItIs: "Pulled or built images not referenced by any container (running or stopped).",
                                             whyKeep: "Large base images (CUDA, Android, databases) can take a long time to pull again.",
                                             impact: "The next `docker run` or compose up re-pulls them.", restore: "docker pull / docker compose pull",
                                             action: .command(ShellCommand(tool: docker, args: ["image", "prune", "-a", "-f"])), sizeIsEstimate: true))
                case "Containers":
                    items.append(CleanupItem(category: .docker, title: "Stopped Docker containers", subtitle: "\(total) containers, \(active) running", group: "Docker",
                                             paths: [], size: reclaim, risk: .review, recommendation: .optional,
                                             reason: "Stopped containers keep their writable layer.",
                                             whatItIs: "Containers that exited but were never removed.",
                                             whyKeep: "Files written inside a container (not in a volume) are lost.",
                                             impact: "Stopped containers are deleted. Running ones are untouched.", restore: "docker run / compose up",
                                             action: .command(ShellCommand(tool: docker, args: ["container", "prune", "-f"])), sizeIsEstimate: true))
                case "Local Volumes":
                    items.append(CleanupItem(category: .docker, title: "Unused Docker volumes", subtitle: "\(total) volumes, \(active) in use", group: "Docker",
                                             paths: [], size: reclaim, risk: .high, recommendation: .optional,
                                             reason: "Not attached to any container. May hold database data.",
                                             whatItIs: "Named/anonymous volumes not used by any container. This is where Postgres, MySQL, Redis etc. keep data.",
                                             whyKeep: "Local development databases live here. Deleting means losing seeded data.",
                                             impact: "Volume data is permanently deleted. This can't be undone through the Trash.", restore: "Re-seed your databases",
                                             action: .command(ShellCommand(tool: docker, args: ["volume", "prune", "-a", "-f"])), sizeIsEstimate: true))
                default: break
                }
            }
            if let raw, items.isEmpty == false {
                let m = Sizer.measure(raw)
                items.append(CleanupItem(category: .docker, title: "Docker disk image", subtitle: FS.tildePath(raw), group: "Docker",
                                         paths: [raw], size: m.bytes, risk: .high, recommendation: .keep,
                                         reason: "Docker Desktop's virtual disk. Pruning above frees space inside it.",
                                         whatItIs: "The VM disk that holds all images, containers and volumes.",
                                         whyKeep: "Deleting it wipes everything in Docker. Use the prune items, then Docker shrinks the file over time.",
                                         impact: "—", action: .none, lockedReason: "Managed by Docker Desktop"))
            }
        } else if let raw {
            let m = Sizer.measure(raw)
            if m.bytes >= ctx.minBytes {
                items.append(CleanupItem(category: .docker, title: "Docker disk image", subtitle: FS.tildePath(raw), group: "Docker",
                                         paths: [raw], size: m.bytes, risk: .high, recommendation: .keep,
                                         reason: "Docker isn't running. Start Docker Desktop and rescan to see what's reclaimable inside.",
                                         whatItIs: "Docker Desktop's VM disk with all images, containers, build cache and volumes.",
                                         whyKeep: "Deleting this file wipes everything in Docker, including database volumes.",
                                         impact: "—", action: .none, lockedReason: "Start Docker to analyze"))
            }
        }

        // Homebrew
        if let brew = Shell.which("brew") {
            progress.update("Asking Homebrew what it can clean…")
            let dry = Shell.run(brew, ["cleanup", "-n", "--prune=all"], timeout: 120)
            let combined = dry.stdout + "\n" + dry.stderr
            var size: Int64 = 0
            if let m = Requirements.captures(#"free approximately ([0-9.]+\s*[KMGT]?B)"#, combined, options: []).first { size = Self.parseSize(m) }
            let cache = URL(fileURLWithPath: Shell.run(brew, ["--cache"], timeout: 15).stdout.trimmingCharacters(in: .whitespacesAndNewlines))
            if size == 0, FS.isDir(cache) { size = Sizer.measure(cache).bytes }
            if size >= ctx.minBytes {
                let removable = combined.split(separator: "\n").filter { $0.hasPrefix("Would remove") }.count
                items.append(CleanupItem(category: .docker, title: "Homebrew downloads & old versions", subtitle: "\(removable) items", group: "Homebrew",
                                         paths: [cache], size: size, risk: .safe, recommendation: .recommended,
                                         reason: "Superseded versions and cached downloads.",
                                         whatItIs: "Bottles and source archives in Homebrew's download cache, plus old versions of upgraded formulae.",
                                         impact: "Reinstalling an old version would mean downloading it again.", restore: "brew install",
                                         action: .command(ShellCommand(tool: brew, args: ["cleanup", "--prune=all"])), sizeIsEstimate: true))
            }
            let auto = Shell.run(brew, ["autoremove", "-n"], timeout: 120)
            let formulae = auto.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("==>") }
            if !formulae.isEmpty {
                let cellar = URL(fileURLWithPath: Shell.run(brew, ["--cellar"], timeout: 15).stdout.trimmingCharacters(in: .whitespacesAndNewlines))
                let dirs = formulae.map { cellar.appendingPathComponent($0) }.filter(FS.isDir)
                let total = Sizer.measureMany(dirs).values.reduce(0) { $0 + $1.bytes }
                items.append(CleanupItem(category: .docker, title: "Orphaned Homebrew dependencies", subtitle: formulae.prefix(4).joined(separator: ", ") + (formulae.count > 4 ? " +\(formulae.count - 4)" : ""),
                                         group: "Homebrew", paths: dirs, size: total, risk: .low, recommendation: .recommended,
                                         reason: "Installed only as dependencies of formulae you've since removed.",
                                         whatItIs: "\(formulae.count) formulae that nothing you installed on purpose depends on: \(formulae.joined(separator: ", ")).",
                                         whyKeep: "If you use one of them directly, run `brew install <name>` to mark it as wanted.",
                                         impact: "The formulae are uninstalled.", restore: "brew install <name>",
                                         action: .command(ShellCommand(tool: brew, args: ["autoremove"]))))
            }
        }
        return items
    }
}
