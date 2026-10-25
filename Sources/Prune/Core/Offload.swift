import AppKit
import CryptoKit
import Foundation

// MARK: - Model

struct SkippedArtifact: Codable, Hashable {
    var path: String       // relative to the item root
    var kind: String
    var bytes: Int64
    var restore: String?
}

/// One completed offload, remembered so it can be brought back.
struct OffloadRecord: Codable, Identifiable, Hashable {
    var id = UUID()
    var source: String           // original location (now a link, if linked)
    var destination: String      // copy on the drive
    var volumeName: String
    var date = Date()
    var bytes: Int64
    var files: Int
    var linked: Bool
    var checksummed: Bool
    var skipped: [SkippedArtifact]
}

enum OffloadRegistry {
    static var file = FS.home.appendingPathComponent("Library/Application Support/Prune/offloads.json")

    static func load() -> [OffloadRecord] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([OffloadRecord].self, from: data)) ?? []
    }

    static func save(_ records: [OffloadRecord]) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(records).write(to: file, options: .atomic)
    }

    static func add(_ r: OffloadRecord) { var all = load(); all.removeAll { $0.source == r.source }; all.insert(r, at: 0); save(all) }
    static func remove(_ id: UUID) { save(load().filter { $0.id != id }) }
}

struct OffloadRequest: Hashable {
    var source: URL
    var skipArtifacts: Bool
    var leaveLink: Bool
    /// Data that tools expect at a fixed path (emulators, model caches) must keep a link.
    var linkRequired = false
    /// An app's Application Support folder, moved by the App Mover.
    var appData = false
}

struct OffloadOptions {
    var destinationRoot: URL          // e.g. /Volumes/SSD/Prune Offload
    var checksums = true
    var trashOriginals = false
}

struct OffloadProgress {
    enum Phase: String { case preparing = "Preparing", copying = "Copying", syncing = "Catching up with changes", verifying = "Verifying", finishing = "Finishing", done = "Done" }
    var phase: Phase = .preparing
    var item = ""
    var itemIndex = 0
    var itemCount = 0
    var bytesDone: Int64 = 0
    var bytesTotal: Int64 = 0
    var filesDone = 0
    var filesTotal = 0
    var current = ""
    var bytesPerSecond: Double = 0
}

struct OffloadOutcome: Identifiable {
    var id = UUID()
    var source: URL
    var destination: URL?
    var success: Bool
    var message: String
    var bytes: Int64 = 0
    var skippedBytes: Int64 = 0
}

// MARK: - Safety rules specific to moving data

enum OffloadGuard {
    /// Folders under ~/Library that may be moved, always with a link left behind.
    static let libraryAllowList = [
        "Library/Developer/Xcode/Archives", "Library/Application Support/MobileSync/Backup", "Library/Android/sdk/system-images",
    ]
    static let linkRequiredPrefixes = [".android/avd", ".cache/huggingface", ".ollama/models", ".lmstudio/models", "Library/"]

    static func checkSource(_ url: URL, appData: Bool = false) -> String? {
        let path = url.standardizedFileURL.path
        let home = FS.home.path
        guard path.hasPrefix(home + "/") else { return "Only folders inside your home folder can be offloaded." }
        let rel = String(path.dropFirst(home.count + 1))
        let comps = rel.split(separator: "/")
        if comps.count < 2 { return "Top-level home folders like Documents can't be replaced. Pick folders inside them." }
        if FS.isSymlink(url) { return "This is already a link (probably offloaded before)." }
        if !FS.exists(url) { return "It no longer exists." }
        let appSupport = appData && rel.hasPrefix("Library/Application Support/") && comps.count >= 3
        if rel.hasPrefix("Library/") && !appSupport && !libraryAllowList.contains(where: { rel == $0 || rel.hasPrefix($0 + "/") }) {
            return "Library folders belong to apps and can't be moved safely."
        }
        if comps.contains(".git") { return "Can't move the inside of a .git folder. Move the whole repository instead." }
        if rel.contains("Mobile Documents") || rel.contains("CloudStorage") { return "iCloud and cloud-synced folders are managed by their sync app." }
        if rel.contains(".photoslibrary") { return "Move a Photos library from inside Photos instead." }
        if rel.hasSuffix(".app") || rel.contains(".app/") { return "Apps should be moved by reinstalling them." }
        if [".ssh", ".gnupg", ".aws", ".kube", ".config"].contains(String(comps[0])) { return "Credentials and settings folders stay on the Mac." }
        // Must live on the startup disk; moving between external disks isn't what this is for.
        let vol = (try? url.resourceValues(forKeys: [.volumeIsRootFileSystemKey]))?.volumeIsRootFileSystem ?? true
        if !vol { return "Already on another disk." }
        return nil
    }

    static func linkRequired(_ url: URL) -> Bool {
        let rel = String(url.path.dropFirst(FS.home.path.count + 1))
        return linkRequiredPrefixes.contains { rel.hasPrefix($0) }
    }

    struct Destination { var problem: String?; var warnings: [String]; var fsType: String; var free: Int64 }

