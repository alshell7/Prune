import Foundation

struct ProjectArtifactScanner: Scanner {
    let name = "Project artifacts"

    func scan(_ ctx: ScanContext, _ progress: ScanProgress) -> [CleanupItem] {
        progress.update("Indexing projects…")
        let t0 = Date()
        let idx = ctx.projects()
        if ProcessInfo.processInfo.environment["PRUNE_DEBUG"] != nil { print("index: \(Date().timeIntervalSince(t0))s") }
        var candidates = idx.artifacts.filter { !ctx.settings.isExcluded($0.url) }

        // Anything git tracks is source code, whatever its name.
        progress.update("Checking git for tracked folders…")
        var byRepo: [String: [ArtifactCandidate]] = [:]
        for c in candidates {
            if let scope = idx.scopeRoot(for: c.url), idx.projects[scope]?.gitKind != ProjectInfo.GitKind.none {
                byRepo[scope, default: []].append(c)
            }
        }
        var tracked = Set<String>()
        for (repo, list) in byRepo where Git.tool != nil {
            let rels = list.map { String($0.url.path.dropFirst(repo.count + 1)) }
            for rel in Git.trackedPaths(URL(fileURLWithPath: repo), rels) { tracked.insert(repo + "/" + rel) }
        }
        candidates.removeAll { tracked.contains($0.url.path) }

        progress.update("Measuring \(candidates.count) build folders…")
        let t1 = Date()
        let sizes = Sizer.measureMany(candidates.map(\.url))
        if ProcessInfo.processInfo.environment["PRUNE_DEBUG"] != nil { print("git+measure: \(t1.timeIntervalSince(t0))s / measure \(Date().timeIntervalSince(t1))s, files \(sizes.values.reduce(0) { $0 + $1.files })") }
        for c in candidates { idx.noteArtifactActivity(c.url, sizes[c.url]?.newest) }

        var items: [CleanupItem] = []
        var aggregates: [String: (rule: ArtifactCandidate, paths: [URL], size: Int64, newest: Date?)] = [:]

        for c in candidates {
            guard let m = sizes[c.url] else { continue }
            if c.rule.aggregate {
                let scope = idx.scopeRoot(for: c.url) ?? c.url.deletingLastPathComponent().path
                let key = scope + "|" + c.rule.id
                var a = aggregates[key] ?? (c, [], 0, nil)
                a.paths.append(c.url)
                a.size += m.bytes
                if let n = m.newest, n > (a.newest ?? .distantPast) { a.newest = n }
                aggregates[key] = a
                continue
            }
            guard m.bytes >= max(ctx.minBytes, 512 * 1024) else { continue }
            items.append(makeItem(c, paths: [c.url], size: m.bytes, ctx: ctx, idx: idx))
        }
        for (key, a) in aggregates where a.size >= 256 * 1024 {
            let scope = String(key.split(separator: "|").first ?? "")
            var item = makeItem(a.rule, paths: a.paths, size: a.size, ctx: ctx, idx: idx)
            item.title = idx.displayName(for: scope) + " · \(a.rule.rule.kind)"
            item.subtitle = "\(a.paths.count) folder\(a.paths.count == 1 ? "" : "s")"
            items.append(item)
        }
        return items
    }

    private func ecosystem(_ c: ArtifactCandidate) -> Ecosystem {
        let s = c.siblings
        if s.contains("package.json") && ["dist", "build", "coverage", "out"].contains(c.url.lastPathComponent) { return .node }
        if s.contains("build.gradle") || s.contains("build.gradle.kts") { return .jvm }
        if s.contains("pubspec.yaml") { return .flutter }
        if s.contains("Cargo.toml") { return .rust }
        return c.rule.ecosystem
    }

