import Foundation
import Observation

/// One running process, enriched with what Prune can learn cheaply.
struct ProcInfo: Identifiable, Hashable {
    var id: Int32 { pid }
    var pid: Int32
    var ppid: Int32
    var uid: Int
    var cpu: Double
    var rssKB: Int
    var elapsed: TimeInterval
    var args: String
    var path: String
    var name: String
    var appPath: String?
    var appName: String?
    var isSystem: Bool
    var launchdLabel: String?

    var started: Date { Date().addingTimeInterval(-elapsed) }
    var memBytes: Int64 { Int64(rssKB) * 1024 }
    var isScriptRuntime: Bool { ProcessCatalog.runtimes.contains(name) || name.hasPrefix("python") }
}

enum ProcessCatalog {
    static let runtimes: Set<String> = ["node", "python", "python3", "ruby", "perl", "java", "deno", "bun", "php", "bash", "sh", "zsh", "osascript", "dotnet", "Rscript"]
    static let devServerHints = ["vite", "next", "webpack", "nodemon", "uvicorn", "gunicorn", "flask", "django", "rails", "serve", "http.server", "expo", "metro", "storybook", "jest", "tsx", "ts-node", "npm", "pnpm", "yarn", "bun run", "wrangler", "tauri", "cargo run"]

    static func parseElapsed(_ s: String) -> TimeInterval {
        // [[dd-]hh:]mm:ss
        var days = 0.0
        var rest = Substring(s)
        if let dash = rest.firstIndex(of: "-") { days = Double(rest[..<dash]) ?? 0; rest = rest[rest.index(after: dash)...] }
        let parts = rest.split(separator: ":").compactMap { Double($0) }
        var secs = 0.0
        for p in parts { secs = secs * 60 + p }
        return days * 86_400 + secs
    }

