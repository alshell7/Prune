import Foundation

/// Finds what breaks when projects move between disks (or just age): virtualenvs whose scripts point at
/// the old location, worktrees that lost their repository, git object stores borrowed from a folder that
/// no longer exists, dangling symlinks, stale git locks and repositories full of loose objects.
struct DoctorIssue: Identifiable, Hashable {
    enum Kind: String, CaseIterable {
        case brokenVenv = "Broken virtualenvs"
        case brokenWorktree = "Disconnected worktrees"
        case brokenAlternates = "Broken git object links"
        case brokenSymlink = "Dangling symlinks"
        case staleLock = "Stale git locks"
        case gitGarbage = "Repositories to optimize"

        var symbol: String {
            switch self {
            case .brokenVenv: "shippingbox.and.arrow.backward"
            case .brokenWorktree: "arrow.triangle.branch"
            case .brokenAlternates: "link.badge.plus"
            case .brokenSymlink: "link"
            case .staleLock: "lock.trianglebadge.exclamationmark"
            case .gitGarbage: "archivebox"
            }
        }
    }

    enum Level: Int, Comparable {
        case tidy = 0, warning, broken
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
        var label: String { switch self { case .tidy: "Tidy-up"; case .warning: "Warning"; case .broken: "Broken" } }
    }

    enum Fix: Hashable {
        case trash([URL], restore: String?)
        case relink(link: URL, target: String)
        case repairWorktree(repo: URL, worktree: URL)
        case removeLock(URL)
        case gitGC(URL)
        case none
    }

    var id: String { kind.rawValue + ":" + path.path }
    var kind: Kind
    var level: Level
    var project: URL
    var path: URL
    var title: String
    var detail: String
    var evidence: [String]
    var fix: Fix
    var fixLabel: String
    var bytes: Int64 = 0
    /// Where the thing used to live, when a move caused the breakage.
    var oldLocation: String?
}

enum ProjectDoctor {
    // MARK: Virtualenvs

    struct VenvHealth { var broken: Bool; var reason: String?; var oldPath: String? }

