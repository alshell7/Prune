import Foundation

/// A link in the "how it fits together" chain shown for each finding (item → program → signer → network).
struct ChainNode: Hashable { var kind: String; var label: String; var detail: String; var risky: Bool }

struct ProtectionStatus: Hashable {
    var name: String
    var on: Bool
    var detail: String
    var settingsURL: String?
}

struct SecurityReport {
    var findings: [SecurityFinding] = []
    var protections: [ProtectionStatus] = []
    var chains: [String: [ChainNode]] = [:]
    var stats: [String: Int] = [:]
    /// name@version → install folders, kept for the optional online check.
    var npmPackages: [String: [String]] = [:]
    /// Full credential results, shown on the Secrets page.
    var secrets: SecretsReport?
}

// MARK: - Background items (launchd)

enum PersistenceAnalyzer {
    static let interpreters: Set<String> = ["sh", "bash", "zsh", "dash", "python", "python3", "perl", "ruby", "osascript", "node", "env", "php"]

    static func scan(dirs: [(String, Bool)]? = nil, report: inout SecurityReport) {
        let h = FS.home.path
        let locations = dirs ?? [(h + "/Library/LaunchAgents", false), ("/Library/LaunchAgents", true), ("/Library/LaunchDaemons", true)]
        var loaded: [String: Int32] = [:]
        for line in Shell.run("/bin/launchctl", ["list"], timeout: 10).stdout.split(separator: "\n").dropFirst() {
            let cols = line.split(separator: "\t").map(String.init)
            if cols.count == 3, let pid = Int32(cols[0]) { loaded[cols[2]] = pid }
        }
        for (dir, isSystem) in locations {
            for url in FS.children(URL(fileURLWithPath: dir)) where url.pathExtension == "plist" {
                guard let data = try? Data(contentsOf: url),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { continue }
                let label = plist["Label"] as? String ?? url.deletingPathExtension().lastPathComponent
                let args = (plist["ProgramArguments"] as? [String]) ?? []
                let program = (plist["Program"] as? String) ?? args.first ?? (plist["BundleProgram"] as? String) ?? ""
                analyze(plist: url, label: label, program: program, args: args, info: plist, system: isSystem, pid: loaded[label], report: &report)
            }
        }
    }

