import Foundation

enum Severity: Int, Comparable, CaseIterable, Codable {
    case info = 0, low, medium, high, critical
    static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    var label: String { ["Info", "Low", "Medium", "High", "Critical"][rawValue] }

    static func from(score: Int) -> Severity {
        switch score {
        case ..<1: .info
        case 1...2: .low
        case 3...4: .medium
        case 5...7: .high
        default: .critical
        }
    }
}

enum SecurityArea: String, CaseIterable, Codable {
    case persistence = "Background items"
    case processes = "Running processes"
    case packages = "Packages (npm, Python)"
    case aiTools = "AI agents, skills & MCP"
    case projects = "Project auto-run code"
    case credentials = "Project credentials"
    case browser = "Browser extensions"
    case system = "System settings"
    case files = "Hidden executables"

    var icon: String {
        switch self {
        case .persistence: "clock.arrow.2.circlepath"
        case .processes: "cpu"
        case .packages: "shippingbox"
        case .aiTools: "sparkles"
        case .projects: "hammer"
        case .credentials: "key.fill"
        case .browser: "globe"
        case .system: "lock.shield"
        case .files: "doc.badge.gearshape"
        }
    }
}

/// What Prune can do about a finding. Every action is reversible except stopping a process.
enum SecurityAction: Hashable {
    case stopProcess(pid: Int32, name: String, asRoot: Bool)
    case disableLaunchItem(plist: String, label: String, system: Bool)
    case quarantine(paths: [String])
    case removeJSONEntry(file: String, entry: JSONEntryRef)
    case commentOutLines(file: String, lines: [Int])
    case removeCronLines(lines: [String])
    case openURL(String)

    var title: String {
        switch self {
        case .stopProcess: "Stop process"
        case .disableLaunchItem: "Disable & quarantine"
        case .quarantine: "Quarantine"
        case .removeJSONEntry: "Remove from config"
        case .commentOutLines: "Comment out lines"
        case .removeCronLines: "Remove cron entries"
        case .openURL: "Open Settings"
        }
    }

    var symbol: String {
        switch self {
        case .stopProcess: "stop.circle"
        case .disableLaunchItem: "pause.circle"
        case .quarantine: "lock.doc"
        case .removeJSONEntry: "minus.circle"
        case .commentOutLines: "text.badge.minus"
        case .removeCronLines: "calendar.badge.minus"
        case .openURL: "gearshape"
        }
    }

    var explanation: String {
        switch self {
        case .stopProcess(let pid, let name, let root):
            return "Sends \(name) (pid \(pid)) a polite quit signal, then forces it if needed.\(root ? " Needs your administrator password." : "") It may start again if something relaunches it, so disable its background item too."
        case .disableLaunchItem(let plist, let label, let system):
            return "Unloads \(label) from launchd and moves \(FS.tildePath(URL(fileURLWithPath: plist))) into Prune's quarantine so it can't start again.\(system ? " Needs your administrator password." : "") Restorable from Quarantine."
        case .quarantine(let paths):
            return "Moves \(paths.count == 1 ? FS.tildePath(URL(fileURLWithPath: paths[0])) : "\(paths.count) items") into Prune's quarantine and removes execute permission. Restorable from Quarantine."
        case .removeJSONEntry(let file, let entry):
            return "Removes \(entry.description) from \(FS.tildePath(URL(fileURLWithPath: file))). A backup of the file is kept in Quarantine."
        case .commentOutLines(let file, let lines):
            return "Prefixes line\(lines.count == 1 ? "" : "s") \(lines.map(String.init).joined(separator: ", ")) of \(FS.tildePath(URL(fileURLWithPath: file))) with \"# disabled by Prune: \". A backup is kept in Quarantine."
        case .removeCronLines(let lines):
            return "Removes \(lines.count) line(s) from your crontab. A backup is kept in Quarantine."
        case .openURL:
            return "Opens the relevant System Settings pane."
        }
    }
}

/// Points at a removable entry in a JSON config (an MCP server or a hook command).
struct JSONEntryRef: Hashable, Codable {
    enum Kind: String, Codable { case mcpServer, hookCommand }
    var kind: Kind
    var path: [String]        // object keys leading to the container (e.g. ["projects", "/x", "mcpServers"])
    var key: String           // server name, or hook event name
    var command: String?      // for hooks: the exact command string to drop

