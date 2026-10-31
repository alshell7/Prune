import Foundation

/// A realistic, fictional Mac for README captures (`-PruneDemo YES`). Nothing here comes from this machine.
enum DemoData {
    static let home = "/Users/sam"
    static let ssd = "/Volumes/Studio SSD"
    static func u(_ p: String) -> URL { URL(fileURLWithPath: p) }
    static let gb: Int64 = 1_000_000_000, mb: Int64 = 1_000_000
    static func ago(_ days: Double) -> Date { Date().addingTimeInterval(-days * 86_400) }

    static var volumes: [VolumeInfo] { volumes(bootFree: cleaned ? 31_400_000_000 : 9_800_000_000) }
    /// Flipped by the scene director to show the "after cleaning" state.
    nonisolated(unsafe) static var cleaned = false

    static func volumes(bootFree: Int64) -> [VolumeInfo] {
        [VolumeInfo(url: u("/"), name: "Macintosh HD", total: 245 * gb, available: bootFree, availableStrict: bootFree - 600 * mb, isInternal: true, isBoot: true, format: "APFS"),
         VolumeInfo(url: u(ssd), name: "Studio SSD", total: 1_000 * gb, available: 612 * gb, availableStrict: 612 * gb, isInternal: false, isBoot: false, format: "APFS")]
    }

    // MARK: Cleanup

    static var items: [CleanupItem] {
        func art(_ project: String, _ folder: String, _ size: Int64, kind: String, eco: String, days: Double, rec: Recommendation, risk: Risk = .low, root: String = home + "/Developer") -> CleanupItem {
            CleanupItem(category: .projectArtifacts, title: "\(project)/\(folder)", subtitle: "\(kind) · \(eco)", group: project,
                        paths: [u("\(root)/\(project)/\(folder)")], size: size, risk: risk, recommendation: rec,
                        reason: days >= 30 ? "Project untouched for \(Int(days / 30)) month\(days >= 60 ? "s" : "")." : "Active project (\(Int(days)) days ago). You'd need to rebuild.",
                        whatItIs: "\(kind) for \(project). Every file can be regenerated from the project's sources and lockfile.",
                        whyRemove: days >= 30 ? "You haven't touched this project in a while. Rebuilding later is cheaper than keeping \(Fmt.bytes(size)) on disk." : nil,
                        whyKeep: days < 30 ? "You worked on this project recently. Removing it means a rebuild the next time you open it." : nil,
                        impact: "The next build or install recreates it.", restore: kind == "node_modules" ? "pnpm install" : "cargo build", lastUsed: ago(days))
        }
        var list: [CleanupItem] = [
            art("weather-app", "node_modules", 1_840 * mb, kind: "node_modules", eco: "Node.js", days: 96, rec: .recommended),
            art("pixel-forge", "target", 6_210 * mb, kind: "Rust build output", eco: "Rust", days: 140, rec: .recommended),
            art("storefront", ".next", 2_380 * mb, kind: "Next.js build", eco: "Node.js", days: 3, rec: .optional, risk: .safe),
            art("atlas-api", "node_modules", 912 * mb, kind: "node_modules", eco: "Node.js", days: 1, rec: .optional),
            art("mobile-shell", "android/app/build", 1_120 * mb, kind: "Build output", eco: "Android", days: 51, rec: .recommended, root: ssd + "/Projects"),
            art("ml-notebooks", ".venv", 3_480 * mb, kind: "Python virtualenv", eco: "Python", days: 12, rec: .recommended, root: ssd + "/Projects"),
            art("game-jam-2025", "Library", 4_260 * mb, kind: "Unity cache", eco: "Unity", days: 210, rec: .recommended, root: ssd + "/Projects"),
            art("design-system", "storybook-static", 380 * mb, kind: "Build output", eco: "Node.js", days: 34, rec: .recommended, risk: .safe, root: ssd + "/Projects"),
        ]
        list[5].reason = "Broken virtualenv: its scripts still point to /Users/sam/Developer/ml-notebooks/.venv, where it lived before it was moved."
        list[5].whyRemove = "Python can't start from this environment, so nothing uses it. Recreate it with: uv sync"
        func item(_ c: Category, _ title: String, _ sub: String, _ path: String, _ size: Int64, _ rec: Recommendation, _ risk: Risk, _ reason: String, _ what: String) -> CleanupItem {
            CleanupItem(category: c, title: title, subtitle: sub, paths: [u(path)], size: size, risk: risk, recommendation: rec, reason: reason, whatItIs: what,
                        impact: "Recreated automatically when needed.", restore: "Automatic")
        }
        list += [
            item(.xcode, "DerivedData", "Xcode build products", home + "/Library/Developer/Xcode/DerivedData", 7_940 * mb, .recommended, .safe, "Regenerates on the next build.", "Xcode's build products and indexes for every project."),
            item(.xcode, "iOS 17.5 Simulator runtime", "Not used by any project", home + "/Library/Developer/CoreSimulator/Volumes/iOS_21F79", 7_300 * mb, .recommended, .low, "No simulator uses this runtime.", "A downloaded simulator runtime."),
            item(.devCaches, "npm cache", "~/.npm/_cacache", home + "/.npm/_cacache", 1_310 * mb, .recommended, .safe, "Regenerates automatically.", "Downloaded package tarballs."),
            item(.devCaches, "Gradle dependency cache", "~/.gradle/caches", home + "/.gradle/caches", 2_860 * mb, .optional, .low, "You worked on Android (mobile-shell) 51 days ago. Expect a re-download.", "Downloaded Maven/Gradle dependencies."),
            item(.devCaches, "Homebrew downloads", "~/Library/Caches/Homebrew", home + "/Library/Caches/Homebrew", 940 * mb, .recommended, .safe, "Old bottles and installers.", "Homebrew's download cache."),
            item(.environments, "Android NDK 25.1.8937393", "No project uses this version", home + "/Library/Android/sdk/ndk/25.1.8937393", 2_420 * mb, .recommended, .low, "Stale: projects pin NDK 27.", "An Android native toolchain."),
            item(.environments, "Emulator Pixel_6_API_33", "Last used 5 months ago", home + "/.android/avd/Pixel_6_API_33.avd", 5_100 * mb, .optional, .review, "Last used 5 months ago.", "An Android emulator image with its user data."),
            item(.largeFiles, "Xcode_16.4.xip", "Installer, already installed", ssd + "/Downloads/Xcode_16.4.xip", 9_100 * mb, .recommended, .low, "Looks already installed (Xcode).", "An installer archive."),
            item(.systemJunk, "Trash on Studio SSD", "Items deleted from this disk", ssd + "/.Trashes/501", 1_460 * mb, .optional, .review, "Space returns when the Trash is emptied.", "Files you deleted from this disk."),
            item(.aiModels, "Hugging Face model: whisper-large-v3", "Not loaded in 4 months", home + "/.cache/huggingface/hub/models--openai--whisper-large-v3", 3_090 * mb, .optional, .low, "Not used in 4 months. Re-downloads on demand.", "A downloaded model."),
        ]
        return list
    }

