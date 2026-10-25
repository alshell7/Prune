import Foundation

/// Data kept by AI coding tools: Claude Desktop's sandbox VM and bundled Claude Code builds,
/// Claude Code transcripts, Codex sessions.
struct AIToolsScanner: Scanner {
    let name = "AI tools"

    func scan(_ ctx: ScanContext, _ progress: ScanProgress) -> [CleanupItem] {
        progress.update("Checking AI tool data…")
        var items: [CleanupItem] = []
        let processes = Shell.run("/bin/ps", ["-Ao", "command"], timeout: 5).stdout
        items += claudeDesktop(ctx, processes)
        items += claudeCodeTranscripts(ctx)
        items += codexSessions(ctx)
        return items
    }

    // MARK: Claude Desktop

    private func claudeDesktop(_ ctx: ScanContext, _ processes: String) -> [CleanupItem] {
        let support = FS.home.appendingPathComponent("Library/Application Support/Claude")
        guard FS.isDir(support) else { return [] }
        var items: [CleanupItem] = []
        let claudeRunning = ctx.running.contains("com.anthropic.claudefordesktop")

        // Bundled Claude Code builds: every update leaves the previous version behind.
        for sub in ["claude-code", "claude-code-vm"] {
            let dir = support.appendingPathComponent(sub)
            let versions = FS.childDirs(dir).filter { $0.lastPathComponent.first?.isNumber == true }
            guard versions.count > 1, let newest = versions.max(by: { Versions.compare($0.lastPathComponent, $1.lastPathComponent) }) else { continue }
            let old = versions.filter { $0 != newest }
            let sizes = Sizer.measureMany(old)
            for v in old {
                guard let m = sizes[v], m.bytes >= ctx.minBytes else { continue }
                let inUse = processes.contains("/\(sub)/\(v.lastPathComponent)/")
                items.append(CleanupItem(
                    category: .aiModels, title: "Claude Code \(v.lastPathComponent) (\(sub == "claude-code" ? "Claude Desktop" : "Claude VM"))",
                    subtitle: FS.tildePath(v), group: "AI tools", paths: [v], size: m.bytes, risk: .safe,
                    recommendation: inUse ? .keep : .recommended,
                    reason: inUse ? "A running session still uses this version." : "Superseded by \(newest.lastPathComponent).",
                    whatItIs: "A Claude Code build that Claude Desktop downloaded for its Code tab. Desktop keeps the previous version after updating.",
                    whyRemove: inUse ? nil : "Claude Desktop now runs \(newest.lastPathComponent) and no process uses this one.",
                    impact: "None. Sessions use the current version.", restore: "Claude Desktop downloads versions as needed",
                    lastUsed: m.newest, lockedReason: inUse ? "In use by a running Claude Code session." : nil))
            }
        }

        // The sandbox VM used for Claude Desktop's agent/Cowork features.
        let bundle = support.appendingPathComponent("vm_bundles/claudevm.bundle")
        if FS.isDir(bundle) {
            let m = Sizer.measure(bundle)
            if m.bytes >= ctx.minBytes {
                items.append(CleanupItem(
                    category: .aiModels, title: "Claude Desktop sandbox VM", subtitle: FS.tildePath(bundle), group: "AI tools",
                    paths: [bundle], size: m.bytes, risk: .low, recommendation: claudeRunning ? .keep : .optional,
                    reason: claudeRunning ? "Claude Desktop is running, and the VM may be in use." : "Re-downloaded by Claude Desktop when a feature needs it.",
                    whatItIs: "A Linux VM disk image (rootfs.img) that Claude Desktop uses to run agent tasks in an isolated sandbox. Most of the size is a 10 GB disk image.",
                    whyRemove: "If you don't use Claude Desktop's sandboxed agent features, this is the single biggest file Claude keeps.",
                    whyKeep: "Claude Desktop downloads it again (several GB) the next time a sandboxed task runs, and files created inside the VM are lost.",
                    impact: "The VM is recreated on next use.", restore: "Automatic, on the next sandboxed task in Claude Desktop",
                    lastUsed: m.newest, lockedReason: claudeRunning ? "Quit Claude Desktop first. The VM may be running." : nil,
                    appBundleID: "com.anthropic.claudefordesktop"))
            }
        }
        return items
    }

    // MARK: Claude Code transcripts

    /// Transcript folders whose project no longer exists (deleted repos, removed worktrees).
    private func claudeCodeTranscripts(_ ctx: ScanContext) -> [CleanupItem] {
        let root = FS.home.appendingPathComponent(".claude/projects")
        var orphans: [URL] = []
        var orphanPaths: [String] = []
        for dir in FS.childDirs(root) {
            guard let first = FS.children(dir).first(where: { $0.pathExtension == "jsonl" }),
                  let head = FS.readText(first, limit: 256 * 1024),
                  let cwd = Requirements.captures(#""cwd":"([^"]+)""#, head, options: []).first else { continue }
            if !FS.exists(URL(fileURLWithPath: cwd)) { orphans.append(dir); orphanPaths.append(cwd) }
        }
        guard !orphans.isEmpty else { return [] }
        let sizes = Sizer.measureMany(orphans)
        let total = sizes.values.reduce(0) { $0 + $1.bytes }
        return [CleanupItem(
            category: .dangling, title: "Claude Code history for deleted folders", subtitle: "\(orphans.count) project\(orphans.count == 1 ? "" : "s")",
            group: "AI tools", paths: orphans, size: total, risk: .low, recommendation: .recommended,
            reason: "The projects these sessions ran in no longer exist.",
            whatItIs: "Claude Code session transcripts for: \(orphanPaths.map { FS.tildePath(URL(fileURLWithPath: $0)) }.joined(separator: ", ")).",
            whyRemove: "You can't resume a session in a folder that's gone. Worktrees removed by Prune or git leave these behind.",
            whyKeep: "Keep them if you want to read old conversations.",
            impact: "Those sessions disappear from `claude --resume`.", restore: "Restore from Trash",
            lastUsed: sizes.values.compactMap(\.newest).max())]
    }

    // MARK: Codex

    private func codexSessions(_ ctx: ScanContext) -> [CleanupItem] {
        let root = FS.home.appendingPathComponent(".codex/sessions")
        var old: [URL] = []
        let cutoff = Date().addingTimeInterval(-Double(max(ctx.staleDays, 30)) * 86_400)
        for year in FS.childDirs(root) {
            for month in FS.childDirs(year) {
                for day in FS.childDirs(month) {
                    guard let y = Int(year.lastPathComponent), let mo = Int(month.lastPathComponent), let d = Int(day.lastPathComponent),
                          let date = Calendar.current.date(from: DateComponents(year: y, month: mo, day: d)), date < cutoff else { continue }
                    old.append(day)
                }
            }
        }
        guard !old.isEmpty else { return [] }
        let total = Sizer.measureMany(old).values.reduce(0) { $0 + $1.bytes }
        guard total >= ctx.minBytes else { return [] }
        return [CleanupItem(
            category: .aiModels, title: "Codex sessions older than \(max(ctx.staleDays, 30)) days", subtitle: "\(old.count) days of history",
            group: "AI tools", paths: old, size: total, risk: .low, recommendation: .optional,
            reason: "Old Codex conversation logs.",
            whatItIs: "Rollout logs of past Codex CLI/app sessions in ~/.codex/sessions, one folder per day.",
            whyKeep: "You can no longer resume or search those sessions.",
            impact: "Older sessions disappear from Codex's history.", restore: "Restore from Trash")]
    }
}
