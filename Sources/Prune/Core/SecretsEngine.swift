import CryptoKit
import Foundation

/// One credential-shaped value. The value itself is never stored: only a masked preview and a
/// one-way fingerprint (to notice the same secret reused across files).
struct SecretHit: Hashable, Identifiable {
    var id: String { "\(line):\(kind):\(fingerprint)" }
    var kind: String
    var provider: String?
    var line: Int
    var key: String?
    var masked: String
    var length: Int
    var fingerprint: String
    var confidence: Double
    var why: String
    /// Public by design (e.g. a Firebase web key or a Stripe test key): shown, but not treated as a leak.
    var lowImpact = false
}

struct SecretFile: Identifiable, Hashable {
    enum GitState: String { case tracked = "tracked by git", ignored = "ignored by git", untracked = "untracked, not ignored", notInGit = "not in git", unknown = "git status unknown" }
    enum Origin: String { case project = "Projects", home = "Home & shell" }

    var id: String { url.path }
    var url: URL
    var project: URL?
    var origin: Origin
    var label: String?
    var isEnvFile: Bool
    var isExample: Bool
    var git: GitState
    /// Some version of the file exists on a remote-tracking branch.
    var pushed = false
    /// It was committed at some point, so it lives on in history even if it's ignored now.
    var inHistory = false
    var publiclyServed = false
    var worldReadable = false
    var hits: [SecretHit]
    var tooLarge = false
    var unreadable = false
    var note: String?

    var realHits: [SecretHit] { hits.filter { !$0.lowImpact } }
    var hasSecret: Bool { !realHits.isEmpty }

    /// Something to act on (not just inventory).
    var isShellProfile: Bool { label?.contains("shell") == true }

    var isIssue: Bool {
        if origin == .home {
            // Credential stores are where tools are meant to keep logins; they matter when exposed.
            return worldReadable || (hasSecret && (isShellProfile || label == "Git plaintext credential store"))
        }
        if hasSecret { return true }
        return isEnvFile && !isExample && (git == .tracked || git == .untracked || publiclyServed)
    }

    var severity: Severity {
        if origin == .home {
            if isIssue { return .medium }
            return hasSecret ? .low : .info
        }
        if hasSecret {
            if pushed { return realHits.contains { $0.confidence >= 0.9 } ? .critical : .high }
            if git == .tracked || publiclyServed { return .high }
            if inHistory { return .high }
            return git == .ignored ? .low : .medium
        }
        return isIssue ? .medium : .low
    }

    var headline: String {
        if hasSecret {
            let kinds = Array(Set(realHits.map { $0.provider.map { "\($0) key" } ?? $0.kind })).sorted()
            return kinds.prefix(3).joined(separator: ", ") + (kinds.count > 3 ? " +\(kinds.count - 3)" : "")
        }
        if isEnvFile { return isExample ? "Example file, placeholders only" : "Environment file, no credential-shaped values" }
        return note ?? "No credential-shaped values"
    }
}

struct RemoteCredential: Hashable, Identifiable {
    var id: String { project.path }
    var project: URL
    var config: String?
}

struct SecretsReport {
    var files: [SecretFile] = []
    var remotes: [RemoteCredential] = []
    var filesChecked = 0
    var envFiles = 0
    var skippedLarge = 0
    var unreadable = 0
    var truncated = false
    var scannedAt: Date?
    /// fingerprint → files containing it (only when it appears in 2+ files).
    var reused: [String: [String]] = [:]

    var issues: [SecretFile] { files.filter(\.isIssue) }
}

enum SecretsEngine {
    // MARK: Detectors

    private struct Pattern {
        var kind: String
        var provider: String?
        var markers: [String]
        var regex: NSRegularExpression
        var confidence: Double
        var lowImpact = false
        /// Characters to keep visible at the start of the masked preview.
        var prefix: Int = 4
    }

    private static func p(_ kind: String, _ provider: String?, _ regex: String, _ markers: [String], _ confidence: Double,
                          lowImpact: Bool = false, prefix: Int = 4) -> Pattern {
        Pattern(kind: kind, provider: provider, markers: markers, regex: try! NSRegularExpression(pattern: regex), confidence: confidence, lowImpact: lowImpact, prefix: prefix)
    }