    static func scannerStatus() -> [String: String] {
        ["Project index": "\(ssd)/Projects/mobile-shell/android", "Developer caches": "Measuring ~/.gradle…", "Xcode & simulators": "Reading simulator runtimes…"]
    }

    // MARK: Security, secrets, code backup, doctor

    static var security: SecurityReport {
        var r = SecurityReport()
        r.protections = [ProtectionStatus(name: "FileVault", on: true, detail: "Disk encrypted"), ProtectionStatus(name: "Firewall", on: true, detail: "On"),
                         ProtectionStatus(name: "Gatekeeper", on: true, detail: "App Store and identified developers"), ProtectionStatus(name: "System Integrity Protection", on: true, detail: "Enabled")]
        r.findings = [
            SecurityFinding(id: "demo:agent", area: .persistence, severity: .high, title: "com.update-helper.agent", subtitle: "~/Library/LaunchAgents · unsigned script",
                            evidence: ["Runs /Users/sam/.local/share/.uh/run.sh every 300 s", "Downloads and runs a remote script (curl … | sh)", "No installed app owns it"],
                            explanation: "A background item that re-downloads and runs a script on a timer is a classic persistence pattern.", legitNote: "Some installers do this, but they sign their helpers.",
                            recommendation: "Disable it and quarantine the script.", actions: [.disableLaunchItem(plist: home + "/Library/LaunchAgents/com.update-helper.agent.plist", label: "com.update-helper.agent", system: false)]),
            SecurityFinding(id: "demo:npm", area: .packages, severity: .medium, title: "postinstall in colors-tiny@1.0.4", subtitle: "weather-app/node_modules",
                            evidence: ["Reads ~/.npmrc and environment variables", "Sends data to a hard-coded IP address"], explanation: "Install scripts run with your permissions.", legitNote: nil,
                            recommendation: "Remove the package and rotate npm tokens.", actions: [.quarantine(paths: [home + "/Developer/weather-app/node_modules/colors-tiny"])]),
            SecurityFinding(id: "demo:mcp", area: .aiTools, severity: .low, title: "MCP server runs an unpinned package", subtitle: "~/.cursor/mcp.json · npx -y some-mcp@latest",
                            evidence: ["@latest re-downloads code on every launch"], explanation: "An unpinned package can change under you.", legitNote: "Common during development.",
                            recommendation: "Pin a version.", actions: []),
        ]
        r.stats = ["projects": 14]
        return r
    }