    static func checkDestination(_ root: URL) -> Destination {
        var st = statfs()
        let probe = FS.exists(root) ? root : root.deletingLastPathComponent()
        guard statfs(probe.path, &st) == 0 else { return Destination(problem: "Can't read that location.", warnings: [], fsType: "?", free: 0) }
        let fsType = withUnsafePointer(to: st.f_fstypename) { $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) } }
        let free = Int64(st.f_bavail) * Int64(st.f_bsize)
        var bootStat = statfs()
        statfs("/System/Volumes/Data", &bootStat)
        var warnings: [String] = []
        if st.f_fsid.val.0 == bootStat.f_fsid.val.0 && st.f_fsid.val.1 == bootStat.f_fsid.val.1 {
            return Destination(problem: "That's on your startup disk, so moving there wouldn't free any space.", warnings: [], fsType: fsType, free: free)
        }
        if (st.f_flags & UInt32(MNT_RDONLY)) != 0 { return Destination(problem: "The drive is read-only.", warnings: [], fsType: fsType, free: free) }
        switch fsType {
        case "apfs", "hfs": break
        case "exfat":
            warnings.append("ExFAT can't store symlinks, permissions or extended attributes. Fine for media and archives, but code projects may break. For developer data, reformat the drive as APFS in Disk Utility.")
        case "msdos":
            warnings.append("FAT32 can't hold files over 4 GB, symlinks or permissions. Reformat as APFS for developer data.")
        case "smbfs", "afpfs", "nfs", "webdav":
            warnings.append("Network drives are slow and may disconnect. Links will break whenever the share isn't mounted.")
        default:
            warnings.append("Unusual file system (\(fsType)). Make sure it preserves symlinks and permissions.")
        }
        return Destination(problem: nil, warnings: warnings, fsType: fsType, free: free)
    }

    /// Room for the copy plus file-system overhead and a little headroom.
    static func fits(need: Int64, free: Int64) -> Bool { free >= Int64(Double(need) * 1.03) + 64 * 1_048_576 }

    /// Processes that have files open (or their working directory) inside the folder.
    static func processesUsing(_ url: URL) -> [String] {
        let r = Shell.run("/usr/sbin/lsof", ["-Fpcn", "-w", "+c", "0", "-u", String(getuid())], timeout: 25)
        var users = Set<String>()
        var command = ""
        let prefix = url.path + "/"
        for line in r.stdout.split(separator: "\n") {
            if line.hasPrefix("c") { command = String(line.dropFirst()) }
            else if line.hasPrefix("n"), line.dropFirst().hasPrefix(prefix) || line.dropFirst() == url.path[...] { users.insert(command) }
        }
        users.remove("Prune")
        return users.sorted()
    }
}

// MARK: - Engine

/// Copies a folder to another volume, verifies it, then swaps the original for a link (or removes it).
/// Nothing on the Mac is touched until the copy is verified.
final class OffloadEngine {
    private let lock = NSLock()
    private var cancelled = false
    private var progress = OffloadProgress()
    private var lastReport = Date.distantPast
    private var speedMark: (Date, Int64) = (Date(), 0)
    private let onProgress: (OffloadProgress) -> Void

    init(onProgress: @escaping (OffloadProgress) -> Void) { self.onProgress = onProgress }

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    private func report(force: Bool = false, _ mutate: (inout OffloadProgress) -> Void) {
        lock.lock()
        mutate(&progress)
        let now = Date()
        let dt = now.timeIntervalSince(speedMark.0)
        if dt > 1 {
            progress.bytesPerSecond = Double(progress.bytesDone - speedMark.1) / dt
            speedMark = (now, progress.bytesDone)
        }
        let send = force || now.timeIntervalSince(lastReport) > 0.15
        if send { lastReport = now }
        let snapshot = progress
        lock.unlock()
        if send { onProgress(snapshot) }
    }

    // MARK: File inventory

    struct Entry {
        enum Kind { case file, dir, link }
        var rel: String
        var kind: Kind
        var size: Int64
        var alloc: Int64
        var mtime: Int
        var mtimeNs: Int
    }

    /// Lists everything under root (not following links), skipping excluded absolute paths.
    static func inventory(_ root: URL, excluding: Set<String>) -> (entries: [Entry], errors: [String]) {
        var out: [Entry] = []
        var errors: [String] = []
        var stack = [""]
        while let rel = stack.popLast() {
            let dir = rel.isEmpty ? root.path : root.path + "/" + rel
            guard let names = FS.list(dir) else { errors.append(rel.isEmpty ? "." : rel); continue }
            for e in names {
                let childRel = rel.isEmpty ? e.name : rel + "/" + e.name
                let abs = root.path + "/" + childRel
                if excluding.contains(abs) { continue }
                var st = stat()
                guard lstat(abs, &st) == 0 else { errors.append(childRel); continue }
                let mode = st.st_mode & S_IFMT
                let kind: Entry.Kind = mode == S_IFDIR ? .dir : (mode == S_IFLNK ? .link : .file)
                if mode != S_IFDIR && mode != S_IFLNK && mode != S_IFREG { continue } // sockets, fifos
                out.append(Entry(rel: childRel, kind: kind, size: Int64(st.st_size), alloc: Int64(st.st_blocks) * 512,
                                 mtime: st.st_mtimespec.tv_sec, mtimeNs: st.st_mtimespec.tv_nsec))
                if kind == .dir { stack.append(childRel) }
            }
        }
        return (out, errors)
    }

