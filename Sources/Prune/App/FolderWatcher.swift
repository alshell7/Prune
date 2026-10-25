import CoreServices
import Foundation
import Observation

/// Watches chosen folders with FSEvents and re-measures only the ones that changed.
@MainActor
@Observable
final class FolderWatcher {
    static let shared = FolderWatcher()

    var measuring: Set<String> = []
    private let settings = AppSettings.shared
    private var stream: FSEventStreamRef?
    private var dirty: Set<String> = []
    private var alerted: [String: Int64] = [:]
    private var timer: Timer?

    var folders: [WatchedFolder] { settings.watchedFolders }

    func start() {
        rebuildStream()
        timer?.invalidate()
        // Re-measure changed folders at most every 2 minutes; everything at least every 6 hours.
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { _ in
            Task { @MainActor in FolderWatcher.shared.measureDirty() }
        }
        for f in folders where (f.lastChecked ?? .distantPast) < Date().addingTimeInterval(-3600) { measure(f.path) }
    }

    func add(_ url: URL) {
        guard !settings.watchedFolders.contains(where: { $0.path == url.path }) else { return }
        settings.watchedFolders.append(WatchedFolder(path: url.path))
        rebuildStream()
        measure(url.path, setBaseline: true)
    }

    func remove(_ path: String) {
        settings.watchedFolders.removeAll { $0.path == path }
        rebuildStream()
    }

    func resetBaseline(_ path: String) {
        guard let i = settings.watchedFolders.firstIndex(where: { $0.path == path }) else { return }
        settings.watchedFolders[i].baselineSize = settings.watchedFolders[i].lastSize
        settings.watchedFolders[i].baselineDate = Date()
        alerted[path] = nil
    }

    func measureAll() { folders.forEach { measure($0.path) } }

    func measure(_ path: String, setBaseline: Bool = false) {
        guard !measuring.contains(path) else { return }
        measuring.insert(path)
        dirty.remove(path)
        DispatchQueue.global(qos: .utility).async {
            let r = Sizer.measure(URL(fileURLWithPath: path))
            DispatchQueue.main.async {
                let w = FolderWatcher.shared
                w.measuring.remove(path)
                guard let i = w.settings.watchedFolders.firstIndex(where: { $0.path == path }) else { return }
                var f = w.settings.watchedFolders[i]
                f.lastSize = r.bytes
                f.lastChecked = Date()
                if setBaseline || f.baselineSize == nil { f.baselineSize = r.bytes; f.baselineDate = Date() }
                w.settings.watchedFolders[i] = f
                w.checkGrowth(f)
            }
        }
    }

    private func checkGrowth(_ f: WatchedFolder) {
        guard let growth = f.growth else { return }
        let limit = Int64(settings.growthAlertGB) * 1_000_000_000
        guard limit > 0, growth >= limit, (alerted[f.path] ?? 0) + limit <= growth else { return }
        alerted[f.path] = growth
        Notifier.post(title: "\(f.name) grew by \(Fmt.bytes(growth))", body: "It's now \(Fmt.bytes(f.lastSize ?? 0)). Open Prune to see what's inside.")
    }

    private func measureDirty() {
        for p in dirty { measure(p) }
        for f in folders where (f.lastChecked ?? .distantPast) < Date().addingTimeInterval(-6 * 3600) { measure(f.path) }
    }

    fileprivate func noteChanges(_ paths: [String]) {
        for f in folders where paths.contains(where: { $0 == f.path || $0.hasPrefix(f.path + "/") }) { dirty.insert(f.path) }
    }

    private func rebuildStream() {
        if let s = stream {
            FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s)
            stream = nil
        }
        let paths = folders.map(\.path).filter { FS.isDir(URL(fileURLWithPath: $0)) }
        guard !paths.isEmpty else { return }
        var ctx = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, _, count, eventPaths, _, _ in
            let arr = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            let list = Array(arr.prefix(count))
            Task { @MainActor in FolderWatcher.shared.noteChanges(list) }
        }
        guard let s = FSEventStreamCreate(nil, callback, &ctx, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 30,
                                          FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)) else { return }
        FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
        FSEventStreamStart(s)
        stream = s
    }
}