    static var secrets: SecretsReport {
        func hit(_ kind: String, _ provider: String?, _ line: Int, _ masked: String, _ conf: Double, _ why: String, low: Bool = false) -> SecretHit {
            SecretHit(kind: kind, provider: provider, line: line, key: nil, masked: masked, length: 56, fingerprint: String(kind.hashValue, radix: 16), confidence: conf, why: why, lowImpact: low)
        }
        var r = SecretsReport()
        r.files = [
            SecretFile(url: u(home + "/Developer/storefront/.env"), project: u(home + "/Developer/storefront"), origin: .project, isEnvFile: true, isExample: false, git: .tracked,
                       pushed: true, inHistory: true, hits: [hit("OpenAI API key", "OpenAI", 4, "sk-proj-••••••••7b", 0.97, "Matches the OpenAI API key format"),
                                                             hit("Stripe live key", "Stripe", 7, "sk_live_••••••••Q2", 0.97, "Matches the Stripe live key format")]),
            SecretFile(url: u(home + "/Developer/atlas-api/config/database.yml"), project: u(home + "/Developer/atlas-api"), origin: .project, isEnvFile: false, isExample: false, git: .tracked,
                       inHistory: true, hits: [hit("Database URL with password", "Database", 12, "••••••••@db.atlas.internal:5432", 0.85, "A connection string with an embedded password")]),
            SecretFile(url: u(ssd + "/Projects/mobile-shell/.env.local"), project: u(ssd + "/Projects/mobile-shell"), origin: .project, isEnvFile: true, isExample: false, git: .untracked,
                       hits: [hit("Hard-coded credential", "Firebase", 2, "AI••••••••xQ", 0.78, "FIREBASE_SERVICE_KEY = 40 characters, random-looking")]),
            SecretFile(url: u(home + "/.zshrc"), project: nil, origin: .home, label: "Zsh shell profile", isEnvFile: false, isExample: false, git: .notInGit,
                       hits: [hit("GitHub token", "GitHub", 31, "ghp_••••••••Ud", 0.95, "Matches the GitHub token format")],
                       note: "Exported secrets reach every program you start, including npm and pip install scripts."),
            SecretFile(url: u(home + "/Developer/weather-app/.env"), project: u(home + "/Developer/weather-app"), origin: .project, isEnvFile: true, isExample: false, git: .ignored,
                       hits: [hit("Hard-coded credential", "OpenWeather", 1, "a3••••••••9f", 0.84, "OPENWEATHER_API_KEY = 32 characters, high randomness")]),
            SecretFile(url: u(home + "/Developer/weather-app/.env.example"), project: u(home + "/Developer/weather-app"), origin: .project, isEnvFile: true, isExample: true, git: .tracked, hits: []),
        ]
        r.filesChecked = 18_406; r.envFiles = 9; r.scannedAt = Date()
        r.reused = ["demo": [home + "/Developer/storefront/.env", home + "/.zshrc"]]
        return r
    }

    static var repos: [RepoStatus] {
        func repo(_ path: String, _ level: RepoStatus.Level, git: Bool = true, remote: Bool = true, ahead: Int = 0, modified: Int = 0, stashes: Int = 0, bytes: Int64, days: Double) -> RepoStatus {
            var r = RepoStatus(path: u(path), level: level, isGit: git)
            if remote { r.remotes = ["origin": "github.com/sam/\(u(path).lastPathComponent).git"] }
            r.currentBranch = "main"
            r.branches = git ? [.init(name: "main", upstream: remote ? "origin/main" : nil, ahead: ahead, behind: 0, localOnlyCommits: remote ? 0 : ahead, gone: false)] : []
            r.modified = modified; r.stashes = stashes; r.sourceBytes = bytes; r.lastCommit = ago(days); r.lastActivity = ago(days); r.hasCommits = git
            return r
        }
        return [
            repo(ssd + "/Projects/game-jam-2025", .noGit, git: false, remote: false, bytes: 182 * mb, days: 210),
            repo(home + "/Developer/pixel-forge", .noRemote, remote: false, ahead: 23, bytes: 41 * mb, days: 140),
            repo(home + "/Developer/storefront", .unpushed, ahead: 4, stashes: 1, bytes: 66 * mb, days: 3),
            repo(ssd + "/Projects/mobile-shell", .uncommitted, modified: 17, bytes: 58 * mb, days: 51),
            repo(home + "/Developer/atlas-api", .backedUp, bytes: 22 * mb, days: 1),
            repo(home + "/Developer/weather-app", .backedUp, bytes: 9 * mb, days: 96),
            repo(ssd + "/Projects/design-system", .backedUp, bytes: 31 * mb, days: 34),
            repo(ssd + "/Projects/ml-notebooks", .backedUp, bytes: 12 * mb, days: 12),
        ]
    }

