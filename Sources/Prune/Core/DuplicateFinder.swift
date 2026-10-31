import CryptoKit
import Foundation

/// On-demand duplicate discovery: size, sampled hash, then a full SHA-256 of every candidate.
enum DuplicateFinder {
    struct Snapshot: Hashable {
        var device: Int32
        var inode: UInt64
        var size: Int64
        var allocated: Int64
        var modifiedSeconds: Int
        var modifiedNanos: Int
        var changedSeconds: Int
        var changedNanos: Int

        init(_ st: stat) {
            device = st.st_dev; inode = st.st_ino; size = st.st_size; allocated = Int64(st.st_blocks) * 512
            modifiedSeconds = st.st_mtimespec.tv_sec; modifiedNanos = st.st_mtimespec.tv_nsec
            changedSeconds = st.st_ctimespec.tv_sec; changedNanos = st.st_ctimespec.tv_nsec
        }
    }
    struct File: Hashable, Identifiable {
        var url: URL
        var snapshot: Snapshot
        var id: String { url.path }
    }
    struct Group: Identifiable {
        var id: String
        var files: [File]
        var size: Int64 { files.first?.snapshot.size ?? 0 }
        var possibleSavings: Int64 { files.dropFirst().reduce(0) { $0 + $1.snapshot.allocated } }
    }
    struct Report {
        var groups: [Group] = []
        var filesConsidered = 0
        var unreadable = 0
        var skippedForBudget = 0
        var incomplete = false
    }

    static let defaultMinimum: Int64 = 10 * 1_048_576
    static let defaultBudget: Int64 = 8 * 1_073_741_824
    private static let skipNames: Set<String> = [".git", ".hg", ".svn", ".Trash", ".Trashes", ".Spotlight-V100", ".fseventsd",
        ".DocumentRevisions-V100", ".ssh", ".gnupg", ".aws", ".kube", "Keychains", "node_modules", "site-packages", ".venv"]
    private static let skipAbsolute: Set<String> = ["/System", "/Library", "/private", "/usr", "/bin", "/sbin", "/dev", "/Volumes", "/Applications", "/opt", "/cores"]

    private static func current(_ path: String) -> Snapshot? {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        return Snapshot(st)
    }

