import Foundation

/// Reversible containment. Quarantined items are moved (not copied) into
/// ~/Library/Application Support/Prune/Quarantine/<id>/ with execute permission removed, plus a manifest to restore them.
struct QuarantineEntry: Codable, Identifiable, Hashable {
    struct Item: Codable, Hashable { var original: String; var stored: String; var mode: UInt16; var wasLaunchItem: String? }
    var id = UUID()
    var date = Date()
    var reason: String
    var items: [Item]
    var isConfigBackup = false
}

enum Quarantine {
    static var root = FS.home.appendingPathComponent("Library/Application Support/Prune/Quarantine")
    static var manifest: URL { root.appendingPathComponent("manifest.json") }

    static func load() -> [QuarantineEntry] {
        guard let d = try? Data(contentsOf: manifest) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([QuarantineEntry].self, from: d)) ?? []
    }

    private static func save(_ list: [QuarantineEntry]) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted]
        try? enc.encode(list).write(to: manifest, options: .atomic)
    }

    /// Moves items into quarantine and strips execute bits. Root-owned items go through the admin prompt.
    static func contain(_ paths: [String], reason: String, launchLabels: [String: String] = [:]) -> (QuarantineEntry?, String?) {
        let fm = FileManager.default
        var entry = QuarantineEntry(reason: reason, items: [])
        let dir = root.appendingPathComponent(entry.id.uuidString)
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { return (nil, error.localizedDescription) }
        var adminLines: [String] = []
        for (i, p) in paths.enumerated() {
            let src = URL(fileURLWithPath: p)
            guard FS.exists(src) else { continue }
            if let refusal = guardPath(p) { return (nil, "\(FS.tildePath(src)): \(refusal)") }
            let stored = dir.appendingPathComponent("\(i)-\(src.lastPathComponent)")
            let mode = ((try? fm.attributesOfItem(atPath: p)[.posixPermissions]) as? NSNumber)?.uint16Value ?? 0o644
            do {
                try fm.moveItem(at: src, to: stored)
            } catch where fm.isWritableFile(atPath: src.deletingLastPathComponent().path) == false {
                adminLines.append("mv -f \(Shell.shellQuote(p)) \(Shell.shellQuote(stored.path)) && chown -R \(getuid()) \(Shell.shellQuote(stored.path))")
            } catch {
                return (nil, "Couldn't move \(FS.tildePath(src)): \(error.localizedDescription)")
            }
            entry.items.append(.init(original: p, stored: stored.path, mode: mode, wasLaunchItem: launchLabels[p]))
        }
        if !adminLines.isEmpty {
            let r = Shell.runAsAdmin(adminLines.joined(separator: " && "))
            if !r.ok { return (nil, "Administrator step failed: \(r.stderr)") }
        }
        // Neutralize: nothing in quarantine can be executed.
        neutralize(dir)
        var all = load(); all.insert(entry, at: 0); save(all)
        return (entry, nil)
    }

    /// Files lose every execute bit; folders stay traversable (owner rwx) so items can be inspected and restored.
    static func neutralize(_ dir: URL) {
        chmod(dir.path, 0o700)
        guard let e = FileManager.default.enumerator(atPath: dir.path) else { return }
        while let rel = e.nextObject() as? String {
            let p = dir.path + "/" + rel
            var st = stat()
            guard lstat(p, &st) == 0 else { continue }
            switch st.st_mode & S_IFMT {
            case S_IFDIR: chmod(p, (st.st_mode & 0o7777) | 0o700)
            case S_IFREG: chmod(p, ((st.st_mode & 0o7777) & ~0o111) | 0o600)
            default: break
            }
        }
    }

    /// Keeps a copy of a config file before Prune edits it.
    static func backup(_ file: String, reason: String) -> QuarantineEntry? {
        var entry = QuarantineEntry(reason: reason, items: [], isConfigBackup: true)
        let dir = root.appendingPathComponent(entry.id.uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stored = dir.appendingPathComponent(URL(fileURLWithPath: file).lastPathComponent)
        guard (try? FileManager.default.copyItem(atPath: file, toPath: stored.path)) != nil else { return nil }
        let mode = ((try? FileManager.default.attributesOfItem(atPath: file)[.posixPermissions]) as? NSNumber)?.uint16Value ?? 0o644
        entry.items = [.init(original: file, stored: stored.path, mode: mode)]
        var all = load(); all.insert(entry, at: 0); save(all)
        return entry
    }

    static func restore(_ entry: QuarantineEntry) -> String? {
        let fm = FileManager.default
        for item in entry.items {
            let dst = URL(fileURLWithPath: item.original)
            if FS.exists(dst) && !entry.isConfigBackup { return "\(FS.tildePath(dst)) exists again. Move it away first." }
            do {
                try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                if entry.isConfigBackup {
                    if FS.exists(dst) { try fm.removeItem(at: dst) }
                    try fm.copyItem(atPath: item.stored, toPath: item.original)
                } else {
                    try fm.moveItem(atPath: item.stored, toPath: item.original)
                }
                chmod(item.original, mode_t(item.mode))
                if FS.isDir(dst), !entry.isConfigBackup {
                    _ = Shell.run("/bin/chmod", ["-R", "u+rwX", item.original])
                    // Execute bits inside folders can't be reconstructed per file; restore it for scripts/binaries that had a shebang or Mach-O header.
                    if let e = fm.enumerator(atPath: item.original) {
                        while let rel = e.nextObject() as? String {
                            let p = item.original + "/" + rel
                            if ExecutableKind.isMachO(p) || ExecutableKind.isScript(p) { chmod(p, 0o755) }
                        }
                    }
                }
            } catch {
                return "Couldn't restore \(FS.tildePath(dst)): \(error.localizedDescription)"
            }
            if let label = item.wasLaunchItem, item.original.hasPrefix(FS.home.path) {
                Shell.run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", item.original], timeout: 15)
                _ = label
            }
        }
        var all = load(); all.removeAll { $0.id == entry.id }; save(all)
        try? fm.removeItem(at: root.appendingPathComponent(entry.id.uuidString))
        return nil
    }

    static func deleteForever(_ entry: QuarantineEntry) {
        let dir = root.appendingPathComponent(entry.id.uuidString)
        _ = Shell.run("/bin/chmod", ["-R", "u+rwX", dir.path])
        try? FileManager.default.removeItem(at: dir)
        var all = load(); all.removeAll { $0.id == entry.id }; save(all)
    }

    /// Containment is broader than cleanup (a malicious agent may live in ~/Library), but system areas stay off-limits.
    static func guardPath(_ p: String) -> String? {
        let h = FS.home.path
        if p.hasPrefix("/System/") || p.hasPrefix("/usr/") && !p.hasPrefix("/usr/local/") || p.hasPrefix("/bin/") || p.hasPrefix("/sbin/") { return "System files are protected by macOS." }
        if p == h || p == h + "/Library" || p == h + "/Documents" || p == h + "/Desktop" || p == h + "/Downloads" { return "Top-level folders can't be quarantined." }
        if p.contains("/Keychains") || p.contains(".photoslibrary") || p.hasPrefix(h + "/Library/Mobile Documents") { return "Protected personal data." }
        if p.hasPrefix(root.path) { return "Already in quarantine." }
        return nil
    }
}

