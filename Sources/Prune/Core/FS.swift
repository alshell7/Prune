import Foundation
import CoreServices

struct SizeResult {
    var bytes: Int64 = 0
    var files: Int = 0
    var newest: Date?
    var unreadable: Int = 0
}

/// Fast on-disk size measurement. A pool of threads walks directories with getattrlistbulk(2)
/// (one syscall per directory instead of one stat per file), counts allocated bytes, stays on the
/// starting volume, never follows symlinks and counts each hard-linked file once.
enum Sizer {
    static func measure(_ url: URL) -> SizeResult { measureMany([url])[url] ?? SizeResult() }

    static func measureMany(_ urls: [URL]) -> [URL: SizeResult] {
        guard !urls.isEmpty else { return [:] }
        let walker = BulkWalker(roots: urls)
        walker.run()
        var dict: [URL: SizeResult] = [:]
        for (i, u) in urls.enumerated() { dict[u] = walker.results[i] }
        return dict
    }
}

private final class BulkWalker {
    private let cond = NSCondition()
    private var stack: [(root: Int, path: String)] = []
    private var pending = 0
    private struct InodeKey: Hashable { var root: Int; var device: Int32; var inode: UInt64 }
    private var seenInodes = Set<InodeKey>()
    private let rootDevs: [Int32]
    var results: [SizeResult]

    init(roots: [URL]) {
        results = [SizeResult](repeating: SizeResult(), count: roots.count)
        var devs = [Int32](repeating: 0, count: roots.count)
        for (i, u) in roots.enumerated() {
            var st = stat()
            guard lstat(u.path, &st) == 0 else { continue }
            devs[i] = st.st_dev
            let mtime = st.st_mtimespec.tv_sec
            results[i].newest = mtime > 0 ? Date(timeIntervalSince1970: TimeInterval(mtime)) : nil
            if (st.st_mode & S_IFMT) == S_IFDIR {
                results[i].bytes = Int64(st.st_blocks) * 512
                stack.append((i, u.path))
            } else {
                results[i].bytes = Int64(st.st_blocks) * 512
                results[i].files = 1
            }
        }
        rootDevs = devs
        pending = stack.count
    }

    func run() {
        guard pending > 0 else { return }
        let threads = min(16, max(4, ProcessInfo.processInfo.activeProcessorCount * 2))
        let group = DispatchGroup()
        for _ in 0..<threads {
            group.enter()
            let t = Thread { self.worker(); group.leave() }
            t.stackSize = 1 << 20
            t.start()
        }
        group.wait()
    }

    private struct Acc { var bytes: Int64 = 0; var files = 0; var newest = 0; var unreadable = 0 }