    static func outermostApp(_ path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return nil }
        return String(path[..<r.lowerBound]) + ".app"
    }

    static func launchdLabels() -> [Int32: String] {
        var map: [Int32: String] = [:]
        for line in Shell.run("/bin/launchctl", ["list"], timeout: 10).stdout.split(separator: "\n").dropFirst() {
            let cols = line.split(separator: "\t").map(String.init)
            if cols.count == 3, let pid = Int32(cols[0]), pid > 0 { map[pid] = cols[2] }
        }
        return map
    }

    static func snapshot() -> [ProcInfo] {
        let r = Shell.run("/bin/ps", ["-axo", "pid=,ppid=,uid=,pcpu=,rss=,etime=,args="], timeout: 10)
        let labels = launchdLabels()
        return r.stdout.split(separator: "\n").compactMap { line -> ProcInfo? in
            let parts = line.split(separator: " ", maxSplits: 6, omittingEmptySubsequences: true).map(String.init)
            guard parts.count == 7, let pid = Int32(parts[0]), let ppid = Int32(parts[1]), let uid = Int(parts[2]) else { return nil }
            let path = CodeSigning.path(of: pid) ?? String(parts[6].split(separator: " ").first ?? "")
            let app = outermostApp(path)
            let isSystem = ProcessAnalyzer.systemPrefixes.contains { path.hasPrefix($0) } || (app?.hasPrefix("/System/") ?? false)
            return ProcInfo(pid: pid, ppid: ppid, uid: uid, cpu: Double(parts[3]) ?? 0, rssKB: Int(parts[4]) ?? 0,
                            elapsed: parseElapsed(parts[5]), args: parts[6], path: path, name: (path as NSString).lastPathComponent,
                            appPath: app, appName: app.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension },
                            isSystem: isSystem, launchdLabel: labels[pid])
        }
    }

    /// Plist that defines a launchd job, if it's one of the visible ones.
    static func plist(for label: String) -> String? {
        for dir in [FS.home.path + "/Library/LaunchAgents", "/Library/LaunchAgents", "/Library/LaunchDaemons"] {
            let p = "\(dir)/\(label).plist"
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return nil
    }

    static func workingDirectory(_ pid: Int32) -> String? {
        let r = Shell.run("/usr/sbin/lsof", ["-a", "-p", String(pid), "-d", "cwd", "-Fn"], timeout: 5)
        return r.stdout.split(separator: "\n").first { $0.hasPrefix("n") }.map { String($0.dropFirst()) }
    }

    static func openFileCount(_ pid: Int32) -> Int {
        Shell.run("/usr/sbin/lsof", ["-p", String(pid), "-Fn"], timeout: 8).stdout.split(separator: "\n").filter { $0.hasPrefix("n") }.count
    }

    /// Plain-language answer to "why is this running?".
    static func origin(_ p: ProcInfo, all: [Int32: ProcInfo]) -> (summary: String, chain: [ChainNode]) {
        var chain: [ChainNode] = []
        var cursor = p
        var hops = 0
        var ancestors: [ProcInfo] = []
        while cursor.ppid > 1, let parent = all[cursor.ppid], hops < 6 { ancestors.insert(parent, at: 0); cursor = parent; hops += 1 }
        if let label = (ancestors.first ?? p).launchdLabel ?? p.launchdLabel {
            let plist = plist(for: label)
            chain.append(ChainNode(kind: "Started by launchd", label: label, detail: plist.map { FS.tildePath(URL(fileURLWithPath: $0)) } ?? "built-in or app-registered job", risky: false))
        } else {
            chain.append(ChainNode(kind: "Started by", label: "launchd", detail: "macOS service manager", risky: false))
        }
        for a in ancestors.suffix(3) { chain.append(ChainNode(kind: "via", label: a.appName ?? a.name, detail: "pid \(a.pid)", risky: false)) }
        chain.append(ChainNode(kind: "Process", label: p.appName.map { $0 == p.name ? $0 : "\($0) › \(p.name)" } ?? p.name, detail: "pid \(p.pid)", risky: false))

        let names = ancestors.map { $0.appName ?? $0.name }
        let summary: String
        if let t = names.last(where: { ["Terminal", "iTerm2", "Warp", "Ghostty", "kitty", "Alacritty", "WezTerm", "zsh", "bash", "fish"].contains($0) }) {
            summary = "You started it from \(t)."
        } else if let editor = names.last(where: { ["Code", "Visual Studio Code", "Cursor", "Windsurf", "Xcode", "Android Studio", "Claude", "ChatGPT", "Codex"].contains($0) }) {
            summary = "Started by \(editor)."
        } else if p.ppid == 1, let l = p.launchdLabel {
            summary = plist(for: l) != nil ? "A background item (\(l)) starts it automatically." : "launchd runs it as \(l)."
        } else if p.ppid == 1 && p.isScriptRuntime {
            summary = "Its parent quit, so it's orphaned and kept running on its own."
        } else if let app = p.appName, p.ppid == 1 {
            summary = "Part of \(app)."
        } else if let parent = all[p.ppid] {
            summary = "Started by \(parent.appName ?? parent.name)."
        } else {
            summary = "Started by macOS."
        }
        return (summary, chain)
    }
}

// MARK: - Network monitor

struct Endpoint: Hashable {
    var host: String
    var port: Int
    var display: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }
}

struct PidNet {
    var inRate: Double = 0          // bytes/s
    var outRate: Double = 0
    var totalIn: Int64 = 0
    var totalOut: Int64 = 0
    var connections: [Endpoint] = []
    var listening: [String] = []
    var history: [Double] = []      // combined rate samples for sparklines
}