/// Carries out security actions. Each one is confirmed in the UI first and recorded in History.
enum SecurityActions {
    static func perform(_ action: SecurityAction, finding: SecurityFinding) -> (ok: Bool, message: String) {
        let result: (Bool, String)
        switch action {
        case .stopProcess(let pid, let name, let asRoot):
            result = stop(pid: pid, name: name, asRoot: asRoot)
        case .disableLaunchItem(let plist, let label, let system):
            let domain = system ? "system/\(label)" : "gui/\(getuid())/\(label)"
            if system {
                let r = Shell.runAsAdmin("/bin/launchctl bootout \(Shell.shellQuote(domain)) 2>/dev/null; true")
                if !r.ok { result = (false, r.stderr); break }
            } else {
                Shell.run("/bin/launchctl", ["bootout", domain], timeout: 15)
            }
            let (entry, err) = Quarantine.contain([plist], reason: "Disabled background item \(label): \(finding.title)", launchLabels: [plist: label])
            result = entry != nil ? (true, "Unloaded \(label) and quarantined its plist.") : (false, err ?? "Failed")
        case .quarantine(let paths):
            let (entry, err) = Quarantine.contain(paths, reason: finding.title)
            result = entry != nil ? (true, "Quarantined \(paths.count) item(s).") : (false, err ?? "Failed")
        case .removeJSONEntry(let file, let entry):
            result = removeJSON(file: file, entry: entry, reason: finding.title)
        case .commentOutLines(let file, let lines):
            result = commentOut(file: file, lines: lines, reason: finding.title)
        case .removeCronLines(let lines):
            result = removeCron(lines, reason: finding.title)
        case .openURL(let s):
            if let u = URL(string: s) { DispatchQueue.main.async { NSWorkspaceOpen.open(u) } }
            result = (true, "Opened Settings.")
        }
        if case .openURL = action {} else {
            AuditLog.append([CleanOutcome(title: finding.title, category: "Security", paths: finding.paths, size: 0,
                                          method: action.title, success: result.0, message: result.1)])
        }
        return result
    }

    static let protectedProcesses: Set<String> = ["launchd", "kernel_task", "WindowServer", "loginwindow", "Prune", "logd", "securityd", "opendirectoryd", "syspolicyd", "tccd"]