    private func worker() {
        var local: [Int: Acc] = [:]
        let bufSize = 128 * 1024
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 16)
        defer { buf.deallocate() }
        var found: [String] = []
        while true {
            cond.lock()
            while stack.isEmpty && pending > 0 { cond.wait() }
            guard let job = stack.popLast() else { cond.unlock(); break }
            cond.unlock()

            found.removeAll(keepingCapacity: true)
            var acc = local[job.root] ?? Acc()
            scan(job.path, root: job.root, dev: rootDevs[job.root], buf: buf, bufSize: bufSize, acc: &acc, dirs: &found)
            local[job.root] = acc

            cond.lock()
            for d in found { stack.append((job.root, d)) }
            pending += found.count - 1
            cond.broadcast()
            cond.unlock()
        }
        cond.lock()
        for (i, a) in local {
            results[i].bytes += a.bytes
            results[i].files += a.files
            results[i].unreadable += a.unreadable
            if a.newest > 0 {
                let d = Date(timeIntervalSince1970: TimeInterval(a.newest))
                if d > (results[i].newest ?? .distantPast) { results[i].newest = d }
            }
        }
        cond.unlock()
    }

    // attrlist bits (sys/attr.h)
    private static let cmnName: UInt32 = 0x0000_0001, cmnDevID: UInt32 = 0x0000_0002, cmnObjType: UInt32 = 0x0000_0008
    private static let cmnModTime: UInt32 = 0x0000_0400, cmnFileID: UInt32 = 0x0200_0000, cmnReturned: UInt32 = 0x8000_0000
    private static let fileLinkCount: UInt32 = 0x0000_0001, fileAllocSize: UInt32 = 0x0000_0004
    private static let vREG: UInt32 = 1, vDIR: UInt32 = 2

    private func scan(_ path: String, root: Int, dev: Int32, buf: UnsafeMutableRawPointer, bufSize: Int, acc: inout Acc, dirs: inout [String]) {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { acc.unreadable += 1; return }
        defer { close(fd) }
        var al = attrlist()
        al.bitmapcount = 5
        al.commonattr = Self.cmnReturned | Self.cmnName | Self.cmnDevID | Self.cmnObjType | Self.cmnModTime | Self.cmnFileID
        al.fileattr = Self.fileLinkCount | Self.fileAllocSize
        let startAcc = acc, startDirs = dirs.count
        var insertedInodes: [InodeKey] = []
        func restartWithFallback() {
            acc = startAcc
            if dirs.count > startDirs { dirs.removeSubrange(startDirs..<dirs.count) }
            cond.lock(); insertedInodes.forEach { _ = seenInodes.remove($0) }; cond.unlock()
            fallback(path, root: root, dev: dev, acc: &acc, dirs: &dirs)
        }
        while true {
            let n = getattrlistbulk(fd, &al, buf, bufSize, 0)
            if n < 0 {
                if errno == ENOTSUP || errno == EINVAL || errno == ENOSYS { restartWithFallback() } else { acc.unreadable += 1 }
                return
            }
            if n == 0 { return }
            var entry = buf
            for _ in 0..<n {
                let length = Int(entry.load(as: UInt32.self))
                var p = entry + 4
                let common = p.loadUnaligned(as: UInt32.self)
                let fileAttrs = p.loadUnaligned(fromByteOffset: 12, as: UInt32.self)
                if common & (Self.cmnName | Self.cmnObjType) != (Self.cmnName | Self.cmnObjType) { restartWithFallback(); return }
                p += 20 // attribute_set_t
                var nameStart: UnsafeMutableRawPointer?
                if common & Self.cmnName != 0 {
                    let off = p.loadUnaligned(as: Int32.self)
                    nameStart = p + Int(off)
                    p += 8
                }
                var entryDev = dev
                if common & Self.cmnDevID != 0 { entryDev = p.loadUnaligned(as: Int32.self); p += 4 }
                var type: UInt32 = 0
                if common & Self.cmnObjType != 0 { type = p.loadUnaligned(as: UInt32.self); p += 4 }
                var mtime = 0
                if common & Self.cmnModTime != 0 { mtime = p.loadUnaligned(as: Int.self); p += 16 }
                var fileID: UInt64 = 0
                if common & Self.cmnFileID != 0 { fileID = p.loadUnaligned(as: UInt64.self); p += 8 }
                var links: UInt32 = 1
                if fileAttrs & Self.fileLinkCount != 0 { links = p.loadUnaligned(as: UInt32.self); p += 4 }
                var alloc: Int64 = 0
                if fileAttrs & Self.fileAllocSize != 0 { alloc = p.loadUnaligned(as: Int64.self); p += 8 }
                if fileAttrs & Self.fileAllocSize == 0, type == Self.vREG, let ns = nameStart {
                    let child = path + "/" + String(cString: ns.assumingMemoryBound(to: CChar.self))
                    var st = stat()
                    if lstat(child, &st) == 0 { alloc = Int64(st.st_blocks) * 512 }
                }

                if mtime > acc.newest { acc.newest = mtime }
                if type == Self.vDIR {
                    if entryDev == dev, let ns = nameStart {
                        dirs.append(path + "/" + String(cString: ns.assumingMemoryBound(to: CChar.self)))
                    }
                } else {
                    if links > 1 && fileID != 0 {
                        let key = InodeKey(root: root, device: entryDev, inode: fileID)
                        cond.lock()
                        let fresh = seenInodes.insert(key).inserted
                        cond.unlock()
                        if !fresh { entry += length; continue }
                        insertedInodes.append(key)
                    }
                    acc.bytes += alloc
                    acc.files += 1
                }
                entry += length
            }
        }
    }

    /// For file systems without getattrlistbulk support.
    private func fallback(_ path: String, root: Int, dev: Int32, acc: inout Acc, dirs: inout [String]) {
        guard let entries = FS.list(path) else { acc.unreadable += 1; return }
        for e in entries {
            let child = path + "/" + e.name
            var st = stat()
            guard lstat(child, &st) == 0 else { continue }
            if st.st_mtimespec.tv_sec > acc.newest { acc.newest = st.st_mtimespec.tv_sec }
            if (st.st_mode & S_IFMT) == S_IFDIR {
                if st.st_dev == dev { dirs.append(child) }
            } else {
                if st.st_nlink > 1 {
                    let key = InodeKey(root: root, device: st.st_dev, inode: st.st_ino)
                    cond.lock(); let fresh = seenInodes.insert(key).inserted; cond.unlock()
                    if !fresh { continue }
                }
                acc.bytes += Int64(st.st_blocks) * 512
                acc.files += 1
            }
        }
    }
}

enum FS {
    static let fm = FileManager.default
    static let home = URL(fileURLWithPath: NSHomeDirectory())

