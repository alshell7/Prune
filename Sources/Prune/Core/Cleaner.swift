import AppKit
import Foundation

struct CleanOutcome: Identifiable, Codable, Hashable {
    var id = UUID()
    var itemID: String?
    var date = Date()
    var title: String
    var category: String
    var paths: [String]
    var size: Int64
    var method: String
    var success: Bool
    var message: String
}

enum AuditLog {
    static let dir = FS.home.appendingPathComponent("Library/Logs/Prune")
    static let file = dir.appendingPathComponent("history.jsonl")

    static var enabled = true

    static func append(_ outcomes: [CleanOutcome]) {
        guard enabled else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        var blob = Data()
        for o in outcomes {
            if let d = try? enc.encode(o) { blob.append(d); blob.append(0x0A) }
        }
        if let h = try? FileHandle(forWritingTo: file) {
            h.seekToEndOfFile(); h.write(blob); try? h.close()
        } else {
            try? blob.write(to: file)
        }
    }

    static func load() -> [CleanOutcome] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { try? dec.decode(CleanOutcome.self, from: Data($0.utf8)) }.reversed()
    }
}

/// Executes cleanups. Every path passes SafetyGuard again right before removal.
enum Cleaner {
    typealias Progress = (_ done: Int, _ total: Int, _ current: String) -> Void

    static func clean(_ items: [CleanupItem], deleteSafeImmediately: Bool, progress: Progress) -> [CleanOutcome] {
        let plan = dedupe(items)
        var outcomes: [CleanOutcome] = []
        var adminQueue: [(CleanupItem, [URL])] = []

        // Commands first: e.g. `git worktree remove` takes everything inside the worktree with it.
        let ordered = plan.kept.sorted { a, b in
            func rank(_ i: CleanupItem) -> Int {
                switch i.action {
                case .command: return 0
                case .emptyTrash: return 2   // last, after everything else has been moved to the Trash
                default: return 1
                }
            }
            return rank(a) < rank(b)
        }

        for (idx, item) in ordered.enumerated() {
            progress(idx, ordered.count, item.title)
            switch item.action {
            case .none:
                continue
            case .emptyTrash:
                outcomes.append(tag(emptyTrash(item), item))
            case .command(let cmd):
                outcomes.append(tag(runCommand(item, cmd), item))
            case .uninstallApp:
                outcomes.append(tag(uninstall(item), item))
            case .removeFiles:
                if item.needsAdmin {
                    adminQueue.append((item, item.paths))
                    continue
                }
                let permanent = deleteSafeImmediately && item.risk == .safe
                var errors: [String] = []
                var needAdmin: [URL] = []
                var removedAny = false
                for url in item.paths {
                    if let reason = SafetyGuard.check(url) { errors.append("\(FS.tildePath(url)): \(reason)"); continue }
                    guard FS.exists(url) else { removedAny = true; continue }
                    do {
                        if permanent { try deletePermanently(url) } else { try moveToTrash(url) }
                        removedAny = true
                    } catch {
                        if isPermissionError(error) && !url.path.hasPrefix(FS.home.path + "/") {
                            needAdmin.append(url)
                        } else {
                            errors.append("\(FS.tildePath(url)): \(error.localizedDescription)")
                        }
                    }
                }
                if !needAdmin.isEmpty { adminQueue.append((item, needAdmin)) }
                if needAdmin.count < item.paths.count {
                    outcomes.append(CleanOutcome(itemID: item.id, title: item.title, category: item.category.title,
                                                 paths: item.paths.map(\.path), size: item.size,
                                                 method: permanent ? "Deleted" : "Moved to Trash",
                                                 success: errors.isEmpty && removedAny,
                                                 message: errors.isEmpty ? "" : errors.joined(separator: "\n")))
                }
            }
        }

        if !adminQueue.isEmpty {
            progress(ordered.count, ordered.count, "Waiting for administrator approval…")
            outcomes += adminTrash(adminQueue)
        }
        for skipped in plan.skipped {
            outcomes.append(CleanOutcome(itemID: skipped.item.id, title: skipped.item.title, category: skipped.item.category.title,
                                         paths: skipped.item.paths.map(\.path), size: 0, method: "Skipped",
                                         success: true, message: "Already included in \u{201C}\(skipped.coveredBy)\u{201D}"))
        }
        AuditLog.append(outcomes)
        progress(ordered.count, ordered.count, "Done")
        return outcomes
    }

