import Foundation

/// Is each project's source code safe somewhere other than this Mac?
struct RepoStatus: Identifiable, Hashable {
    enum Level: Int, Comparable, CaseIterable {
        case backedUp = 0, uncommitted, unpushed, noRemote, noGit
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }

        var title: String {
            switch self {
            case .backedUp: "Backed up"
            case .uncommitted: "Uncommitted changes"
            case .unpushed: "Not pushed"
            case .noRemote: "No remote"
            case .noGit: "Not in git"
            }
        }
        var blurb: String {
            switch self {
            case .backedUp: "Everything is committed and pushed."
            case .uncommitted: "Edits that aren't committed exist only in this folder."
            case .unpushed: "Commits, branches or stashes exist only on this Mac."
            case .noRemote: "Git history exists, but only on this Mac."
            case .noGit: "No version control. This folder is the only copy."
            }
        }
        var symbol: String {
            switch self {
            case .backedUp: "checkmark.icloud"
            case .uncommitted: "pencil.circle"
            case .unpushed: "icloud.and.arrow.up"
            case .noRemote: "externaldrive.badge.xmark"
            case .noGit: "exclamationmark.triangle"
            }
        }
    }

    struct Branch: Hashable { var name: String; var upstream: String?; var ahead: Int; var behind: Int; var localOnlyCommits: Int; var gone: Bool }

    var id: String { path.path }
    var path: URL
    var level: Level
    var isGit: Bool
    var isWorktree = false
    var remotes: [String: String] = [:]     // name → URL
    var currentBranch: String?
    var branches: [Branch] = []
    var modified = 0
    var untracked = 0
    var stashes = 0
    var hasCommits = true
    var lastCommit: Date?
    var lastActivity: Date?
    var lastFetch: Date?
    var sourceBytes: Int64 = 0
    var vendored = false

    var name: String { path.lastPathComponent }
    var unpushedCommits: Int { branches.reduce(0) { $0 + $1.ahead + $1.localOnlyCommits } }

    var headline: String {
        var parts: [String] = []
        if !isGit { return "No git repository · \(Fmt.bytes(sourceBytes)) of source" }
        if remotes.isEmpty { parts.append(hasCommits ? "No remote" : "No commits yet") }
        if unpushedCommits > 0 { parts.append("\(unpushedCommits) commit\(unpushedCommits == 1 ? "" : "s") not pushed") }
        let localOnly = branches.filter { $0.upstream == nil && $0.localOnlyCommits > 0 }.count
        if localOnly > 0 { parts.append("\(localOnly) local-only branch\(localOnly == 1 ? "" : "es")") }
        if stashes > 0 { parts.append("\(stashes) stash\(stashes == 1 ? "" : "es")") }
        if modified + untracked > 0 { parts.append("\(modified + untracked) uncommitted file\(modified + untracked == 1 ? "" : "s")") }
        return parts.isEmpty ? "Clean and pushed" : parts.joined(separator: " · ")
    }
}

enum CodeBackup {
    /// Dependency checkouts and downloaded sources: their upstream is the backup.
    static let vendoredMarkers = ["/third_party/", "/third-party/", "/vendor/", "/external/", "/deps/", "/.tmp/", "/tmp/", "/node_modules/",
                                  "/checkouts/", "/SourcePackages/", "/.build/", "/Pods/", "/Carthage/"]

    static func analyze(settings: SettingsSnapshot, progress: @escaping (String) -> Void) -> [RepoStatus] {
        progress("Finding projects…")
        let idx = ProjectIndex.build(roots: settings.scanRoots.filter(FS.isDir), settings: settings) { _ in }
        // Git checkouts, plus top-level projects that aren't inside any repository.
        var targets: [(URL, ProjectInfo.GitKind)] = idx.projects.values.filter { $0.gitKind != .none }.map { ($0.root, $0.gitKind) }
        let gitPaths = targets.map(\.0.path)
        for (path, p) in idx.projects where p.gitKind == .none {
            guard idx.outermostProject(for: p.root) == path else { continue }
            if gitPaths.contains(where: { FS.isAncestor($0, of: path) }) { continue }
            targets.append((p.root, .none))
        }
        progress("Checking \(targets.count) projects…")
        var out = [RepoStatus?](repeating: nil, count: targets.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: targets.count) { i in
            let (url, kind) = targets[i]
            var s = kind == .none ? folderStatus(url, idx: idx) : gitStatus(url, linked: kind == .linked)
            s.lastActivity = idx.activity(for: url)
            s.vendored = vendoredMarkers.contains { url.path.contains($0) }
            lock.lock(); out[i] = s; lock.unlock()
        }
        return out.compactMap { $0 }.sorted { ($0.level, $0.sourceBytes) > ($1.level, $1.sourceBytes) }
    }