    // MARK: Offload

    func offload(_ req: OffloadRequest, options: OffloadOptions, index: Int, count: Int) -> (OffloadOutcome, OffloadRecord?) {
        let src = req.source.standardizedFileURL
        var outcome = OffloadOutcome(source: src, destination: nil, success: false, message: "")
        report(force: true) { $0 = OffloadProgress(phase: .preparing, item: src.lastPathComponent, itemIndex: index, itemCount: count) }

        if let problem = OffloadGuard.checkSource(src, appData: req.appData) { outcome.message = problem; return (outcome, nil) }
        let dest = options.destinationRoot.appendingPathComponent(String(src.path.dropFirst(FS.home.path.count + 1)))
        outcome.destination = dest
        let check = OffloadGuard.checkDestination(options.destinationRoot)
        if let p = check.problem { outcome.message = p; return (outcome, nil) }

        let users = OffloadGuard.processesUsing(src)
        if !users.isEmpty {
            outcome.message = "In use by \(users.joined(separator: ", ")). Quit them (or stop dev servers and terminals open there) and try again."
            return (outcome, nil)
        }
        if !FS.isDir(src) { return offloadFile(src, dest, req, options, check) }

        // Rebuildable folders to leave behind.
        var skipped: [SkippedArtifact] = []
        var excluded = Set<String>()
        if req.skipArtifacts {
            for a in Self.artifacts(in: src) {
                excluded.insert(a.url.path)
                skipped.append(SkippedArtifact(path: String(a.url.path.dropFirst(src.path.count + 1)), kind: a.rule.kind,
                                               bytes: a.bytes, restore: a.rule.restore(a.siblings)))
            }
        }
        outcome.skippedBytes = skipped.reduce(0) { $0 + $1.bytes }

        var inv = Self.inventory(src, excluding: excluded)
        if !inv.errors.isEmpty {
            outcome.message = "Couldn't read \(inv.errors.count) item(s), e.g. \(inv.errors.prefix(3).joined(separator: ", ")). Nothing was moved."
            return (outcome, nil)
        }
        let need = inv.entries.reduce(Int64(0)) { $0 + $1.alloc }
        if !OffloadGuard.fits(need: need, free: check.free) {
            outcome.message = "Not enough room on the drive: needs \(Fmt.bytes(need)), \(Fmt.bytes(check.free)) free."
            return (outcome, nil)
        }
        if check.fsType == "msdos", inv.entries.contains(where: { $0.size >= 4_294_967_295 }) {
            outcome.message = "Files over 4 GB can't be stored on a FAT32 drive."; return (outcome, nil)
        }
        if ["exfat", "msdos"].contains(check.fsType), inv.entries.contains(where: { $0.kind == .link }) {
            outcome.message = "This folder contains symlinks, which a \(check.fsType == "exfat" ? "ExFAT" : "FAT32") drive can't store. Reformat the drive as APFS."
            return (outcome, nil)
        }

        do { try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true) }
        catch { outcome.message = "Can't create the folder on the drive: \(error.localizedDescription)"; return (outcome, nil) }

        // Copy, then catch up with anything that changed while copying.
        let total = inv.entries.filter { $0.kind == .file }.reduce(Int64(0)) { $0 + $1.size }
        report(force: true) { $0.phase = .copying; $0.bytesTotal = total; $0.filesTotal = inv.entries.count }
        if let err = copyTree(src, dest, inv.entries) { outcome.message = err; return (outcome, nil) }
        var stable = false
        for _ in 0..<3 {
            if isCancelled { outcome.message = "Cancelled. Nothing was removed from your Mac, and the partial copy resumes next time."; return (outcome, nil) }
            report(force: true) { $0.phase = .syncing }
            let again = Self.inventory(src, excluding: excluded)
            let changed = Self.diff(old: inv.entries, new: again.entries)
            if changed.modified.isEmpty && changed.removed.isEmpty { stable = true; inv = again; break }
            for r in changed.removed { try? FileManager.default.removeItem(at: dest.appendingPathComponent(r)) }
            if let err = copyTree(src, dest, changed.modified) { outcome.message = err; return (outcome, nil) }
            inv = again
        }
        guard stable else {
            outcome.message = "Files keep changing while copying. Close apps using this folder and try again. Nothing was removed."
            return (outcome, nil)
        }

        // Verify every entry (sizes, links, and checksums if requested).
        report(force: true) { $0.phase = .verifying; $0.bytesDone = 0; $0.filesDone = 0 }
        if let err = verify(src, dest, inv.entries, checksums: options.checksums) {
            outcome.message = "Verification failed: \(err). Your original is untouched."
            return (outcome, nil)
        }
        applyDirectoryMetadata(src, dest, inv.entries)