    static func analyze(plist: URL, label: String, program: String, args: [String], info: [String: Any], system: Bool, pid: Int32?, report: inout SecurityReport) {
        var score = 0
        var evidence: [String] = []
        var chain: [ChainNode] = [ChainNode(kind: system ? "Launch daemon" : "Launch agent", label: label, detail: FS.tildePath(plist), risky: false)]
        let created = (try? FileManager.default.attributesOfItem(atPath: plist.path)[.creationDate]) as? Date

        if label.lowercased().hasPrefix("com.apple.") {
            score += 7; evidence.append("Uses an Apple-style name (com.apple.…) but lives outside Apple's protected folders, a classic disguise.")
        }
        if ExecutableKind.looksRandom(label) { score += 2; evidence.append("The label looks randomly generated, as adware installers do.") }

        let exeName = (program as NSString).lastPathComponent
        var signer: String?
        if program.isEmpty {
            evidence.append("No program is defined.")
        } else if interpreters.contains(exeName) || exeName.hasPrefix("python") {
            score += 1
            chain.append(ChainNode(kind: "Interpreter", label: exeName, detail: program, risky: false))
            // Inline code (-c "…") or a script file.
            var body = args.dropFirst().joined(separator: " ")
            if let scriptPath = args.dropFirst().first(where: { $0.hasPrefix("/") || $0.hasPrefix("~") }),
               let text = FS.readText(URL(fileURLWithPath: (scriptPath as NSString).expandingTildeInPath), limit: 1_000_000) {
                body += "\n" + text
                chain.append(ChainNode(kind: "Script", label: (scriptPath as NSString).lastPathComponent, detail: scriptPath,
                                       risky: ExecutableKind.suspiciousLocation(scriptPath) != nil))
                if let where_ = ExecutableKind.suspiciousLocation(scriptPath) { score += 4; evidence.append("The script \(where_).") }
            }
            let hits = RedFlags.scan(body)
            score += RedFlags.score(hits)
            evidence += RedFlags.evidence(hits)
        } else if FS.exists(URL(fileURLWithPath: program)) {
            let target = CodeSigning.bundle(containing: program) ?? program
            let sig = CodeSigning.check(target)
            signer = sig.label
            chain.append(ChainNode(kind: "Program", label: (target as NSString).lastPathComponent, detail: target,
                                   risky: ExecutableKind.suspiciousLocation(program) != nil))
            chain.append(ChainNode(kind: "Signed by", label: sig.label, detail: sig.identifier ?? "", risky: !sig.isTrustedVendor))
            if let where_ = ExecutableKind.suspiciousLocation(program) { score += 4; evidence.append("The program \(where_).") }
            switch sig.trust {
            case .invalid: score += 5; evidence.append("The program's code signature is broken. It was modified after signing.")
            case .unsigned, .adhoc:
                if !ExecutableKind.inDevTools(program) { score += 2; evidence.append("The program isn't signed by an identified developer.") }
            case .unknown:
                evidence.append("Its signature can't be checked without administrator access.")
            default: break
            }
            if ExecutableKind.isScript(program), let text = FS.readText(URL(fileURLWithPath: program), limit: 1_000_000) {
                let hits = RedFlags.scan(text); score += RedFlags.score(hits); evidence += RedFlags.evidence(hits)
            }
        } else {
            evidence.append("Its program (\(program)) no longer exists, so this item does nothing.")
        }
        if let c = created, Date().timeIntervalSince(c) < 3 * 86_400 { score += 1; evidence.append("Installed \(Fmt.ago(c)).") }
        if let pid, pid > 0 { chain.append(ChainNode(kind: "Running", label: "pid \(pid)", detail: "", risky: false)) }

        let runAtLoad = info["RunAtLoad"] as? Bool ?? false
        let keepAlive = (info["KeepAlive"] as? Bool) ?? (info["KeepAlive"] != nil)
        let when = [runAtLoad ? "at login" : nil, keepAlive ? "kept alive" : nil, (info["StartInterval"] as? Int).map { "every \($0)s" }].compactMap { $0 }.joined(separator: ", ")

        var actions: [SecurityAction] = [.disableLaunchItem(plist: plist.path, label: label, system: system)]
        if let pid, pid > 0 { actions.insert(.stopProcess(pid: pid, name: exeName, asRoot: system), at: 0) }
        if !program.isEmpty, !program.contains(".app/"), !program.hasPrefix("/System/"), !program.hasPrefix("/usr/"),
           FS.exists(URL(fileURLWithPath: program)), !interpreters.contains(exeName) {
            actions.append(.quarantine(paths: [program]))
        }

        let severity = Severity.from(score: score)
        let id = "persist:\(plist.path)"
        report.chains[id] = chain
        report.findings.append(SecurityFinding(
            id: id, area: .persistence, severity: severity,
            title: label, subtitle: (system ? "Launch daemon (runs as root)" : "Launch agent") + (when.isEmpty ? "" : " · \(when)"),
            evidence: evidence,
            explanation: "launchd starts this automatically\(system ? " for every user, with root privileges" : " when you log in"). Programs: \(program.isEmpty ? "—" : program) \(args.dropFirst().prefix(4).joined(separator: " "))",
            legitNote: severity >= .medium ? "Updaters, VPNs, sync clients and developer tools install agents too. If you recognise the app, it's probably fine." : nil,
            recommendation: severity >= .high ? "Disable it now, then look for the app or package that installed it." :
                (severity >= .medium ? "Check that you recognise it. Disabling is reversible from Quarantine." : "Nothing suspicious found."),
            actions: actions, paths: [plist.path] + (program.isEmpty ? [] : [program]), signer: signer, inventoryOnly: severity == .info))
    }
}

// MARK: - Processes & network

enum ProcessAnalyzer {
    struct Proc { var pid: Int32; var ppid: Int32; var uid: Int; var cpu: Double; var rssKB: Int; var args: String; var path: String }

