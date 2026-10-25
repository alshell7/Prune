import Foundation

// MARK: - npm & Python packages

enum PackageAnalyzer {
    /// Versions published by attackers in well-documented npm compromises. Offline baseline; the OSV check covers newer incidents.
    static let compromised: [String: (Set<String>, String)] = {
        var m: [String: (Set<String>, String)] = [:]
        func add(_ incident: String, _ list: [(String, [String])]) { for (n, v) in list { m[n] = (Set(v).union(m[n]?.0 ?? []), incident) } }
        add("Sept 2025 hijack of popular color/debug packages (crypto-wallet stealer)", [
            ("chalk", ["5.6.1"]), ("debug", ["4.4.2"]), ("ansi-styles", ["6.2.2"]), ("supports-color", ["10.2.1"]), ("strip-ansi", ["7.1.1"]),
            ("ansi-regex", ["6.2.1"]), ("wrap-ansi", ["9.0.1"]), ("color-convert", ["3.1.1"]), ("color-name", ["2.0.1"]), ("is-arrayish", ["0.3.3"]),
            ("slice-ansi", ["7.1.1"]), ("color", ["5.0.1"]), ("color-string", ["2.1.1"]), ("simple-swizzle", ["0.2.3"]), ("supports-hyperlinks", ["4.1.1"]),
            ("has-ansi", ["6.0.1"]), ("chalk-template", ["1.1.1"]), ("backslash", ["0.2.1"]), ("error-ex", ["1.3.3"]),
            ("duckdb", ["1.3.3"]), ("@duckdb/node-api", ["1.3.3"]), ("@duckdb/node-bindings", ["1.3.3"]), ("@duckdb/duckdb-wasm", ["1.29.2"]),
        ])
        add("Sept 2025 \u{201C}Shai-Hulud\u{201D} self-spreading npm worm (steals tokens with trufflehog)", [("@ctrl/tinycolor", ["4.1.1", "4.1.2"])])
        add("Aug 2025 nx \u{201C}s1ngularity\u{201D} compromise (abused AI CLIs to steal secrets)", [
            ("nx", ["20.9.0", "20.10.0", "20.11.0", "20.12.0", "21.5.0", "21.6.0", "21.7.0", "21.8.0"]),
            ("@nx/devkit", ["20.9.0", "21.5.0"]), ("@nx/js", ["20.9.0", "21.5.0"]), ("@nx/workspace", ["20.9.0", "21.5.0"]),
            ("@nx/node", ["20.9.0", "21.5.0"]), ("@nx/eslint", ["21.5.0"]), ("@nx/key", ["3.2.0"]), ("@nx/enterprise-cloud", ["3.2.0"]),
        ])
        add("July 2025 eslint-config-prettier / \u{201C}Scavenger\u{201D} compromise", [
            ("eslint-config-prettier", ["8.10.1", "9.1.1", "10.1.6", "10.1.7"]), ("eslint-plugin-prettier", ["4.2.2", "4.2.3"]),
            ("synckit", ["0.11.9"]), ("@pkgr/core", ["0.2.8"]), ("napi-postinstall", ["0.3.1"]), ("is", ["3.3.1", "5.0.0"]), ("got-fetch", ["5.1.11", "5.1.12"]),
        ])
        add("Dec 2024 compromises (@solana/web3.js key stealer, rspack miner)", [
            ("@solana/web3.js", ["1.95.6", "1.95.7"]), ("@rspack/core", ["1.1.7"]), ("@rspack/cli", ["1.1.7"]),
        ])
        add("Oct 2024 @lottiefiles/lottie-player wallet drainer", [("@lottiefiles/lottie-player", ["2.0.5", "2.0.6", "2.0.7"])])
        add("2022 protestware / sabotage", [("node-ipc", ["9.2.2", "10.1.1", "10.1.2", "10.1.3"]), ("colors", ["1.4.1", "1.4.2", "1.4.44-liberty-2"]), ("faker", ["6.6.6"])])
        add("2021 hijacks (password stealer + miner)", [("ua-parser-js", ["0.7.29", "0.8.0", "1.0.0"]), ("coa", ["2.0.3", "2.0.4", "2.1.1", "2.1.3", "3.0.1", "3.1.3"]), ("rc", ["1.2.9", "1.3.9", "2.3.9"])])
        add("2018 event-stream backdoor", [("event-stream", ["3.3.6"]), ("flatmap-stream", ["0.1.1"])])
        return m
    }()