        // Swap: rename original aside (atomic), put a link in its place, then remove the original.
        report(force: true) { $0.phase = .finishing }
        if isCancelled { outcome.message = "Cancelled before removing anything."; return (outcome, nil) }
        let aside = src.deletingLastPathComponent().appendingPathComponent(".\(src.lastPathComponent).prune-offloading")
        do {
            try? FileManager.default.removeItem(at: aside)
            try FileManager.default.moveItem(at: src, to: aside)
        } catch {
            outcome.message = "Couldn't swap in the link: \(error.localizedDescription). The copy on the drive is complete. Your original is untouched."
            return (outcome, nil)
        }
        let link = req.leaveLink || req.linkRequired
        if link {
            do { try FileManager.default.createSymbolicLink(at: src, withDestinationURL: dest) }
            catch {
                try? FileManager.default.moveItem(at: aside, to: src) // roll back
                outcome.message = "Couldn't create the link: \(error.localizedDescription). Rolled back."
                return (outcome, nil)
            }
        }
        if options.trashOriginals {
            try? FileManager.default.trashItem(at: aside, resultingItemURL: nil)
        } else {
            _ = Shell.run("/bin/chmod", ["-R", "u+w", aside.path], timeout: 300)
            try? FileManager.default.removeItem(at: aside)
        }
        Self.repairWorktrees(dest)

