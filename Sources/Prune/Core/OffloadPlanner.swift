import Foundation

struct OffloadCandidate: Identifiable, Hashable {
    enum Kind: String, CaseIterable {
        case project = "Projects"
        case dataFolder = "Data folders inside projects"
        case userFolder = "Documents, Downloads, Desktop & media"

        var blurb: String {
            switch self {
            case .project: "Whole projects (with git history). Rebuildable folders like node_modules and target/ are left behind instead of copied."
            case .dataFolder: "Large model, dataset or media folders inside projects. A link keeps your code's paths working."
            case .userFolder: "Folders and big files you keep but rarely open."
            }
        }
    }

    var id: String { url.path }
    var url: URL
    var kind: Kind
    var bytes: Int64           // what would be copied
    var skippable: Int64       // rebuildable data left behind
    var lastActivity: Date?
    var note: String
    var defaultLink: Bool
    var defaultSkip: Bool
    var isGoodCandidate: Bool

    var title: String {
        let rel = url.path.hasPrefix(FS.home.path + "/") ? String(url.path.dropFirst(FS.home.path.count + 1)) : url.path
        return rel
    }
}

/// Finds projects, data folders and user folders worth moving off the internal disk.
enum OffloadPlanner {
    static let userFolders = ["Documents", "Downloads", "Desktop", "Movies", "Music", "Pictures"]
    static let dataNames: Set<String> = ["models", "model", "data", "datasets", "dataset", "weights", "checkpoints", "assets", "media",
                                         "videos", "recordings", "samples", "raw", "exports", "renders", "footage", "promo", "backups"]