    static func folderStatus(_ url: URL, idx: ProjectIndex?) -> RepoStatus {
        let artifacts = (idx?.artifacts ?? []).filter { FS.isAncestor(url.path, of: $0.url.path) }.map(\.url)
        let sizes = Sizer.measureMany([url] + artifacts)
        let source = (sizes[url]?.bytes ?? 0) - artifacts.reduce(Int64(0)) { $0 + (sizes[$1]?.bytes ?? 0) }
        return RepoStatus(path: url, level: .noGit, isGit: false, hasCommits: false, sourceBytes: max(0, source))
    }

    static func gitStatus(_ url: URL, linked: Bool) -> RepoStatus {
        var s = RepoStatus(path: url, level: .backedUp, isGit: true, isWorktree: linked)
        for line in Git.run(url, ["remote", "-v"]).stdout.split(separator: "\n") {
            let cols = line.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
            if cols.count >= 2 { s.remotes[cols[0]] = cols[1] }
        }
        s.hasCommits = Git.run(url, ["rev-parse", "--verify", "-q", "HEAD"]).ok
        s.currentBranch = Git.run(url, ["branch", "--show-current"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        for line in Git.run(url, ["status", "--porcelain=v1", "--untracked-files=normal"], timeout: 60).stdout.split(separator: "\n") {
            if line.hasPrefix("??") { s.untracked += 1 } else { s.modified += 1 }
        }
        if let ct = Double(Git.run(url, ["log", "-1", "--format=%ct"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)) {
            s.lastCommit = Date(timeIntervalSince1970: ct)
        }
        if !linked {
            s.stashes = Git.run(url, ["stash", "list"]).stdout.split(separator: "\n").count
            let gitDir = url.appendingPathComponent(".git")
            s.lastFetch = FS.mtime(gitDir.appendingPathComponent("FETCH_HEAD"))
            let refs = Git.run(url, ["for-each-ref", "--format=%(refname:short)%09%(upstream:short)%09%(upstream:track)", "refs/heads"]).stdout
            for line in refs.split(separator: "\n") {
                let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard let name = cols.first, !name.isEmpty else { continue }
                let upstream = cols.count > 1 && !cols[1].isEmpty ? cols[1] : nil
                let track = cols.count > 2 ? cols[2] : ""
                let ahead = Int(Requirements.captures(#"ahead (\d+)"#, track, options: []).first ?? "") ?? 0
                let behind = Int(Requirements.captures(#"behind (\d+)"#, track, options: []).first ?? "") ?? 0
                var localOnly = 0
                if upstream == nil || track.contains("gone") {
                    let args = s.remotes.isEmpty ? ["rev-list", "--count", name] : ["rev-list", "--count", name, "--not", "--remotes"]
                    localOnly = Int(Git.run(url, args).stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                }
                s.branches.append(.init(name: name, upstream: upstream, ahead: ahead, behind: behind, localOnlyCommits: localOnly, gone: track.contains("gone")))
            }
        }
        if s.remotes.isEmpty && !linked { s.level = .noRemote }
        else if s.unpushedCommits > 0 || s.stashes > 0 { s.level = .unpushed }
        else if s.modified + s.untracked > 0 { s.level = .uncommitted }
        if s.level != .backedUp || !linked {
            s.sourceBytes = Int64(Git.run(url, ["count-objects", "-v"]).stdout.split(separator: "\n")
                .first { $0.hasPrefix("size-pack:") }.flatMap { Int64($0.split(separator: " ").last ?? "") }.map { $0 * 1024 } ?? 0)
        }
        return s
    }

    /// One-line warning when a folder holds source code that isn't safe elsewhere (used before moving or trashing).
    static func riskSummary(for url: URL) -> String? {
        var findings: [String] = []
        func check(_ dir: URL, depth: Int) {
            guard findings.count < 4 else { return }
            let names = Set((FS.list(dir.path) ?? []).map(\.name))
            if names.contains(".git") {
                let s = gitStatus(dir, linked: !FS.isDir(dir.appendingPathComponent(".git")))
                if s.level >= .uncommitted { findings.append("\(dir.lastPathComponent): \(s.headline.lowercased())") }
                return
            }
            if !names.isDisjoint(with: Set(ProjectIndex.markerFiles.keys)) {
                findings.append("\(dir.lastPathComponent): not in git, so this is the only copy")
                return
            }
            guard depth < 3 else { return }
            for c in FS.childDirs(dir) where !c.lastPathComponent.hasPrefix(".") && !ArtifactRules.allNames.contains(c.lastPathComponent) {
                check(c, depth: depth + 1)
            }
        }
        if FS.isDir(url) { check(url, depth: 0) }
        guard !findings.isEmpty else { return nil }
        return "Contains source code that isn't backed up: " + findings.joined(separator: "; ") + "."
    }

    // MARK: Actions (each confirmed in the UI)

    static func initialize(_ url: URL, ecosystems: Set<Ecosystem>) -> (Bool, String) {
        let r = Git.run(url, ["init", "-q"])
        guard r.ok else { return (false, r.stderr) }
        let ignore = url.appendingPathComponent(".gitignore")
        if !FS.exists(ignore) {
            var lines = [".DS_Store", ".env", ".env.*", "*.log"]
            if ecosystems.contains(.node) { lines += ["node_modules/", "dist/", ".next/", ".turbo/", "coverage/"] }
            if ecosystems.contains(.python) { lines += [".venv/", "venv/", "__pycache__/", "*.pyc", ".pytest_cache/"] }
            if ecosystems.contains(.rust) { lines += ["target/"] }
            if ecosystems.contains(.jvm) || ecosystems.contains(.android) { lines += ["build/", ".gradle/", "local.properties"] }
            if ecosystems.contains(.apple) { lines += ["DerivedData/", "Pods/", ".build/", "xcuserdata/"] }
            try? (lines.joined(separator: "\n") + "\n").write(to: ignore, atomically: true, encoding: .utf8)
        }
        return (true, "Initialized a git repository with a starter .gitignore. Review `git status`, then commit.")
    }

    static func push(_ s: RepoStatus) -> (Bool, String) {
        guard let remote = s.remotes.keys.contains("origin") ? "origin" : s.remotes.keys.sorted().first else { return (false, "No remote configured.") }
        var pushed: [String] = []
        var errors: [String] = []
        for b in s.branches where b.ahead > 0 || b.localOnlyCommits > 0 {
            let args = b.upstream == nil || b.gone ? ["push", "-u", remote, b.name] : ["push", remote, b.name]
            let r = Git.run(s.path, args, timeout: 300)
            if r.ok { pushed.append(b.name) } else { errors.append("\(b.name): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))") }
        }
        if errors.isEmpty { return (true, "Pushed \(pushed.joined(separator: ", ")) to \(remote).") }
        return (false, errors.joined(separator: "\n"))
    }

    static func fetch(_ s: RepoStatus) -> (Bool, String) {
        let r = Git.run(s.path, ["fetch", "--all", "--prune", "--quiet"], timeout: 180)
        return (r.ok, r.ok ? "Fetched. Status refreshed." : r.stderr)
    }

    static var gh: String? { Shell.which("gh") }

    static func githubAccount() -> String? {
        guard let gh else { return nil }
        let r = Shell.run(gh, ["api", "user", "--jq", ".login"], timeout: 15)
        return r.ok ? r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    static func createPrivateRepo(_ s: RepoStatus) -> (Bool, String) {
        guard let gh else { return (false, "GitHub CLI (gh) isn't installed.") }
        let name = s.name.replacingOccurrences(of: " ", with: "-")
        let r = Shell.run(gh, ["repo", "create", name, "--private", "--source", s.path.path, "--remote", "origin", "--push"], cwd: s.path.path, timeout: 300)
        guard r.ok else { return (false, (r.stderr + r.stdout).trimmingCharacters(in: .whitespacesAndNewlines)) }
        let all = Git.run(s.path, ["push", "-u", "origin", "--all"], timeout: 300)
        return (true, "Created private repository \(name) and pushed" + (all.ok ? " all branches." : " the current branch."))
    }
}