    /// Refuses symlinks and files that changed before, during or after reading.
    private static func digest(_ file: File, sample: Bool) -> String? {
        let fd = open(file.url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(fd, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG, Snapshot(before) == file.snapshot else { return nil }
        var hasher = SHA256()
        do {
            if sample {
                let chunk: Int64 = 64 * 1024
                for offset in [Int64(0), max(0, file.snapshot.size / 2 - chunk / 2), max(0, file.snapshot.size - chunk)] {
                    try handle.seek(toOffset: UInt64(offset))
                    guard let data = try handle.read(upToCount: Int(chunk)), data.count == Int(min(chunk, file.snapshot.size - offset)) else { return nil }
                    hasher.update(data: data)
                }
            } else {
                while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hasher.update(data: data) }
            }
        } catch { return nil }
        var after = stat()
        guard fstat(fd, &after) == 0, Snapshot(after) == file.snapshot, current(file.url.path) == file.snapshot else { return nil }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func scan(settings: SettingsSnapshot, roots: [URL]? = nil, minimum: Int64 = defaultMinimum,
                     budget: Int64 = defaultBudget, progress: (String) -> Void) -> Report {
        var report = Report()
        var stack = (roots ?? settings.resolvedScanRoots()).map { ($0.standardizedFileURL, 0) }
        var visited = Set<String>(), seenLinks = Set<String>()
        var bySize: [Int64: [File]] = [:]
        while let (dir, depth) = stack.popLast() {
            guard visited.insert(dir.path).inserted, !settings.isExcluded(dir) else { continue }
            if visited.count > 100_000 || report.filesConsidered >= 250_000 { report.incomplete = true; break }
            guard let entries = FS.list(dir.path) else { report.unreadable += 1; continue }
            if visited.count % 500 == 0 { progress("Checking \(FS.tildePath(dir))…") }
            for entry in entries {
                let child = dir.appendingPathComponent(entry.name)
                guard !entry.isLink, !settings.isExcluded(child) else { continue }
                if entry.isDir {
                    if skipNames.contains(entry.name) || skipAbsolute.contains(child.path) ||
                        entry.name.hasSuffix(".app") || entry.name.hasSuffix(".photoslibrary") ||
                        (dir.path == FS.home.path && (entry.name == "Library" || entry.name.hasPrefix("."))) { continue }
                    if depth >= 24 { report.incomplete = true } else { stack.append((child, depth + 1)) }
                    continue
                }
                if CredentialsAnalyzer.isEnvironmentFile(entry.name) || ["pem", "key", "p12", "pfx"].contains(child.pathExtension.lowercased()) { continue }
                var st = stat()
                guard lstat(child.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size >= minimum else { continue }
                report.filesConsidered += 1
                if st.st_nlink > 1 && !seenLinks.insert("\(st.st_dev):\(st.st_ino)").inserted { continue }
                bySize[st.st_size, default: []].append(File(url: child, snapshot: Snapshot(st)))
                if report.filesConsidered >= 250_000 { report.incomplete = true; break }
            }
            if report.incomplete && report.filesConsidered >= 250_000 { break }
        }
        progress("Comparing candidate files…")
        var bySample: [String: [File]] = [:]
        for (size, files) in bySize where files.count > 1 {
            for file in files {
                if let hash = digest(file, sample: true) { bySample["\(size):\(hash)", default: []].append(file) }
                else { report.unreadable += 1 }
            }
        }
        var spent: Int64 = 0
        let candidates = bySample.values.filter { $0.count > 1 }.sorted { ($0.first?.snapshot.size ?? 0) < ($1.first?.snapshot.size ?? 0) }
        for files in candidates {
            let size = files[0].snapshot.size
            guard size > 0, Int64(files.count) <= max(0, budget - spent) / size else {
                report.skippedForBudget += files.count; report.incomplete = true; continue
            }
            var byDigest: [String: [File]] = [:]
            for file in files {
                spent += size
                if let hash = digest(file, sample: false) { byDigest[hash, default: []].append(file) }
                else { report.unreadable += 1 }
            }
            for (hash, copies) in byDigest where copies.count > 1 {
                report.groups.append(Group(id: hash, files: copies.sorted { $0.url.path < $1.url.path }))
            }
        }
        report.groups.sort { $0.possibleSavings > $1.possibleSavings }
        return report
    }

    /// Recheck both copies immediately before moving one to Trash, and never remove the last one.
    static func trash(_ file: File, keeping other: File) -> (Bool, String) {
        guard file.url != other.url, file.snapshot.device != other.snapshot.device || file.snapshot.inode != other.snapshot.inode else {
            return (false, "Choose a separate physical file to keep.")
        }
        if let reason = SafetyGuard.check(file.url) { return (false, reason) }
        guard let first = digest(file, sample: false), let second = digest(other, sample: false), first == second,
              current(file.url.path) == file.snapshot, current(other.url.path) == other.snapshot else {
            return (false, "A file changed, disappeared, or could not be read. Scan again before removing it.")
        }
        let item = CleanupItem(category: .largeFiles, title: file.url.lastPathComponent, paths: [file.url], size: file.snapshot.allocated,
                               risk: .high, recommendation: .optional, reason: "Verified duplicate", whatItIs: "", impact: "")
        let outcome = Cleaner.clean([item], deleteSafeImmediately: false) { _, _, _ in }.first
        return (outcome?.success == true, outcome?.success == true ? "Moved to Trash. The other copy remains in place." : (outcome?.message ?? "Could not move the file to Trash."))
    }
}