    static let systemNames: Set<String> = ["kernel_task", "launchd", "WindowServer", "loginwindow", "mds", "mds_stores", "mdworker", "softwareupdated",
                                           "XProtect", "XProtectService", "syspolicyd", "trustd", "securityd", "coreaudiod", "bluetoothd", "airportd",
                                           "Finder", "Dock", "SystemUIServer", "cfprefsd", "distnoted", "sharingd", "nsurlsessiond", "Safari", "kextd", "configd"]
    static let systemPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/usr/bin/", "/sbin/", "/bin/", "/Library/Apple/", "/System/Volumes/Preboot/Cryptexes/",
                                 "/Library/Developer/CommandLineTools/", "/Applications/Xcode.app/"]

    static func snapshot() -> [Proc] {
        let r = Shell.run("/bin/ps", ["-axo", "pid=,ppid=,uid=,pcpu=,rss=,args="], timeout: 10)
        return r.stdout.split(separator: "\n").compactMap { line -> Proc? in
            let parts = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true).map(String.init)
            guard parts.count == 6, let pid = Int32(parts[0]), let ppid = Int32(parts[1]), let uid = Int(parts[2]) else { return nil }
            let path = CodeSigning.path(of: pid) ?? String(parts[5].split(separator: " ").first ?? "")
            return Proc(pid: pid, ppid: ppid, uid: uid, cpu: Double(parts[3]) ?? 0, rssKB: Int(parts[4]) ?? 0, args: parts[5], path: path)
        }
    }

    struct Net { var established: [String] = []; var listening: [String] = [] }

    static func network() -> [Int32: Net] {
        let r = Shell.run("/usr/sbin/lsof", ["-nP", "-i", "-FpnT"], timeout: 20)
        var out: [Int32: Net] = [:]
        var pid: Int32 = 0
        var name = ""
        for line in r.stdout.split(separator: "\n") {
            switch line.first {
            case "p": pid = Int32(line.dropFirst()) ?? 0
            case "n": name = String(line.dropFirst())
            case "T":
                let t = line.dropFirst()
                if t == "ST=ESTABLISHED", let remote = name.components(separatedBy: "->").last, name.contains("->") {
                    out[pid, default: Net()].established.append(remote)
                } else if t == "ST=LISTEN" {
                    out[pid, default: Net()].listening.append(name)
                }
            default: break
            }
        }
        return out
    }

    static func isPrivate(_ endpoint: String) -> Bool {
        let host = endpoint.hasPrefix("[") ? String(endpoint.dropFirst().prefix { $0 != "]" }) : String(endpoint.split(separator: ":").first ?? "")
        if host.hasPrefix("10.") || host.hasPrefix("192.168.") || host.hasPrefix("127.") || host == "::1" || host.hasPrefix("fe80") || host.hasPrefix("169.254.") { return true }
        if host.hasPrefix("172."), let second = Int(host.split(separator: ".")[1]), (16...31).contains(second) { return true }
        if host.hasPrefix("100."), let second = Int(host.split(separator: ".")[1]), (64...127).contains(second) { return true }   // CGNAT / Tailscale
        return false
    }

    static func scan(report: inout SecurityReport) {
        let procs = snapshot()
        let net = network()
        report.stats["processes"] = procs.count
        let me = getpid()
        // Skip Prune and the shells that launched it (their command lines contain whatever invoked us).
        var ancestors = Set<Int32>([me])
        var cursor = getppid()
        while cursor > 1, ancestors.insert(cursor).inserted { cursor = procs.first { $0.pid == cursor }?.ppid ?? 1 }
        for p in procs where p.pid > 1 && !ancestors.contains(p.pid) && !p.path.contains("/Prune.app/") {
            let name = (p.path as NSString).lastPathComponent
            let isSystemPath = systemPrefixes.contains { p.path.hasPrefix($0) }
            var score = 0
            var evidence: [String] = []
            var chain: [ChainNode] = []
            let parentName = procs.first { $0.pid == p.ppid }.map { ($0.path as NSString).lastPathComponent } ?? "launchd"
            chain.append(ChainNode(kind: "Started by", label: parentName, detail: "pid \(p.ppid)", risky: false))

            // Impersonating a system process from a user location.
            if systemNames.contains(name) && !isSystemPath && !p.path.contains(".app/") {
                score += 8; evidence.append("Named like the macOS process \u{201C}\(name)\u{201D} but runs from \(p.path).")
            }
            if !isSystemPath && !p.path.isEmpty && p.path.hasPrefix("/") && !FS.exists(URL(fileURLWithPath: p.path)) && !p.path.contains(".app/") {
                score += 4; evidence.append("Its program file was deleted after it started, a common way to hide.")
            }
            if let where_ = ExecutableKind.suspiciousLocation(p.path) { score += 4; evidence.append("It \(where_).") }

            let argHits = RedFlags.scan(p.args, limit: 8_000).filter { $0.weight >= 4 }
            if !argHits.isEmpty { score += RedFlags.score(argHits); evidence += RedFlags.evidence(argHits) }

            var signer: SignatureInfo?
            if !isSystemPath && FS.exists(URL(fileURLWithPath: p.path)) {
                let target = CodeSigning.bundle(containing: p.path) ?? p.path
                let sig = CodeSigning.check(target)
                signer = sig
                if sig.trust == .invalid { score += 5; evidence.append("Its code signature is broken.") }
                else if sig.isAnonymous && !ExecutableKind.inDevTools(p.path) { score += 1; evidence.append("Not signed by an identified developer.") }
            }
            chain.append(ChainNode(kind: "Program", label: name, detail: p.path, risky: ExecutableKind.suspiciousLocation(p.path) != nil))
            chain.append(ChainNode(kind: "Signed by", label: isSystemPath ? "Apple (system location)" : (signer?.label ?? "unknown"),
                                   detail: "", risky: !(isSystemPath || (signer?.isTrustedVendor ?? false))))

            let n = net[p.pid] ?? Net()
            let publicConns = n.established.filter { !isPrivate($0) }
            let exposed = n.listening.filter { $0.hasPrefix("*:") || $0.hasPrefix("0.0.0.0") || $0.hasPrefix("[::]") }
            if !publicConns.isEmpty {
                chain.append(ChainNode(kind: "Talks to", label: publicConns.prefix(2).joined(separator: ", ") + (publicConns.count > 2 ? " +\(publicConns.count - 2)" : ""),
                                       detail: "", risky: score > 0))
                if !(signer?.isTrustedVendor ?? isSystemPath) && !ExecutableKind.inDevTools(p.path) && score > 0 {
                    score += 2; evidence.append("Connected to \(publicConns.count) internet address(es): \(publicConns.prefix(3).joined(separator: ", ")).")
                }
            }
            if !exposed.isEmpty {
                chain.append(ChainNode(kind: "Listens on", label: exposed.prefix(2).joined(separator: ", "), detail: "reachable from your network", risky: score > 0))
                if !(signer?.isTrustedVendor ?? isSystemPath) && score > 0 { score += 1; evidence.append("Accepts connections from other machines (\(exposed.prefix(2).joined(separator: ", "))).") }
            }
            if p.cpu > 80 && !(signer?.isTrustedVendor ?? isSystemPath) && !ExecutableKind.inDevTools(p.path) {
                score += 1; evidence.append("Using \(Int(p.cpu))% CPU.")
            }

            let severity = Severity.from(score: score)
            // Inventory shows third-party processes only; system processes appear only when suspicious.
            if severity == .info && isSystemPath { continue }
            if severity == .info && (signer?.trust ?? .apple) == .apple { continue }
            let id = "proc:\(p.pid)"
            report.chains[id] = chain
            var actions: [SecurityAction] = [.stopProcess(pid: p.pid, name: name, asRoot: p.uid == 0)]
            if severity >= .medium, !p.path.contains(".app/"), !isSystemPath, FS.exists(URL(fileURLWithPath: p.path)) { actions.append(.quarantine(paths: [p.path])) }
            report.findings.append(SecurityFinding(
                id: id, area: .processes, severity: severity, title: name.isEmpty ? "pid \(p.pid)" : name,
                subtitle: "pid \(p.pid) · \(p.uid == 0 ? "root" : "you") · \(String(format: "%.0f", p.cpu))% CPU · \(Fmt.bytes(Int64(p.rssKB) * 1024))" + (publicConns.isEmpty ? "" : " · \(publicConns.count) connection(s)"),
                evidence: evidence, explanation: "Command: \(p.args.prefix(300))",
                legitNote: severity >= .medium ? "Developer tools you built or downloaded yourself are often unsigned. If you started it, it's probably fine." : nil,
                recommendation: severity >= .high ? "Stop it, then disable whatever launches it (check Background items)." : (severity >= .medium ? "Check that you recognise it." : "Nothing suspicious found."),
                actions: actions, paths: [p.path], signer: isSystemPath ? "Apple (system location)" : signer?.label, inventoryOnly: severity == .info))
        }
    }
}