    var description: String {
        kind == .mcpServer ? "MCP server \u{201C}\(key)\u{201D}" : "the \(key) hook running \u{201C}\((command ?? "").prefix(60))\u{201D}"
    }
}

struct SecurityFinding: Identifiable, Hashable {
    var id: String
    var area: SecurityArea
    var severity: Severity
    var title: String
    var subtitle: String
    var evidence: [String]
    var explanation: String
    var legitNote: String?
    var recommendation: String
    var actions: [SecurityAction]
    var paths: [String] = []
    var signer: String?
    /// Shown in the inventory even when nothing is wrong (e.g. every background item).
    var inventoryOnly = false
}

/// Pattern engine for scripts, commands and configs. Weights add up; combinations matter more than any single hit.
enum RedFlags {
    struct Rule { var name: String; var weight: Int; var regex: NSRegularExpression }
    struct Hit: Hashable { var name: String; var weight: Int; var excerpt: String }

    private static func r(_ name: String, _ weight: Int, _ pattern: String, caseSensitive: Bool = false) -> Rule {
        Rule(name: name, weight: weight, regex: try! NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive]))
    }

    static let rules: [Rule] = [
        r("Downloads and runs a remote script", 6, #"(curl|wget)[^\n|;]{0,200}\|\s*(sudo\s+)?(ba|z)?sh\b"#),
        r("Downloads and runs a remote script", 6, #"(ba|z)?sh\s+-c\s+["']?\$\((curl|wget)"#),
        r("Decodes a hidden payload and runs it", 6, #"base64\s+(-d|--decode|-D)[^\n]{0,80}\|\s*(ba|z)?sh|eval\s*\(\s*(atob|Buffer\.from)\(|exec\(\s*base64\.b64decode|eval\(base64"#),
        r("Reverse shell", 9, #"/dev/tcp/\d|bash\s+-i\s*>&|\bnc\s+(-e|-c)\s|socket\.socket\([^)]*\)[^\n]{0,200}(subprocess|pty\.spawn)|mkfifo\s+/tmp/"#),
        r("Asks for your password in a fake dialog", 8, #"display dialog[^\n]{0,200}(hidden answer|password)"#),
        r("Reads the macOS keychain", 6, #"security\s+(find-generic-password|find-internet-password|dump-keychain)"#),
        r("Touches browser passwords, cookies or crypto wallets", 4,
          #"(Google/Chrome|BraveSoftware|Microsoft Edge|Chromium|Firefox/Profiles)[^"'\n]{0,80}(Login Data|Cookies|Local State|Web Data|logins\.json|key4\.db)|nkbihfbeogaeaoehlefnkodbefgpgknn|Application Support/(Exodus|Electrum|atomic|Guarda)|Cookies\.binarycookies|login\.keychain-db"#,
          caseSensitive: true),
        r("Reads developer credentials", 2, #"\.ssh/id_(rsa|ed25519|ecdsa)|\.aws/credentials|\.npmrc|\.git-credentials|\.docker/config\.json|\.kube/config|NPM_TOKEN|AWS_SECRET_ACCESS_KEY"#),
        r("Sends data to a paste/webhook/tunnel service", 4, #"webhook\.site|discord(app)?\.com/api/webhooks|pastebin\.com|ngrok(-free)?\.(io|app)|requestbin|pipedream\.net|hastebin|transfer\.sh|api\.telegram\.org/bot|oast\.(fun|me|site)|interact\.sh|burpcollaborator"#),
        r("Runs a secret scanner (supply-chain worm behaviour)", 6, #"trufflehog"#),
        r("Crypto miner", 8, #"xmrig|stratum\+(tcp|ssl)://|cryptonight|--donate-level|\bminerd\b|nicehash"#),
        r("Removes Gatekeeper's quarantine flag", 5, #"xattr\s+(-r\s+)?-(c|d)\s+(-r\s+)?(com\.apple\.quarantine)?"#),
        r("Installs a background item", 4, #"launchctl\s+(load|bootstrap|submit)|LaunchAgents/[^\s"']+\.plist"#),
        r("Drops and runs a binary from a temp folder", 5, #"(/tmp/|/private/tmp/|\$TMPDIR)[^\s"']*[^\n]{0,80}(chmod\s+\+?[0-7]*x|nohup|&\s*$)"#),
        r("Shuts down or wipes the machine", 7, #"sudo\s+shutdown\s+-h|rm\s+-rf\s+(~|\$HOME|/)\s*($|[;&])"#),
        r("Executes code built from obfuscated strings", 5, #"(_0x[0-9a-f]{4,}[\s\S]{0,400}){8,}|String\.fromCharCode\([^)]{200,}\)|\\x[0-9a-f]{2}(\\x[0-9a-f]{2}){60,}"#),
        r("Spawns shell commands from JavaScript", 2, #"require\(\s*['"]child_process['"]\s*\)|from\s+['"]child_process['"]"#),
        r("Makes network requests", 1, #"https?://(?!localhost|127\.0\.0\.1|(www\.)?w3\.org|([a-z0-9-]+\.)*(npmjs\.(org|com)|github\.com|githubusercontent\.com|nodejs\.org|pypi\.org|pythonhosted\.org|huggingface\.co|openai\.com|anthropic\.com|googleapis\.com|google\.com|apple\.com|microsoft\.com|mozilla\.org|json-schema\.org|schema\.org|example\.com|cloudflare\.com|jsdelivr\.net|unpkg\.com|vercel\.app|amazonaws\.com))[a-z0-9.-]+\.[a-z]{2,}"#),
        r("Modifies shell startup files", 4, #">>\s*~?/?[^\s]*\.(zshrc|bashrc|bash_profile|zprofile|profile)\b"#),
        r("Adds an SSH key for remote access", 6, #">>\s*~?/?[^\s]*\.ssh/authorized_keys"#),
        r("Reads environment secrets in bulk", 2, #"process\.env\b(?!\.)|os\.environ\b(?!\.get|\[)|printenv\b|\benv\s*\|"#),
    ]

    static func scan(_ text: String, limit: Int = 2_000_000) -> [Hit] {
        let t = text.count > limit ? String(text.prefix(limit)) : text
        let ns = t as NSString
        var hits: [Hit] = []
        var seen = Set<String>()
        for rule in rules where !seen.contains(rule.name) {
            guard let m = rule.regex.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)) else { continue }
            seen.insert(rule.name)
            let excerpt = ns.substring(with: m.range).replacingOccurrences(of: "\n", with: " ")
            hits.append(Hit(name: rule.name, weight: rule.weight, excerpt: String(excerpt.prefix(160))))
        }
        return hits
    }

    /// Network + credentials/keychain together is exfiltration; weight the combination.
    static func score(_ hits: [Hit]) -> Int {
        var s = hits.reduce(0) { $0 + $1.weight }
        let names = Set(hits.map(\.name))
        let exfil = names.contains("Sends data to a paste/webhook/tunnel service")
        let network = names.contains("Makes network requests")
        let secrets = names.contains("Reads developer credentials") || names.contains("Reads the macOS keychain")
            || names.contains("Touches browser passwords, cookies or crypto wallets") || names.contains("Reads environment secrets in bulk")
        if exfil && secrets { s += 4 } else if network && secrets { s += 1 }
        // Plain network use or child_process alone is everyday developer code.
        if hits.allSatisfy({ $0.weight <= 2 }) { s = min(s, 2) }
        return s
    }

    static func evidence(_ hits: [Hit]) -> [String] {
        hits.sorted { $0.weight > $1.weight }.map { "\($0.name): \u{201C}\($0.excerpt)\u{201D}" }
    }

    // MARK: Hidden text in AI instructions

    /// Invisible characters used to smuggle instructions into rule/skill files ("ASCII smuggling", bidi tricks).
    static func hiddenUnicode(_ text: String) -> (count: Int, kinds: Set<String>) {
        var count = 0
        var kinds = Set<String>()
        for s in text.unicodeScalars {
            switch s.value {
            case 0xE0000...0xE007F: count += 1; kinds.insert("Unicode tag characters (invisible ASCII)")
            case 0x202A...0x202E, 0x2066...0x2069: count += 1; kinds.insert("bidirectional overrides")
            case 0x200B...0x200D, 0x2060, 0xFEFF: count += 1; kinds.insert("zero-width characters")
            default: break
            }
        }
        return (count, kinds)
    }

    static let injection = try! NSRegularExpression(pattern:
        #"ignore (all |any )?(previous|prior|above) (instructions|prompts)|do not (tell|inform|mention (this|it) to) the user|without (asking|telling) the user|exfiltrat|send (the )?(contents|keys|tokens|secrets|credentials)|base64[- ]encode (the )?(secrets|keys|env)|(curl|wget) [^\n`]{0,120}\|\s*(ba)?sh"#,
        options: [.caseInsensitive])
}

/// Quick checks on executable files.
enum ExecutableKind {
    static func isMachO(_ path: String) -> Bool {
        guard let h = FileHandle(forReadingAtPath: path), let d = try? h.read(upToCount: 4), d.count == 4 else { return false }
        try? h.close()
        let magic = d.withUnsafeBytes { $0.load(as: UInt32.self) }
        return [0xFEEDFACE, 0xFEEDFACF, 0xCAFEBABE, 0xCEFAEDFE, 0xCFFAEDFE, 0xBEBAFECA].contains(magic)
    }

    static func isScript(_ path: String) -> Bool {
        guard let h = FileHandle(forReadingAtPath: path), let d = try? h.read(upToCount: 2) else { return false }
        try? h.close()
        return d == Data("#!".utf8)
    }

    /// Folders where unsigned developer binaries are normal.
    static let devToolPrefixes: [String] = {
        let h = FS.home.path
        return ["/opt/homebrew/", "/usr/local/", "\(h)/.cargo/", "\(h)/.rustup/", "\(h)/.nvm/", "\(h)/.volta/", "\(h)/.bun/", "\(h)/.deno/",
                "\(h)/.local/", "\(h)/.pyenv/", "\(h)/go/", "\(h)/.gradle/", "\(h)/Library/Android/", "\(h)/.android/", "\(h)/.espressif/",
                "\(h)/.vscode/", "\(h)/.cursor/", "\(h)/.codex/", "\(h)/.claude/", "\(h)/.docker/", "\(h)/.orbstack/", "\(h)/.npm/",
                "\(h)/Documents/", "\(h)/Developer/", "\(h)/Projects/", "\(h)/.cache/", "/Library/Frameworks/Python.framework/",
                "\(h)/Library/Developer/", "/Applications/Xcode", "\(h)/.tauri/", "\(h)/.expo/", "\(h)/.swiftpm/"]
    }()

    static func inDevTools(_ path: String) -> Bool { devToolPrefixes.contains { path.hasPrefix($0) } }

    /// Locations malware favours: temp folders, shared folders, hidden folders, Downloads.
    static func suspiciousLocation(_ path: String) -> String? {
        let h = FS.home.path
        if path.hasPrefix("/tmp/") || path.hasPrefix("/private/tmp/") || path.hasPrefix("/var/tmp/") || path.hasPrefix("/private/var/tmp/") { return "runs from a temporary folder" }
        if path.range(of: #"^/private/var/folders/[^/]+/[^/]+/T/"#, options: .regularExpression) != nil, !path.contains("/T/AppTranslocation/") { return "runs from the per-user temp folder" }
        if path.hasPrefix("/Users/Shared/") { return "runs from /Users/Shared, which every account can write to" }
        if path.hasPrefix(h + "/Downloads/") { return "runs straight out of Downloads" }
        if path.hasPrefix(h + "/"), !inDevTools(path) {
            let rel = path.dropFirst(h.count + 1)
            if rel.split(separator: "/").dropLast().contains(where: { $0.hasPrefix(".") }) { return "lives in a hidden folder" }
            if rel.hasPrefix("Library/Application Support/"), rel.split(separator: "/").count >= 3,
               rel.split(separator: "/")[2].hasPrefix(".") { return "lives in a hidden Application Support folder" }
        }
        return nil
    }

    /// Labels like com.d8f3kq.x9 — random-looking reverse-DNS names adware uses.
    static func looksRandom(_ s: String) -> Bool {
        let parts = s.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return false }
        return parts.dropFirst().contains { p in
            guard p.count >= 6 else { return false }
            let letters = p.filter(\.isLetter).lowercased()
            let vowels = letters.filter { "aeiou".contains($0) }.count
            let digits = p.filter(\.isNumber).count
            return (letters.count >= 6 && Double(vowels) / Double(letters.count) < 0.15) || (digits >= 3 && letters.count >= 3)
        }
    }
}