    private func makeItem(_ c: ArtifactCandidate, paths: [URL], size: Int64, ctx: ScanContext, idx: ProjectIndex) -> CleanupItem {
        let rule = c.rule
        // Folders outside any recognised project fall back to their parent folder's newest entry.
        let activity = idx.activity(for: c.url) ?? FS.newestChildMtime(c.url.deletingLastPathComponent(), skipping: ArtifactRules.allNames)
        let days = Age.days(activity)
        let stale = days.map { $0 >= ctx.staleDays } ?? true
        let scope = idx.scopeRoot(for: c.url)
        let inLinkedWorktree = scope.flatMap { idx.projects[$0]?.gitKind } == .linked
        let orphanNodeModules = rule.id == "node_modules" && !c.siblings.contains("package.json")

        var rec: Recommendation
        var reason: String
        var whyRemove: String?
        var whyKeep: String?

        let venv = rule.id == "venv" ? ProjectDoctor.venvHealth(c.url) : nil
        if let venv, venv.broken {
            rec = .recommended
            reason = "Broken virtualenv: " + (venv.reason ?? "it can't run.")
            whyRemove = "Python can't start from this environment, so nothing uses it. Recreate it with: \(ProjectDoctor.pyRecreate(c.url.deletingLastPathComponent()))"
        } else if orphanNodeModules {
            rec = .recommended
            reason = "No package.json next to it, so it was probably left behind."
            whyRemove = "There is no package.json in the parent folder, so no project can use these packages."
        } else if stale {
            rec = .recommended
            reason = days.map { _ in "Project untouched for \(Fmt.age(activity))." } ?? "No recent activity detected."
            whyRemove = "You haven't touched this project in \(Fmt.age(activity)). Rebuilding it later is cheaper than keeping \(Fmt.bytes(size)) on disk."
        } else if rule.risk == .safe && (days ?? 0) >= 7 {
            rec = .recommended
            reason = "Disposable cache, and the project is quiet (\(Fmt.age(activity)))."
        } else {
            rec = .optional
            reason = "Active project (\(days == 0 ? "today" : Fmt.age(activity) + " ago")). You'd need to rebuild."
            whyKeep = "You worked on this project recently. Removing it means a reinstall or rebuild the next time you open it."
        }
        if inLinkedWorktree, let scope {
            reason += " Inside worktree \u{201C}\((scope as NSString).lastPathComponent)\u{201D}."
        }
        if rule.id == "venv" {
            whyKeep = (whyKeep.map { $0 + " " } ?? "") + "Packages you installed by hand (not in requirements or the lockfile) would need reinstalling."
        }

        let eco = ecosystem(c)
        return CleanupItem(
            category: .projectArtifacts,
            title: idx.displayName(for: c.url.path),
            subtitle: orphanNodeModules ? "node_modules · orphaned" : "\(rule.kind) · \(eco.title)",
            group: idx.projectName(c.url.path),
            paths: paths, size: size, risk: rule.risk, recommendation: rec, reason: reason,
            whatItIs: rule.what, whyRemove: whyRemove, whyKeep: whyKeep, impact: rule.impact,
            restore: rule.restore(c.siblings), lastUsed: activity)
    }
}

struct WorktreeScanner: Scanner {
    let name = "Git worktrees"