    static func exists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    static func isDir(_ url: URL) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFDIR
    }

    static func isSymlink(_ url: URL) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFLNK
    }

    static func mtime(_ url: URL) -> Date? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
    }

    static func fileSize(_ url: URL) -> Int64 {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return 0 }
        return Int64(st.st_blocks) * 512
    }

    /// Directory children including hidden entries. Empty on error.
    static func children(_ url: URL) -> [URL] {
        (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])) ?? []
    }

    static func childDirs(_ url: URL) -> [URL] {
        children(url).filter { isDir($0) }
    }

    struct Entry { var name: String; var isDir: Bool; var isLink: Bool }

    /// Raw readdir listing — much cheaper than FileManager for big walks.
    static func list(_ path: String) -> [Entry]? {
        guard let dir = opendir(path) else { return nil }
        defer { closedir(dir) }
        var out: [Entry] = []
        while let ent = readdir(dir) {
            let name = withUnsafePointer(to: ent.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(ent.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            var t = Int32(ent.pointee.d_type)
            // Some external file systems do not provide d_type in directory entries.
            if t == DT_UNKNOWN {
                var st = stat()
                let child = (path as NSString).appendingPathComponent(name)
                if lstat(child, &st) == 0 {
                    switch st.st_mode & S_IFMT {
                    case S_IFDIR: t = DT_DIR
                    case S_IFLNK: t = DT_LNK
                    default: t = DT_REG
                    }
                }
            }
            out.append(Entry(name: name, isDir: t == DT_DIR, isLink: t == DT_LNK))
        }
        return out
    }

    static func readText(_ url: URL, limit: Int = 512 * 1024) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let data = try? h.read(upToCount: limit) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func readJSON(_ url: URL) -> Any? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// Newest modification time among a directory's immediate entries (cheap activity signal).
    static func newestChildMtime(_ url: URL, skipping skip: Set<String> = []) -> Date? {
        guard let entries = list(url.path) else { return nil }
        var newest: Date?
        for e in entries where !skip.contains(e.name) && e.name != ".DS_Store" {
            if let m = mtime(url.appendingPathComponent(e.name)), m > (newest ?? .distantPast) { newest = m }
        }
        return newest
    }

    static func tildePath(_ url: URL) -> String {
        let p = url.path
        let h = home.path
        if p == h { return "~" }
        if p.hasPrefix(h + "/") { return "~" + p.dropFirst(h.count) }
        return p
    }

    static func isAncestor(_ a: String, of b: String) -> Bool {
        b.hasPrefix(a.hasSuffix("/") ? a : a + "/")
    }
}

/// Spotlight metadata helpers (fast, indexed).
enum Spotlight {
    static func attribute(_ url: URL, _ name: String) -> Any? {
        guard let item = MDItemCreateWithURL(nil, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, name as CFString)
    }

    static func lastUsed(_ url: URL) -> Date? { attribute(url, "kMDItemLastUsedDate") as? Date }

    static func physicalSize(_ url: URL) -> Int64? {
        (attribute(url, "kMDItemPhysicalSize") as? NSNumber)?.int64Value
    }

    /// Runs an mdfind query; returns matching paths.
    static func find(_ query: String, onlyIn: String? = nil, timeout: TimeInterval = 30) -> [String] {
        var args: [String] = []
        if let onlyIn { args += ["-onlyin", onlyIn] }
        args.append(query)
        let r = Shell.run("/usr/bin/mdfind", args, timeout: timeout)
        guard r.ok else { return [] }
        return r.stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }
}

enum Fmt {
    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    static func relative(_ d: Date?) -> String {
        guard let d else { return "—" }
        if abs(d.timeIntervalSinceNow) < 60 { return "just now" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: d, relativeTo: Date())
    }

    static func age(_ d: Date?) -> String {
        guard let days = Age.days(d) else { return "unknown" }
        switch days {
        case ..<1: return "today"
        case 1: return "1 day"
        case ..<31: return "\(days) days"
        case ..<365: return "\(days / 30) month\(days / 30 == 1 ? "" : "s")"
        default:
            let y = Double(days) / 365
            return String(format: y < 2 ? "%.1f years" : "%.0f years", y).replacingOccurrences(of: "1.0 years", with: "1 year")
        }
    }
}

extension Fmt {
    /// "today" / "3 days ago"
    static func ago(_ d: Date?) -> String {
        let a = age(d)
        return a == "today" || a == "unknown" ? a : a + " ago"
    }
}

enum Age {
    static func days(_ d: Date?) -> Int? {
        guard let d else { return nil }
        return max(0, Int(Date().timeIntervalSince(d) / 86_400))
    }
}
