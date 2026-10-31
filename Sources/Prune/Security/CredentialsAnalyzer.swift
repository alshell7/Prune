import Foundation

/// Local, bounded credential inspection. Findings contain types and line numbers, never values.
enum CredentialsAnalyzer {
    struct Signal: Hashable { var kind: String; var line: Int }
    private struct Pattern { var name: String; var markers: [String]; var expression: NSRegularExpression }

    private static func pattern(_ name: String, _ regex: String, _ markers: [String]) -> Pattern {
        Pattern(name: name, markers: markers, expression: try! NSRegularExpression(pattern: regex))
    }
    private static let patterns: [Pattern] = [
        pattern("Private key", #"-----BEGIN (?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----"#, ["-----begin "]),
        pattern("AWS access key ID", #"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"#, ["akia", "asia"]),
        pattern("GitHub token", #"\b(?:gh[pousr]_[A-Za-z0-9]{30,255}|github_pat_[A-Za-z0-9_]{40,255})\b"#, ["ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_"]),
        pattern("GitLab token", #"\bglpat-[A-Za-z0-9_-]{20,}"#, ["glpat-"]),
        pattern("Slack token", #"\bxox[baprs]-[A-Za-z0-9-]{20,}"#, ["xox"]),
        pattern("Stripe live secret key", #"\bsk_live_[A-Za-z0-9]{20,}"#, ["sk_live_"]),
        pattern("API token", #"\bsk-proj-[A-Za-z0-9_-]{30,}"#, ["sk-proj-"]),
        pattern("Google API key", #"\bAIza[A-Za-z0-9_-]{35}\b"#, ["aiza"]),
        pattern("Database URL with password", #"(?i)\b(?:postgres(?:ql)?|mysql|mongodb(?:\+srv)?|redis)://[^\s/@:]+:[^\s/@]+@"#, ["postgres://", "postgresql://", "mysql://", "mongodb://", "mongodb+srv://", "redis://"]),
    ]
    private static let assignment = try! NSRegularExpression(pattern:
        #"(?i)["']?([a-z_][a-z0-9_.-]{0,100})["']?\s*[:=]\s*(?:["']([^"'\r\n]{1,512})["']|([^\s#;,}\]]+))"#)
    private static let secretName = try! NSRegularExpression(pattern:
        #"(?i)(?:^|[_\-.])(?:password|passwd|pwd|secret|token|credentials?)(?:$|[_\-.])|api[_\-.]?key|access[_\-.]?key|private[_\-.]?key|client[_\-.]?secret|auth[_\-.]?key"#)

    static func isEnvironmentFile(_ name: String) -> Bool {
        let n = name.lowercased()
        return n == ".env" || n == ".envrc" || n.hasPrefix(".env.") || n.hasPrefix(".env-")
    }

    private static func isExample(_ name: String) -> Bool {
        let n = name.lowercased()
        return ["example", "sample", "template", "dist"].contains { n.hasSuffix("." + $0) || n.hasSuffix("-" + $0) }
    }

    private static func plausibleValue(_ value: String, key: String) -> Bool {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let low = v.lowercased()
        guard v.count >= 8 && v.count <= 512 else { return false }
        if low.hasPrefix("http://") || low.hasPrefix("https://") || low.hasPrefix("$") || low.hasPrefix("<") ||
            low.hasPrefix("{{") || low.contains("process.env") || low.contains("os.environ") || low.contains("getenv(") ||
            low.contains("env(") || low.contains("example") || low.contains("placeholder") || low.contains("changeme") ||
            low.contains("change_me") || low.contains("replace") || low.contains("your_") || low.contains("your-") ||
            low.contains("dummy") || low.contains("redacted") || low.contains("not-a-") || low.contains("fake") ||
            low.contains("xxxxx") || low.contains("test_token") || low.contains("test-key") || low == "password" ||
            low == "secretkey" || low == "undefined" || low == "localhost" { return false }
        // Passwords can be human-chosen; token-like values should have a little variety.
        if key.lowercased().contains("password") || key.lowercased().contains("passwd") || key.lowercased().contains("pwd") { return true }
        guard v.count >= 16 else { return false }
        var counts: [Character: Int] = [:]
        for c in v { counts[c, default: 0] += 1 }
        let entropy = counts.values.reduce(0.0) { total, count in
            let p = Double(count) / Double(v.count)
            return total - p * log2(p)
        }
        return entropy >= 3.0
    }

    static func hasEmbeddedRemoteCredential(_ value: String) -> Bool {
        guard let url = URLComponents(string: value), url.host != nil else { return false }
        if let password = url.password, !password.isEmpty,
           !["example", "placeholder", "your_password", "replace"].contains(where: { password.lowercased().contains($0) }) { return true }
        if let user = url.user, plausibleValue(user, key: "token") { return true }
        return (url.queryItems ?? []).contains { item in
            let key = item.name.lowercased()
            return ["token", "secret", "password", "credential", "api_key", "apikey"].contains(where: { key.contains($0) }) && !(item.value ?? "").isEmpty
        }
    }

    static func signals(in text: String) -> [Signal] {
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        let lower = text.lowercased()
        var newlines: [Int]?
        func line(_ offset: Int) -> Int {
            if newlines == nil { newlines = text.utf16.enumerated().compactMap { $0.element == 10 ? $0.offset : nil } }
            let positions = newlines ?? []
            var lo = 0, hi = positions.count
            while lo < hi { let mid = (lo + hi) / 2; if positions[mid] < offset { lo = mid + 1 } else { hi = mid } }
            return lo + 1
        }
        var found = Set<Signal>()
        for p in patterns where p.markers.contains(where: { lower.contains($0) }) {
            var count = 0
            p.expression.enumerateMatches(in: text, range: whole) { match, _, stop in
                guard let match else { return }
                let value = ns.substring(with: match.range)
                if p.name == "Private key" || p.name == "Database URL with password" || plausibleValue(value, key: "token") {
                    found.insert(Signal(kind: p.name, line: line(match.range.location)))
                    count += 1
                }
                if count >= 30 { stop.pointee = true }
            }
        }
        guard ["secret", "token", "password", "passwd", "pwd", "credential", "api_key", "api-key", "apikey", "access_key", "access-key", "accesskey", "private_key", "privatekey", "auth_key", "authkey"].contains(where: { lower.contains($0) }) else {
            return found.sorted { ($0.line, $0.kind) < ($1.line, $1.kind) }
        }
        var matches = 0
        assignment.enumerateMatches(in: text, range: whole) { m, _, stop in
            guard let m else { return }
            matches += 1
            if matches >= 10_000 { stop.pointee = true }
            let key = ns.substring(with: m.range(at: 1))
            let keyRange = NSRange(location: 0, length: (key as NSString).length)
            let keyLower = key.lowercased()
            guard secretName.firstMatch(in: key, range: keyRange) != nil || keyLower.hasSuffix("token") || keyLower.hasSuffix("password") else { return }
            let valueRange = m.range(at: m.range(at: 2).location != NSNotFound ? 2 : 3)
            guard valueRange.location != NSNotFound, plausibleValue(ns.substring(with: valueRange), key: key) else { return }
            found.insert(Signal(kind: "Hard-coded credential", line: line(m.range.location)))
        }
        return found.sorted { ($0.line, $0.kind) < ($1.line, $1.kind) }
    }

    private static let extensions: Set<String> = [
        "js", "jsx", "ts", "tsx", "mjs", "cjs", "py", "rb", "php", "go", "rs", "java", "kt", "swift", "m", "mm", "h", "c", "cpp", "cs",
        "json", "jsonc", "yaml", "yml", "toml", "ini", "cfg", "conf", "config", "properties", "xml", "plist", "tf", "tfvars", "gradle",
        "sh", "bash", "zsh", "fish", "sql", "html", "vue", "svelte", "md", "txt", "pem", "key", "p8"
    ]
    private static let skip: Set<String> = [
        ".git", ".hg", ".svn", "node_modules", "vendor", "Pods", "Carthage", "site-packages", ".venv", "venv", "__pycache__",
        ".gradle", ".terraform", ".build", "target", ".next", ".nuxt", ".turbo", ".cache", ".Trash", ".Trashes"
    ]
    private static let lockFiles: Set<String> = ["package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml", "bun.lock", "cargo.lock", "composer.lock", "poetry.lock", "uv.lock", "gemfile.lock"]
    private static let maxFileBytes: Int64 = 512 * 1024
    private static let maxFiles = 100_000
    private static let maxDirs = 100_000

    private static func read(_ url: URL) -> (String?, Bool) {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return (nil, false) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return (nil, false) }
        guard st.st_size <= maxFileBytes else { return (nil, true) }
        guard let data = try? handle.read(upToCount: Int(maxFileBytes) + 1), !data.contains(0),
              let text = String(data: data, encoding: .utf8) else { return (nil, false) }
        return (text, false)
    }

    static func scan(index: ProjectIndex, settings: SettingsSnapshot, report: inout SecurityReport) {
        let roots = index.projects.values.filter { $0.gitKind != .none || index.outermostProject(for: $0.root) == $0.root.path }
            .map(\.root).sorted { $0.path.count < $1.path.count }
        var stack = roots.map { ($0, 0) }
        var visited = Set<String>()
        var filesChecked = 0, envFiles = 0, skippedLarge = 0, unreadable = 0
        var truncated = false
        var tracked: [String: Set<String>] = [:]
        var failedTracking = Set<String>()

        func gitState(_ file: URL) -> String {
            guard let root = index.scopeRoot(for: file), let project = index.projects[root], project.gitKind != .none else { return "not in git" }
            if tracked[root] == nil && !failedTracking.contains(root) {
                let result = Git.run(URL(fileURLWithPath: root), ["ls-files", "--cached", "-z"], timeout: 60)
                if result.ok { tracked[root] = Set(result.stdout.split(separator: "\0").map(String.init)) }
                else { failedTracking.insert(root) }
            }
            guard let paths = tracked[root] else { return "git status unknown" }
            let rel = String(file.path.dropFirst(root.count + 1))
            if paths.contains(rel) { return "tracked by git" }
            let ignored = Git.run(URL(fileURLWithPath: root), ["check-ignore", "-q", "--", rel], timeout: 15)
            return ignored.status == 0 ? "ignored by git" : (ignored.status == 1 ? "untracked, not ignored" : "git status unknown")
        }

        while let (dir, depth) = stack.popLast() {
            guard visited.insert(dir.path).inserted, !settings.isExcluded(dir) else { continue }
            if visited.count > maxDirs || filesChecked >= maxFiles { truncated = true; break }
            guard let entries = FS.list(dir.path) else { unreadable += 1; continue }
            for e in entries {
                let file = dir.appendingPathComponent(e.name)
                guard !e.isLink, !settings.isExcluded(file) else { continue }
                if e.isDir {
                    if depth < 20 && !skip.contains(e.name) && !e.name.hasSuffix(".app") && !e.name.hasSuffix(".photoslibrary") {
                        stack.append((file, depth + 1))
                    }
                    continue
                }
                let env = isEnvironmentFile(e.name)
                if lockFiles.contains(e.name.lowercased()) { continue }
                guard env || extensions.contains(file.pathExtension.lowercased()) else { continue }
                if filesChecked >= maxFiles { truncated = true; break }
                filesChecked += 1
                if env { envFiles += 1 }
                let (text, tooLarge) = read(file)
                if tooLarge { skippedLarge += 1 }
                if text == nil && !tooLarge { unreadable += 1 }
                let hits = text.map(signals) ?? []
                guard env || !hits.isEmpty else { continue }
                let state = gitState(file)
                let components = file.pathComponents.map { $0.lowercased() }
                let publiclyServed = components.contains("public") || components.contains("www") || components.contains("wwwroot")
                let example = env && isExample(e.name)
                let hasSecret = !hits.isEmpty
                let issue = hasSecret || (env && !example && (state == "tracked by git" || state == "untracked, not ignored" || publiclyServed))
                let severity: Severity = hasSecret && (state == "tracked by git" || publiclyServed) ? .high :
                    (hasSecret ? (state == "ignored by git" ? .low : .medium) : (issue ? .medium : .low))
                var evidence = hits.prefix(15).map { "\($0.kind) · line \($0.line)" }
                if hits.count > 15 { evidence.append("\(hits.count - 15) more possible matches") }
                evidence.append("File is \(state).")
                if publiclyServed { evidence.append("Located under a public web folder; check whether it is deployed.") }
                if tooLarge { evidence.append("File exceeds 512 KiB; its contents were not inspected.") }
                if text == nil && !tooLarge { evidence.append("The file could not be read as UTF-8 text.") }
                let title = hasSecret ? "Possible credentials in \(e.name)" : "Environment file: \(e.name)"
                let advice = hasSecret ? "Review the indicated lines. If a real credential was exposed, revoke or rotate it, remove it from source and deployment artifacts, and review repository history." :
                    "Keep real secrets out of tracked or publicly served files. Use an ignored local environment file and a placeholder-only example."
                report.findings.append(SecurityFinding(id: "credentials:\(file.path)", area: .credentials, severity: severity,
                    title: title, subtitle: FS.tildePath(file), evidence: evidence,
                    explanation: "Prune checks local project files for credential-shaped values and environment files. Secret values are never included in these findings.",
                    legitNote: "A match can be a test value, a public identifier, or a secret intentionally stored in an ignored local file. Prune does not verify credentials or contact a provider.",
                    recommendation: advice, actions: [], paths: [file.path], inventoryOnly: !issue))
            }
            if truncated { break }
        }
        // Git metadata is skipped by the walk, so inspect remote configuration through Git itself.
        for project in index.projects.values where project.gitKind != .none {
            let result = Git.run(project.root, ["remote", "-v"], timeout: 15)
            guard result.ok else { continue }
            let exposed = result.stdout.split(separator: "\n").contains { line in
                let fields = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
                return fields.count >= 2 && hasEmbeddedRemoteCredential(String(fields[1]))
            }
            guard exposed else { continue }
            let common = project.gitKind == .linked ? Git.resolveGitDir(worktree: project.root).flatMap(Git.mainRepo(fromGitDir:)) : project.root
            let config = common?.appendingPathComponent(".git/config")
            let paths = config.flatMap { FS.exists($0) ? [$0.path] : nil } ?? []
            report.findings.append(SecurityFinding(id: "credentials:remote:\(project.root.path)", area: .credentials, severity: .medium,
                title: "Credential embedded in a Git remote", subtitle: FS.tildePath(project.root),
                evidence: ["A configured remote URL contains a possible credential. Its value is not shown."],
                explanation: "Git stores remote URLs in repository configuration, where a password or token can be read by other processes with access to the file.",
                legitNote: "The value may be a placeholder. Prune does not verify credentials or contact the remote.",
                recommendation: "Move authentication into a credential manager or SSH key, update the remote URL, and rotate any exposed credential.",
                actions: [], paths: paths))
        }
        report.stats["credential files"] = filesChecked
        report.stats["environment files"] = envFiles
        if truncated || skippedLarge > 0 || unreadable > 0 {
            var reasons: [String] = []
            if truncated { reasons.append("The 100,000-file or directory limit was reached.") }
            if skippedLarge > 0 { reasons.append("\(skippedLarge) files over 512 KiB were skipped.") }
            if unreadable > 0 { reasons.append("\(unreadable) files or folders could not be read as UTF-8.") }
            report.findings.append(SecurityFinding(id: "credentials:coverage", area: .credentials, severity: .low,
                title: "Credential scan was incomplete", subtitle: "Some project content was not inspected", evidence: reasons,
                explanation: "Prune limits file size and scan work to keep the check responsive.", legitNote: nil,
                recommendation: "Inspect skipped or inaccessible content separately if it may contain secrets.", actions: []))
        }
    }
}