    private static func tag(_ o: CleanOutcome, _ item: CleanupItem) -> CleanOutcome {
        var o = o; o.itemID = item.id; return o
    }

    // MARK: - Overlap handling

    struct Plan { var kept: [CleanupItem]; var skipped: [(item: CleanupItem, coveredBy: String)] }

    /// Drops items whose paths are all inside (or equal to) paths of an item already kept, so nothing is processed or counted twice.
    /// Shallower items win, so a worktree removal absorbs the node_modules inside it.
    static func dedupe(_ items: [CleanupItem]) -> Plan {
        func depth(_ i: CleanupItem) -> Int { i.paths.map { $0.pathComponents.count }.min() ?? Int.max }
        let ordered = items.filter(\.isActionable).sorted { depth($0) < depth($1) }
        var claimed: [String: String] = [:]   // path → title of the item that claimed it
        var kept: [CleanupItem] = []
        var skipped: [(CleanupItem, String)] = []
        for i in ordered {
            if case .emptyTrash = i.action { kept.append(i); continue }
            let mine = i.paths.map(\.path)
            let owners = mine.map { claimedOwner(of: $0, in: claimed) }
            if !mine.isEmpty, owners.allSatisfy({ $0 != nil }), let first = owners.first, let owner = first {
                skipped.append((i, owner))
                continue
            }
            kept.append(i)
            for p in mine where claimed[p] == nil { claimed[p] = i.title }
        }
        return Plan(kept: kept, skipped: skipped)
    }

    /// The claim on this path or its nearest claimed ancestor (walks up the path, O(depth)).
    static func claimedOwner(of path: String, in claimed: [String: String]) -> String? {
        var p = path
        while true {
            if let t = claimed[p] { return t }
            guard let slash = p.lastIndex(of: "/"), slash > p.startIndex else { return claimed["/"] }
            p = String(p[..<slash])
        }
    }

    static func effectiveSize(_ items: [CleanupItem]) -> Int64 {
        dedupe(items).kept.totalSize
    }

    // MARK: - Primitives

    static func moveToTrash(_ url: URL) throws {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch let error where isPermissionError(error) && url.path.hasPrefix(FS.home.path + "/") {
            // Read-only folders (e.g. Go module cache) — temporarily make the parent writable.
            let parent = url.deletingLastPathComponent()
            let attrs = try? FileManager.default.attributesOfItem(atPath: parent.path)
            let originalMode = (attrs?[.posixPermissions] as? NSNumber)?.int16Value
            chmod(parent.path, 0o755)
            _ = Shell.run("/bin/chmod", ["u+w", url.path])
            defer { if let m = originalMode { chmod(parent.path, mode_t(m)) } }
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }

    static func deletePermanently(_ url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error where isPermissionError(error) && url.path.hasPrefix(FS.home.path + "/") {
            _ = Shell.run("/bin/chmod", ["-R", "u+w", url.path], timeout: 300)
            try FileManager.default.removeItem(at: url)
        }
    }

    static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && (ns.code == NSFileWriteNoPermissionError || ns.code == NSFileReadNoPermissionError) { return true }
        if let u = ns.userInfo[NSUnderlyingErrorKey] as? NSError, u.domain == NSPOSIXErrorDomain, u.code == Int(EACCES) || u.code == Int(EPERM) { return true }
        return ns.domain == NSPOSIXErrorDomain && (ns.code == Int(EACCES) || ns.code == Int(EPERM))
    }