// MARK: - System posture & tamper points

enum PostureAnalyzer {
    static func scan(report: inout SecurityReport) {
        let sip = Shell.run("/usr/bin/csrutil", ["status"], timeout: 10).stdout
        report.protections.append(ProtectionStatus(name: "System Integrity Protection", on: sip.contains("enabled"), detail: sip.contains("enabled") ? "System files can't be modified" : "Disabled: malware can modify system files", settingsURL: nil))
        let gk = Shell.run("/usr/sbin/spctl", ["--status"], timeout: 10).stdout
        report.protections.append(ProtectionStatus(name: "Gatekeeper", on: gk.contains("enabled"), detail: gk.contains("enabled") ? "Unidentified apps are blocked by default" : "Disabled: any app can run unchecked",
                                                   settingsURL: "x-apple.systempreferences:com.apple.preference.security?General"))
        let fv = Shell.run("/usr/bin/fdesetup", ["status"], timeout: 10).stdout
        report.protections.append(ProtectionStatus(name: "FileVault", on: fv.contains("On"), detail: fv.contains("On") ? "Disk is encrypted" : "Disk isn't encrypted: a stolen Mac exposes your files",
                                                   settingsURL: "x-apple.systempreferences:com.apple.preference.security?FileVault"))
        let fw = Shell.run("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"], timeout: 10).stdout
        report.protections.append(ProtectionStatus(name: "Firewall", on: fw.contains("enabled"), detail: fw.contains("enabled") ? "Incoming connections are filtered" : "Off: apps can accept connections from your network",
                                                   settingsURL: "x-apple.systempreferences:com.apple.Network-Settings.extension?Firewall"))
        let xp = URL(fileURLWithPath: "/Library/Apple/System/Library/CoreServices/XProtect.bundle/Contents/Info.plist")
        if let d = NSDictionary(contentsOf: xp) {
            let ver = d["CFBundleShortVersionString"] as? String ?? "?"
            let age = Age.days(FS.mtime(xp)) ?? 0
            report.protections.append(ProtectionStatus(name: "XProtect", on: age < 60, detail: "Malware definitions v\(ver), updated \(Fmt.ago(FS.mtime(xp)))",
                                                       settingsURL: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension"))
        }
        for p in report.protections where !p.on {
            report.findings.append(SecurityFinding(id: "posture:\(p.name)", area: .system, severity: p.name == "Firewall" ? .low : (p.name == "XProtect" ? .low : .high),
                                                   title: "\(p.name) is off", subtitle: p.detail, evidence: [p.detail],
                                                   explanation: "\(p.name) is one of macOS's built-in protections.", legitNote: nil,
                                                   recommendation: "Turn it back on in System Settings.", actions: p.settingsURL.map { [.openURL($0)] } ?? []))
        }

        shellStartupFiles(&report)
        cron(&report)
        hosts(&report)
        profiles(&report)
        sshKeys(&report)
        loginHook(&report)
        helpers(&report)
    }

    static func shellStartupFiles(_ report: inout SecurityReport) {
        for name in [".zshrc", ".zprofile", ".zshenv", ".zlogin", ".bashrc", ".bash_profile", ".profile"] {
            let f = FS.home.appendingPathComponent(name)
            guard let text = FS.readText(f, limit: 1_000_000) else { continue }
            var bad: [(Int, [RedFlags.Hit])] = []
            for (i, line) in text.components(separatedBy: "\n").enumerated() where !line.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
                let hits = RedFlags.scan(line).filter { $0.weight >= 4 }
                if RedFlags.score(hits) >= 5 { bad.append((i + 1, hits)) }
            }
            guard !bad.isEmpty else { continue }
            report.findings.append(SecurityFinding(
                id: "rc:\(name)", area: .system, severity: .high, title: "Suspicious line in ~/\(name)", subtitle: "Runs in every new terminal",
                evidence: bad.flatMap { line, hits in RedFlags.evidence(hits).map { "Line \(line): \($0)" } },
                explanation: "Shell startup files run on every terminal launch. Supply-chain malware (e.g. the 2025 nx compromise) appended commands here.",
                legitNote: "Installers sometimes add `curl … | sh` lines for tool setup. Check whether you added it.",
                recommendation: "Disable the line(s). A backup is kept.", actions: [.commentOutLines(file: f.path, lines: bad.map(\.0))], paths: [f.path]))
        }
    }