    /// A venv is broken when its base interpreter is gone or its scripts carry another folder's path
    /// (virtualenvs hard-code their absolute location, so moving a project breaks them).
    static func venvHealth(_ venv: URL) -> VenvHealth {
        if let cfg = FS.readText(venv.appendingPathComponent("pyvenv.cfg"), limit: 16_384) {
            for line in cfg.split(separator: "\n") {
                let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2, parts[0] == "home", parts[1].hasPrefix("/") else { continue }
                if !FileManager.default.fileExists(atPath: parts[1]) {
                    return VenvHealth(broken: true, reason: "Its base Python (\(parts[1])) no longer exists.", oldPath: nil)
                }
            }
        }
        let bin = venv.appendingPathComponent("bin")
        let python = bin.appendingPathComponent("python")
        if FS.isSymlink(python) && !FileManager.default.fileExists(atPath: python.path) {
            return VenvHealth(broken: true, reason: "bin/python points to an interpreter that no longer exists.", oldPath: nil)
        }
        for script in ["pip", "pip3", "activate"] {
            guard let text = FS.readText(bin.appendingPathComponent(script), limit: 8192) else { continue }
            let referenced: String?
            if script == "activate" {
                referenced = text.split(separator: "\n").first { $0.hasPrefix("VIRTUAL_ENV=") }
                    .map { String($0.dropFirst("VIRTUAL_ENV=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "'\" ")) }
            } else {
                referenced = text.split(separator: "\n").first.flatMap { line -> String? in
                    guard line.hasPrefix("#!/") else { return nil }
                    let exe = String(line.dropFirst(2)).split(separator: " ").first.map(String.init) ?? ""
                    return exe.hasSuffix("/bin/python") || exe.contains("/bin/python") ? URL(fileURLWithPath: exe).deletingLastPathComponent().deletingLastPathComponent().path : nil
                }
            }
            guard let old = referenced, old.hasPrefix("/") else { continue }
            let here = venv.standardizedFileURL.path
            let resolvedHere = venv.resolvingSymlinksInPath().path
            if old != here && old != resolvedHere && !FileManager.default.fileExists(atPath: old) {
                return VenvHealth(broken: true, reason: "Its scripts still point to \(old), where it lived before it was moved.", oldPath: old)
            }
        }
        return VenvHealth(broken: false, reason: nil, oldPath: nil)
    }

    // MARK: Scan

    static func scan(index: ProjectIndex, progress: (String) -> Void = { _ in }) -> [DoctorIssue] {
        var issues: [DoctorIssue] = []
        let lock = NSLock()
        func add(_ i: DoctorIssue) { lock.lock(); issues.append(i); lock.unlock() }

        progress("Checking virtualenvs…")
        DispatchQueue.concurrentPerform(iterations: index.venvs.count) { i in
            let venv = index.venvs[i]
            let h = venvHealth(venv)
            guard h.broken else { return }
            let project = venv.deletingLastPathComponent()
            add(DoctorIssue(kind: .brokenVenv, level: .broken, project: project, path: venv,
                            title: "\(project.lastPathComponent)/\(venv.lastPathComponent)", detail: h.reason ?? "Broken",
                            evidence: [h.reason ?? "", "Python can't run from it, so every tool using it fails."].filter { !$0.isEmpty },
                            fix: .trash([venv], restore: pyRecreate(project)), fixLabel: "Move to Trash",
                            bytes: Sizer.measure(venv).bytes, oldLocation: h.oldPath.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }))
        }

        progress("Checking worktrees…")
        let repos = index.gitRepos
        for wt in index.gitFileDirs {
            guard let gitDir = Git.resolveGitDir(worktree: wt), !FS.exists(gitDir) else { continue }
            // .../.git/worktrees/<name>: find the repository that still has this worktree entry.
            let name = gitDir.lastPathComponent
            let owner = repos.first { FS.isDir($0.appendingPathComponent(".git/worktrees/\(name)")) }
            let oldRepo = Git.mainRepo(fromGitDir: gitDir)?.path
            add(DoctorIssue(kind: .brokenWorktree, level: .broken, project: wt, path: wt, title: wt.lastPathComponent,
                            detail: owner != nil ? "Its repository moved to \(FS.tildePath(owner!)). Git can reconnect them." : "Its repository is gone or on another disk.",
                            evidence: ["The worktree's .git file points to \(gitDir.path), which no longer exists."],
                            fix: owner.map { .repairWorktree(repo: $0, worktree: wt) } ?? .none,
                            fixLabel: owner != nil ? "Reconnect (git worktree repair)" : "",
                            oldLocation: oldRepo))
        }
        // The other direction: the repository's record of a worktree that moved.
        let worktreesByName = Dictionary(grouping: index.gitFileDirs, by: \.lastPathComponent)
        for repo in repos {
            let admin = repo.appendingPathComponent(".git/worktrees")
            for entry in FS.childDirs(admin) {
                guard let recorded = FS.readText(entry.appendingPathComponent("gitdir"), limit: 4096)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !recorded.isEmpty, !FS.exists(URL(fileURLWithPath: recorded)) else { continue }
                let oldWorktree = URL(fileURLWithPath: recorded).deletingLastPathComponent()
                guard let moved = worktreesByName[oldWorktree.lastPathComponent]?.first(where: {
                    Git.resolveGitDir(worktree: $0)?.lastPathComponent == entry.lastPathComponent
                }) else { continue }
                guard !issues.contains(where: { $0.path == moved }) else { continue }
                add(DoctorIssue(kind: .brokenWorktree, level: .warning, project: repo, path: moved, title: moved.lastPathComponent,
                                detail: "\(repo.lastPathComponent) still thinks this worktree is at \(FS.tildePath(oldWorktree)).",
                                evidence: ["git worktree list shows a stale path; commands like git worktree prune could drop it."],
                                fix: .repairWorktree(repo: repo, worktree: moved), fixLabel: "Reconnect (git worktree repair)",
                                oldLocation: oldWorktree.path))
            }
        }

        progress("Checking git object stores…")
        DispatchQueue.concurrentPerform(iterations: repos.count) { i in
            let repo = repos[i]
            let gitDir = repo.appendingPathComponent(".git")
            if let alt = FS.readText(gitDir.appendingPathComponent("objects/info/alternates"), limit: 16_384) {
                let missing = alt.split(separator: "\n").map(String.init).filter { $0.hasPrefix("/") && !FS.exists(URL(fileURLWithPath: $0)) }
                if let first = missing.first {
                    // SwiftPM and Xcode keep package clones that borrow objects from a sibling "repositories" cache.
                    let comps = repo.pathComponents
                    let cacheRoot: URL? = comps.lastIndex(of: "checkouts").map { idx in
                        URL(fileURLWithPath: NSString.path(withComponents: Array(comps[..<idx])))
                    }
                    let isPackageCache = cacheRoot.map { FS.exists($0.appendingPathComponent("workspace-state.json")) || FS.isDir($0.appendingPathComponent("repositories")) } ?? false
                    let old = URL(fileURLWithPath: first).deletingLastPathComponent().deletingLastPathComponent().path
                    if isPackageCache, let cacheRoot {
                        add(DoctorIssue(kind: .brokenAlternates, level: .broken, project: cacheRoot, path: cacheRoot,
                                        title: "\(cacheRoot.deletingLastPathComponent().lastPathComponent)/\(cacheRoot.lastPathComponent)",
                                        detail: "Swift package clones that borrow git objects from a folder that moved. Xcode re-downloads them.",
                                        evidence: ["\(missing.count) borrowed object store\(missing.count == 1 ? "" : "s") missing, e.g. \(first)", "git reports \u{201C}bad object HEAD\u{201D} in these checkouts."],
                                        fix: .trash([cacheRoot], restore: "Xcode or swift package resolve fetches the packages again"), fixLabel: "Move cache to Trash",
                                        bytes: Sizer.measure(cacheRoot).bytes, oldLocation: old))
                    } else {
                        add(DoctorIssue(kind: .brokenAlternates, level: .broken, project: repo, path: repo, title: repo.lastPathComponent,
                                        detail: "This clone borrows git objects from a folder that no longer exists, so its history can't be read.",
                                        evidence: ["Missing object store: \(first)", "Fix by restoring that folder, or re-clone the repository from its remote."],
                                        fix: .none, fixLabel: "", oldLocation: old))
                    }
                    return
                }
            }
            let lockFile = gitDir.appendingPathComponent("index.lock")
            if let m = FS.mtime(lockFile), Date().timeIntervalSince(m) > 15 * 60 {
                add(DoctorIssue(kind: .staleLock, level: .warning, project: repo, path: lockFile, title: repo.lastPathComponent,
                                detail: "A leftover index.lock from \(Fmt.ago(m)) blocks every git command in this repository.",
                                evidence: ["Usually left by a crashed git, editor or agent process.", "Prune removes it only when no git process is running."],
                                fix: .removeLock(lockFile), fixLabel: "Remove lock"))
            }
            let r = Git.run(repo, ["count-objects", "-v"], timeout: 20)
            guard r.ok else { return }
            var kv: [String: Int64] = [:]
            for line in r.stdout.split(separator: "\n") {
                let p = line.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }
                if p.count == 2, let v = Int64(p[1]) { kv[p[0]] = v }
            }
            let loose = (kv["size"] ?? 0) * 1024, garbage = (kv["size-garbage"] ?? 0) * 1024
            let packs = kv["packs"] ?? 0
            if loose + garbage >= 64 * 1_048_576 || (packs >= 25 && (kv["size-pack"] ?? 0) * 1024 >= 256 * 1_048_576) {
                add(DoctorIssue(kind: .gitGarbage, level: .tidy, project: repo, path: gitDir, title: repo.lastPathComponent,
                                detail: "\(Fmt.bytes(loose + garbage)) of loose or unreferenced objects\(packs >= 25 ? " across \(packs) packs" : "").",
                                evidence: ["\(kv["count"] ?? 0) loose objects (\(Fmt.bytes(loose)))", "\(packs) pack files (\(Fmt.bytes((kv["size-pack"] ?? 0) * 1024)))",
                                           "git gc compresses them. Nothing reachable from a branch, tag or the reflog is removed."],
                                fix: .gitGC(repo), fixLabel: "Optimize (git gc)", bytes: loose / 2 + garbage))
            }
        }

        progress("Checking symlinks…")
        let roots = index.projects.values.filter { $0.gitKind != .none || index.outermostProject(for: $0.root) == $0.root.path }.map(\.root)
        DispatchQueue.concurrentPerform(iterations: roots.count) { i in
            for issue in danglingLinks(in: roots[i]) { add(issue) }
        }
        return issues.sorted { ($0.level, $0.bytes) > ($1.level, $1.bytes) }
    }

    /// Dangling absolute symlinks near the top of a project. When the project moved, the same relative
    /// path usually exists under its new location, so Prune can offer to retarget the link.
    static func danglingLinks(in root: URL, maxDepth: Int = 3) -> [DoctorIssue] {
        let skip: Set<String> = [".git", "node_modules", ".venv", "venv", ".build", "build", "target", "Pods", ".next", "dist", "DerivedData", ".gradle"]
        var out: [DoctorIssue] = []
        var stack: [(String, Int)] = [(root.path, 0)]
        var seen = 0
        while let (dir, depth) = stack.popLast(), seen < 20_000 {
            guard let entries = FS.list(dir) else { continue }
            for e in entries {
                seen += 1
                let path = dir + "/" + e.name
                if e.isLink {
                    guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path), target.hasPrefix("/"),
                          !FileManager.default.fileExists(atPath: target) else { continue }
                    let link = URL(fileURLWithPath: path)
                    var fix: DoctorIssue.Fix = .none, label = ""
                    if let range = target.range(of: "/" + root.lastPathComponent + "/") {
                        let candidate = root.path + "/" + target[range.upperBound...]
                        if FileManager.default.fileExists(atPath: candidate) { fix = .relink(link: link, target: candidate); label = "Point to new location" }
                    }
                    out.append(DoctorIssue(kind: .brokenSymlink, level: .warning, project: root, path: link,
                                           title: "\(root.lastPathComponent)/\(String(path.dropFirst(root.path.count + 1)))",
                                           detail: label.isEmpty ? "Points to \(target), which doesn't exist." : "Points to the project's old location. The same file exists in the new one.",
                                           evidence: ["Target: \(target)"], fix: fix, fixLabel: label,
                                           oldLocation: target.range(of: "/" + root.lastPathComponent + "/").map { String(target[..<$0.lowerBound]) + "/" + root.lastPathComponent }))
                } else if e.isDir, depth < maxDepth, !skip.contains(e.name), !e.name.hasSuffix(".app") {
                    stack.append((path, depth + 1))
                }
            }
        }
        return out
    }