    private static func runCommand(_ item: CleanupItem, _ cmd: ShellCommand) -> CleanOutcome {
        let r: ShellResult
        if cmd.needsAdmin {
            let line = ([cmd.tool] + cmd.args).map(Shell.shellQuote).joined(separator: " ")
            r = Shell.runAsAdmin((cmd.cwd.map { "cd \(Shell.shellQuote($0)) && " } ?? "") + line)
        } else {
            r = Shell.run(cmd.tool, cmd.args, cwd: cmd.cwd, timeout: 900)
        }
        let msg = r.ok ? "" : (r.timedOut ? "Timed out" : (r.stderr.isEmpty ? r.stdout : r.stderr)).trimmingCharacters(in: .whitespacesAndNewlines)
        return CleanOutcome(title: item.title, category: item.category.title, paths: item.paths.map(\.path),
                            size: item.size, method: "Ran \(cmd.display)", success: r.ok, message: msg)
    }

    private static func uninstall(_ item: CleanupItem) -> CleanOutcome {
        guard let app = item.paths.first else {
            return CleanOutcome(title: item.title, category: item.category.title, paths: [], size: 0, method: "Uninstall", success: false, message: "No app path")
        }
        if let reason = SafetyGuard.check(app, allowAppBundle: true) {
            return CleanOutcome(title: item.title, category: item.category.title, paths: [app.path], size: item.size, method: "Uninstall", success: false, message: reason)
        }
        if let bid = item.appBundleID, NSRunningApplication.runningApplications(withBundleIdentifier: bid).isEmpty == false {
            return CleanOutcome(title: item.title, category: item.category.title, paths: [app.path], size: item.size, method: "Uninstall", success: false, message: "The app is running. Quit it first.")
        }
        var targets: [URL] = []
        var errors: [String] = []
        for url in item.paths {
            let allowBundle = url == app
            if let reason = SafetyGuard.check(url, allowAppBundle: allowBundle) { errors.append("\(FS.tildePath(url)): \(reason)") }
            else if FS.exists(url) { targets.append(url) }
        }
        let sem = DispatchSemaphore(value: 0)
        var recycleError: Error?
        NSWorkspace.shared.recycle(targets) { _, err in recycleError = err; sem.signal() }
        sem.wait()
        if let recycleError { errors.append(recycleError.localizedDescription) }
        return CleanOutcome(title: item.title, category: item.category.title, paths: targets.map(\.path), size: item.size,
                            method: "Uninstalled to Trash", success: recycleError == nil && !FS.exists(app),
                            message: errors.joined(separator: "\n"))
    }

    private static func emptyTrash(_ item: CleanupItem) -> CleanOutcome {
        let r = Shell.run("/usr/bin/osascript", ["-e", "tell application \"Finder\" to empty trash"], timeout: 600)
        return CleanOutcome(title: item.title, category: item.category.title, paths: item.paths.map(\.path), size: item.size,
                            method: "Emptied Trash", success: r.ok, message: r.ok ? "" : r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Moves root-owned items into the Trash with a single administrator prompt.
    private static func adminTrash(_ queue: [(CleanupItem, [URL])]) -> [CleanOutcome] {
        let stamp = Int(Date().timeIntervalSince1970)
        let trash = FS.home.appendingPathComponent(".Trash/Prune-\(stamp)").path
        var lines: [String] = []
        var n = 0
        var blocked: [String: String] = [:]
        for (_, urls) in queue {
            for u in urls {
                if let reason = SafetyGuard.check(u) { blocked[u.path] = reason; continue }
                n += 1
                let dest = "\(trash)/\(n)"
                lines.append("mkdir -p \(Shell.shellQuote(dest)) && mv -f \(Shell.shellQuote(u.path)) \(Shell.shellQuote(dest))/")
            }
        }
        var result = ShellResult(status: 0, stdout: "", stderr: "")
        if !lines.isEmpty { result = Shell.runAsAdmin(lines.joined(separator: "; ")) }
        return queue.map { item, urls in
            let gone = urls.filter { blocked[$0.path] == nil && !FS.exists($0) }
            var msgs = urls.compactMap { u in blocked[u.path].map { "\(FS.tildePath(u)): \($0)" } }
            if !result.ok { msgs.append(result.stderr) }
            return CleanOutcome(itemID: item.id, title: item.title, category: item.category.title, paths: urls.map(\.path), size: item.size,
                                method: "Moved to Trash (admin)", success: gone.count == urls.count, message: msgs.joined(separator: "\n"))
        }
    }
}