    static let popular = ["react", "react-dom", "express", "lodash", "axios", "chalk", "commander", "webpack", "typescript", "eslint", "prettier", "moment",
                          "dotenv", "request", "jquery", "vue", "next", "nodemon", "mongoose", "socket.io", "uuid", "redux", "yargs", "inquirer", "debug",
                          "body-parser", "cors", "jsonwebtoken", "bcrypt", "passport", "babel-core", "electron", "puppeteer", "playwright", "vite",
                          "tailwindcss", "postcss", "autoprefixer", "classnames", "date-fns", "dayjs", "zod", "prisma", "sequelize", "knex", "pg", "mysql",
                          "mysql2", "redis", "ioredis", "nodemailer", "sharp", "cheerio", "node-fetch", "cross-env", "rimraf", "glob", "minimist", "semver",
                          "colors", "ethers", "web3", "openai", "anthropic", "langchain", "discord.js", "telegraf", "firebase", "stripe", "aws-sdk"]

    struct Pkg { var name: String; var version: String; var dir: URL; var json: [String: Any] }

    static func enumerate(nodeModules: URL, into out: inout [Pkg], depth: Int = 0) {
        guard depth < 6 else { return }
        for c in FS.children(nodeModules) where !FS.isSymlink(c) {
            let n = c.lastPathComponent
            if n == ".pnpm" {
                for store in FS.childDirs(c) { enumerate(nodeModules: store.appendingPathComponent("node_modules"), into: &out, depth: depth + 1) }
            } else if n.hasPrefix("@") {
                for s in FS.childDirs(c) where !FS.isSymlink(s) { add(s, &out, depth) }
            } else if !n.hasPrefix(".") && FS.isDir(c) {
                add(c, &out, depth)
            }
        }
    }