    static func pyRecreate(_ project: URL) -> String {
        let names = Set(FS.children(project).map(\.lastPathComponent))
        if names.contains("uv.lock") { return "uv sync" }
        if names.contains("poetry.lock") { return "poetry install" }
        if names.contains("Pipfile.lock") { return "pipenv install" }
        if names.contains("requirements.txt") { return "python3 -m venv .venv && .venv/bin/pip install -r requirements.txt" }
        if names.contains("pyproject.toml") { return "python3 -m venv .venv && .venv/bin/pip install -e ." }
        return "python3 -m venv .venv"
    }

    /// Where moved projects used to live, most common first ("~/Documents/Development" → 7 references).
    static func previousLocations(_ issues: [DoctorIssue]) -> [(String, Int)] {
        var counts: [String: Int] = [:]
        for i in issues {
            guard let old = i.oldLocation else { continue }
            // Group by the parent of the old project folder.
            let parent = URL(fileURLWithPath: old).deletingLastPathComponent().path
            counts[parent, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }
    }

    // MARK: Fixes

    static func apply(_ issue: DoctorIssue) -> (Bool, String) {
        switch issue.fix {
        case .trash(let urls, _):
            let outcomes = urls.map { url -> (Bool, String) in
                if let blocked = SafetyGuard.check(url) { return (false, blocked) }
                do { try Cleaner.moveToTrash(url); return (true, "") }
                catch { return (false, error.localizedDescription) }
            }
            if let fail = outcomes.first(where: { !$0.0 }) { return (false, "Couldn't move to Trash: \(fail.1)") }
            AuditLog.append([CleanOutcome(title: issue.title, category: "Project Doctor", paths: urls.map(\.path), size: issue.bytes,
                                          method: "Trash", success: true, message: issue.kind.rawValue)])
            return (true, "Moved to the Trash.")
        case .relink(let link, let target):
            guard FS.isSymlink(link), FileManager.default.fileExists(atPath: target) else { return (false, "The link or its new target changed. Nothing was done.") }
            let tmp = link.deletingLastPathComponent().appendingPathComponent(".\(link.lastPathComponent).prune-relink")
            do {
                try? FileManager.default.removeItem(at: tmp)
                try FileManager.default.createSymbolicLink(atPath: tmp.path, withDestinationPath: target)
                guard rename(tmp.path, link.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
                return (true, "The link now points to \(FS.tildePath(URL(fileURLWithPath: target))).")
            } catch {
                try? FileManager.default.removeItem(at: tmp)
                return (false, "Couldn't update the link: \(error.localizedDescription)")
            }
        case .repairWorktree(let repo, let wt):
            let r = Git.run(repo, ["worktree", "repair", wt.path], timeout: 30)
            let ok = r.ok && Git.run(wt, ["rev-parse", "--git-dir"], timeout: 15).ok
            return ok ? (true, "Reconnected \(wt.lastPathComponent) to \(repo.lastPathComponent).") : (false, "git worktree repair failed: \(r.stderr.isEmpty ? r.stdout : r.stderr)")
        case .removeLock(let lock):
            let running = Shell.run("/usr/bin/pgrep", ["-x", "git"], timeout: 5)
            guard !running.ok else { return (false, "A git process is running right now. Try again when it finishes.") }
            guard lock.lastPathComponent == "index.lock", lock.deletingLastPathComponent().lastPathComponent == ".git" else { return (false, "Unexpected lock path.") }
            do { try FileManager.default.removeItem(at: lock); return (true, "Removed the stale lock. Git works again.") }
            catch { return (false, error.localizedDescription) }
        case .gitGC(let repo):
            let before = Sizer.measure(repo.appendingPathComponent(".git")).bytes
            let r = Git.run(repo, ["gc", "--quiet"], timeout: 600)
            guard r.ok else { return (false, "git gc failed: \(r.stderr)") }
            let after = Sizer.measure(repo.appendingPathComponent(".git")).bytes
            AuditLog.append([CleanOutcome(title: repo.lastPathComponent, category: "Project Doctor", paths: [repo.path], size: max(0, before - after),
                                          method: "git gc", success: true, message: "Optimized repository")])
            return (true, "Optimized. Saved \(Fmt.bytes(max(0, before - after))).")
        case .none:
            return (false, "No automatic fix.")
        }
    }
}