        let record = OffloadRecord(source: src.path, destination: dest.path, volumeName: Self.volumeName(dest), bytes: total,
                                   files: inv.entries.count, linked: link, checksummed: options.checksums, skipped: skipped)
        OffloadRegistry.add(record)
        AuditLog.append([CleanOutcome(title: src.lastPathComponent, category: "Offload", paths: [src.path, dest.path], size: total + outcome.skippedBytes,
                                      method: "Offloaded to \(record.volumeName)", success: true,
                                      message: skipped.isEmpty ? "" : "Left behind (rebuildable): " + skipped.map(\.path).joined(separator: ", "))])
        outcome.success = true
        outcome.bytes = total
        outcome.message = link ? "Moved. A link at the original location points to the drive." : "Moved."
        report(force: true) { $0.phase = .done }
        return (outcome, record)
    }

    /// A single large file: copy, checksum, swap.
    private func offloadFile(_ src: URL, _ dest: URL, _ req: OffloadRequest, _ options: OffloadOptions, _ check: OffloadGuard.Destination) -> (OffloadOutcome, OffloadRecord?) {
        var outcome = OffloadOutcome(source: src, destination: dest, success: false, message: "")
        var st = stat()
        guard lstat(src.path, &st) == 0 else { outcome.message = "Can't read it."; return (outcome, nil) }
        let size = Int64(st.st_size)
        if !OffloadGuard.fits(need: Int64(st.st_blocks) * 512, free: check.free) { outcome.message = "Not enough room on the drive."; return (outcome, nil) }
        if check.fsType == "msdos" && size >= 4_294_967_295 { outcome.message = "Files over 4 GB can't be stored on a FAT32 drive."; return (outcome, nil) }
        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let entry = Entry(rel: src.lastPathComponent, kind: .file, size: size, alloc: Int64(st.st_blocks) * 512,
                          mtime: st.st_mtimespec.tv_sec, mtimeNs: st.st_mtimespec.tv_nsec)
        report(force: true) { $0.phase = .copying; $0.bytesTotal = size; $0.filesTotal = 1 }
        if let err = copyTree(src.deletingLastPathComponent(), dest.deletingLastPathComponent(), [entry]) { outcome.message = err; return (outcome, nil) }
        report(force: true) { $0.phase = .verifying; $0.bytesDone = 0; $0.filesDone = 0 }
        if let err = verify(src.deletingLastPathComponent(), dest.deletingLastPathComponent(), [entry], checksums: options.checksums) {
            outcome.message = "Verification failed: \(err). Your original is untouched."; return (outcome, nil)
        }
        var now = stat()
        if lstat(src.path, &now) != 0 || now.st_mtimespec.tv_sec != st.st_mtimespec.tv_sec || Int64(now.st_size) != size {
            outcome.message = "The file changed while copying. Try again when it's not in use."; return (outcome, nil)
        }
        report(force: true) { $0.phase = .finishing }
        let aside = src.deletingLastPathComponent().appendingPathComponent(".\(src.lastPathComponent).prune-offloading")
        do { try FileManager.default.moveItem(at: src, to: aside) } catch { outcome.message = error.localizedDescription; return (outcome, nil) }
        let link = req.leaveLink || req.linkRequired
        if link {
            do { try FileManager.default.createSymbolicLink(at: src, withDestinationURL: dest) }
            catch { try? FileManager.default.moveItem(at: aside, to: src); outcome.message = "Couldn't create the link. Rolled back."; return (outcome, nil) }
        }
        if options.trashOriginals { try? FileManager.default.trashItem(at: aside, resultingItemURL: nil) } else { try? FileManager.default.removeItem(at: aside) }
        let record = OffloadRecord(source: src.path, destination: dest.path, volumeName: Self.volumeName(dest), bytes: size, files: 1,
                                   linked: link, checksummed: options.checksums, skipped: [])
        OffloadRegistry.add(record)
        outcome.success = true; outcome.bytes = size; outcome.message = link ? "Moved, with a link left in place." : "Moved."
        report(force: true) { $0.phase = .done }
        return (outcome, record)
    }

    // MARK: Apps

    /// Moves an application bundle (and optionally its Application Support data) to another drive, leaving links behind.
    func offloadApp(_ app: AppEntry, moveData: Bool, options: OffloadOptions) -> [OffloadOutcome] {
        let src = URL(fileURLWithPath: app.path)
        var outcome = OffloadOutcome(source: src, destination: nil, success: false, message: "")
        report(force: true) { $0 = OffloadProgress(phase: .preparing, item: app.name, itemIndex: 1, itemCount: 1) }
        if case .notMovable(let reasons) = app.move { outcome.message = reasons.joined(separator: " "); return [outcome] }
        if FS.isSymlink(src) { outcome.message = "Already moved."; return [outcome] }
        if !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty { outcome.message = "\(app.name) is running. Quit it first."; return [outcome] }
        let check = OffloadGuard.checkDestination(options.destinationRoot)
        if let p = check.problem { outcome.message = p; return [outcome] }
        if ["exfat", "msdos", "ntfs"].contains(check.fsType) { outcome.message = "Apps contain symlinks and permissions that a \(check.fsType.uppercased()) drive can't store. Use an APFS drive."; return [outcome] }
        let dest = options.destinationRoot.appendingPathComponent("Applications/\(src.lastPathComponent)")
        outcome.destination = dest
        let inv = Self.inventory(src, excluding: [])
        if !inv.errors.isEmpty { outcome.message = "Couldn't read parts of the app (\(inv.errors.prefix(2).joined(separator: ", "))). Nothing was moved."; return [outcome] }
        let need = inv.entries.reduce(Int64(0)) { $0 + $1.alloc }
        if !OffloadGuard.fits(need: need, free: check.free) { outcome.message = "Not enough room on the drive (needs \(Fmt.bytes(need)))."; return [outcome] }
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let total = inv.entries.filter { $0.kind == .file }.reduce(Int64(0)) { $0 + $1.size }
        report(force: true) { $0.phase = .copying; $0.bytesTotal = total; $0.filesTotal = inv.entries.count }
        if let err = copyTree(src, dest, inv.entries) { outcome.message = err; return [outcome] }
        report(force: true) { $0.phase = .verifying; $0.bytesDone = 0; $0.filesDone = 0 }
        if let err = verify(src, dest, inv.entries, checksums: options.checksums) { outcome.message = "Verification failed: \(err). The original is untouched."; return [outcome] }
        applyDirectoryMetadata(src, dest, inv.entries)
        // The copy must still pass macOS's own signature check, or Gatekeeper would refuse to open it.
        if app.signer.trust >= .adhoc {
            let cs = Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", dest.path], timeout: 900)
            if !cs.ok { outcome.message = "The copied app fails code-signature verification (\(cs.stderr.prefix(120))). The original is untouched."; return [outcome] }
        }
        report(force: true) { $0.phase = .finishing }
        let aside = src.deletingLastPathComponent().appendingPathComponent(".\(src.lastPathComponent).prune-offloading")
        do {
            try? FileManager.default.removeItem(at: aside)
            try FileManager.default.moveItem(at: src, to: aside)
            try FileManager.default.createSymbolicLink(at: src, withDestinationURL: dest)
        } catch {
            if FS.exists(aside) && !FS.exists(src) { try? FileManager.default.moveItem(at: aside, to: src) }
            outcome.message = "Couldn't swap in the link: \(error.localizedDescription). The original is untouched."
            return [outcome]
        }
        Self.removeAside(aside)
        _ = Shell.run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", ["-f", dest.path], timeout: 60)
        let record = OffloadRecord(source: src.path, destination: dest.path, volumeName: Self.volumeName(dest), bytes: total,
                                   files: inv.entries.count, linked: true, checksummed: options.checksums, skipped: [])
        OffloadRegistry.add(record)
        AuditLog.append([CleanOutcome(title: app.name, category: "App Mover", paths: [src.path, dest.path], size: total,
                                      method: "Moved app to \(record.volumeName)", success: true, message: "")])
        outcome.success = true
        outcome.bytes = total
        outcome.message = "Moved. /Applications keeps a link, so Dock, Spotlight and login items still find it while the drive is connected."
        var results = [outcome]
        if moveData {
            for d in app.movableData where Sizer.measure(d).bytes >= 50 * 1_048_576 {
                let (o, _) = offload(OffloadRequest(source: d, skipArtifacts: false, leaveLink: true, linkRequired: true, appData: true),
                                     options: options, index: 1, count: 1)
                results.append(o)
            }
        }
        report(force: true) { $0.phase = .done }
        return results
    }

    /// Deletes the set-aside original. Root-owned app bundles need one administrator prompt.
    static func removeAside(_ aside: URL) {
        guard aside.lastPathComponent.hasSuffix(".prune-offloading") else { return }
        _ = Shell.run("/bin/chmod", ["-R", "u+w", aside.path], timeout: 300)
        if (try? FileManager.default.removeItem(at: aside)) == nil && FS.exists(aside) {
            _ = Shell.runAsAdmin("/bin/rm -rf \(Shell.shellQuote(aside.path))")
        }
    }

    // MARK: Bring back

    func bringBack(_ record: OffloadRecord, keepCopyOnDrive: Bool) -> OffloadOutcome {
        let original = URL(fileURLWithPath: record.source)
        let copy = URL(fileURLWithPath: record.destination)
        var outcome = OffloadOutcome(source: copy, destination: original, success: false, message: "")
        report(force: true) { $0 = OffloadProgress(phase: .preparing, item: original.lastPathComponent, itemIndex: 1, itemCount: 1) }
        guard FS.exists(copy) else { outcome.message = "The drive with \(copy.lastPathComponent) isn't connected."; return outcome }
        if FS.exists(original) {
            let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: original.path)).map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            guard FS.isSymlink(original), target == copy.standardizedFileURL.path else {
                outcome.message = "Something else now exists at \(FS.tildePath(original)). Move it away first."
                return outcome
            }
        }
        if !FS.isDir(copy) && FS.exists(copy) { return bringBackFile(record, copy, original, keepCopyOnDrive) }
        let inv = Self.inventory(copy, excluding: [])
        let need = inv.entries.reduce(Int64(0)) { $0 + $1.alloc }
        let free = SystemInfo.bootVolume()?.availableStrict ?? 0
        if free < need + 2_000_000_000 { outcome.message = "Not enough free space on the Mac: needs \(Fmt.bytes(need))."; return outcome }

        let staging = original.deletingLastPathComponent().appendingPathComponent(".\(original.lastPathComponent).prune-restoring")
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let total = inv.entries.filter { $0.kind == .file }.reduce(Int64(0)) { $0 + $1.size }
        report(force: true) { $0.phase = .copying; $0.bytesTotal = total; $0.filesTotal = inv.entries.count }
        if let err = copyTree(copy, staging, inv.entries) { outcome.message = err; return outcome }
        report(force: true) { $0.phase = .verifying; $0.bytesDone = 0; $0.filesDone = 0 }
        if let err = verify(copy, staging, inv.entries, checksums: true) { outcome.message = "Verification failed: \(err)."; return outcome }
        applyDirectoryMetadata(copy, staging, inv.entries)
        report(force: true) { $0.phase = .finishing }
        do {
            if FS.isSymlink(original) { try FileManager.default.removeItem(at: original) }
            try FileManager.default.moveItem(at: staging, to: original)
        } catch {
            outcome.message = "Couldn't put it back: \(error.localizedDescription). The drive copy is untouched."
            return outcome
        }
        if !keepCopyOnDrive {
            _ = Shell.run("/bin/chmod", ["-R", "u+w", copy.path], timeout: 300)
            try? FileManager.default.removeItem(at: copy)
        }
        Self.repairWorktrees(original)
        if original.pathExtension == "app" {
            _ = Shell.run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", ["-f", original.path], timeout: 60)
        }
        OffloadRegistry.remove(record.id)
        AuditLog.append([CleanOutcome(title: original.lastPathComponent, category: "Offload", paths: [copy.path, original.path], size: total,
                                      method: "Brought back from \(record.volumeName)", success: true, message: keepCopyOnDrive ? "Drive copy kept" : "")])
        outcome.success = true
        outcome.bytes = total
        outcome.message = "Back on your Mac" + (record.skipped.isEmpty ? "." : ". Rebuild skipped folders with: " + Set(record.skipped.compactMap(\.restore)).sorted().joined(separator: ", "))
        report(force: true) { $0.phase = .done }
        return outcome
    }

    private func bringBackFile(_ record: OffloadRecord, _ copy: URL, _ original: URL, _ keep: Bool) -> OffloadOutcome {
        var outcome = OffloadOutcome(source: copy, destination: original, success: false, message: "")
        var st = stat()
        guard lstat(copy.path, &st) == 0 else { outcome.message = "Can't read the copy."; return outcome }
        let entry = Entry(rel: copy.lastPathComponent, kind: .file, size: Int64(st.st_size), alloc: Int64(st.st_blocks) * 512,
                          mtime: st.st_mtimespec.tv_sec, mtimeNs: st.st_mtimespec.tv_nsec)
        let stagingDir = original.deletingLastPathComponent().appendingPathComponent(".prune-restoring-\(record.id.uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingDir) }
        report(force: true) { $0.phase = .copying; $0.bytesTotal = entry.size; $0.filesTotal = 1 }
        if let err = copyTree(copy.deletingLastPathComponent(), stagingDir, [entry]) { outcome.message = err; return outcome }
        if let err = verify(copy.deletingLastPathComponent(), stagingDir, [entry], checksums: true) { outcome.message = "Verification failed: \(err)."; return outcome }
        do {
            if FS.isSymlink(original) { try FileManager.default.removeItem(at: original) }
            try FileManager.default.moveItem(at: stagingDir.appendingPathComponent(copy.lastPathComponent), to: original)
        } catch { outcome.message = error.localizedDescription; return outcome }
        if !keep { try? FileManager.default.removeItem(at: copy) }
        OffloadRegistry.remove(record.id)
        outcome.success = true; outcome.bytes = entry.size; outcome.message = "Back on your Mac."
        return outcome
    }

    // MARK: Primitives

    private static let cfAll: copyfile_flags_t = 0xF                       // ACL | STAT | XATTR | DATA
    private static let cfMetadata: copyfile_flags_t = 0x7                  // ACL | STAT | XATTR
    private static let cfNoFollow: copyfile_flags_t = (1 << 18) | (1 << 19)
    private static let cfSparse: copyfile_flags_t = 1 << 27

    final class CopyContext {
        var lastCopied: off_t = 0
        weak var engine: OffloadEngine?
        init(_ e: OffloadEngine) { engine = e }
    }

    /// Creates directories, then copies files in parallel. Already-identical files are skipped (resume).
    private func copyTree(_ src: URL, _ dst: URL, _ entries: [Entry]) -> String? {
        let fm = FileManager.default
        for e in entries where e.kind == .dir {
            let d = dst.appendingPathComponent(e.rel)
            if FS.isSymlink(d) || (FS.exists(d) && !FS.isDir(d)) { try? fm.removeItem(at: d) }
            if !FS.isDir(d) {
                do { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
                catch { return "Couldn't create \(e.rel) on the drive: \(error.localizedDescription)" }
            }
        }
        let work = entries.filter { $0.kind != .dir }
        var firstError: String?
        let errLock = NSLock()
        let workers = min(8, max(2, ProcessInfo.processInfo.activeProcessorCount))
        let chunk = max(1, (work.count + workers * 8 - 1) / (workers * 8))
        let batches = stride(from: 0, to: work.count, by: chunk).map { Array(work[$0..<min($0 + chunk, work.count)]) }
        DispatchQueue.concurrentPerform(iterations: batches.count) { b in
            for e in batches[b] {
                errLock.lock(); let stop = firstError != nil; errLock.unlock()
                if stop || isCancelled { return }
                let s = src.path + "/" + e.rel, d = dst.path + "/" + e.rel
                report { $0.current = e.rel }
                // Resume: identical size and mtime means it's already there.
                var dst_st = stat()
                if lstat(d, &dst_st) == 0 {
                    let sameKind = (dst_st.st_mode & S_IFMT) == (e.kind == .link ? S_IFLNK : S_IFREG)
                    if sameKind && Int64(dst_st.st_size) == e.size && dst_st.st_mtimespec.tv_sec == e.mtime {
                        report { $0.bytesDone += e.kind == .file ? e.size : 0; $0.filesDone += 1 }
                        continue
                    }
                    unlink(d)
                }
                let ctx = CopyContext(self)
                let state = copyfile_state_alloc()
                let cb: copyfile_callback_t = { what, stage, state, _, _, ctxPtr in
                    guard let ctxPtr else { return COPYFILE_CONTINUE }
                    let c = Unmanaged<CopyContext>.fromOpaque(ctxPtr).takeUnretainedValue()
                    guard let engine = c.engine else { return COPYFILE_QUIT }
                    if engine.isCancelled { return COPYFILE_QUIT }
                    if what == COPYFILE_COPY_DATA && stage == COPYFILE_PROGRESS {
                        var copied: off_t = 0
                        copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
                        let delta = Int64(copied - c.lastCopied)
                        c.lastCopied = copied
                        if delta > 0 { engine.report { $0.bytesDone += delta } }
                    }
                    return COPYFILE_CONTINUE
                }
                copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(cb, to: UnsafeRawPointer.self))
                let ctxPtr = Unmanaged.passRetained(ctx).toOpaque()
                copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), ctxPtr)
                let rc = copyfile(s, d, state, Self.cfAll | Self.cfNoFollow | Self.cfSparse)
                let err = errno
                copyfile_state_free(state)
                Unmanaged<CopyContext>.fromOpaque(ctxPtr).release()
                if rc != 0 {
                    if isCancelled { return }
                    errLock.lock()
                    if firstError == nil { firstError = "Copy failed for \(e.rel): \(String(cString: strerror(err)))" }
                    errLock.unlock()
                    return
                }
                report { $0.bytesDone += max(0, (e.kind == .file ? e.size : 0) - Int64(ctx.lastCopied)); $0.filesDone += 1 }
            }
        }
        if isCancelled { return "Cancelled. Nothing was removed from your Mac, and the partial copy resumes next time." }
        return firstError
    }

    private func verify(_ src: URL, _ dst: URL, _ entries: [Entry], checksums: Bool) -> String? {
        var problem: String?
        let lock = NSLock()
        let files = entries
        let total = files.filter { $0.kind == .file }.reduce(Int64(0)) { $0 + $1.size }
        report(force: true) { $0.bytesTotal = checksums ? total : 0; $0.filesTotal = files.count }
        DispatchQueue.concurrentPerform(iterations: max(1, min(8, files.count))) { w in
            var i = w
            while i < files.count {
                defer { i += max(1, min(8, files.count)) }
                lock.lock(); let stop = problem != nil; lock.unlock()
                if stop || isCancelled { return }
                let e = files[i]
                let s = src.path + "/" + e.rel, d = dst.path + "/" + e.rel
                var st = stat()
                var bad: String?
                if lstat(d, &st) != 0 { bad = "\(e.rel) is missing on the drive" }
                else {
                    switch e.kind {
                    case .dir: if (st.st_mode & S_IFMT) != S_IFDIR { bad = "\(e.rel) isn't a folder on the drive" }
                    case .link:
                        let a = try? FileManager.default.destinationOfSymbolicLink(atPath: s)
                        let b = try? FileManager.default.destinationOfSymbolicLink(atPath: d)
                        if a != b { bad = "link \(e.rel) differs" }
                    case .file:
                        if Int64(st.st_size) != e.size { bad = "\(e.rel) has a different size" }
                        else if checksums && Self.sha256(s) != Self.sha256(d) { bad = "\(e.rel) has different contents" }
                    }
                }
                if let bad { lock.lock(); if problem == nil { problem = bad }; lock.unlock(); return }
                report { $0.filesDone += 1; if checksums && e.kind == .file { $0.bytesDone += e.size }; $0.current = e.rel }
            }
        }
        if isCancelled { return "cancelled" }
        return problem
    }

    static func sha256(_ path: String) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while true {
            let data = h.readData(ofLength: 4 << 20)
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Directory permissions and timestamps are applied last, deepest first, so file copies don't disturb them.
    private func applyDirectoryMetadata(_ src: URL, _ dst: URL, _ entries: [Entry]) {
        for e in entries.filter({ $0.kind == .dir }).sorted(by: { $0.rel.count > $1.rel.count }) {
            _ = copyfile(src.path + "/" + e.rel, dst.path + "/" + e.rel, nil, Self.cfMetadata | Self.cfNoFollow)
        }
        _ = copyfile(src.path, dst.path, nil, Self.cfMetadata | Self.cfNoFollow)
    }

    static func diff(old: [Entry], new: [Entry]) -> (modified: [Entry], removed: [String]) {
        var before: [String: Entry] = [:]
        for e in old { before[e.rel] = e }
        var modified: [Entry] = []
        var seen = Set<String>()
        for e in new {
            seen.insert(e.rel)
            if let o = before[e.rel], o.kind == e.kind, o.size == e.size, o.mtime == e.mtime, o.mtimeNs == e.mtimeNs { continue }
            if e.kind == .dir, before[e.rel]?.kind == .dir { continue }
            modified.append(e)
        }
        let removed = old.filter { !seen.contains($0.rel) }.map(\.rel)
        return (modified, removed)
    }

    struct FoundArtifact { var url: URL; var rule: ArtifactRule; var siblings: Set<String>; var bytes: Int64 }

    /// Rebuildable folders inside a tree, validated the same way as the cleanup scanner (and never git-tracked ones).
    static func artifacts(in root: URL) -> [FoundArtifact] {
        var settings = AppSettings.shared.snapshot
        settings.scanRoots = [root]
        settings.excludedPaths = []
        let idx = ProjectIndex.build(roots: [root], settings: settings) { _ in }
        var found = idx.artifacts
        var byRepo: [String: [ArtifactCandidate]] = [:]
        for c in found {
            if let scope = idx.scopeRoot(for: c.url), idx.projects[scope]?.gitKind != ProjectInfo.GitKind.none { byRepo[scope, default: []].append(c) }
        }
        var tracked = Set<String>()
        for (repo, list) in byRepo {
            for rel in Git.trackedPaths(URL(fileURLWithPath: repo), list.map { String($0.url.path.dropFirst(repo.count + 1)) }) { tracked.insert(repo + "/" + rel) }
        }
        found.removeAll { tracked.contains($0.url.path) }
        let sizes = Sizer.measureMany(found.map(\.url))
        return found.map { FoundArtifact(url: $0.url, rule: $0.rule, siblings: $0.siblings, bytes: sizes[$0.url]?.bytes ?? 0) }
    }

    /// Keeps git worktree links valid after a repository or worktree moves.
    static func repairWorktrees(_ root: URL) {
        guard Git.tool != nil else { return }
        var candidates = [root]
        for c in FS.childDirs(root).prefix(200) { candidates.append(c) }
        for d in candidates where FS.exists(d.appendingPathComponent(".git")) {
            Git.run(d, ["worktree", "repair"], timeout: 30)
        }
    }

    static func volumeName(_ url: URL) -> String {
        (try? url.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? url.pathComponents.dropFirst(2).first ?? "drive"
    }
}