    static func stop(pid: Int32, name: String, asRoot: Bool) -> (Bool, String) {
        // Judge by where the program lives, not its name: impersonators borrow system names.
        let path = CodeSigning.path(of: pid) ?? ""
        let isSystem = ProcessAnalyzer.systemPrefixes.contains { path.hasPrefix($0) }
        if pid <= 1 || (isSystem && protectedProcesses.contains(name)) { return (false, "\(name) is part of macOS and can't be stopped.") }
        if pid == getpid() { return (false, "That's Prune.") }
        if asRoot {
            let r = Shell.runAsAdmin("kill -TERM \(pid); sleep 2; kill -0 \(pid) 2>/dev/null && kill -KILL \(pid); true")
            return r.ok ? (true, "Stopped \(name).") : (false, r.stderr)
        }
        if kill(pid, SIGTERM) != 0 { return (false, String(cString: strerror(errno))) }
        for _ in 0..<20 { usleep(100_000); if kill(pid, 0) != 0 { return (true, "Stopped \(name).") } }
        kill(pid, SIGKILL)
        usleep(200_000)
        return kill(pid, 0) != 0 ? (true, "Force-stopped \(name).") : (false, "\(name) didn't stop.")
    }

    static func removeJSON(file: String, entry: JSONEntryRef, reason: String) -> (Bool, String) {
        guard let data = FileManager.default.contents(atPath: file),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return (false, "Couldn't read \(file).") }
        guard Quarantine.backup(file, reason: "Backup before removing \(entry.description): \(reason)") != nil else { return (false, "Couldn't back up the file first, so nothing was changed.") }

        func edit(_ obj: [String: Any], _ path: ArraySlice<String>) -> [String: Any]? {
            var o = obj
            if let k = path.first {
                guard let child = o[k] as? [String: Any], let updated = edit(child, path.dropFirst()) else { return nil }
                o[k] = updated
                return o
            }
            switch entry.kind {
            case .mcpServer:
                guard o[entry.key] != nil else { return nil }
                o[entry.key] = nil
            case .hookCommand:
                guard var groups = o[entry.key] as? [[String: Any]] else { return nil }
                var removed = false
                for gi in groups.indices {
                    if var hooks = groups[gi]["hooks"] as? [[String: Any]] {
                        let before = hooks.count
                        hooks.removeAll { ($0["command"] as? String) == entry.command }
                        removed = removed || hooks.count != before
                        groups[gi]["hooks"] = hooks
                    }
                }
                groups.removeAll { (($0["hooks"] as? [Any]) ?? []).isEmpty }
                guard removed else { return nil }
                o[entry.key] = groups.isEmpty ? nil : groups
            }
            return o
        }
        guard let updated = edit(root, entry.path[...]) else { return (false, "The entry wasn't found (it may have changed). Nothing was modified.") }
        root = updated
        guard let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              (try? out.write(to: URL(fileURLWithPath: file), options: .atomic)) != nil else { return (false, "Couldn't write \(file).") }
        return (true, "Removed \(entry.description). Backup kept in Quarantine.")
    }

    static func commentOut(file: String, lines: [Int], reason: String) -> (Bool, String) {
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return (false, "Couldn't read \(file).") }
        guard Quarantine.backup(file, reason: "Backup before disabling lines: \(reason)") != nil else { return (false, "Couldn't back up the file first.") }
        var all = text.components(separatedBy: "\n")
        for n in lines where n >= 1 && n <= all.count && !all[n - 1].hasPrefix("# disabled by Prune") {
            all[n - 1] = "# disabled by Prune: " + all[n - 1]
        }
        guard (try? all.joined(separator: "\n").write(toFile: file, atomically: true, encoding: .utf8)) != nil else { return (false, "Couldn't write \(file).") }
        return (true, "Disabled \(lines.count) line(s). Open a new terminal for it to take effect.")
    }

    static func removeCron(_ lines: [String], reason: String) -> (Bool, String) {
        let current = Shell.run("/usr/bin/crontab", ["-l"], timeout: 10).stdout
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("prune-crontab-\(getpid())")
        try? current.write(to: tmp, atomically: true, encoding: .utf8)
        _ = Quarantine.backup(tmp.path, reason: "Crontab before removing entries: \(reason)")
        let kept = current.components(separatedBy: "\n").filter { !lines.contains($0) }.joined(separator: "\n")
        try? kept.write(to: tmp, atomically: true, encoding: .utf8)
        let r = Shell.run("/usr/bin/crontab", [tmp.path], timeout: 10)
        try? FileManager.default.removeItem(at: tmp)
        return r.ok ? (true, "Removed \(lines.count) cron entr\(lines.count == 1 ? "y" : "ies").") : (false, r.stderr)
    }
}

import AppKit
enum NSWorkspaceOpen { static func open(_ u: URL) { NSWorkspace.shared.open(u) } }