/// Samples per-process traffic (nettop) and sockets (lsof) every couple of seconds while someone is watching.
@MainActor
@Observable
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    var byPid: [Int32: PidNet] = [:]
    var hostnames: [String: String] = [:]
    var appearances: [String: [Date]] = [:]   // "pid|host:port" → times the connection was (re)opened
    var running = false
    var lastSample: Date?
    private var previous: [Int32: (Int64, Int64, Date)] = [:]
    private var lastTuples = Set<String>()
    private var watchers = 0
    private var resolving = Set<String>()

    func start() {
        watchers += 1
        guard !running else { return }
        running = true
        Task { [weak self] in
            while let self, self.running {
                await self.sample()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        watchers = max(0, watchers - 1)
        if watchers == 0 { running = false }
    }

    var totalIn: Double { byPid.values.reduce(0) { $0 + $1.inRate } }
    var totalOut: Double { byPid.values.reduce(0) { $0 + $1.outRate } }

    func sample() async {
        let (bytes, sockets) = await AppModel.background { () -> ([Int32: (Int64, Int64)], [Int32: (conns: [Endpoint], listen: [String])]) in
            var b: [Int32: (Int64, Int64)] = [:]
            for line in Shell.run("/usr/bin/nettop", ["-P", "-L", "1", "-n", "-x", "-J", "bytes_in,bytes_out"], timeout: 10).stdout.split(separator: "\n").dropFirst() {
                let cols = line.split(separator: ",", omittingEmptySubsequences: false)
                guard cols.count >= 3, let dot = cols[0].lastIndex(of: "."), let pid = Int32(cols[0][cols[0].index(after: dot)...]) else { continue }
                b[pid] = (Int64(cols[1]) ?? 0, Int64(cols[2]) ?? 0)
            }
            var s: [Int32: (conns: [Endpoint], listen: [String])] = [:]
            var pid: Int32 = 0
            var name = ""
            for line in Shell.run("/usr/sbin/lsof", ["-nP", "-i", "-FpnT"], timeout: 15).stdout.split(separator: "\n") {
                switch line.first {
                case "p": pid = Int32(line.dropFirst()) ?? 0
                case "n": name = String(line.dropFirst())
                case "T":
                    if line == "TST=ESTABLISHED", let remote = name.components(separatedBy: "->").last, name.contains("->"), let ep = NetworkMonitor.parse(remote) {
                        s[pid, default: ([], [])].conns.append(ep)
                    } else if line == "TST=LISTEN" {
                        s[pid, default: ([], [])].listen.append(name)
                    }
                default: break
                }
            }
            return (b, s)
        }
        let now = Date()
        var next: [Int32: PidNet] = [:]
        var tuples = Set<String>()
        for pid in Set(bytes.keys).union(sockets.keys) {
            var n = byPid[pid] ?? PidNet()
            if let (bi, bo) = bytes[pid] {
                if let (pi, po, t) = previous[pid] {
                    let dt = max(0.5, now.timeIntervalSince(t))
                    n.inRate = Double(max(0, bi - pi)) / dt
                    n.outRate = Double(max(0, bo - po)) / dt
                }
                n.totalIn = bi; n.totalOut = bo
                previous[pid] = (bi, bo, now)
            }
            n.connections = sockets[pid]?.conns ?? []
            n.listening = sockets[pid]?.listen ?? []
            n.history = Array((n.history + [n.inRate + n.outRate]).suffix(40))
            next[pid] = n
            for ep in n.connections {
                let key = "\(pid)|\(ep.display)"
                tuples.insert(key)
                if !lastTuples.contains(key) { appearances[key, default: []].append(now) }
                resolve(ep.host)
            }
        }
        lastTuples = tuples
        byPid = next
        lastSample = now
        // Keep memory bounded.
        if appearances.count > 4000 { appearances = appearances.filter { now.timeIntervalSince($0.value.last ?? now) < 600 } }
    }

    nonisolated static func parse(_ s: String) -> Endpoint? {
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            let host = String(s[s.index(after: s.startIndex)..<close])
            let port = Int(s[s.index(after: close)...].dropFirst()) ?? 0
            return Endpoint(host: host, port: port)
        }
        guard let colon = s.lastIndex(of: ":") else { return nil }
        return Endpoint(host: String(s[..<colon]), port: Int(s[s.index(after: colon)...]) ?? 0)
    }

    private func resolve(_ ip: String) {
        guard hostnames[ip] == nil, !resolving.contains(ip), !ProcessAnalyzer.isPrivate(ip + ":0") else { return }
        resolving.insert(ip)
        DispatchQueue.global(qos: .utility).async {
            let name = NetworkMonitor.reverseDNS(ip) ?? ""
            DispatchQueue.main.async {
                NetworkMonitor.shared.hostnames[ip] = name
                NetworkMonitor.shared.resolving.remove(ip)
            }
        }
    }

    nonisolated static func reverseDNS(_ ip: String) -> String? {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(ip, nil, &hints, &res) == 0, let r = res else { return nil }
        defer { freeaddrinfo(res) }
        var host = [CChar](repeating: 0, count: 1025)
        guard getnameinfo(r.pointee.ai_addr, r.pointee.ai_addrlen, &host, socklen_t(host.count), nil, 0, NI_NAMEREQD) == 0 else { return nil }
        return String(cString: host)
    }

    /// Recognisable owner of a hostname, so "17.57.144.10" reads as "Apple".
    nonisolated static func service(_ host: String) -> String? {
        let h = host.lowercased()
        let table: [(String, String)] = [
            ("apple.com", "Apple"), ("icloud.com", "iCloud"), ("aaplimg.com", "Apple"), ("mzstatic.com", "Apple"), ("cdn-apple.com", "Apple"),
            ("1e100.net", "Google"), ("google", "Google"), ("gvt1.com", "Google"), ("googleusercontent.com", "Google"), ("youtube", "YouTube"),
            ("github", "GitHub"), ("githubusercontent.com", "GitHub"), ("anthropic.com", "Anthropic"), ("claude.ai", "Anthropic"),
            ("openai.com", "OpenAI"), ("chatgpt.com", "OpenAI"), ("microsoft", "Microsoft"), ("azure", "Microsoft Azure"), ("msedge.net", "Microsoft"),
            ("amazonaws.com", "Amazon AWS"), ("cloudfront.net", "Amazon CloudFront"), ("cloudflare", "Cloudflare"), ("akamai", "Akamai"),
            ("fastly", "Fastly"), ("tailscale", "Tailscale"), ("slack", "Slack"), ("discord", "Discord"), ("zoom.us", "Zoom"),
            ("spotify", "Spotify"), ("docker", "Docker"), ("npmjs", "npm"), ("vercel", "Vercel"), ("facebook", "Meta"), ("fbcdn", "Meta"),
            ("whatsapp", "WhatsApp"), ("telegram", "Telegram"), ("dropbox", "Dropbox"), ("notion", "Notion"), ("figma", "Figma"),
            ("parsec", "Parsec"), ("huggingface", "Hugging Face"), ("sentry.io", "Sentry"), ("segment", "Segment"), ("mixpanel", "Mixpanel"),
            ("datadoghq", "Datadog"), ("supabase", "Supabase"), ("firebase", "Firebase"), ("stripe", "Stripe"),
        ]
        return table.first { h.contains($0.0) }?.1
    }

    /// Repeated short connections at a steady interval: how implants "check in".
    func beaconing(pid: Int32) -> [(Endpoint, TimeInterval, Int)] {
        var out: [(Endpoint, TimeInterval, Int)] = []
        for (key, times) in appearances where key.hasPrefix("\(pid)|") && times.count >= 4 {
            let gaps = zip(times.dropFirst(), times).map { $0.timeIntervalSince($1) }
            let mean = gaps.reduce(0, +) / Double(gaps.count)
            let sd = (gaps.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(gaps.count)).squareRoot()
            if mean >= 3, sd / mean < 0.35, let ep = NetworkMonitor.parse(String(key.split(separator: "|").last ?? "")) {
                out.append((ep, mean, times.count))
            }
        }
        return out
    }
}