    private static let patterns: [Pattern] = [
        p("Private key", nil, #"-----BEGIN (?:RSA |EC |OPENSSH |DSA |ENCRYPTED |PGP )?PRIVATE KEY(?: BLOCK)?-----"#, ["-----begin "], 0.95, prefix: 0),
        p("AWS access key ID", "AWS", #"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"#, ["akia", "asia"], 0.9),
        p("GitHub token", "GitHub", #"\b(?:gh[pousr]_[A-Za-z0-9]{30,255}|github_pat_[A-Za-z0-9_]{40,255})\b"#, ["ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_"], 0.95, prefix: 4),
        p("GitLab token", "GitLab", #"\bglpat-[A-Za-z0-9_-]{20,}"#, ["glpat-"], 0.95, prefix: 6),
        p("Slack token", "Slack", #"\bxox[baprs]-[A-Za-z0-9-]{10,}"#, ["xox"], 0.9, prefix: 5),
        p("Slack webhook", "Slack", #"https://hooks\.slack\.com/services/T[A-Za-z0-9]+/B[A-Za-z0-9]+/[A-Za-z0-9]+"#, ["hooks.slack.com"], 0.9, prefix: 0),
        p("Discord webhook", "Discord", #"https://(?:ptb\.|canary\.)?discord(?:app)?\.com/api/webhooks/\d+/[A-Za-z0-9_-]{20,}"#, ["/api/webhooks/"], 0.9, prefix: 0),
        p("Stripe live key", "Stripe", #"\b(?:sk|rk)_live_[A-Za-z0-9]{20,}"#, ["_live_"], 0.97, prefix: 8),
        p("Stripe test key", "Stripe", #"\b(?:sk|rk)_test_[A-Za-z0-9]{20,}"#, ["_test_"], 0.6, lowImpact: true, prefix: 8),
        p("Stripe webhook secret", "Stripe", #"\bwhsec_[A-Za-z0-9]{24,}"#, ["whsec_"], 0.9, prefix: 6),
        p("OpenAI API key", "OpenAI", #"\bsk-(?:proj|svcacct|admin)-[A-Za-z0-9_-]{20,}|\bsk-[A-Za-z0-9]{20}T3BlbkFJ[A-Za-z0-9]{20}\b"#, ["sk-proj-", "sk-svcacct-", "sk-admin-", "t3blbkfj"], 0.97, prefix: 8),
        p("Anthropic API key", "Anthropic", #"\bsk-ant-(?:api|admin|oat)\d{2}-[A-Za-z0-9_-]{20,}"#, ["sk-ant-"], 0.97, prefix: 10),
        p("Google API key", "Google", #"\bAIza[0-9A-Za-z_-]{35}\b"#, ["aiza"], 0.75, prefix: 4),
        p("Google OAuth client secret", "Google", #"\bGOCSPX-[A-Za-z0-9_-]{24,}"#, ["gocspx-"], 0.95, prefix: 7),
        p("Hugging Face token", "Hugging Face", #"\bhf_[A-Za-z0-9]{30,}\b"#, ["hf_"], 0.9, prefix: 3),
        p("npm access token", "npm", #"\bnpm_[A-Za-z0-9]{36}\b"#, ["npm_"], 0.95, prefix: 4),
        p("PyPI token", "PyPI", #"\bpypi-AgEIcHlwaS5vcmc[A-Za-z0-9_-]{40,}"#, ["pypi-ageichlwas5vcmc"], 0.97, prefix: 5),
        p("SendGrid API key", "SendGrid", #"\bSG\.[A-Za-z0-9_-]{22}\.[A-Za-z0-9_-]{43}\b"#, ["sg."], 0.95, prefix: 3),
        p("Mailgun API key", "Mailgun", #"\bkey-[0-9a-f]{32}\b"#, ["key-"], 0.8, prefix: 4),
        p("Shopify access token", "Shopify", #"\bshp(?:at|ss|ca|pa)_[a-fA-F0-9]{32}\b"#, ["shpat_", "shpss_", "shpca_", "shppa_"], 0.95, prefix: 6),
        p("DigitalOcean token", "DigitalOcean", #"\bdo[por]_v1_[a-f0-9]{64}\b"#, ["dop_v1_", "doo_v1_", "dor_v1_"], 0.95, prefix: 7),
        p("Telegram bot token", "Telegram", #"\b\d{8,10}:AA[A-Za-z0-9_-]{33}\b"#, [":aa"], 0.85, prefix: 0),
        p("Groq API key", "Groq", #"\bgsk_[A-Za-z0-9]{48,}\b"#, ["gsk_"], 0.95, prefix: 4),
        p("Replicate token", "Replicate", #"\br8_[A-Za-z0-9]{37,}\b"#, ["r8_"], 0.9, prefix: 3),
        p("Perplexity API key", "Perplexity", #"\bpplx-[A-Za-z0-9]{40,}\b"#, ["pplx-"], 0.95, prefix: 5),
        p("xAI API key", "xAI", #"\bxai-[A-Za-z0-9]{60,}\b"#, ["xai-"], 0.9, prefix: 4),
        p("Notion token", "Notion", #"\b(?:secret_|ntn_)[A-Za-z0-9]{40,}\b"#, ["secret_", "ntn_"], 0.85, prefix: 4),
        p("Linear API key", "Linear", #"\blin_api_[A-Za-z0-9]{40}\b"#, ["lin_api_"], 0.95, prefix: 8),
        p("Doppler token", "Doppler", #"\bdp\.(?:st|ct|sa|scim|pt)\.[A-Za-z0-9_-]{40,}"#, ["dp.st.", "dp.ct.", "dp.sa.", "dp.pt."], 0.95, prefix: 6),
        p("Mapbox secret token", "Mapbox", #"\bsk\.eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}"#, ["sk.eyj"], 0.95, prefix: 6),
        p("Azure storage key", "Azure", #"AccountKey=[A-Za-z0-9+/=]{60,}"#, ["accountkey="], 0.95, prefix: 11),
        p("Databricks token", "Databricks", #"\bdapi[a-f0-9]{32}\b"#, ["dapi"], 0.9, prefix: 4),
        p("Atlassian API token", "Atlassian", #"\bATATT3[A-Za-z0-9_\-=]{40,}"#, ["atatt3"], 0.95, prefix: 6),
        p("Postman API key", "Postman", #"\bPMAK-[a-f0-9]{24}-[a-f0-9]{34}\b"#, ["pmak-"], 0.95, prefix: 5),
        p("age secret key", "age", #"AGE-SECRET-KEY-1[0-9A-Z]{58}"#, ["age-secret-key-"], 0.97, prefix: 15),
        p("Database URL with password", "Database", #"(?i)\b(?:postgres(?:ql)?|mysql|mariadb|mongodb(?:\+srv)?|rediss?|amqps?|mssql|sqlserver)://[^\s/@:'"]+:[^\s/@'"]+@[^\s/'"]+"#,
          ["postgres://", "postgresql://", "mysql://", "mariadb://", "mongodb://", "mongodb+srv://", "redis://", "rediss://", "amqp://", "amqps://", "mssql://", "sqlserver://"], 0.85, prefix: 0),
        p("JSON Web Token", nil, #"\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"#, ["eyj"], 0.6, prefix: 0),
    ]

    private static let assignment = try! NSRegularExpression(pattern:
        #"(?i)["']?([a-z_][a-z0-9_.-]{0,100})["']?\s*[:=]\s*(?:["']([^"'\r\n]{1,512})["']|([^\s#;,}\]]+))"#)
    private static let secretName = try! NSRegularExpression(pattern:
        #"(?i)(?:^|[_\-.])(?:password|passwd|pwd|secret|token|credentials?)(?:$|[_\-.])|api[_\-.]?key|access[_\-.]?key|private[_\-.]?key|client[_\-.]?secret|auth[_\-.]?key|signing[_\-.]?key|encryption[_\-.]?key|_authtoken|webhook[_\-.]?url"#)
    private static let netrcPassword = try! NSRegularExpression(pattern: #"(?m)^\s*machine\s+\S+(?:\s+login\s+\S+)?\s+password\s+(\S{4,})"#)
    private static let keywordGate = ["secret", "token", "password", "passwd", "pwd", "credential", "api_key", "api-key", "apikey", "access_key", "access-key",
                                      "accesskey", "private_key", "privatekey", "auth_key", "authkey", "_authtoken", "client_secret", "signing_key", "encryption_key", "webhook"]

    /// References to a secret manager, environment, or template: never the secret itself.
    private static let referenceMarkers = ["process.env", "import.meta.env", "os.environ", "getenv(", "env(", "env[", "${", "{{", "%(", "secrets.", "op://", "vault:", "vault://",
                                           "arn:aws:secretsmanager", "sm://", "projects/", "keychain", "credstash", "doppler run", "settings.", "config.", "<%"]
    private static let placeholders = ["example", "placeholder", "changeme", "change_me", "change-me", "replace", "your_", "your-", "yourkey", "dummy", "redacted", "not-a-", "fake",
                                       "xxxxx", "*****", "•••", "test_token", "test-key", "sample", "todo", "insert", "<", "lorem", "foobar", "mysecret", "my_secret", "secret123",
                                       "password123", "abcdef", "123456", "000000", "111111", "null", "undefined", "none", "nil", "true", "false", "disabled", "enabled"]

    static func isPlaceholder(_ raw: String) -> Bool {
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let low = v.lowercased()
        if v.isEmpty || low == "password" || low == "secret" || low == "secretkey" || low == "token" || low == "localhost" { return true }
        if placeholders.contains(where: { low.contains($0) }) { return true }
        if referenceMarkers.contains(where: { low.contains($0) }) { return true }
        if low.hasPrefix("$") || low.hasPrefix("http://localhost") { return true }
        // One repeated character, or a plain sequence.
        if Set(v).count <= 2 { return true }
        return false
    }

    static func entropy(_ v: String) -> Double {
        guard !v.isEmpty else { return 0 }
        var counts: [Character: Int] = [:]
        for c in v { counts[c, default: 0] += 1 }
        return counts.values.reduce(0.0) { total, n in
            let p = Double(n) / Double(v.count)
            return total - p * log2(p)
        }
    }

    /// 0...1: how likely a value assigned to a secret-sounding name is a real credential.
    static func score(value raw: String, key: String, envFile: Bool) -> (Double, String) {
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard v.count >= 6, v.count <= 512, !isPlaceholder(v) else { return (0, "placeholder or reference") }
        let k = key.lowercased()
        let low = v.lowercased()
        // Paths, URLs without credentials, identifiers and code are not secrets.
        if v.contains("/") && !v.contains("+") && !v.contains("=") && v.split(separator: "/").count > 2 { return (0, "looks like a path") }
        if low.hasPrefix("http") && !v.contains("@") { return (0, "a URL without credentials") }
        if v.range(of: #"^[A-Z][A-Z0-9_]+$"#, options: .regularExpression) != nil && v.contains("_") { return (0, "an environment variable name") }
        if v.contains("(") || v.contains(")") || v.hasSuffix(";") { return (0, "code, not a value") }
        if v.contains("{") && v.contains("}") { return (0, "a template string") }
        if v.range(of: #"^[a-z0-9_]+(\.[a-z0-9_]+)+$"#, options: .regularExpression) != nil { return (0, "a dotted identifier") }
        let isPassword = k.contains("password") || k.contains("passwd") || k.hasSuffix("pwd")
        if isPassword {
            let c = envFile ? 0.8 : 0.65
            return (c, "a non-placeholder value assigned to \(key)")
        }
        guard v.count >= 12 else { return (0, "too short for a token") }
        if v.contains(" ") { return (0, "contains spaces, reads like text") }
        let e = entropy(v)
        var s = 0.42
        var notes: [String] = []
        if e >= 4.2 { s += 0.3; notes.append("high randomness") } else if e >= 3.6 { s += 0.22; notes.append("random-looking") } else if e >= 3.0 { s += 0.12 } else { s -= 0.25 }
        if v.count >= 32 { s += 0.12 } else if v.count >= 20 { s += 0.08 }
        let classes = [v.contains { $0.isLowercase }, v.contains { $0.isUppercase }, v.contains { $0.isNumber }, v.contains { !$0.isLetter && !$0.isNumber }].filter { $0 }.count
        if classes >= 3 { s += 0.08 }
        if !v.contains(where: \.isNumber) && v.allSatisfy({ $0.isLetter || $0 == "-" || $0 == "_" || $0 == " " || $0 == "." }) { s -= 0.35; notes.append("reads like words") }
        if v.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#, options: [.regularExpression, .caseInsensitive]) != nil { s -= 0.08; notes.append("UUID-shaped") }
        if envFile { s += 0.08 }
        return (min(max(s, 0), 0.92), (["\(v.count) characters"] + notes).joined(separator: ", "))
    }

    static func fingerprint(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    static func mask(_ value: String, keep prefix: Int) -> String {
        let chars = Array(value)
        guard chars.count > 8 else { return String(repeating: "•", count: 8) }
        let head = String(chars.prefix(min(prefix, chars.count / 3)))
        let tail = String(chars.suffix(2))
        return head + String(repeating: "•", count: 8) + tail
    }

    private static func provider(forKey key: String) -> String? {
        let k = key.lowercased()
        let table: [(String, String)] = [("aws", "AWS"), ("openai", "OpenAI"), ("anthropic", "Anthropic"), ("claude", "Anthropic"), ("stripe", "Stripe"),
                                        ("github", "GitHub"), ("gitlab", "GitLab"), ("google", "Google"), ("gcp", "Google"), ("firebase", "Firebase"), ("slack", "Slack"),
                                        ("twilio", "Twilio"), ("sendgrid", "SendGrid"), ("supabase", "Supabase"), ("postgres", "Database"), ("mysql", "Database"),
                                        ("mongo", "Database"), ("database", "Database"), ("db_", "Database"), ("redis", "Redis"), ("jwt", "JWT signing"),
                                        ("sentry", "Sentry"), ("azure", "Azure"), ("cloudflare", "Cloudflare"), ("vercel", "Vercel"), ("npm", "npm"),
                                        ("huggingface", "Hugging Face"), ("hf_", "Hugging Face"), ("gemini", "Google"), ("mistral", "Mistral"), ("groq", "Groq"),
                                        ("resend", "Resend"), ("clerk", "Clerk"), ("auth0", "Auth0"), ("nextauth", "Auth.js"), ("smtp", "Email"), ("mail", "Email")]
        return table.first { k.contains($0.0) }?.1
    }

    /// Detects credential-shaped values in text. Line numbers are 1-based.
    static func detect(in text: String, envFile: Bool = false, codeFile: Bool = false, threshold: Double = 0.55) -> [SecretHit] {
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        let lowerNS = text.lowercased() as NSString
        // Literal NSString search: Swift's Unicode-aware String.contains is far too slow across thousands of files.
        func has(_ s: String) -> Bool { lowerNS.range(of: s, options: .literal).location != NSNotFound }
        var newlines: [Int]?
        func line(_ offset: Int) -> Int {
            if newlines == nil { newlines = text.utf16.enumerated().compactMap { $0.element == 10 ? $0.offset : nil } }
            let positions = newlines ?? []
            var lo = 0, hi = positions.count
            while lo < hi { let mid = (lo + hi) / 2; if positions[mid] < offset { lo = mid + 1 } else { hi = mid } }
            return lo + 1
        }
        var hits: [SecretHit] = []
        var coveredLines = Set<Int>()
        for pat in patterns where pat.markers.contains(where: has) {
            var count = 0
            pat.regex.enumerateMatches(in: text, range: whole) { m, _, stop in
                guard let m else { return }
                let value = ns.substring(with: m.range)
                var kind = pat.kind, provider = pat.provider, confidence = pat.confidence, lowImpact = pat.lowImpact
                var why = "Matches the \(pat.kind) format"
                if pat.kind == "Private key" {
                    if value.contains("ENCRYPTED") { confidence = 0.5; lowImpact = true; why = "A passphrase-protected private key" }
                    if has("\"service_account\"") { provider = "Google Cloud"; kind = "Service account key"; why = "A Google Cloud service-account key file" }
                } else if pat.kind == "JSON Web Token" {
                    let role = jwtRole(value)
                    if role == "service_role" { kind = "Supabase service-role key"; provider = "Supabase"; confidence = 0.97; why = "A JWT with role service_role (bypasses row-level security)" }
                    else if role == "anon" { kind = "Supabase anon key"; provider = "Supabase"; lowImpact = true; confidence = 0.6; why = "Public by design; safe in client code" }
                    else if isPlaceholder(value) { return }
                } else if pat.kind == "Database URL with password" {
                    guard let at = value.lastIndex(of: "@"), let colon = value[..<at].lastIndex(of: ":") else { return }
                    let password = String(value[value.index(after: colon)..<at])
                    let host = value[value.index(after: at)...].lowercased()
                    let weak = ["postgres", "password", "root", "admin", "secret", "example", "pass", "mysql", "test", "dev", "guest"].contains(password.lowercased())
                    let local = ["localhost", "127.0.0.1", "0.0.0.0", "host.docker.internal", "[::1]"].contains { host.hasPrefix($0) }
                    if isPlaceholder(password) || (weak && (local || host.hasPrefix("db") || host.hasPrefix("postgres"))) { return }
                    why = "A connection string with an embedded password"
                    if local { lowImpact = true; why = "A local development database password" }
                } else if pat.kind == "Google API key" {
                    why = "Google API key. Firebase web keys are public by design; others should be restricted."
                } else if isPlaceholder(value) {
                    return
                }
                let ln = line(m.range.location)
                coveredLines.insert(ln)
                hits.append(SecretHit(kind: kind, provider: provider, line: ln, key: nil,
                                      masked: pat.prefix == 0 ? (kind == "Private key" || kind == "Service account key" ? "-----BEGIN … PRIVATE KEY-----" : mask(value, keep: 0)) : mask(value, keep: pat.prefix),
                                      length: value.count, fingerprint: fingerprint(value), confidence: confidence, why: why, lowImpact: lowImpact))
                count += 1
                if count >= 50 { stop.pointee = true }
            }
        }
        // Netrc-style "password value" pairs.
        if has("machine ") && has("password ") {
            netrcPassword.enumerateMatches(in: text, range: whole) { m, _, _ in
                guard let m else { return }
                let value = ns.substring(with: m.range(at: 1))
                guard !isPlaceholder(value) else { return }
                let ln = line(m.range.location)
                coveredLines.insert(ln)
                hits.append(SecretHit(kind: "Stored login password", provider: nil, line: ln, key: "password", masked: mask(value, keep: 0), length: value.count,
                                      fingerprint: fingerprint(value), confidence: 0.85, why: "A netrc password entry"))
            }
        }
        guard keywordGate.contains(where: has) else { return hits.sorted { $0.line < $1.line } }
        var matches = 0
        assignment.enumerateMatches(in: text, range: whole) { m, _, stop in
            guard let m else { return }
            matches += 1
            if matches >= 20_000 { stop.pointee = true }
            let key = ns.substring(with: m.range(at: 1))
            let keyLower = key.lowercased()
            let keyRange = NSRange(location: 0, length: (key as NSString).length)
            guard secretName.firstMatch(in: key, range: keyRange) != nil || keyLower.hasSuffix("token") || keyLower.hasSuffix("password") || keyLower.hasSuffix("secret") else { return }
            // Settings that only name or toggle a secret.
            if ["_file", "_path", "_url_env", "_name", "_id", "_enabled", "_length", "_ttl", "_expiry", "_expires", "_header", "_type", "_field", "_prefix", "_env", "_sha256", "_sha1", "_md5", "_hash", "_digest", "_checksum", "_count", "_len", "_size"].contains(where: { keyLower.hasSuffix($0) }) && !keyLower.hasSuffix("webhook_url") { return }
            // In source code an unquoted right-hand side is an expression, not a literal secret.
            let quoted = m.range(at: 2).location != NSNotFound
            if codeFile && !quoted { return }
            let valueRange = m.range(at: quoted ? 2 : 3)
            guard valueRange.location != NSNotFound else { return }
            let value = ns.substring(with: valueRange)
            let ln = line(m.range.location)
            guard !coveredLines.contains(ln) else { return }
            let (s, why) = score(value: value, key: key, envFile: envFile)
            guard s >= threshold else { return }
            coveredLines.insert(ln)
            hits.append(SecretHit(kind: "Hard-coded credential", provider: provider(forKey: key), line: ln, key: key,
                                  masked: mask(value, keep: 2), length: value.count, fingerprint: fingerprint(value),
                                  confidence: s, why: "\(key) = \(why)"))
        }
        return hits.sorted { ($0.line, $0.kind) < ($1.line, $1.kind) }
    }

    private static func jwtRole(_ token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["role"] as? String
    }

    // MARK: File classification

    static func isEnvironmentFile(_ name: String) -> Bool {
        let n = name.lowercased()
        return n == ".env" || n == ".envrc" || n.hasPrefix(".env.") || n.hasPrefix(".env-") || n == ".dev.vars" || n.hasSuffix(".env")
    }

    static func isExample(_ name: String) -> Bool {
        let n = name.lowercased()
        return ["example", "sample", "template", "dist", "defaults", "schema"].contains { n.hasSuffix("." + $0) || n.hasSuffix("-" + $0) || n.hasSuffix("_" + $0) }
    }

    static let extensions: Set<String> = [
        "js", "jsx", "ts", "tsx", "mjs", "cjs", "py", "rb", "php", "go", "rs", "java", "kt", "kts", "swift", "m", "mm", "h", "c", "cpp", "cs", "dart", "ex", "exs",
        "json", "jsonc", "yaml", "yml", "toml", "ini", "cfg", "conf", "config", "properties", "xml", "plist", "tf", "tfvars", "gradle",
        "sh", "bash", "zsh", "fish", "sql", "html", "vue", "svelte", "md", "txt", "pem", "key", "p8", "npmrc", "pypirc", "netrc", "xcconfig"
    ]
    static let codeExtensions: Set<String> = ["js", "jsx", "ts", "tsx", "mjs", "cjs", "py", "rb", "php", "go", "rs", "java", "kt", "kts", "swift", "m", "mm", "h", "c", "cpp", "cs",
                                              "dart", "ex", "exs", "html", "vue", "svelte", "md", "txt", "gradle", "sql"]
    static let namedFiles: Set<String> = [".npmrc", ".pypirc", ".netrc", "credentials", ".dev.vars", "secrets.toml", ".secrets", "id_rsa", "id_ed25519", "id_ecdsa", ".htpasswd", "wp-config.php"]
    static let skipDirs: Set<String> = [
        ".git", ".hg", ".svn", "node_modules", "vendor", "Pods", "Carthage", "site-packages", ".venv", "venv", "__pycache__",
        ".gradle", ".terraform", ".build", "target", ".next", ".nuxt", ".turbo", ".cache", ".Trash", ".Trashes", "DerivedData", "checkouts", "dist-packages",
        "third_party", "third-party", "thirdparty", "external", "_deps", "deps", "bower_components", "coverage", ".pytest_cache", ".mypy_cache"
    ]
    static let lockFiles: Set<String> = ["package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml", "bun.lock", "cargo.lock", "composer.lock", "poetry.lock", "uv.lock", "gemfile.lock", "go.sum", "podfile.lock", "package.resolved"]
    static let maxFileBytes: Int64 = 512 * 1024

    static func read(_ url: URL) -> (String?, Bool, Bool) {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return (nil, false, false) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return (nil, false, false) }
        let worldReadable = st.st_mode & 0o004 != 0
        guard st.st_size <= maxFileBytes else { return (nil, true, worldReadable) }
        guard let data = try? handle.read(upToCount: Int(maxFileBytes) + 1), !data.contains(0),
              let text = String(data: data, encoding: .utf8) else { return (nil, false, worldReadable) }
        return (text, false, worldReadable)
    }

    // MARK: Scanning

    static func scan(index: ProjectIndex, settings: SettingsSnapshot, includeHome: Bool = true, progress: (String) -> Void = { _ in }) -> SecretsReport {
        var report = scanProjects(index: index, settings: settings, progress: progress)
        if includeHome { progress("Checking home credential files…"); report.files += scanHome() }
        var byFingerprint: [String: Set<String>] = [:]
        for f in report.files { for h in f.realHits { byFingerprint[h.fingerprint, default: []].insert(f.url.path) } }
        report.reused = byFingerprint.filter { $0.value.count > 1 }.mapValues { Array($0).sorted() }
        report.scannedAt = Date()
        return report
    }

    static func scanProjects(index: ProjectIndex, settings: SettingsSnapshot, progress: (String) -> Void = { _ in }) -> SecretsReport {
        var report = SecretsReport()
        let roots = index.projects.values.filter { $0.gitKind != .none || index.outermostProject(for: $0.root) == $0.root.path }
            .map(\.root).sorted { $0.path.count < $1.path.count }
        let maxFiles = 100_000, maxDirs = 150_000
        let ignoredIDs = Set(UserDefaults.standard.stringArray(forKey: "secretsIgnored") ?? [])

        // 1. Walk (cheap readdir) to collect candidate files.
        progress("Finding config and source files…")
        var stack = roots.map { ($0, 0) }
        var visited = Set<String>()
        var candidates: [(URL, Bool)] = []
        walk: while let (dir, depth) = stack.popLast() {
            guard visited.insert(dir.path).inserted, !settings.isExcluded(dir) else { continue }
            if visited.count > maxDirs { report.truncated = true; break }
            guard let entries = FS.list(dir.path) else { report.unreadable += 1; continue }
            for e in entries {
                let file = dir.appendingPathComponent(e.name)
                guard !e.isLink else { continue }
                if e.isDir {
                    if depth < 20 && !skipDirs.contains(e.name) && !e.name.hasSuffix(".app") && !e.name.hasSuffix(".photoslibrary") && !e.name.hasSuffix(".xcassets")
                        && !settings.isExcluded(file) { stack.append((file, depth + 1)) }
                    continue
                }
                let lowerName = e.name.lowercased()
                let env = isEnvironmentFile(e.name)
                if lockFiles.contains(lowerName) || lowerName.hasSuffix(".min.js") || lowerName.hasSuffix(".map") { continue }
                guard env || namedFiles.contains(lowerName) || extensions.contains(file.pathExtension.lowercased()) else { continue }
                if candidates.count >= maxFiles { report.truncated = true; break walk }
                candidates.append((file, env))
            }
        }
        report.filesChecked = candidates.count
        report.envFiles = candidates.filter(\.1).count

        // 2. Read and detect in parallel.
        progress("Reading \(candidates.count) files…")
        var found = [SecretFile?](repeating: nil, count: candidates.count)
        var large = 0, unreadable = 0
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: candidates.count) { i in
            let (file, env) = candidates[i]
            let (text, tooLarge, worldReadable) = read(file)
            let code = !env && codeExtensions.contains(file.pathExtension.lowercased())
            var hits = text.map { detect(in: $0, envFile: env, codeFile: code) } ?? []
            hits.removeAll { ignoredIDs.contains(file.path + "#" + $0.fingerprint) }
            let example = env ? isExample(file.lastPathComponent) : false
            if example || isTestPath(file.path) {
                // Fixtures and examples hold sample values; only a real provider-format key still counts.
                for k in hits.indices where !(hits[k].provider != nil && hits[k].confidence >= 0.9 && hits[k].kind != "Database URL with password" && hits[k].kind != "Hard-coded credential") {
                    hits[k].lowImpact = true
                    hits[k].why += example ? " (example file)" : " (test fixture)"
                }
            }
            lock.lock()
            if tooLarge { large += 1 }
            if text == nil && !tooLarge { unreadable += 1 }
            lock.unlock()
            guard env || !hits.isEmpty else { return }
            let components = file.pathComponents.map { $0.lowercased() }
            found[i] = SecretFile(url: file, project: index.scopeRoot(for: file).map { URL(fileURLWithPath: $0) }, origin: .project,
                                  isEnvFile: env, isExample: example, git: .notInGit,
                                  publiclyServed: components.contains("public") || components.contains("www") || components.contains("wwwroot") || components.contains("static"),
                                  worldReadable: worldReadable, hits: hits, tooLarge: tooLarge, unreadable: text == nil && !tooLarge)
        }
        report.skippedLarge = large
        report.unreadable += unreadable

        // 3. Git exposure, grouped by repository (each repository checked once, repositories in parallel).
        progress("Checking git exposure…")
        var files = found.compactMap { $0 }
        var byRepo: [String: [Int]] = [:]
        for (i, f) in files.enumerated() {
            if let root = index.scopeRoot(for: f.url), let p = index.projects[root], p.gitKind != .none { byRepo[root, default: []].append(i) }
        }
        let repos = Array(byRepo.keys)
        DispatchQueue.concurrentPerform(iterations: repos.count) { r in
            let root = repos[r], repo = URL(fileURLWithPath: root)
            let ls = Git.run(repo, ["ls-files", "--cached", "-z"], timeout: 60)
            let tracked: Set<String>? = ls.ok ? Set(ls.stdout.split(separator: "\0").map(String.init)) : nil
            for i in byRepo[root] ?? [] {
                var f = files[i]
                let rel = String(f.url.path.dropFirst(root.count + 1))
                f.project = repo
                if let tracked {
                    if tracked.contains(rel) { f.git = .tracked }
                    else {
                        let ignored = Git.run(repo, ["check-ignore", "-q", "--", rel], timeout: 15)
                        f.git = ignored.status == 0 ? .ignored : (ignored.status == 1 ? .untracked : .unknown)
                    }
                } else { f.git = .unknown }
                if f.hasSecret {
                    f.pushed = !Git.run(repo, ["log", "--remotes", "-1", "--format=%h", "--", rel], timeout: 20).stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    f.inHistory = f.pushed || !Git.run(repo, ["log", "--all", "-1", "--format=%h", "--", rel], timeout: 20).stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                lock.lock(); files[i] = f; lock.unlock()
            }
        }
        report.files = files
        progress("Checking git remotes…")
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
            report.remotes.append(RemoteCredential(project: project.root, config: config.flatMap { FS.exists($0) ? $0.path : nil }))
        }
        return report
    }

    static func isTestPath(_ path: String) -> Bool {
        let p = path.lowercased()
        let comps = p.split(separator: "/").dropLast()
        if comps.contains(where: { c in ["test", "tests", "spec", "fixtures", "__tests__", "__mocks__", "mocks", "testdata", "e2e", "docs", "examples", "samples"].contains(String(c))
            || c.hasSuffix("-tests") || c.hasSuffix("_tests") || c.hasSuffix("-test") || c.hasPrefix("test-") }) { return true }
        let name = (p as NSString).lastPathComponent
        return [".test.", ".spec.", "_test.", "_spec.", "test_"].contains { name.contains($0) } || name.hasSuffix(".md")
    }

    static func hasEmbeddedRemoteCredential(_ value: String) -> Bool {
        guard let url = URLComponents(string: value), url.host != nil else { return false }
        if let password = url.password, !password.isEmpty,
           !["example", "placeholder", "your_password", "replace"].contains(where: { password.lowercased().contains($0) }) { return true }
        if let user = url.user, user.count >= 16, score(value: user, key: "token", envFile: false).0 >= 0.55 { return true }
        return (url.queryItems ?? []).contains { item in
            let key = item.name.lowercased()
            return ["token", "secret", "password", "credential", "api_key", "apikey"].contains(where: { key.contains($0) }) && !(item.value ?? "").isEmpty
        }
    }

    /// Well-known plaintext credential stores and shell profiles in the home folder.
    static let homeFiles: [(String, String)] = [
        (".zshrc", "Zsh shell profile"), (".zprofile", "Zsh shell profile"), (".zshenv", "Zsh shell profile"), (".bashrc", "Bash shell profile"),
        (".bash_profile", "Bash shell profile"), (".profile", "Login shell profile"), (".config/fish/config.fish", "Fish shell profile"),
        (".aws/credentials", "AWS CLI credentials"), (".netrc", "netrc logins (curl, git, pip)"), (".git-credentials", "Git plaintext credential store"),
        (".npmrc", "npm registry auth"), (".yarnrc.yml", "Yarn registry auth"), (".pypirc", "PyPI upload credentials"), (".docker/config.json", "Docker registry logins"),
        (".config/gh/hosts.yml", "GitHub CLI token"), (".kube/config", "Kubernetes cluster credentials"), (".cargo/credentials.toml", "crates.io token"),
        (".gem/credentials", "RubyGems API key"), (".m2/settings.xml", "Maven server passwords"), (".gradle/gradle.properties", "Gradle properties"),
        (".composer/auth.json", "Composer auth"), (".terraform.d/credentials.tfrc.json", "Terraform Cloud token"),
        (".config/gcloud/application_default_credentials.json", "Google Cloud credentials"), (".cache/huggingface/token", "Hugging Face token"),
        (".huggingface/token", "Hugging Face token"), (".codex/auth.json", "Codex CLI login"), (".config/configstore/firebase-tools.json", "Firebase CLI login"),
    ]

    static func scanHome(home: URL = FS.home) -> [SecretFile] {
        var out: [SecretFile] = []
        for (rel, label) in homeFiles {
            let url = home.appendingPathComponent(rel)
            guard FS.exists(url), !FS.isSymlink(url) else { continue }
            let (text, tooLarge, worldReadable) = read(url)
            var hits = text.map { detect(in: $0, envFile: label.contains("shell") == false) } ?? []
            if url.lastPathComponent == ".git-credentials", let text {
                hits += text.split(separator: "\n").enumerated().compactMap { i, line in
                    hasEmbeddedRemoteCredential(String(line)) ? SecretHit(kind: "Git password or token", provider: URLComponents(string: String(line))?.host, line: i + 1, key: nil,
                                                                         masked: "https://user:••••••••@" + (URLComponents(string: String(line))?.host ?? "host"), length: line.count,
                                                                         fingerprint: fingerprint(String(line)), confidence: 0.95, why: "Stored in plain text by git's \u{201C}store\u{201D} helper") : nil
                }
            }
            let isShell = label.contains("shell")
            if isShell && hits.isEmpty { continue }
            var f = SecretFile(url: url, project: nil, origin: .home, label: label, isEnvFile: false, isExample: false, git: .notInGit,
                               worldReadable: worldReadable, hits: hits, tooLarge: tooLarge, unreadable: text == nil && !tooLarge)
            f.note = isShell ? "Exported secrets reach every program you start, including npm and pip install scripts."
                : (worldReadable ? "Other accounts on this Mac can read this file." : "Normal for this tool; keep it readable only by you.")
            out.append(f)
        }
        for key in FS.children(home.appendingPathComponent(".ssh")) where key.lastPathComponent.hasPrefix("id_") && key.pathExtension != "pub" {
            guard let text = FS.readText(key, limit: 64 * 1024) else { continue }
            let unencrypted = sshKeyIsUnencrypted(text)
            var st = stat(); lstat(key.path, &st)
            out.append(SecretFile(url: key, project: nil, origin: .home, label: "SSH private key", isEnvFile: false, isExample: false, git: .notInGit,
                                  worldReadable: st.st_mode & 0o044 != 0,
                                  hits: unencrypted ? [SecretHit(kind: "SSH key without passphrase", provider: "SSH", line: 1, key: nil, masked: "-----BEGIN … PRIVATE KEY-----",
                                                                 length: text.count, fingerprint: fingerprint(text), confidence: 0.6,
                                                                 why: "Anyone who copies this file can use it", lowImpact: true)] : [],
                                  note: unencrypted ? "No passphrase. Add one with ssh-keygen -p, and let the macOS keychain remember it." : "Protected by a passphrase."))
        }
        return out
    }

    static func sshKeyIsUnencrypted(_ text: String) -> Bool {
        if text.contains("ENCRYPTED") || text.contains("Proc-Type: 4,ENCRYPTED") { return false }
        guard text.contains("BEGIN OPENSSH PRIVATE KEY") else { return text.contains("PRIVATE KEY") }
        let body = text.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        guard let data = Data(base64Encoded: String(body)) else { return false }
        // openssh-key-v1\0, then length-prefixed ciphername ("none" when unencrypted).
        let magic = 15
        guard data.count >= magic + 8 else { return false }
        let len = data[magic..<magic + 4].reduce(0) { $0 << 8 | Int($1) }
        guard len > 0, len < 64, data.count >= magic + 4 + len else { return false }
        return String(data: data[(magic + 4)..<(magic + 4 + len)], encoding: .utf8) == "none"
    }

    // MARK: Fixes (each confirmed in the UI)

    static func repoRoot(for file: URL) -> URL? {
        let r = Git.run(file.deletingLastPathComponent(), ["rev-parse", "--show-toplevel"], timeout: 10)
        guard r.ok else { return nil }
        let path = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    /// Appends the file to the repository's root .gitignore and confirms git now ignores it.
    static func addToGitignore(_ file: URL) -> (Bool, String) {
        guard let root = repoRoot(for: file) else { return (false, "This file isn't inside a git repository.") }
        let resolved = file.resolvingSymlinksInPath().path, rootPath = root.resolvingSymlinksInPath().path
        guard resolved.hasPrefix(rootPath + "/") else { return (false, "The file is outside its repository.") }
        let rel = String(resolved.dropFirst(rootPath.count + 1))
        let ignoreFile = root.appendingPathComponent(".gitignore")
        var text = (try? String(contentsOf: ignoreFile, encoding: .utf8)) ?? ""
        let entry = "/" + rel
        if !text.split(separator: "\n").contains(where: { $0.trimmingCharacters(in: .whitespaces) == entry }) {
            if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
            text += "\n# Added by Prune: keep local secrets out of git\n\(entry)\n"
            do { try text.write(to: ignoreFile, atomically: true, encoding: .utf8) } catch { return (false, "Couldn't update .gitignore: \(error.localizedDescription)") }
        }
        let check = Git.run(root, ["check-ignore", "-q", "--", rel], timeout: 10)
        if check.status == 0 { return (true, "Added \(entry) to .gitignore.") }
        let trackedNow = !Git.run(root, ["ls-files", "--", rel], timeout: 10).stdout.isEmpty
        return (false, trackedNow ? "Added to .gitignore, but git still tracks the file. Use Stop tracking." : "Added to .gitignore, but git doesn't report it as ignored. Check for a negating rule.")
    }

    /// Removes the file from git's index (it stays on disk) and ignores it from now on.
    static func stopTracking(_ file: URL) -> (Bool, String) {
        guard let root = repoRoot(for: file) else { return (false, "This file isn't inside a git repository.") }
        let rootPath = root.resolvingSymlinksInPath().path
        let rel = String(file.resolvingSymlinksInPath().path.dropFirst(rootPath.count + 1))
        let r = Git.run(root, ["rm", "--cached", "-q", "--", rel], timeout: 20)
        guard r.ok else { return (false, "git rm --cached failed: \(r.stderr)") }
        guard FS.exists(file) else { return (false, "Unexpected: the file is missing after untracking.") }
        let ignored = addToGitignore(file)
        return (true, "Git no longer tracks \(file.lastPathComponent) (the file is still on disk). \(ignored.1) Commit this change, and rotate the credential: it remains in git history.")
    }

    static func restrictPermissions(_ file: URL) -> (Bool, String) {
        guard chmod(file.path, 0o600) == 0 else { return (false, String(cString: strerror(errno))) }
        return (true, "Only your account can read \(file.lastPathComponent) now.")
    }

    /// Writes "<name>.example" next to an env file: the same keys, values blanked.
    static func makeExample(_ file: URL) -> (Bool, String) {
        guard let text = FS.readText(file) else { return (false, "Couldn't read the file.") }
        let dest = file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent + ".example")
        guard !FS.exists(dest) else { return (false, "\(dest.lastPathComponent) already exists.") }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { return String(line) }
            return String(line[...eq])
        }
        do { try lines.joined(separator: "\n").write(to: dest, atomically: true, encoding: .utf8) }
        catch { return (false, error.localizedDescription) }
        return (true, "Created \(dest.lastPathComponent) with the same keys and empty values. It's safe to commit.")
    }

    static func ignore(_ file: SecretFile) {
        var list = UserDefaults.standard.stringArray(forKey: "secretsIgnored") ?? []
        list += file.hits.map { file.url.path + "#" + $0.fingerprint }
        UserDefaults.standard.set(Array(Set(list)), forKey: "secretsIgnored")
    }

    static func openInEditor(_ file: URL, line: Int?) {
        for (tool, args) in [("cursor", ["-g"]), ("code", ["-g"]), ("zed", [])] {
            if let path = Shell.which(tool) {
                let target = line.map { "\(file.path):\($0)" } ?? file.path
                DispatchQueue.global().async { _ = Shell.run(path, args + [target], timeout: 10) }
                return
            }
        }
        _ = Shell.run("/usr/bin/open", ["-t", file.path], timeout: 10)
    }
}
