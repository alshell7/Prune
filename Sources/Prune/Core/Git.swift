import Foundation

enum Git {
    static var tool: String? { Shell.which("git") }

    struct Worktree {
        var path: URL
        var head: String?
        var branch: String?       // short name
        var detached = false
        var locked = false
        var prunable = false
        var bare = false
    }

    @discardableResult
    static func run(_ repo: URL, _ args: [String], timeout: TimeInterval = 30) -> ShellResult {
        guard let git = tool else { return ShellResult(status: -1, stdout: "", stderr: "git not found") }
        return Shell.run(git, ["-C", repo.path] + args, timeout: timeout)
    }

    /// For a checkout whose `.git` is a file, returns the git dir it points to.
    static func resolveGitDir(worktree: URL) -> URL? {
        guard let text = FS.readText(worktree.appendingPathComponent(".git"), limit: 4096) else { return nil }
        guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        let raw = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        if raw.hasPrefix("/") { return URL(fileURLWithPath: raw).standardizedFileURL }
        return worktree.appendingPathComponent(raw).standardizedFileURL
    }

    /// The main repository's working directory for a linked worktree's git dir.
    static func mainRepo(fromGitDir gitDir: URL) -> URL? {
        var common = gitDir.deletingLastPathComponent().deletingLastPathComponent() // .../.git/worktrees/x → .../.git
        if let c = FS.readText(gitDir.appendingPathComponent("commondir"), limit: 4096)?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty {
            common = (c.hasPrefix("/") ? URL(fileURLWithPath: c) : gitDir.appendingPathComponent(c)).standardizedFileURL
        }
        guard common.lastPathComponent == ".git" else { return nil }
        return common.deletingLastPathComponent()
    }

    static func worktrees(_ repo: URL) -> [Worktree] {
        let r = run(repo, ["worktree", "list", "--porcelain"])
        guard r.ok else { return [] }
        var out: [Worktree] = []
        var cur: Worktree?
        for line in r.stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("worktree ") {
                if let c = cur { out.append(c) }
                cur = Worktree(path: URL(fileURLWithPath: String(line.dropFirst(9))))
            } else if line.hasPrefix("HEAD ") {
                cur?.head = String(line.dropFirst(5))
            } else if line.hasPrefix("branch ") {
                cur?.branch = String(line.dropFirst(7)).replacingOccurrences(of: "refs/heads/", with: "")
            } else if line == "detached" {
                cur?.detached = true
            } else if line.hasPrefix("locked") {
                cur?.locked = true
            } else if line.hasPrefix("prunable") {
                cur?.prunable = true
            } else if line == "bare" {
                cur?.bare = true
            }
        }
        if let c = cur { out.append(c) }
        return out
    }

    /// Returns which of the given repo-relative paths contain tracked files (those are source, not artifacts).
    static func trackedPaths(_ repo: URL, _ rels: [String]) -> Set<String> {
        var tracked = Set<String>()
        guard !rels.isEmpty else { return tracked }
        for chunk in stride(from: 0, to: rels.count, by: 80).map({ Array(rels[$0..<min($0 + 80, rels.count)]) }) {
            let r = run(repo, ["ls-files", "-z", "--"] + chunk, timeout: 60)
            guard r.status == 0 else { continue }
            let files = r.stdout.split(separator: "\0").map(String.init)
            for rel in chunk where files.contains(where: { $0 == rel || $0.hasPrefix(rel + "/") }) {
                tracked.insert(rel)
            }
        }
        return tracked
    }
}