    static func candidates(settings: SettingsSnapshot, progress: @escaping (String) -> Void) -> [OffloadCandidate] {
        progress("Indexing projects…")
        let idx = ProjectIndex.build(roots: settings.scanRoots.filter(FS.isDir), settings: settings) { progress("Walking " + $0) }
        var out: [OffloadCandidate] = []

        // Top-level projects: the outermost project folders.
        let roots = idx.projects.keys.filter { idx.outermostProject(for: URL(fileURLWithPath: $0)) == $0 }
            .map { URL(fileURLWithPath: $0) }
            .filter { OffloadGuard.checkSource($0) == nil && !$0.path.contains("/.claude/worktrees/") }
        progress("Measuring \(roots.count) projects…")
        let artifactsByRoot = Dictionary(grouping: idx.artifacts) { a in roots.first { FS.isAncestor($0.path, of: a.url.path) }?.path ?? "" }
        let totals = Sizer.measureMany(roots)
        let artSizes = Sizer.measureMany(idx.artifacts.map(\.url))
        for r in roots {
            let total = totals[r]?.bytes ?? 0
            let skip = (artifactsByRoot[r.path] ?? []).reduce(Int64(0)) { $0 + (artSizes[$1.url]?.bytes ?? 0) }
            let movable = max(0, total - skip)
            guard total >= 100 * 1_048_576 else { continue }
            let activity = idx.scopeActivity[r.path] ?? idx.activity(for: r)
            let idleDays = Age.days(activity) ?? 999
            let good = idleDays >= settings.staleDays
            var note = idleDays == 0 ? "Worked on today" : "Last touched \(Fmt.ago(activity))"
            if skip > 0 { note += " · \(Fmt.bytes(skip)) rebuildable stays behind" }
            if !good { note += " · Active: builds via the link will run from the drive" }
            let backup = r.appendingPathComponent(".git").path
            if !FS.exists(URL(fileURLWithPath: backup)) { note += " · \u{26A0} not in git" }
            else {
                let s = CodeBackup.gitStatus(r, linked: !FS.isDir(URL(fileURLWithPath: backup)))
                if s.level >= .unpushed { note += " · \u{26A0} \(s.headline.lowercased())" }
            }
            out.append(OffloadCandidate(url: r, kind: .project, bytes: movable, skippable: skip, lastActivity: activity, note: note,
                                        defaultLink: true, defaultSkip: true, isGoodCandidate: good))
        }

        // Large data folders inside projects (not tracked by git, not build artifacts).
        progress("Looking for large data folders…")
        var dataDirs: [URL] = []
        for r in roots {
            var stack: [(URL, Int)] = [(r, 0)]
            while let (d, depth) = stack.popLast() {
                for c in FS.childDirs(d) where !c.lastPathComponent.hasPrefix(".") && !ArtifactRules.allNames.contains(c.lastPathComponent) {
                    if dataNames.contains(c.lastPathComponent.lowercased()) { dataDirs.append(c) }
                    else if depth < 2 { stack.append((c, depth + 1)) }
                }
            }
        }
        let dataSizes = Sizer.measureMany(dataDirs)
        for d in dataDirs {
            guard let m = dataSizes[d], m.bytes >= 500 * 1_048_576 else { continue }
            if let scope = idx.scopeRoot(for: d), idx.projects[scope]?.gitKind != ProjectInfo.GitKind.none {
                let rel = String(d.path.dropFirst(scope.count + 1))
                if !Git.trackedPaths(URL(fileURLWithPath: scope), [rel]).isEmpty { continue }   // replacing tracked files with a link would change the repo
            }
            out.append(OffloadCandidate(url: d, kind: .dataFolder, bytes: m.bytes, skippable: 0, lastActivity: m.newest,
                                        note: "Not tracked by git · last changed \(Fmt.ago(m.newest)) · code keeps using it through a link",
                                        defaultLink: true, defaultSkip: false, isGoodCandidate: (Age.days(m.newest) ?? 0) >= 7))
        }

        // Folders in Documents, Downloads, Desktop… that aren't projects. Folders that *contain* projects
        // (e.g. a workspace with code plus a big models/ folder) are opened up so their data can move on its own.
        progress("Checking your folders…")
        let projectPaths = Array(idx.projects.keys)
        var userItems: [URL] = []
        var insideWorkspace = Set<String>()
        func collect(_ dir: URL, depth: Int) {
            for c in FS.children(dir) where !c.lastPathComponent.hasPrefix(".") {
                if idx.projects[c.path] != nil { continue }
                if c.pathExtension == "app" || c.lastPathComponent.hasSuffix(".photoslibrary") || FS.isSymlink(c) { continue }
                if ArtifactRules.allNames.contains(c.lastPathComponent) { continue }
                // Data folders (models/, data/…) move as one unit, even with a vendored checkout inside.
                let isDataName = dataNames.contains(c.lastPathComponent.lowercased())
                if !isDataName && projectPaths.contains(where: { FS.isAncestor(c.path, of: $0) }) {
                    if depth < 3 { collect(c, depth: depth + 1) }
                    continue
                }
                if OffloadGuard.checkSource(c) != nil { continue }
                if depth > 0 { insideWorkspace.insert(c.path) }
                userItems.append(c)
            }
        }
        for f in userFolders { collect(FS.home.appendingPathComponent(f), depth: 0) }
        let userSizes = Sizer.measureMany(userItems)
        for u in userItems {
            guard let m = userSizes[u], m.bytes >= 200 * 1_048_576 else { continue }
            let inner = idx.artifacts.filter { FS.isAncestor(u.path, of: $0.url.path) }
            let innerSkip = inner.reduce(Int64(0)) { $0 + (artSizes[$1.url]?.bytes ?? 0) }
            let used = Spotlight.lastUsed(u) ?? m.newest
            let days = Age.days(used) ?? 999
            let inDownloads = u.path.hasPrefix(FS.home.path + "/Downloads/")
            let isData = dataNames.contains(u.lastPathComponent.lowercased())
            var note = (FS.isDir(u) ? "Folder" : "File") + " · last used \(Fmt.ago(used))"
            if insideWorkspace.contains(u.path) { note += " · sits next to code in \(u.deletingLastPathComponent().lastPathComponent)/, and the link keeps relative paths working" }
            if innerSkip > 0 { note += " · \(Fmt.bytes(innerSkip)) rebuildable stays behind" }
            out.append(OffloadCandidate(url: u, kind: isData && insideWorkspace.contains(u.path) ? .dataFolder : .userFolder,
                                        bytes: max(0, m.bytes - innerSkip), skippable: innerSkip,
                                        lastActivity: used, note: note, defaultLink: !inDownloads, defaultSkip: innerSkip > 0,
                                        isGoodCandidate: days >= 30 || (isData && days >= 7)))
        }
        return out.sorted { ($0.isGoodCandidate ? 0 : 1, -$0.bytes) < ($1.isGoodCandidate ? 0 : 1, -$1.bytes) }
    }
}
