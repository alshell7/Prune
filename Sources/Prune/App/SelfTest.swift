import Foundation

/// `Prune --selftest`: exercises the safety guard, project analysis and cleaner against throwaway
/// fixtures in ~/Library/Caches/PruneSelfTest-<pid>. Nothing outside that folder is touched.
enum SelfTest {
    static var failures = 0

    static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print((ok ? "  PASS  " : "  FAIL  ") + name + (detail.isEmpty ? "" : " — \(detail)"))
        if !ok { failures += 1 }
    }

    @discardableResult
    static func sh(_ args: [String], cwd: URL) -> ShellResult {
        Shell.run(Git.tool ?? "/usr/bin/git", args, cwd: cwd.path, timeout: 30)
    }

    static func write(_ url: URL, bytes: Int = 16) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 0x61, count: bytes))
    }

    static func run() -> Int32 {
        AuditLog.enabled = false   // fixtures are not the user's history
        let fm = FileManager.default
        let base = FS.home.appendingPathComponent("Library/Caches/PruneSelfTest-\(getpid())")
        try? fm.removeItem(at: base)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        print("Safety guard")
        let h = FS.home.path
        for (p, label) in [("/", "root"), (h, "home"), (h + "/Documents", "Documents"), (h + "/Library", "Library"),
                           (h + "/Library/Caches", "Caches root"), (h + "/.ssh/id_rsa", ".ssh"), (h + "/Library/Keychains/login.keychain-db", "Keychains"),
                           ("/System/Library/CoreServices", "/System"), ("/usr/bin/git", "/usr/bin"), ("/private/etc/hosts", "/etc"),
                           (h + "/Library/Mobile Documents/x", "iCloud Drive"), (h + "/Pictures/Photos Library.photoslibrary/x", "Photos"),
                           ("/Applications/Safari.app/Contents", "inside app bundle"), ("/tmp/whatever", "/tmp")] {
            check("blocks \(label)", SafetyGuard.check(URL(fileURLWithPath: p)) != nil)
        }
        let repoLike = base.appendingPathComponent("looks-like-build")
        try? fm.createDirectory(at: repoLike.appendingPathComponent(".git"), withIntermediateDirectories: true)
        check("blocks a folder that is a git repository", SafetyGuard.check(repoLike) != nil)
        check("blocks paths inside .git", SafetyGuard.check(repoLike.appendingPathComponent(".git/objects")) != nil)
        check("allows a cache folder", SafetyGuard.check(base.appendingPathComponent("some-cache")) == nil)

        print("Project analysis")
        // A node project with dependencies.
        let proj = base.appendingPathComponent("webapp")
        write(proj.appendingPathComponent("package.json"))
        write(proj.appendingPathComponent("package-lock.json"))
        write(proj.appendingPathComponent("node_modules/left-pad/index.js"), bytes: 2_000_000)
        // A Node installation's global modules: must never be treated as an artifact.
        write(base.appendingPathComponent("tools/node-v22/lib/node_modules/npm/index.js"), bytes: 2_000_000)
        // A repo that commits its dist/ folder: tracked files are source, not junk.
        let repo = base.appendingPathComponent("library")
        write(repo.appendingPathComponent("package.json"))
        write(repo.appendingPathComponent("dist/bundle.js"), bytes: 2_000_000)
        write(repo.appendingPathComponent("build/out.js"), bytes: 2_000_000)
        try? "node_modules/\nbuild/\n".write(to: repo.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        sh(["init", "-q", "-b", "main"], cwd: repo)
        sh(["-c", "user.email=t@t", "-c", "user.name=t", "add", ".gitignore", "package.json", "dist"], cwd: repo)
        sh(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "init"], cwd: repo)

        var snap = AppSettings.shared.snapshot
        snap.scanRoots = [base]
        snap.includeExternalVolumes = false
        snap.excludedPaths = []
        snap.minItemMB = 1
        let ctx = ScanContext(settings: snap)
        let artifacts = ProjectArtifactScanner().scan(ctx, ScanProgress { _ in })
        let paths = Set(artifacts.flatMap { $0.paths.map(\.path) })
        check("finds node_modules next to package.json", paths.contains(proj.appendingPathComponent("node_modules").path))
        check("restore command matches the lockfile", artifacts.first { $0.paths.first?.lastPathComponent == "node_modules" }?.restore == "npm ci")
        check("ignores <prefix>/lib/node_modules", !paths.contains { $0.contains("/tools/node-v22/") })
        check("skips git-tracked dist/", !paths.contains(repo.appendingPathComponent("dist").path))
        check("keeps untracked build/", paths.contains(repo.appendingPathComponent("build").path))
        let nm = artifacts.first { $0.paths.first == proj.appendingPathComponent("node_modules") }
        check("measures size", (nm?.size ?? 0) >= 2_000_000, nm.map { Fmt.bytes($0.size) } ?? "missing")

        print("Worktrees")
        sh(["worktree", "add", "-q", base.appendingPathComponent("wt-clean").path, "-b", "feature-clean"], cwd: repo)
        sh(["worktree", "add", "-q", base.appendingPathComponent("wt-dirty").path, "-b", "feature-dirty"], cwd: repo)
        write(base.appendingPathComponent("wt-dirty/notes.txt"))
        write(base.appendingPathComponent("wt-clean/node_modules/x/index.js"), bytes: 1_500_000)   // ignored by .gitignore
        let ctx2 = ScanContext(settings: snap)
        let wts = WorktreeScanner().scan(ctx2, ScanProgress { _ in })
        let clean = wts.first { $0.paths.first?.lastPathComponent == "wt-clean" }
        let dirty = wts.first { $0.paths.first?.lastPathComponent == "wt-dirty" }
        check("detects clean worktree as removable", clean != nil && clean!.lockedReason == nil)
        check("locks worktree with uncommitted changes", dirty?.lockedReason != nil, dirty?.lockedReason ?? "missing")

        print("Cleaner")
        let nested = ProjectArtifactScanner().scan(ctx2, ScanProgress { _ in }).filter { $0.paths.first?.path.contains("/wt-clean/") == true }
        if let clean {
            let plan = Cleaner.dedupe([clean] + nested)
            check("nested node_modules is absorbed by its worktree", plan.skipped.count == nested.count && !nested.isEmpty)
            let out = Cleaner.clean([clean], deleteSafeImmediately: false) { _, _, _ in }
            check("git worktree remove succeeds", out.first?.success == true, out.first?.message ?? "")
            check("worktree folder is gone", !FS.exists(base.appendingPathComponent("wt-clean")))
            let branch = sh(["branch", "--list", "feature-clean"], cwd: repo).stdout
            check("branch survives removal", branch.contains("feature-clean"))
        }
        if var dirty {
            dirty.lockedReason = nil   // force it: git itself must still refuse
            let out = Cleaner.clean([dirty], deleteSafeImmediately: false) { _, _, _ in }
            check("git refuses to remove a dirty worktree", out.first?.success == false && FS.exists(base.appendingPathComponent("wt-dirty/notes.txt")))
        }
        let cache = base.appendingPathComponent("disposable-cache")
        write(cache.appendingPathComponent("blob"), bytes: 100_000)
        let cacheItem = CleanupItem(category: .devCaches, title: "selftest cache", paths: [cache], size: 100_000, risk: .safe,
                                    recommendation: .recommended, reason: "", whatItIs: "", impact: "")
        let out = Cleaner.clean([cacheItem], deleteSafeImmediately: true) { _, _, _ in }
        check("permanently deletes a Safe item when enabled", out.first?.success == true && !FS.exists(cache))
        let evil = CleanupItem(category: .devCaches, title: "selftest evil", paths: [URL(fileURLWithPath: h + "/Documents")], size: 0, risk: .safe,
                               recommendation: .recommended, reason: "", whatItIs: "", impact: "")
        let evilOut = Cleaner.clean([evil], deleteSafeImmediately: true) { _, _, _ in }
        check("refuses to delete ~/Documents even if asked", evilOut.first?.success == false && FS.exists(URL(fileURLWithPath: h + "/Documents")))

        print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
        return failures == 0 ? 0 : 1
    }
}