    static func cron(_ report: inout SecurityReport) {
        let r = Shell.run("/usr/bin/crontab", ["-l"], timeout: 10)
        let lines = r.stdout.components(separatedBy: "\n").filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard r.ok, !lines.isEmpty else { return }
        let hits = RedFlags.scan(lines.joined(separator: "\n"))
        let sev = Severity.from(score: max(RedFlags.score(hits), 1))
        report.findings.append(SecurityFinding(
            id: "cron", area: .persistence, severity: sev, title: "Cron jobs", subtitle: "\(lines.count) scheduled command(s)",
            evidence: lines.prefix(6).map { "\u{201C}\($0.prefix(140))\u{201D}" } + RedFlags.evidence(hits),
            explanation: "Cron runs these commands on a schedule. It's rarely used on modern macOS, so unexpected entries deserve a look.",
            legitNote: "Backup scripts and dev tooling sometimes use cron.", recommendation: "Remove entries you don't recognise. A backup is kept.",
            actions: [.removeCronLines(lines: lines)]))
    }

    static func hosts(_ report: inout SecurityReport) {
        guard let text = FS.readText(URL(fileURLWithPath: "/etc/hosts")) else { return }
        let entries = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.contains("localhost") && !$0.contains("broadcasthost") }
        guard !entries.isEmpty else { return }
        let sensitive = entries.filter { $0.range(of: #"apple\.com|icloud|google|microsoft|github|npmjs|pypi|update|xprotect|malwarebytes|bank"#, options: [.regularExpression, .caseInsensitive]) != nil }
        report.findings.append(SecurityFinding(
            id: "hosts", area: .system, severity: sensitive.isEmpty ? .low : .high, title: "Custom /etc/hosts entries", subtitle: "\(entries.count) override(s)",
            evidence: entries.prefix(8).map { "\u{201C}\($0)\u{201D}" },
            explanation: "/etc/hosts overrides DNS. Malware uses it to block security updates or redirect sites to fake copies.",
            legitNote: "Developers add local hostnames here (e.g. myapp.test). Those are harmless.",
            recommendation: sensitive.isEmpty ? "Review the list." : "Entries redirect well-known services. Edit /etc/hosts (needs admin) and remove them.",
            actions: [], paths: ["/etc/hosts"]))
    }

    static func profiles(_ report: inout SecurityReport) {
        let r = Shell.run("/usr/bin/profiles", ["list"], timeout: 15)
        let text = r.stdout + r.stderr
        guard r.ok, !text.contains("There are no configuration profiles"), text.contains("attribute") || text.contains("profileIdentifier") else { return }
        report.findings.append(SecurityFinding(
            id: "profiles", area: .system, severity: .medium, title: "Configuration profiles installed", subtitle: "Can change proxies, certificates and browser settings",
            evidence: text.components(separatedBy: "\n").filter { $0.contains("profileIdentifier") }.prefix(5).map { $0.trimmingCharacters(in: .whitespaces) },
            explanation: "Profiles can install root certificates, force proxies and manage browsers. Adware abuses them. Employers use them for device management.",
            legitNote: "Expected if your Mac is managed by work or school.", recommendation: "Review them in System Settings › General › Device Management.",
            actions: [.openURL("x-apple.systempreferences:com.apple.Profiles-Settings.extension")]))
    }

    static func sshKeys(_ report: inout SecurityReport) {
        let f = FS.home.appendingPathComponent(".ssh/authorized_keys")
        guard let text = FS.readText(f) else { return }
        let keys = text.components(separatedBy: "\n").filter { $0.contains("ssh-") || $0.contains("ecdsa-") }
        guard !keys.isEmpty else { return }
        report.findings.append(SecurityFinding(
            id: "ssh-authorized", area: .system, severity: .medium, title: "SSH login keys present", subtitle: "\(keys.count) key(s) in ~/.ssh/authorized_keys",
            evidence: keys.prefix(5).map { "Key comment: \($0.split(separator: " ").dropFirst(2).joined(separator: " ").prefix(60))" },
            explanation: "Anyone holding these keys can log into this Mac over SSH if Remote Login is on. Attackers add their key to keep access.",
            legitNote: "Expected if you SSH into this Mac from your other machines.", recommendation: "Remove keys you don't recognise. Quarantining the file disables all of them and is reversible.",
            actions: [.quarantine(paths: [f.path])], paths: [f.path]))
    }

    static func loginHook(_ report: inout SecurityReport) {
        let r = Shell.run("/usr/bin/defaults", ["read", "com.apple.loginwindow", "LoginHook"], timeout: 5)
        guard r.ok, !r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        report.findings.append(SecurityFinding(
            id: "loginhook", area: .persistence, severity: .high, title: "Login hook set", subtitle: r.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            evidence: ["LoginHook = \(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines))"],
            explanation: "Login hooks are a deprecated mechanism that runs a script at every login. Modern apps don't use them; malware sometimes does.",
            legitNote: nil, recommendation: "Remove it: run `defaults delete com.apple.loginwindow LoginHook` and quarantine the script.",
            actions: [], paths: []))
    }

    static func helpers(_ report: inout SecurityReport) {
        let daemons = FS.children(URL(fileURLWithPath: "/Library/LaunchDaemons")).compactMap { FS.readText($0, limit: 64 * 1024) }.joined()
        for h in FS.children(URL(fileURLWithPath: "/Library/PrivilegedHelperTools")) {
            let sig = CodeSigning.check(h.path)
            let referenced = daemons.contains(h.lastPathComponent)
            var score = 0
            var evidence: [String] = []
            if sig.isAnonymous || sig.trust == .invalid { score += 4; evidence.append("Root helper isn't signed by an identified developer (\(sig.label)).") }
            if !referenced { score += 1; evidence.append("No launch daemon refers to it. Probably left behind by an uninstalled app.") }
            let sev = Severity.from(score: score)
            report.chains["helper:\(h.path)"] = [ChainNode(kind: "Root helper", label: h.lastPathComponent, detail: h.path, risky: score > 0),
                                                  ChainNode(kind: "Signed by", label: sig.label, detail: sig.teamID ?? "", risky: !sig.isTrustedVendor)]
            report.findings.append(SecurityFinding(
                id: "helper:\(h.path)", area: .persistence, severity: sev, title: h.lastPathComponent, subtitle: "Privileged helper (runs as root)",
                evidence: evidence, explanation: "Apps install privileged helpers to do admin tasks (VPNs, Docker, updaters).",
                legitNote: "Docker, VPN and backup apps all use these.", recommendation: sev == .info ? "Nothing suspicious found." : "Quarantine it if the app it belongs to is gone.",
                actions: sev == .info ? [] : [.quarantine(paths: [h.path])], paths: [h.path], signer: sig.label, inventoryOnly: sev == .info))
        }
    }
}

// MARK: - Hidden executables & known indicators

enum FileSweepAnalyzer {
    /// Known indicator paths from public reports of macOS developer-targeted malware.
    static let indicators: [(String, String)] = [
        (".n2", "Folder used by the BeaverTail/InvisibleFerret malware from fake job-interview projects (\u{201C}Contagious Interview\u{201D})"),
        (".npl", "File dropped by InvisibleFerret (Python backdoor delivered through fake npm projects)"),
        (".n3", "Folder used by BeaverTail-family stealers"),
    ]