    static var doctor: [DoctorIssue] {
        [DoctorIssue(kind: .brokenVenv, level: .broken, project: u(ssd + "/Projects/ml-notebooks"), path: u(ssd + "/Projects/ml-notebooks/.venv"), title: "ml-notebooks/.venv",
                     detail: "Its scripts still point to /Users/sam/Developer/ml-notebooks/.venv, where it lived before it was moved.",
                     evidence: ["Python can't run from it, so every tool using it fails."], fix: .trash([u(ssd + "/Projects/ml-notebooks/.venv")], restore: "uv sync"),
                     fixLabel: "Move to Trash", bytes: 3_480 * mb, oldLocation: home + "/Developer/ml-notebooks"),
         DoctorIssue(kind: .brokenWorktree, level: .broken, project: u(ssd + "/Projects/mobile-shell-release"), path: u(ssd + "/Projects/mobile-shell-release"), title: "mobile-shell-release",
                     detail: "Its repository moved to /Volumes/Studio SSD/Projects/mobile-shell. Git can reconnect them.",
                     evidence: ["The worktree's .git file points to /Users/sam/Developer/mobile-shell/.git/worktrees/release, which no longer exists."],
                     fix: .repairWorktree(repo: u(ssd + "/Projects/mobile-shell"), worktree: u(ssd + "/Projects/mobile-shell-release")), fixLabel: "Reconnect (git worktree repair)",
                     oldLocation: home + "/Developer/mobile-shell"),
         DoctorIssue(kind: .brokenSymlink, level: .warning, project: u(ssd + "/Projects/design-system"), path: u(ssd + "/Projects/design-system/tokens"), title: "design-system/tokens",
                     detail: "Points to the project's old location. The same file exists in the new one.", evidence: ["Target: /Users/sam/Developer/design-system/packages/tokens"],
                     fix: .relink(link: u(ssd + "/Projects/design-system/tokens"), target: ssd + "/Projects/design-system/packages/tokens"), fixLabel: "Point to new location",
                     oldLocation: home + "/Developer/design-system"),
         DoctorIssue(kind: .gitGarbage, level: .tidy, project: u(home + "/Developer/pixel-forge"), path: u(home + "/Developer/pixel-forge/.git"), title: "pixel-forge",
                     detail: "1.2 GB of loose or unreferenced objects.", evidence: ["48,210 loose objects (1.1 GB)", "git gc compresses them. Nothing reachable from a branch, tag or the reflog is removed."],
                     fix: .gitGC(u(home + "/Developer/pixel-forge")), fixLabel: "Optimize (git gc)", bytes: 640 * mb)]
    }

    // MARK: Apps

    static var apps: [AppEntry] {
        func app(_ name: String, _ id: String, _ size: Int64, _ data: Int64, days: Double?, arch: AppEntry.Arch = .universal, flags: [AppEntry.Flag] = [], comps: [AppComponent] = [],
                 move: AppEntry.Move = .movable, trust: SignatureInfo.Trust = .developerID) -> AppEntry {
            AppEntry(path: "/Applications/\(name).app", name: name, bundleID: id, version: "2.4.1", appSize: size, dataSize: data,
                     dataPaths: [u(home + "/Library/Application Support/\(name)")], lastUsed: days.map(ago), added: ago(300),
                     signer: SignatureInfo(trust: trust, teamID: "A1B2C3D4E5", identifier: id), appStore: trust == .appStore, arch: arch, running: false,
                     components: comps, updater: nil, flags: flags, move: move, userOwned: true, movableDataSize: data / 2)
        }
        return [
            app("Xcode", "com.apple.dt.Xcode", 11_800 * mb, 9_200 * mb, days: 1, arch: .appleSilicon, move: .notMovable(["Xcode expects to live in /Applications."]), trust: .appStore),
            app("Unity Hub", "com.unity3d.unityhub", 980 * mb, 4_100 * mb, days: 210, flags: [.unused, .heavyHelpers], comps: [AppComponent(kind: .launchAgent, name: "Unity Hub Helper", path: "")]),
            app("PhotoLab Pro", "com.example.photolab", 2_300 * mb, 6_800 * mb, days: 400, arch: .intel, flags: [.unused, .intelOnly]),
            app("SecureVPN", "com.example.vpn", 140 * mb, 30 * mb, days: 2, comps: [AppComponent(kind: .systemExtension, name: "VPN Network Extension", path: "")],
                move: .notMovable(["It installs a system extension, which macOS only loads from /Applications."])),
            app("CloudDrive", "com.example.clouddrive", 410 * mb, 220 * mb, days: 0.2, comps: [AppComponent(kind: .appExtension, name: "Finder Sync", path: ""), AppComponent(kind: .loginItem, name: "CloudDrive Helper", path: "")]),
            app("Figma", "com.figma.Desktop", 520 * mb, 1_900 * mb, days: 0.5),
            app("Old Installer", "com.example.installer", 180 * mb, 0, days: nil, flags: [.neverOpened, .installer]),
        ]
    }

