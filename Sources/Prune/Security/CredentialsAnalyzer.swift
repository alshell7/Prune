import Foundation

/// Security-report view of the secrets engine. Findings contain types, masked previews and line numbers, never values.
enum CredentialsAnalyzer {
    struct Signal: Hashable { var kind: String; var line: Int }

    static func isEnvironmentFile(_ name: String) -> Bool { SecretsEngine.isEnvironmentFile(name) }
    static func hasEmbeddedRemoteCredential(_ value: String) -> Bool { SecretsEngine.hasEmbeddedRemoteCredential(value) }

    static func signals(in text: String) -> [Signal] {
        SecretsEngine.detect(in: text).filter { !$0.lowImpact }.map { Signal(kind: $0.kind, line: $0.line) }
    }

    static func scan(index: ProjectIndex, settings: SettingsSnapshot, includeHome: Bool = false, report: inout SecurityReport) {
        let secrets = SecretsEngine.scan(index: index, settings: settings, includeHome: includeHome)
        report.secrets = secrets
        report.findings += findings(from: secrets)
        report.stats["credential files"] = secrets.filesChecked
        report.stats["environment files"] = secrets.envFiles
    }

    static func findings(from secrets: SecretsReport) -> [SecurityFinding] {
        var out: [SecurityFinding] = []
        for f in secrets.files {
            var evidence = f.realHits.prefix(15).map { h in
                "\(h.provider.map { "\($0) · " } ?? "")\(h.kind) · line \(h.line) · \(h.masked)"
            }
            if f.realHits.count > 15 { evidence.append("\(f.realHits.count - 15) more possible matches") }
            if f.origin == .project { evidence.append("File is \(f.git.rawValue).") }
            if f.pushed { evidence.append("A version of this file is on a remote branch, so the credential has left this Mac.") }
            else if f.inHistory && f.git != .tracked { evidence.append("It was committed in the past and remains in git history.") }
            if f.publiclyServed { evidence.append("Located under a public web folder; check whether it is deployed.") }
            if f.worldReadable && f.origin == .home { evidence.append("Readable by other accounts on this Mac.") }
            if f.tooLarge { evidence.append("File exceeds 512 KiB; its contents were not inspected.") }
            if f.unreadable { evidence.append("The file could not be read as UTF-8 text.") }
            let title: String
            if f.origin == .home { title = f.hasSecret ? "Credentials in \(f.label ?? f.url.lastPathComponent)" : (f.label ?? f.url.lastPathComponent) }
            else { title = f.hasSecret ? "Possible credentials in \(f.url.lastPathComponent)" : "Environment file: \(f.url.lastPathComponent)" }
            let advice: String
            if f.pushed { advice = "Rotate the credential now: it's on a remote. Then stop tracking the file and keep the real value in an ignored file or a secret manager." }
            else if f.hasSecret && f.origin == .project { advice = "Review the indicated lines. If a real credential was exposed, revoke or rotate it, remove it from source and deployment artifacts, and review repository history." }
            else if f.origin == .home && f.isShellProfile { advice = "Move exported secrets out of the shell profile (use the keychain, a password-manager CLI, or per-project ignored env files)." }
            else if f.origin == .home { advice = "Keep this file readable only by you (chmod 600)." }
            else { advice = "Keep real secrets out of tracked or publicly served files. Use an ignored local environment file and a placeholder-only example." }
            out.append(SecurityFinding(id: "credentials:\(f.url.path)", area: .credentials, severity: f.severity,
                title: title, subtitle: FS.tildePath(f.url), evidence: evidence,
                explanation: "Prune checks local files for credential-shaped values (known token formats plus a randomness score for values assigned to secret-sounding names). Secret values are never stored or shown in full.",
                legitNote: "A match can be a test value, a public identifier, or a secret intentionally stored in an ignored local file. Prune does not verify credentials or contact a provider.",
                recommendation: advice, actions: [], paths: [f.url.path], inventoryOnly: !f.isIssue))
        }
        for r in secrets.remotes {
            out.append(SecurityFinding(id: "credentials:remote:\(r.project.path)", area: .credentials, severity: .medium,
                title: "Credential embedded in a Git remote", subtitle: FS.tildePath(r.project),
                evidence: ["A configured remote URL contains a possible credential. Its value is not shown."],
                explanation: "Git stores remote URLs in repository configuration, where a password or token can be read by other processes with access to the file.",
                legitNote: "The value may be a placeholder. Prune does not verify credentials or contact the remote.",
                recommendation: "Move authentication into a credential manager or SSH key, update the remote URL, and rotate any exposed credential.",
                actions: [], paths: r.config.map { [$0] } ?? []))
        }
        for (fp, files) in secrets.reused where files.count > 1 {
            out.append(SecurityFinding(id: "credentials:reused:\(fp)", area: .credentials, severity: .low,
                title: "The same secret appears in \(files.count) files", subtitle: files.map { FS.tildePath(URL(fileURLWithPath: $0)) }.prefix(3).joined(separator: ", "),
                evidence: files.map { FS.tildePath(URL(fileURLWithPath: $0)) },
                explanation: "Prune compares one-way fingerprints of detected values. A reused credential has to be rotated everywhere at once.",
                legitNote: "Copies of the same local env file are common.", recommendation: "Keep one source of truth (a secret manager or one ignored env file).",
                actions: [], paths: files))
        }
        if secrets.truncated || secrets.skippedLarge > 0 || secrets.unreadable > 0 {
            var reasons: [String] = []
            if secrets.truncated { reasons.append("The 100,000-file or directory limit was reached.") }
            if secrets.skippedLarge > 0 { reasons.append("\(secrets.skippedLarge) files over 512 KiB were skipped.") }
            if secrets.unreadable > 0 { reasons.append("\(secrets.unreadable) files or folders could not be read as UTF-8.") }
            out.append(SecurityFinding(id: "credentials:coverage", area: .credentials, severity: .low,
                title: "Credential scan was incomplete", subtitle: "Some project content was not inspected", evidence: reasons,
                explanation: "Prune limits file size and scan work to keep the check responsive.", legitNote: nil,
                recommendation: "Inspect skipped or inaccessible content separately if it may contain secrets.", actions: [], inventoryOnly: true))
        }
        return out
    }
}