    static func scan(report: inout SecurityReport) {
        let h = FS.home
        for (rel, what) in indicators {
            let u = h.appendingPathComponent(rel)
            guard FS.exists(u) else { continue }
            report.findings.append(SecurityFinding(
                id: "ioc:\(u.path)", area: .files, severity: .high, title: "Known malware location: ~/\(rel)", subtitle: what,
                evidence: ["~/\(rel) exists (modified \(Fmt.ago(FS.mtime(u))))."], explanation: what + ".",
                legitNote: "A coincidental name is possible. Look inside before deleting.",
                recommendation: "Quarantine it, rotate passwords and tokens used on this Mac, and check browser extensions and crypto wallets.",
                actions: [.quarantine(paths: [u.path])], paths: [u.path]))
        }
        var candidates: [URL] = []
        for c in FS.children(h) where c.lastPathComponent.hasPrefix(".") && !FS.isDir(c) { candidates.append(c) }
        for c in FS.childDirs(h) where c.lastPathComponent.hasPrefix(".") && !ExecutableKind.inDevTools(c.path + "/") {
            candidates += FS.children(c).filter { !FS.isDir($0) }
        }
        for dir in ["Library/Application Support"] {
            for c in FS.childDirs(h.appendingPathComponent(dir)) where c.lastPathComponent.hasPrefix(".") {
                candidates += FS.children(c).filter { !FS.isDir($0) }
            }
        }
        for dir in ["/Users/Shared", "/private/tmp", "/private/var/tmp"] {
            candidates += FS.children(URL(fileURLWithPath: dir)).filter { !FS.isDir($0) }
        }
        for f in candidates {
            guard ExecutableKind.isMachO(f.path) else { continue }
            let sig = CodeSigning.check(f.path)
            if sig.isTrustedVendor || sig.trust == .unknown { continue }
            var score = 4 + (sig.trust == .invalid ? 3 : 1)
            if FS.childDirs(f.deletingLastPathComponent()).isEmpty == false { score += 0 }
            report.chains["hidden:\(f.path)"] = [ChainNode(kind: "Executable", label: f.lastPathComponent, detail: f.path, risky: true),
                                                  ChainNode(kind: "Signed by", label: sig.label, detail: "", risky: true)]
            report.findings.append(SecurityFinding(
                id: "hidden:\(f.path)", area: .files, severity: Severity.from(score: score), title: FS.tildePath(f), subtitle: "Program in a hidden or shared location",
                evidence: ["A Mach-O program in \(FS.tildePath(f.deletingLastPathComponent())), signed: \(sig.label)."],
                explanation: "Legitimate apps install into /Applications or Library folders with visible names. Hidden or shared-folder binaries are a common malware pattern.",
                legitNote: "Some command-line tools install themselves here.", recommendation: "Quarantine it unless you know what it is.",
                actions: [.quarantine(paths: [f.path])], paths: [f.path], signer: sig.label))
        }
    }
}

// MARK: - Browser extensions

enum BrowserAnalyzer {
    static let roots: [(String, String)] = [
        ("Google Chrome", "Library/Application Support/Google/Chrome"), ("Brave", "Library/Application Support/BraveSoftware/Brave-Browser"),
        ("Microsoft Edge", "Library/Application Support/Microsoft Edge"), ("Arc", "Library/Application Support/Arc/User Data"),
        ("Vivaldi", "Library/Application Support/Vivaldi"), ("Chromium", "Library/Application Support/Chromium"),
    ]
    static let dangerous: Set<String> = ["webRequest", "webRequestBlocking", "cookies", "nativeMessaging", "debugger", "proxy", "clipboardRead", "history", "management", "privacy", "desktopCapture"]