    private static func add(_ dir: URL, _ out: inout [Pkg], _ depth: Int) {
        if let json = FS.readJSON(dir.appendingPathComponent("package.json")) as? [String: Any],
           let name = json["name"] as? String, let version = json["version"] as? String {
            out.append(Pkg(name: name, version: version, dir: dir, json: json))
        }
        let nested = dir.appendingPathComponent("node_modules")
        if FS.isDir(nested) { enumerate(nodeModules: nested, into: &out, depth: depth + 1) }
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...max(b.count, 1) where !b.isEmpty {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }

    static func scan(nodeModulesDirs: [URL], sitePackages: [URL], report: inout SecurityReport) {
        var pkgs: [Pkg] = []
        for nm in nodeModulesDirs { enumerate(nodeModules: nm, into: &pkgs) }
        report.stats["npm packages"] = pkgs.count

        // Group installs of the same name@version.
        var groups: [String: [Pkg]] = [:]
        for p in pkgs { groups["\(p.name)@\(p.version)", default: []].append(p) }
        report.npmPackages = groups.mapValues { $0.map(\.dir.path) }
        let lock = NSLock()
        var findings: [SecurityFinding] = []
        let keys = Array(groups.keys)
        DispatchQueue.concurrentPerform(iterations: keys.count) { i in
            guard let list = groups[keys[i]], let p = list.first else { return }
            if let f = evaluate(p, copies: list) { lock.lock(); findings.append(f); lock.unlock() }
        }
        report.findings += findings
        pythonPth(sitePackages, &report)
    }

    static func evaluate(_ p: Pkg, copies: [Pkg]) -> SecurityFinding? {
        var score = 0
        var evidence: [String] = []
        var incident: String?
        if let (bad, what) = compromised[p.name], bad.contains(p.version) {
            score += 10; incident = what
            evidence.append("\(p.name)@\(p.version) is a known malicious release: \(what).")
        }
        let scripts = (p.json["scripts"] as? [String: Any]) ?? [:]
        var lifecycle: [String] = []
        for key in ["preinstall", "install", "postinstall"] { if let s = scripts[key] as? String { lifecycle.append("\(key): \(s)") } }
        var body = lifecycle.joined(separator: "\n")
        if !lifecycle.isEmpty {
            // Follow the script into the file it runs.
            for token in body.components(separatedBy: CharacterSet(charactersIn: " ;&|\"'")) where token.hasSuffix(".js") || token.hasSuffix(".cjs") || token.hasSuffix(".mjs") || token.hasSuffix(".sh") || token.hasSuffix(".py") {
                if let text = FS.readText(p.dir.appendingPathComponent(token), limit: 3_000_000) { body += "\n" + text }
            }
            let hits = RedFlags.scan(body)
            let s = RedFlags.score(hits)
            if s >= 3 { score += s; evidence.append("Runs code automatically when installed (\(lifecycle.map { String($0.prefix(80)) }.joined(separator: "; ")))."); evidence += RedFlags.evidence(hits) }
        }
        // Shai-Hulud: a large bundle.js that runs trufflehog.
        let bundle = p.dir.appendingPathComponent("bundle.js")
        if FS.exists(bundle), let text = FS.readText(bundle, limit: 6_000_000), text.contains("trufflehog") {
            score += 10; evidence.append("Contains bundle.js that downloads and runs trufflehog, the Shai-Hulud worm payload.")
        }
        // Typosquat: one letter away from a very popular package.
        if !p.name.hasPrefix("@"), p.name.count >= 5, !popular.contains(p.name),
           let near = popular.first(where: { abs($0.count - p.name.count) <= 1 && levenshtein($0, p.name) == 1 }) {
            score += lifecycle.isEmpty ? 2 : 4
            evidence.append("Name is one letter away from the popular package \u{201C}\(near)\u{201D}, a typosquatting pattern.")
        }
        let sev = Severity.from(score: score)
        guard sev >= .medium else { return nil }
        let locations = copies.map(\.dir.path)
        return SecurityFinding(
            id: "npm:\(p.name)@\(p.version)", area: .packages, severity: sev, title: "\(p.name)@\(p.version)",
            subtitle: "npm package · \(copies.count) install\(copies.count == 1 ? "" : "s")" + (incident.map { " · \($0)" } ?? ""),
            evidence: evidence + ["Installed in: " + locations.prefix(4).map { FS.tildePath(URL(fileURLWithPath: $0)) }.joined(separator: ", ") + (locations.count > 4 ? " +\(locations.count - 4) more" : "")],
            explanation: "npm runs a package's install scripts with your user's permissions the moment it's installed. That's how most npm malware steals tokens and wallets.",
            legitNote: incident == nil ? "Native modules legitimately run build scripts, but these patterns go beyond building." : nil,
            recommendation: incident != nil
                ? "Quarantine it, pin a safe version in package.json, delete the lockfile entry and reinstall. If its install script ran, rotate npm, GitHub and cloud tokens."
                : "Quarantine it and check where it came from (`npm explain \(p.name)`). If its install script ran, rotate tokens used on this Mac.",
            actions: [.quarantine(paths: locations)], paths: locations)
    }

    /// Python runs `import` lines in .pth files on every interpreter start, a quiet persistence trick.
    static func pythonPth(_ sitePackages: [URL], _ report: inout SecurityReport) {
        let danger = try! NSRegularExpression(pattern: #"exec\(|eval\(|base64|b64decode|urllib|urlopen|requests\.|socket|subprocess|marshal\.loads|__import__\(['"]os"#, options: [.caseInsensitive])
        for sp in sitePackages {
            for f in FS.children(sp) where f.pathExtension == "pth" {
                guard let text = FS.readText(f, limit: 512 * 1024) else { continue }
                let exec = text.components(separatedBy: "\n").filter { $0.hasPrefix("import ") || $0.hasPrefix("import\t") }
                let bad = exec.filter { danger.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
                guard !bad.isEmpty else { continue }
                report.findings.append(SecurityFinding(
                    id: "pth:\(f.path)", area: .packages, severity: .high, title: f.lastPathComponent, subtitle: "Python startup hook in \(FS.tildePath(sp))",
                    evidence: bad.prefix(3).map { "\u{201C}\($0.prefix(160))\u{201D}" },
                    explanation: "Lines starting with `import` in .pth files run every time this Python starts, before your code. Malicious packages use this to persist.",
                    legitNote: "Coverage tools and editable installs use .pth hooks, but they don't decode or download code.",
                    recommendation: "Quarantine the .pth file, then find and remove the package that installed it.",
                    actions: [.quarantine(paths: [f.path])], paths: [f.path]))
            }
        }
    }

    /// Online check against OSV.dev (OpenSSF malicious-packages feed). Sends only package names and versions.
    static func osvMalicious(_ items: [(String, String)]) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for chunk in stride(from: 0, to: items.count, by: 500).map({ Array(items[$0..<min($0 + 500, items.count)]) }) {
            let body: [String: Any] = ["queries": chunk.map { ["package": ["name": $0.0, "ecosystem": "npm"], "version": $0.1] }]
            guard let data = try? JSONSerialization.data(withJSONObject: body) else { continue }
            var req = URLRequest(url: URL(string: "https://api.osv.dev/v1/querybatch")!)
            req.httpMethod = "POST"
            req.httpBody = data
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 30
            let sem = DispatchSemaphore(value: 0)
            var response: Data?
            URLSession.shared.dataTask(with: req) { d, _, _ in response = d; sem.signal() }.resume()
            sem.wait()
            guard let response, let json = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else { continue }
            for (i, r) in results.enumerated() where i < chunk.count {
                let ids = ((r["vulns"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }.filter { $0.hasPrefix("MAL-") }
                if !ids.isEmpty { result["\(chunk[i].0)@\(chunk[i].1)"] = ids }
            }
        }
        return result
    }
}

// MARK: - AI agents: hooks, MCP servers, skills, rule files

enum AIToolsAnalyzer {
    struct MCPServer { var name: String; var command: String; var args: [String]; var url: String?; var env: [String: String]; var file: String; var path: [String]; var tool: String; var key = "mcpServers" }

    static func scan(projectRoots: [URL], report: inout SecurityReport) {
        let h = FS.home
        // Hooks
        var hookFiles = [h.appendingPathComponent(".claude/settings.json"), h.appendingPathComponent(".claude/settings.local.json")]
        for r in projectRoots { hookFiles += [r.appendingPathComponent(".claude/settings.json"), r.appendingPathComponent(".claude/settings.local.json")] }
        for f in hookFiles {
            guard let json = FS.readJSON(f) as? [String: Any], let hooks = json["hooks"] as? [String: Any] else { continue }
            // Committed project settings (not settings.local.json) come from whoever wrote the repo.
            let projectLevel = !f.path.hasPrefix(h.appendingPathComponent(".claude").path) && f.lastPathComponent == "settings.json"
            for (event, groups) in hooks {
                for g in (groups as? [[String: Any]]) ?? [] {
                    for hook in (g["hooks"] as? [[String: Any]]) ?? [] {
                        guard let cmd = hook["command"] as? String else { continue }
                        var text = cmd
                        for token in cmd.components(separatedBy: " ") where token.hasPrefix("/") || token.hasPrefix("~") || token.hasPrefix("./") || token.hasPrefix("$CLAUDE_PROJECT_DIR") {
                            let p = token.replacingOccurrences(of: "$CLAUDE_PROJECT_DIR", with: f.deletingLastPathComponent().deletingLastPathComponent().path)
                            if let t = FS.readText(URL(fileURLWithPath: (p as NSString).expandingTildeInPath), limit: 1_000_000) { text += "\n" + t }
                        }
                        let hits = RedFlags.scan(text)
                        var score = RedFlags.score(hits) + (projectLevel ? 1 : 0)
                        if projectLevel && score >= 3 { score += 2 }
                        let sev = Severity.from(score: score)
                        let id = "hook:\(f.path):\(event):\(cmd.hashValue)"
                        report.chains[id] = [ChainNode(kind: "Claude Code", label: event, detail: projectLevel ? "from this project" : "your settings", risky: projectLevel),
                                             ChainNode(kind: "Runs", label: String(cmd.prefix(50)), detail: cmd, risky: score >= 3)]
                        report.findings.append(SecurityFinding(
                            id: id, area: .aiTools, severity: sev, title: "Claude Code hook: \(event)", subtitle: FS.tildePath(f),
                            evidence: RedFlags.evidence(hits) + (projectLevel ? ["Defined by the project, so it runs for anyone who opens this repo in Claude Code."] : []),
                            explanation: "Hooks run shell commands automatically around Claude Code actions. Command: \(cmd)",
                            legitNote: "Formatters, linters and notifications are common, harmless hooks.",
                            recommendation: sev >= .medium ? "Remove the hook unless you added it yourself." : "Nothing suspicious found.",
                            actions: [.removeJSONEntry(file: f.path, entry: JSONEntryRef(kind: .hookCommand, path: ["hooks"], key: event, command: cmd))],
                            paths: [f.path], inventoryOnly: sev == .info))
                    }
                }
            }
        }

        // MCP servers
        var servers: [MCPServer] = []
        func jsonServers(_ file: URL, key: String, tool: String) {
            guard let json = FS.readJSON(file) as? [String: Any] else { return }
            func collect(_ dict: [String: Any], _ path: [String]) {
                for (name, v) in dict {
                    guard let s = v as? [String: Any] else { continue }
                    servers.append(MCPServer(name: name, command: s["command"] as? String ?? "", args: (s["args"] as? [String]) ?? [],
                                             url: (s["url"] as? String) ?? (s["serverUrl"] as? String), env: (s["env"] as? [String: String]) ?? [:],
                                             file: file.path, path: path, tool: tool, key: key))
                }
            }
            if let top = json[key] as? [String: Any] { collect(top, []) }
            if let projects = json["projects"] as? [String: Any] {
                for (proj, v) in projects { if let m = (v as? [String: Any])?[key] as? [String: Any] { collect(m, ["projects", proj]) } }
            }
        }
        jsonServers(h.appendingPathComponent(".claude.json"), key: "mcpServers", tool: "Claude Code")
        jsonServers(h.appendingPathComponent(".cursor/mcp.json"), key: "mcpServers", tool: "Cursor")
        jsonServers(h.appendingPathComponent(".gemini/settings.json"), key: "mcpServers", tool: "Gemini CLI")
        jsonServers(h.appendingPathComponent(".codeium/windsurf/mcp_config.json"), key: "mcpServers", tool: "Windsurf")
        jsonServers(h.appendingPathComponent("Library/Application Support/Code/User/mcp.json"), key: "servers", tool: "VS Code")
        jsonServers(h.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json"), key: "mcpServers", tool: "Claude Desktop")
        for r in projectRoots {
            jsonServers(r.appendingPathComponent(".mcp.json"), key: "mcpServers", tool: "Claude Code (project)")
            jsonServers(r.appendingPathComponent(".cursor/mcp.json"), key: "mcpServers", tool: "Cursor (project)")
            jsonServers(r.appendingPathComponent(".vscode/mcp.json"), key: "servers", tool: "VS Code (project)")
        }
        // Codex TOML: [mcp_servers.name] blocks with command/args/url.
        if let toml = FS.readText(h.appendingPathComponent(".codex/config.toml")) {
            var current: MCPServer?
            for line in toml.components(separatedBy: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("[") {
                    if let c = current { servers.append(c) }
                    current = nil
                    if let m = Requirements.captures(#"^\[mcp_servers\.([^\].]+)\]$"#, t, options: []).first {
                        current = MCPServer(name: m.trimmingCharacters(in: CharacterSet(charactersIn: "\"")), command: "", args: [], url: nil, env: [:],
                                            file: h.appendingPathComponent(".codex/config.toml").path, path: [], tool: "Codex")
                    }
                } else if current != nil {
                    if let v = Requirements.captures(#"^command\s*=\s*"(.*)"$"#, t, options: []).first { current?.command = v }
                    if let v = Requirements.captures(#"^url\s*=\s*"(.*)"$"#, t, options: []).first { current?.url = v }
                    if t.hasPrefix("args") { current?.args = Requirements.captures(#""([^"]*)""#, t, options: []) }
                }
            }
            if let c = current { servers.append(c) }
        }
        for s in servers { report.findings.append(evaluate(s, &report)) }

        // Skills & plugins
        var skillDirs: [URL] = []
        for base in [".claude/skills", ".agents/skills", ".codex/skills", ".cursor/skills", ".gemini/skills"] { skillDirs += FS.childDirs(h.appendingPathComponent(base)) }
        for r in projectRoots { skillDirs += FS.childDirs(r.appendingPathComponent(".claude/skills")) }
        let pluginRoot = h.appendingPathComponent(".claude/plugins")
        if let e = FileManager.default.enumerator(at: pluginRoot, includingPropertiesForKeys: nil) {
            while let u = e.nextObject() as? URL { if u.lastPathComponent == "skills", FS.isDir(u) { skillDirs += FS.childDirs(u) } }
        }
        for dir in skillDirs { report.findings.append(evaluateSkill(dir, &report)) }

        // Instruction/rule files inside projects.
        let ruleNames = ["CLAUDE.md", "AGENTS.md", "GEMINI.md", ".cursorrules", ".windsurfrules", ".github/copilot-instructions.md"]
        for r in projectRoots {
            var files = ruleNames.map { r.appendingPathComponent($0) }.filter(FS.exists)
            files += FS.children(r.appendingPathComponent(".cursor/rules")).filter { $0.pathExtension == "mdc" || $0.pathExtension == "md" }
            for f in files {
                guard let text = FS.readText(f, limit: 2_000_000) else { continue }
                let hidden = RedFlags.hiddenUnicode(text)
                let injections = RedFlags.injection.matches(in: text, range: NSRange(text.startIndex..., in: text))
                    .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
                var score = 0
                var ev: [String] = []
                if hidden.kinds.contains("Unicode tag characters (invisible ASCII)") || hidden.kinds.contains("bidirectional overrides") { score += 7 }
                else if hidden.count > 20 { score += 3 }
                if hidden.count > 0 { ev.append("\(hidden.count) invisible character(s): \(hidden.kinds.sorted().joined(separator: ", ")). They can hide instructions from you that the AI still reads.") }
                if !injections.isEmpty { score += 4; ev += injections.prefix(3).map { "Instruction: \u{201C}\($0.prefix(100))\u{201D}" } }
                guard score >= 3 else { continue }
                report.findings.append(SecurityFinding(
                    id: "rules:\(f.path)", area: .aiTools, severity: Severity.from(score: score), title: "AI instructions in \(r.lastPathComponent)/\(f.lastPathComponent)",
                    subtitle: "Read automatically by coding agents", evidence: ev,
                    explanation: "Agents follow instruction files like CLAUDE.md and .cursorrules without asking. Hidden characters or \u{201C}ignore previous instructions\u{201D} phrasing are prompt-injection tricks (\u{201C}rules file backdoor\u{201D}).",
                    legitNote: "Emoji and some languages use zero-width joiners legitimately.",
                    recommendation: "Open the file in a hex-aware editor, remove the hidden text, and be wary of the repo it came from.",
                    actions: [.quarantine(paths: [f.path])], paths: [f.path]))
            }
        }
    }

    static func evaluate(_ s: MCPServer, _ report: inout SecurityReport) -> SecurityFinding {
        let cmdline = ([s.command] + s.args).joined(separator: " ")
        var score = 0
        var ev: [String] = []
        let hits = RedFlags.scan(cmdline + " " + s.env.values.joined(separator: " "))
        score += RedFlags.score(hits); ev += RedFlags.evidence(hits)
        let base = (s.command as NSString).lastPathComponent
        if base == "npx" || base == "bunx" || base == "pnpx" {
            if let pkg = s.args.first(where: { !$0.hasPrefix("-") }), !pkg.dropFirst().contains("@") {
                score += 1; ev.append("Runs \u{201C}\(pkg)\u{201D} through \(base) without a pinned version, so whatever was published last runs each time.")
            }
        }
        if base == "uvx" || base == "pipx", let pkg = s.args.first(where: { !$0.hasPrefix("-") }) {
            if pkg.hasPrefix("git+") && !pkg.contains("@") { score += 1; ev.append("Runs the latest commit of \(pkg) on every launch, unpinned.") }
            else if !pkg.contains("==") && !pkg.hasPrefix("git+") { score += 1; ev.append("Runs \u{201C}\(pkg)\u{201D} without a pinned version.") }
        }
        let secretKeys = s.env.keys.filter { $0.range(of: "TOKEN|KEY|SECRET|PASSWORD", options: [.regularExpression, .caseInsensitive]) != nil && !(s.env[$0] ?? "").hasPrefix("$") }
        if !secretKeys.isEmpty { score += 1; ev.append("Secrets stored in plain text in the config: \(secretKeys.joined(separator: ", ")).") }
        if s.tool.contains("project") { score += 1; ev.append("Defined by a project, so cloning a repo can add it.") }
        let sev = Severity.from(score: score)
        let id = "mcp:\(s.file):\(s.path.joined(separator: "/")):\(s.name)"
        report.chains[id] = [ChainNode(kind: s.tool, label: "MCP server", detail: FS.tildePath(URL(fileURLWithPath: s.file)), risky: false),
                             ChainNode(kind: "Server", label: s.name, detail: "", risky: false),
                             ChainNode(kind: s.url != nil ? "Connects to" : "Runs", label: s.url.flatMap { URL(string: $0)?.host } ?? String(cmdline.prefix(50)), detail: s.url ?? cmdline, risky: score >= 3)]
        let editable = s.file.hasSuffix(".json")
        return SecurityFinding(
            id: id, area: .aiTools, severity: sev, title: "MCP server \u{201C}\(s.name)\u{201D}", subtitle: s.tool + (s.url.map { " · \($0)" } ?? " · \(cmdline.prefix(70))"),
            evidence: ev, explanation: "MCP servers give an AI agent tools. Local ones run as programs with your permissions; remote ones receive what the agent sends them.",
            legitNote: "Unpinned servers from well-known publishers are common. Pinning just makes updates deliberate.",
            recommendation: sev >= .medium ? "Remove it unless you set it up yourself." : (score > 0 ? "Consider pinning a version." : "Nothing suspicious found."),
            actions: editable ? [.removeJSONEntry(file: s.file, entry: JSONEntryRef(kind: .mcpServer, path: s.path + [s.key], key: s.name))] : [],
            paths: [s.file], inventoryOnly: sev == .info)
    }

    static func evaluateSkill(_ dir: URL, _ report: inout SecurityReport) -> SecurityFinding {
        // Judge each file on its own, then take the worst file (plus a little for repeated issues):
        // summing across a hundred harmless files would make any big skill look dangerous.
        var fileScores: [Int] = []
        var ev: [String] = []
        var files = 0
        var scripts = 0
        if let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) {
            while let u = e.nextObject() as? URL {
                guard !FS.isDir(u) else { continue }
                files += 1
                let ext = u.pathExtension.lowercased()
                let rel = String(u.path.dropFirst(dir.path.count + 1))
                if ExecutableKind.isMachO(u.path) {
                    let sig = CodeSigning.check(u.path)
                    if sig.isAnonymous || sig.trust == .invalid { fileScores.append(4); ev.append("\(rel): bundled program, \(sig.label).") }
                    continue
                }
                guard let text = FS.readText(u, limit: 3_000_000) else { continue }
                var s = 0
                if ["md", "mdc", "txt"].contains(ext) {
                    let hidden = RedFlags.hiddenUnicode(text)
                    if hidden.kinds.contains("Unicode tag characters (invisible ASCII)") || hidden.kinds.contains("bidirectional overrides") {
                        s += 7; ev.append("\(rel): \(hidden.count) invisible characters (\(hidden.kinds.sorted().joined(separator: ", "))) that hide instructions from you.")
                    }
                    let inj = RedFlags.injection.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
                    if !inj.isEmpty { s += 4; ev.append("\(rel): \u{201C}\(inj[0].prefix(100))\u{201D}") }
                    let hits = RedFlags.scan(text).filter { $0.weight >= 5 }
                    if !hits.isEmpty { s += RedFlags.score(hits); ev += RedFlags.evidence(hits).map { "\(rel): \($0)" } }
                } else if ["sh", "bash", "zsh", "py", "js", "mjs", "cjs", "ts", "rb", "pl"].contains(ext) || ExecutableKind.isScript(u.path) {
                    scripts += 1
                    let hits = RedFlags.scan(text)
                    let fs = RedFlags.score(hits)
                    if fs >= 3 { s += fs; ev += RedFlags.evidence(hits).map { "\(rel): \($0)" } }
                }
                if s > 0 { fileScores.append(s) }
            }
        }
        let worst = fileScores.max() ?? 0
        let score = worst + min(2, max(0, fileScores.filter { $0 >= 3 }.count - 1))
        let sev = Severity.from(score: score)
        let id = "skill:\(dir.path)"
        report.chains[id] = [ChainNode(kind: "Agent skill", label: dir.lastPathComponent, detail: FS.tildePath(dir.deletingLastPathComponent()), risky: false),
                             ChainNode(kind: "Contains", label: "\(files) files, \(scripts) scripts", detail: "", risky: scripts > 0 && score >= 3)]
        return SecurityFinding(
            id: id, area: .aiTools, severity: sev, title: "Skill \u{201C}\(dir.lastPathComponent)\u{201D}", subtitle: "\(FS.tildePath(dir.deletingLastPathComponent())) · \(files) files · \(scripts) scripts",
            evidence: ev, explanation: "Skills are instructions plus optional scripts an AI agent loads and may run with your permissions. Third-party skills are a new supply-chain channel.",
            legitNote: "Scripts that drive a browser or call an API are normal for many skills.",
            recommendation: sev >= .medium ? "Quarantine it and reinstall only from a source you trust." : "Nothing suspicious found.",
            actions: [.quarantine(paths: [dir.path])], paths: [dir.path], inventoryOnly: sev == .info)
    }
}

// MARK: - Code that runs when you open or build a project

enum ProjectThreatAnalyzer {
    static func stripJSONComments(_ s: String) -> String {
        var out = ""
        var i = s.startIndex
        var inString = false
        while i < s.endIndex {
            let c = s[i]
            let next = s.index(after: i) < s.endIndex ? s[s.index(after: i)] : nil
            if inString {
                out.append(c)
                if c == "\\", let n = next { out.append(n); i = s.index(i, offsetBy: 2); continue }
                if c == "\"" { inString = false }
            } else if c == "\"" { inString = true; out.append(c) }
            else if c == "/" && next == "/" { while i < s.endIndex && s[i] != "\n" { i = s.index(after: i) }; continue }
            else if c == "/" && next == "*" {
                i = s.index(i, offsetBy: 2)
                while i < s.endIndex, !(s[i] == "*" && s.index(after: i) < s.endIndex && s[s.index(after: i)] == "/") { i = s.index(after: i) }
                if i < s.endIndex { i = s.index(i, offsetBy: 2) }
                continue
            } else { out.append(c) }
            i = s.index(after: i)
        }
        return out.replacingOccurrences(of: #",(\s*[\]}])"#, with: "$1", options: .regularExpression)
    }

    static func scan(projectRoots: [URL], report: inout SecurityReport) {
        for r in projectRoots {
            // VS Code tasks that run as soon as the folder is opened.
            let tasksFile = r.appendingPathComponent(".vscode/tasks.json")
            if let raw = FS.readText(tasksFile, limit: 1_000_000),
               let json = try? JSONSerialization.jsonObject(with: Data(stripJSONComments(raw).utf8)) as? [String: Any] {
                for t in (json["tasks"] as? [[String: Any]]) ?? [] where ((t["runOptions"] as? [String: Any])?["runOn"] as? String) == "folderOpen" {
                    let cmd = ([t["command"] as? String ?? ""] + ((t["args"] as? [Any]) ?? []).map { "\($0)" }).joined(separator: " ")
                    let hits = RedFlags.scan(cmd)
                    let score = 3 + RedFlags.score(hits) + (cmd.contains("node ") || cmd.contains("npm ") ? 1 : 0)
                    let id = "vstask:\(tasksFile.path):\(t["label"] as? String ?? "")"
                    report.chains[id] = [ChainNode(kind: "Open folder in", label: "VS Code / Cursor", detail: r.lastPathComponent, risky: false),
                                         ChainNode(kind: "Auto-runs task", label: t["label"] as? String ?? "task", detail: "", risky: true),
                                         ChainNode(kind: "Command", label: String(cmd.prefix(50)), detail: cmd, risky: !hits.isEmpty)]
                    report.findings.append(SecurityFinding(
                        id: id, area: .projects, severity: Severity.from(score: score), title: "Auto-run task in \(r.lastPathComponent)",
                        subtitle: ".vscode/tasks.json runs on folder open", evidence: ["Runs: \u{201C}\(cmd.prefix(200))\u{201D}"] + RedFlags.evidence(hits),
                        explanation: "VS Code-family editors can run this task automatically when the folder opens. Fake job-interview repositories (the \u{201C}Contagious Interview\u{201D} campaign) use exactly this to infect developers.",
                        legitNote: "Some teams auto-start a dev server this way.", recommendation: "Quarantine tasks.json unless your team set this up, and don't trust the folder in your editor.",
                        actions: [.quarantine(paths: [tasksFile.path])], paths: [tasksFile.path]))
                }
            }
            // Git hooks that aren't samples.
            for hook in FS.children(r.appendingPathComponent(".git/hooks")) where hook.pathExtension != "sample" && !FS.isDir(hook) {
                guard let text = FS.readText(hook, limit: 512 * 1024) else { continue }
                let hits = RedFlags.scan(text)
                let s = RedFlags.score(hits)
                guard s >= 3 else { continue }
                report.findings.append(SecurityFinding(
                    id: "githook:\(hook.path)", area: .projects, severity: Severity.from(score: s + 1), title: "Git hook \(hook.lastPathComponent) in \(r.lastPathComponent)",
                    subtitle: "Runs on every \(hook.lastPathComponent.replacingOccurrences(of: "-", with: " "))", evidence: RedFlags.evidence(hits),
                    explanation: "Git runs hook scripts automatically during commits, checkouts and merges.", legitNote: "Linters and formatters are common hooks.",
                    recommendation: "Quarantine the hook if you didn't add it.", actions: [.quarantine(paths: [hook.path])], paths: [hook.path]))
            }
            // Install scripts in your own package.json.
            if let pkg = FS.readJSON(r.appendingPathComponent("package.json")) as? [String: Any], let scripts = pkg["scripts"] as? [String: Any] {
                var body = ""
                for k in ["preinstall", "install", "postinstall", "prepare"] { if let s = scripts[k] as? String { body += "\(k): \(s)\n" } }
                for token in body.components(separatedBy: CharacterSet(charactersIn: " ;&|\"'\n")) where token.hasSuffix(".js") || token.hasSuffix(".cjs") || token.hasSuffix(".sh") {
                    if let t = FS.readText(r.appendingPathComponent(token), limit: 2_000_000) { body += t }
                }
                let hits = RedFlags.scan(body)
                let s = RedFlags.score(hits)
                if s >= 4 {
                    report.findings.append(SecurityFinding(
                        id: "projscript:\(r.path)", area: .projects, severity: Severity.from(score: s + 1), title: "Install script in \(r.lastPathComponent)",
                        subtitle: "Runs on npm install", evidence: RedFlags.evidence(hits),
                        explanation: "This project's own package.json runs code when someone runs `npm install`. Malicious sample projects shared in fake job interviews do this.",
                        legitNote: "Build tooling (husky, patch-package) is common here.", recommendation: "Read the script before running npm install. Don't run it if you don't trust the source.",
                        actions: [], paths: [r.appendingPathComponent("package.json").path]))
                }
            }
            // Xcode build phases (XCSSET infects .xcodeproj files).
            for proj in FS.childDirs(r) + FS.childDirs(r.appendingPathComponent("ios")) where proj.pathExtension == "xcodeproj" {
                guard let pbx = FS.readText(proj.appendingPathComponent("project.pbxproj"), limit: 8_000_000) else { continue }
                let scripts = Requirements.captures(#"shellScript = "((?:[^"\\]|\\.)*)";"#, pbx, options: [])
                let hits = RedFlags.scan(scripts.joined(separator: "\n").replacingOccurrences(of: "\\n", with: "\n")).filter { $0.weight >= 4 }
                let s = RedFlags.score(hits)
                guard s >= 4 else { continue }
                report.findings.append(SecurityFinding(
                    id: "xcode:\(proj.path)", area: .projects, severity: Severity.from(score: s + 2), title: "Build-phase script in \(proj.lastPathComponent)",
                    subtitle: "Runs on every Xcode build", evidence: RedFlags.evidence(hits),
                    explanation: "Xcode runs \u{201C}Run Script\u{201D} phases on every build. The XCSSET malware spreads by injecting download-and-run scripts into Xcode projects.",
                    legitNote: "SwiftLint, Crashlytics and CocoaPods add normal build scripts.",
                    recommendation: "Open the project's Build Phases and inspect the script before building again.", actions: [], paths: [proj.path]))
            }
        }
    }
}