    static var addOns: [AddOn] {
        [AddOn(kind: .systemExtension, name: "VirtualHID Driver", path: "com.example.virtualhid.driver", bundleID: "com.example.virtualhid.driver", owner: nil, state: .dangling,
               note: "Installed by KeyRemapper.app, which is no longer on this Mac. Still active. Driver extensions run with deep system access.", active: true),
         AddOn(kind: .systemExtension, name: "VPN Network Extension", path: "com.example.vpn.extension", bundleID: "com.example.vpn.extension", owner: "SecureVPN", state: .ok, note: "Belongs to SecureVPN.", active: true),
         AddOn(kind: .audioDriver, name: "ScreenRecorderAudio", path: "/Library/Audio/Plug-Ins/HAL/ScreenRecorderAudio.driver", bundleID: "com.example.recorder.audio", owner: nil, state: .dangling,
               note: "A virtual audio device driver with no installed app. It shows up as an audio device and loads into the audio system."),
         AddOn(kind: .appExtension, name: "Finder Sync · CloudDrive", path: "/Applications/CloudDrive.app/Contents/PlugIns/FinderSync.appex", bundleID: "com.example.clouddrive.findersync",
               owner: "CloudDrive", state: .ok, note: "Finder Sync extension from CloudDrive. Enabled.", active: true),
         AddOn(kind: .quickLook, name: "MarkdownPreview", path: "/Library/QuickLook/MarkdownPreview.qlgenerator", bundleID: "com.example.mdpreview", owner: nil, state: .outdated,
               note: "Quick Look generators (.qlgenerator) are no longer loaded by current macOS. This one does nothing.")]
    }

    // MARK: History and timeline

    static var history: [CleanOutcome] {
        [CleanOutcome(date: ago(0.1), title: "pixel-forge/target", category: "Project artifacts", paths: [], size: 6_210 * mb, method: "Moved to Trash", success: true, message: ""),
         CleanOutcome(date: ago(0.1), title: "DerivedData", category: "Xcode", paths: [], size: 7_940 * mb, method: "Moved to Trash", success: true, message: ""),
         CleanOutcome(date: ago(0.1), title: "npm cache", category: "Developer caches", paths: [], size: 1_310 * mb, method: "Moved to Trash", success: true, message: ""),
         CleanOutcome(date: ago(2), title: ".env", category: "Secrets", paths: [], size: 0, method: "Stop tracking", success: true, message: "Git no longer tracks .env"),
         CleanOutcome(date: ago(6), title: "Projects", category: "Offload", paths: [], size: 38 * gb, method: "Offloaded to Studio SSD", success: true, message: "Verified")]
    }

    static func timeline() -> [String: SpaceHistory.Series] {
        // Three weeks of shrinking free space, a 38 GB offload six days ago, and today's cleanup.
        let samples = stride(from: 21.0, through: 0, by: -0.25).map { d -> SpaceHistory.Sample in
            var free = d > 6 ? 8 + (d - 6) / 15 * 22 : 9.8 + d / 6 * 30
            free += sin(d * 5) * 0.35
            if d < 0.1 { free = cleaned ? 31.4 : 9.8 }
            return .init(date: ago(d), free: Int64(free * 1e9), total: 245 * gb)
        }
        let ssdSamples = stride(from: 21.0, through: 0, by: -0.5).map { d in SpaceHistory.Sample(date: ago(d), free: Int64((650 - (d < 6 ? 38 : 0)) * 1e9), total: 1_000 * gb) }
        return ["boot": .init(id: "boot", name: "Macintosh HD", isBoot: true, samples: samples),
                ssd: .init(id: ssd, name: "Studio SSD", isBoot: false, samples: ssdSamples)]
    }
}