    func scan(_ ctx: ScanContext, _ progress: ScanProgress) -> [CleanupItem] {
        guard Git.tool != nil else { return [] }
        let idx = ctx.projects()
        progress.update("Reading worktrees…")
        var repos = Set(idx.gitRepos.map(\.path))
        var items: [CleanupItem] = []

        // Checkouts whose .git file points somewhere. Broken links are dangling folders.
        var brokenDirs: [URL] = []
        for dir in idx.gitFileDirs {
            guard let gitDir = Git.resolveGitDir(worktree: dir) else { continue }
            if !FS.exists(gitDir) {
                brokenDirs.append(dir)
            } else if gitDir.path.contains("/worktrees/"), let main = Git.mainRepo(fromGitDir: gitDir) {
                repos.insert(main.path)
            }
        }

        var live: [(repo: URL, wt: Git.Worktree, defaultBranch: String?)] = []
        for repoPath in repos.sorted() {
            let repo = URL(fileURLWithPath: repoPath)
            let list = Git.worktrees(repo)
            guard list.count > 1 else { continue }
            let mainBranch = list.first?.branch
            let prunable = list.dropFirst().filter(\.prunable)
            if !prunable.isEmpty {
                items.append(CleanupItem(
                    id: "worktree-prune:\(repoPath)",
                    category: .dangling, title: "Stale worktree records · \(repo.lastPathComponent)",
                    subtitle: "\(prunable.count) missing worktree\(prunable.count == 1 ? "" : "s")", group: repo.lastPathComponent,
                    paths: [], size: 0, risk: .safe, recommendation: .recommended,
                    reason: "Git still lists worktrees whose folders no longer exist.",
                    whatItIs: "Bookkeeping in .git/worktrees for checkouts that were deleted without `git worktree remove`: \(prunable.map { FS.tildePath($0.path) }.joined(separator: ", ")).",
                    whyRemove: "They point at folders that are gone. They also block their branches from being checked out elsewhere.",
                    impact: "None. Only stale metadata is removed. Branches and commits are untouched.",
                    restore: nil, action: .command(ShellCommand(tool: Git.tool!, args: ["-C", repoPath, "worktree", "prune"]))))
            }
            for wt in list.dropFirst() where !wt.prunable && !wt.bare && FS.isDir(wt.path) {
                live.append((repo, wt, mainBranch))
            }
        }

        progress.update("Measuring \(live.count) worktrees…")
        let sizes = Sizer.measureMany(live.map(\.wt.path) + brokenDirs)

        for (repo, wt, defaultBranch) in live {
            let size = sizes[wt.path]?.bytes ?? 0
            let status = Git.run(wt.path, ["status", "--porcelain", "--untracked-files=normal"], timeout: 60)
            let dirty = status.ok ? status.stdout.split(separator: "\n").count : -1
            var aheadOfDefault = 0
            if let d = defaultBranch, let head = wt.head {
                let r = Git.run(repo, ["rev-list", "--count", "\(d)..\(head)"])
                aheadOfDefault = Int(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            }
            var orphanCommits = false
            if wt.detached, let head = wt.head, aheadOfDefault > 0 {
                let r = Git.run(repo, ["branch", "-a", "--contains", head, "--format=%(refname)"])
                orphanCommits = r.ok && r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }

            var activitySignals: [Date] = []
            if let gd = Git.resolveGitDir(worktree: wt.path) {
                for f in ["index", "HEAD", "logs/HEAD"] { if let m = FS.mtime(gd.appendingPathComponent(f)) { activitySignals.append(m) } }
            }
            if let m = FS.newestChildMtime(wt.path, skipping: ArtifactRules.allNames.union([".git"])) { activitySignals.append(m) }
            let activity = activitySignals.max()
            let days = Age.days(activity) ?? 999
            let byClaude = wt.path.path.contains("/.claude/worktrees/") || (wt.branch ?? "").hasPrefix("claude/")
            let branchLabel = wt.branch ?? (wt.detached ? "detached HEAD" : "unknown")

            var locked: String?
            if wt.locked { locked = "The worktree is locked (git worktree lock). Unlock it first if you really want it gone." }
            else if dirty < 0 { locked = "Couldn't read git status, so Prune leaves it alone." }
            else if dirty > 0 { locked = "\(dirty) uncommitted change\(dirty == 1 ? "" : "s"). Commit, stash or discard them first." }
            else if orphanCommits { locked = "Detached HEAD with \(aheadOfDefault) commit(s) that are on no branch. Removing it could lose them." }

            let rec: Recommendation = locked != nil ? .keep : (days >= 14 ? .recommended : .optional)
            var reason: String
            if let locked { reason = locked }
            else if days >= 14 { reason = "Clean, idle for \(Fmt.age(activity))." }
            else { reason = "Clean, but used \(days == 0 ? "today" : Fmt.age(activity) + " ago")." }
            if byClaude { reason += " Created by Claude Code." }

            let keepNote = aheadOfDefault > 0
                ? "Branch \u{201C}\(branchLabel)\u{201D} has \(aheadOfDefault) commit(s) not in \(defaultBranch ?? "the default branch"). They stay safe in the repository after removal, because only the checkout folder goes."
                : nil

            items.append(CleanupItem(
                category: .worktrees,
                title: "\(repo.lastPathComponent) › \(wt.path.lastPathComponent)",
                subtitle: "branch \(branchLabel)" + (byClaude ? " · Claude Code" : ""),
                group: repo.lastPathComponent,
                paths: [wt.path], size: size, risk: .low, recommendation: rec, reason: reason,
                whatItIs: "A linked git worktree: a second checkout of \(repo.lastPathComponent) at \(FS.tildePath(wt.path)), including its own node_modules and build output.",
                whyRemove: locked == nil ? "It has no uncommitted work, so removing the folder loses nothing. The branch and all its commits live in the main repository." : nil,
                whyKeep: keepNote,
                impact: "The checkout folder and its build artifacts are deleted via `git worktree remove`. Git refuses if anything is uncommitted. The branch stays.",
                restore: "git worktree add \(Shell.quoteIfNeeded(FS.tildePath(wt.path))) \(wt.branch ?? (wt.head ?? ""))",
                lastUsed: activity,
                action: .command(ShellCommand(tool: Git.tool!, args: ["-C", repo.path, "worktree", "remove", wt.path.path])),
                lockedReason: locked))
        }

        for dir in brokenDirs where !ctx.settings.isExcluded(dir) {
            let m = sizes[dir]
            items.append(CleanupItem(
                category: .dangling, title: FS.tildePath(dir), subtitle: "Broken git checkout",
                paths: [dir], size: m?.bytes ?? 0, risk: .review, recommendation: .optional,
                reason: "Its .git file points to a repository that no longer exists.",
                whatItIs: "A worktree or submodule checkout whose parent repository was moved or deleted. Git can no longer see or manage it.",
                whyRemove: "Without its repository, git can't show status, commit, or update it.",
                whyKeep: "Files here may include work that was never committed. Look through it before removing.",
                impact: "The folder moves to the Trash, so you can still restore it.",
                restore: "Restore from Trash", lastUsed: m?.newest))
        }
        return items
    }
}