    static func scan(report: inout SecurityReport) {
        let h = FS.home
        for (browser, rel) in roots {
            let base = h.appendingPathComponent(rel)
            guard FS.isDir(base) else { continue }
            for ext in [base.appendingPathComponent("External Extensions"), URL(fileURLWithPath: "/Library/Application Support/Google/Chrome/External Extensions")] {
                for json in FS.children(ext) where json.pathExtension == "json" {
                    report.findings.append(SecurityFinding(
                        id: "extinstall:\(json.path)", area: .browser, severity: .high, title: "Force-installed \(browser) extension",
                        subtitle: json.lastPathComponent, evidence: [FS.readText(json, limit: 2000) ?? ""],
                        explanation: "Files in External Extensions make \(browser) install an extension automatically for every profile. Adware uses this to keep coming back.",
                        legitNote: "Some password managers ship this way.", recommendation: "Quarantine the file, then remove the extension in the browser.",
                        actions: [.quarantine(paths: [json.path])], paths: [json.path]))
                }
            }
            for profile in FS.childDirs(base) where profile.lastPathComponent == "Default" || profile.lastPathComponent.hasPrefix("Profile ") {
                for idDir in FS.childDirs(profile.appendingPathComponent("Extensions")) {
                    guard let ver = FS.childDirs(idDir).max(by: { $0.lastPathComponent < $1.lastPathComponent }),
                          let manifest = FS.readJSON(ver.appendingPathComponent("manifest.json")) as? [String: Any] else { continue }
                    var name = manifest["name"] as? String ?? idDir.lastPathComponent
                    if name.hasPrefix("__MSG_") {
                        let key = String(name.dropFirst(6).dropLast(2))
                        for loc in ["en", "en_US", "en_GB"] {
                            if let msgs = FS.readJSON(ver.appendingPathComponent("_locales/\(loc)/messages.json")) as? [String: Any],
                               let m = (msgs[key] ?? msgs[key.lowercased()]) as? [String: Any], let s = m["message"] as? String { name = s; break }
                        }
                    }
                    let perms = ((manifest["permissions"] as? [Any]) ?? []).compactMap { $0 as? String } + ((manifest["host_permissions"] as? [Any]) ?? []).compactMap { $0 as? String }
                    let contentMatches = ((manifest["content_scripts"] as? [[String: Any]]) ?? []).flatMap { ($0["matches"] as? [String]) ?? [] }
                    let broad = (perms + contentMatches).contains { $0 == "<all_urls>" || $0.hasPrefix("*://*/") || $0.hasPrefix("http://*/") || $0.hasPrefix("https://*/") }
                    let risky = perms.filter { dangerous.contains($0) }
                    let update = manifest["update_url"] as? String ?? ""
                    let fromStore = update.contains("google.com") || update.contains("microsoft.com") || update.contains("edge.microsoft")
                    var score = 0
                    var evidence: [String] = []
                    if !fromStore { score += 3; evidence.append("Not installed from the browser's web store (sideloaded or developer mode).") }
                    if broad { score += 1; evidence.append("Can read and change every website you visit.") }
                    if !risky.isEmpty { score += min(3, risky.count); evidence.append("Sensitive permissions: \(risky.joined(separator: ", ")).") }
                    if !fromStore && broad && risky.contains(where: { ["cookies", "webRequest", "nativeMessaging", "debugger"].contains($0) }) { score += 2 }
                    let sev = Severity.from(score: fromStore ? min(score, 2) : score)
                    let id = "ext:\(idDir.path)"
                    report.chains[id] = [ChainNode(kind: browser, label: profile.lastPathComponent, detail: "", risky: false),
                                         ChainNode(kind: "Extension", label: name, detail: idDir.lastPathComponent, risky: !fromStore),
                                         ChainNode(kind: "Can access", label: broad ? "All websites" : "Some sites", detail: risky.joined(separator: ", "), risky: broad && !risky.isEmpty)]
                    report.findings.append(SecurityFinding(
                        id: id, area: .browser, severity: sev, title: name, subtitle: "\(browser) · \(profile.lastPathComponent) · v\(manifest["version"] as? String ?? "?")",
                        evidence: evidence, explanation: "Browser extensions see the pages you visit. Stealers and adware often arrive as extensions.",
                        legitNote: fromStore ? "Installed from the store. Broad permissions are normal for ad blockers and password managers." : "You may have loaded it yourself in developer mode.",
                        recommendation: sev >= .medium ? "Remove it in \(browser) › Extensions unless you installed it on purpose. Quarantine works too (quit the browser first)." : "Nothing suspicious found.",
                        actions: sev >= .medium ? [.quarantine(paths: [idDir.path])] : [], paths: [idDir.path], inventoryOnly: sev == .info))
                }
            }
        }
    }
}
